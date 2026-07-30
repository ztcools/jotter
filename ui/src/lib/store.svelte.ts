/** Single source of UI truth.
 *
 * Rust owns the durable state, so this class is a thin reactive mirror: every
 * mutation goes through an IPC call and only lands locally once Rust has
 * accepted it. Writes are local (sub-millisecond), so skipping optimistic
 * updates costs nothing and removes a whole class of rollback bugs.
 */

import * as ipc from './ipc';
import type { Card, Item } from './types';

export const ACCENTS = 6;

class Toasts {
  message = $state<string | null>(null);
  tone = $state<'ok' | 'error'>('ok');
  #timer: ReturnType<typeof setTimeout> | undefined;

  show(message: string, tone: 'ok' | 'error' = 'ok') {
    this.message = message;
    this.tone = tone;
    clearTimeout(this.#timer);
    this.#timer = setTimeout(() => (this.message = null), tone === 'error' ? 3200 : 1600);
  }
}

export const toasts = new Toasts();

/** Outcome of a guarded call.
 *
 * Tagged rather than `T | undefined`: half the commands return nothing, so a
 * plain `undefined` sentinel would read every successful void call as a failure
 * and roll the edit straight back out again. */
type Outcome<T> = { ok: true; value: T } | { ok: false };

/** Wraps an IPC call so a failure surfaces as a toast instead of an unhandled
 * rejection in a window the user cannot open devtools on. */
async function guard<T>(action: () => Promise<T>, failure: string): Promise<Outcome<T>> {
  try {
    return { ok: true, value: await action() };
  } catch (err) {
    console.error(failure, err);
    toasts.show(`${failure}：${String(err)}`, 'error');
    return { ok: false };
  }
}

class WorkspaceState {
  cards = $state<Card[]>([]);
  activeId = $state<string | null>(null);
  pinned = $state(false);
  expanded = $state(false);
  ready = $state(false);

  active = $derived(this.cards.find((c) => c.id === this.activeId) ?? null);
  items = $derived(this.active?.items ?? []);
  openCount = $derived(this.items.filter((i) => !i.done).length);
  /** Unfinished items across every card — what the ball's badge reports. */
  totalOpen = $derived(
    this.cards.reduce((sum, c) => sum + c.items.filter((i) => !i.done).length, 0),
  );

  async load() {
    const res = await guard(() => ipc.loadWorkspace(), '读取数据失败');
    if (!res.ok) return;
    this.cards = res.value.cards;
    this.activeId = res.value.activeCardId;
    this.pinned = res.value.pinned;
    this.ready = true;
  }

  // ------------------------------------------------------------------- cards

  async newCard() {
    const res = await guard(() => ipc.createCard(), '新建卡片失败');
    if (!res.ok) return;
    this.cards.push(res.value);
    this.activeId = res.value.id;
  }

  async selectCard(id: string) {
    if (id === this.activeId) return;
    const previous = this.activeId;
    this.activeId = id;
    const res = await guard(() => ipc.setActiveCard(id), '切换卡片失败');
    if (!res.ok) this.activeId = previous;
  }

  async renameCard(id: string, title: string) {
    const card = this.cards.find((c) => c.id === id);
    const next = title.trim();
    if (!card || !next || next === card.title) return;
    const previous = card.title;
    card.title = next;
    const res = await guard(() => ipc.renameCard(id, next), '重命名失败');
    if (!res.ok) card.title = previous;
  }

  async removeCard(id: string) {
    const res = await guard(() => ipc.deleteCard(id), '删除卡片失败');
    if (!res.ok) return;
    this.cards = res.value.cards;
    this.activeId = res.value.activeCardId;
  }

  /** Cycles to the next card, wrapping around. */
  async cycleCard(step: 1 | -1) {
    if (this.cards.length < 2) return;
    const index = this.cards.findIndex((c) => c.id === this.activeId);
    const next = this.cards[(index + step + this.cards.length) % this.cards.length];
    if (next) await this.selectCard(next.id);
  }

  // ------------------------------------------------------------------- items

  /** Reports whether the line landed, so the composer can keep the text on the
   * screen instead of swallowing it when the write fails. */
  async addItem(text: string): Promise<boolean> {
    const card = this.active;
    const value = text.trim();
    if (!card || !value) return false;
    const res = await guard(() => ipc.addItem(card.id, value), '记录失败');
    if (res.ok) card.items.push(res.value);
    return res.ok;
  }

  async toggleItem(item: Item) {
    const card = this.active;
    if (!card) return;
    const next = !item.done;
    item.done = next;
    const res = await guard(() => ipc.updateItem(card.id, item.id, { done: next }), '更新失败');
    if (!res.ok) item.done = !next;
  }

  async editItem(item: Item, text: string) {
    const card = this.active;
    const value = text.trim();
    if (!card || !value || value === item.text) return;
    const previous = item.text;
    item.text = value;
    const res = await guard(() => ipc.updateItem(card.id, item.id, { text: value }), '更新失败');
    if (!res.ok) item.text = previous;
  }

  async removeItem(item: Item) {
    const card = this.active;
    if (!card) return;
    const res = await guard(() => ipc.deleteItem(card.id, item.id), '删除失败');
    if (res.ok) card.items = card.items.filter((i) => i.id !== item.id);
  }

  async clearDone() {
    const card = this.active;
    if (!card) return;
    const res = await guard(() => ipc.clearDone(card.id), '清理失败');
    if (!res.ok) return;
    card.items = card.items.filter((i) => !i.done);
    toasts.show(res.value > 0 ? `已清理 ${res.value} 条` : '没有已完成的条目');
  }

  // ------------------------------------------------------------------ window

  async setExpanded(expanded: boolean) {
    if (this.expanded === expanded) return;
    const res = await guard(() => ipc.togglePanel(expanded), '窗口操作失败');
    if (res.ok) this.expanded = expanded;
  }

  /** Applies a state change that Rust initiated (tray, shortcut, focus loss). */
  syncExpanded(expanded: boolean) {
    this.expanded = expanded;
  }

  async togglePinned() {
    const next = !this.pinned;
    this.pinned = next;
    const res = await guard(() => ipc.setPinned(next), '设置失败');
    if (!res.ok) this.pinned = !next;
  }
}

export const workspace = new WorkspaceState();
