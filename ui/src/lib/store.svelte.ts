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
    // Convert on-disk image paths to data URLs the webview can display.
    await this.#loadImages();
    this.ready = true;
  }

  /** Collects every image path across all cards and fetches them in one batch. */
  async #loadImages() {
    const allPaths: { cardId: string; itemId: string; paths: string[] }[] = [];
    for (const card of this.cards) {
      for (const item of card.items) {
        if (item.images.length > 0) {
          allPaths.push({ cardId: card.id, itemId: item.id, paths: [...item.images] });
        }
      }
    }
    const flat = allPaths.flatMap((e) => e.paths);
    if (flat.length === 0) return;

    const res = await guard(() => ipc.getItemImages(flat), '加载图片失败');
    if (!res.ok) return;
    const urls = res.value;
    let cursor = 0;
    for (const entry of allPaths) {
      const card = this.cards.find((c) => c.id === entry.cardId);
      const item = card?.items.find((i) => i.id === entry.itemId);
      if (!item) {
        cursor += entry.paths.length;
        continue;
      }
      item.images = urls.slice(cursor, cursor + entry.paths.length);
      cursor += entry.paths.length;
    }
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
  async addItem(text: string, images?: string[]): Promise<boolean> {
    const card = this.active;
    const value = text.trim();
    const hasImages = images && images.length > 0;
    if (!card || (!value && !hasImages)) return false;
    const res = await guard(
      () => ipc.addItem(card.id, value || undefined, images),
      '记录失败',
    );
    if (res.ok) {
      // Images arrive back as data URLs (the Rust side saved them to disk and
      // the store layer converted the paths for display).
      const item = res.value;
      if (images && images.length > 0) item.images = images;
      card.items.push(item);
    }
    return res.ok;
  }

  /** Appends a pasted image to an existing item. */
  async addItemImage(item: Item, imageData: string): Promise<boolean> {
    const card = this.active;
    if (!card) return false;
    const res = await guard(
      () => ipc.addItemImage(card.id, item.id, imageData),
      '添加图片失败',
    );
    if (res.ok) item.images.push(imageData);
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

  /** Puts the notebook away. There is no matching `open`: the mascot window
   * asks Rust to toggle, and Rust hides or shows the panel window — this side
   * never tracks a visibility flag that the OS already owns. */
  async close() {
    await guard(() => ipc.closePanel(), '窗口操作失败');
  }

  async togglePinned() {
    const next = !this.pinned;
    this.pinned = next;
    const res = await guard(() => ipc.setPinned(next), '设置失败');
    if (!res.ok) this.pinned = !next;
  }
}

export const workspace = new WorkspaceState();
