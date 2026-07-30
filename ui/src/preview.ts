/**
 * Entry point for `preview.html` — see that file for why this exists.
 *
 * Installs a stub of the Tauri IPC bridge before anything imports the app, so
 * the real components run unmodified against fixture data in a plain browser.
 */

import './app.css';
import type { Card, Item, Workspace } from './lib/types';

const seed = (title: string, accent: number, lines: Array<[string, boolean]>): Card => ({
  id: `card-${accent}`,
  title,
  accent,
  createdAt: Date.now(),
  updatedAt: Date.now(),
  items: lines.map<Item>(([text, done], i) => ({
    id: `${accent}-${i}`,
    text,
    done,
    createdAt: Date.now(),
  })),
});

const fixture: Workspace = {
  version: 1,
  activeCardId: 'card-0',
  pinned: false,
  ballPosition: null,
  cards: [
    seed('首页改版', 0, [
      ['主按钮圆角 8px，卡片是 12px，视觉上不成体系', false],
      ['头像加载时会闪一下白底，缺骨架占位', false],
      ['滚动到 banner 底部时导航栏背景切换没有过渡', true],
      ['移动端 375 宽度下副标题换行成三行，挤掉了 CTA', false],
    ]),
    seed('登录流程', 1, [['验证码倒计时结束后按钮仍是灰的', false]]),
    seed('结算页', 2, []),
  ],
};

let nextId = 100;

/** Minimal in-memory stand-in for the Rust command surface. */
function handle(cmd: string, args: Record<string, unknown>): unknown {
  const active = fixture.cards.find((c) => c.id === fixture.activeCardId);
  switch (cmd) {
    case 'load_workspace':
      return fixture;
    case 'set_active_card':
      fixture.activeCardId = args.cardId as string;
      return undefined;
    case 'create_card': {
      const card = seed(`卡片 ${fixture.cards.length + 1}`, fixture.cards.length % 6, []);
      card.id = `card-new-${nextId++}`;
      fixture.cards.push(card);
      fixture.activeCardId = card.id;
      return card;
    }
    case 'add_item': {
      const item: Item = {
        id: `i-${nextId++}`,
        text: args.text as string,
        done: false,
        createdAt: Date.now(),
      };
      active?.items.push(item);
      return item;
    }
    case 'clear_done': {
      const before = active?.items.length ?? 0;
      if (active) active.items = active.items.filter((i) => !i.done);
      return before - (active?.items.length ?? 0);
    }
    // Window and clipboard commands are no-ops in the browser.
    default:
      return undefined;
  }
}

// The shape `@tauri-apps/api` v2 probes for. Kept to the minimum the app touches.
Object.defineProperty(window, '__TAURI_INTERNALS__', {
  value: {
    metadata: { currentWindow: { label: 'main' }, currentWebview: { label: 'main' } },
    transformCallback: (cb: unknown) => cb,
    invoke: async (cmd: string, args: Record<string, unknown> = {}) => handle(cmd, args),
  },
});

const params = new URLSearchParams(location.search);
const ball = params.get('state') === 'ball';

// `?card=2` opens a different fixture card — index 2 is empty, which is the
// state a first launch shows.
const card = Number(params.get('card') ?? 0);
if (fixture.cards[card]) fixture.activeCardId = fixture.cards[card].id;
const target = document.getElementById('app');
if (!target) throw new Error('mount target #app is missing');

// Pin the surface to the top-left at exactly the size Rust gives the real
// window. Headless Chrome does not reliably honour `--window-size`, so anything
// centred in the viewport can fall outside the screenshot crop.
const [w, h] = ball ? [72, 72] : [368, 476];
target.style.cssText = `position:fixed;left:0;top:0;width:${w}px;height:${h}px`;

const { mount } = await import('svelte');
const App = (await import('./App.svelte')).default;
const { workspace } = await import('./lib/store.svelte');

mount(App, { target });

// The harness has no Rust side to drive window state, so set it directly.
if (!ball) workspace.syncExpanded(true);
