/** Typed wrappers around the Rust command surface. The rest of the UI never
 * calls `invoke` directly, so command names and payload shapes live in one
 * place. */

import { invoke } from '@tauri-apps/api/core';
import type { Card, Item, Workspace } from './types';

export const loadWorkspace = () => invoke<Workspace>('load_workspace');

export const createCard = (title?: string) => invoke<Card>('create_card', { title });

export const renameCard = (cardId: string, title: string) =>
  invoke<void>('rename_card', { cardId, title });

export const deleteCard = (cardId: string) => invoke<Workspace>('delete_card', { cardId });

export const setActiveCard = (cardId: string) => invoke<void>('set_active_card', { cardId });

export const addItem = (cardId: string, text: string) => invoke<Item>('add_item', { cardId, text });

export const updateItem = (
  cardId: string,
  itemId: string,
  patch: { text?: string; done?: boolean },
) => invoke<void>('update_item', { cardId, itemId, text: patch.text, done: patch.done });

export const deleteItem = (cardId: string, itemId: string) =>
  invoke<void>('delete_item', { cardId, itemId });

export const clearDone = (cardId: string) => invoke<number>('clear_done', { cardId });

export const copyText = (text: string) => invoke<void>('copy_text', { text });

export const writeTextFile = (path: string, text: string) =>
  invoke<void>('write_text_file', { path, text });

/** Rust owns the open/closed state — see the `toggle_panel` command for why the
 * webview must not compute one and pass it in. */
export const togglePanel = () => invoke<void>('toggle_panel');

export const closePanel = () => invoke<void>('close_panel');

export const setPinned = (pinned: boolean) => invoke<void>('set_pinned', { pinned });

/** Bracket any native dialog with this, or the focus it steals collapses the
 * panel before the dialog can be answered. */
export const suspendAutoCollapse = (suspend: boolean) =>
  invoke<void>('suspend_auto_collapse', { suspend });

export const hideWidget = () => invoke<void>('hide_widget');

export const quitApp = () => invoke<void>('quit_app');

/** Sends a webview failure to the app log. See `lib/errors.ts`. */
export const reportError = (message: string, detail?: string) =>
  invoke<void>('report_error', { message, detail });
