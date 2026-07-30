<!--
  Root of the notebook window — a side-bound paper notepad: ring-punched spine,
  warm page, and the capture line pinned at the bottom where the caret already
  is.

  This document only ever renders the open state. Rust owns whether the window
  is visible, anchors it beside the mascot and keeps it there while the mascot is
  dragged, so there is no collapsed variant and no visibility flag to keep in
  sync here.
-->
<script lang="ts">
  import { onMount } from 'svelte';
  import { listen } from '@tauri-apps/api/event';
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import CardTabs from './components/CardTabs.svelte';
  import Composer from './components/Composer.svelte';
  import Icon from './components/Icon.svelte';
  import ItemList from './components/ItemList.svelte';
  import Toast from './components/Toast.svelte';
  import Toolbar from './components/Toolbar.svelte';
  import * as ipc from './lib/ipc';
  import { workspace } from './lib/store.svelte';

  let menuOpen = $state(false);

  onMount(() => {
    void workspace.load();

    const disposers: Array<() => void> = [];
    const track = <T,>(event: string, run: (payload: T) => void) => {
      void listen<T>(event, (e) => run(e.payload)).then((off) => disposers.push(off));
    };
    // The window is hidden rather than destroyed when it closes, so a reopen
    // re-reads the document: the tray can add a card while this webview sits
    // idle in the background.
    track<boolean>('panel-state', (open) => {
      if (open) void workspace.load();
    });
    track('workspace-changed', () => void workspace.load());

    return () => disposers.forEach((off) => off());
  });

  /** The header and spine are the window's drag handle — the panel has no title
   * bar of its own. Real controls inside them keep their own presses. */
  function onDragHandle(event: PointerEvent) {
    if (event.button !== 0 || (event.target as HTMLElement).closest('button, input')) return;
    void getCurrentWindow().startDragging();
  }

  /** A menu that only closes when the pointer leaves it stays open if the pointer
   * never went in — opened from the keyboard, or dismissed by clicking elsewhere.
   * Any press outside it counts as dismissal. */
  function onWindowPointerDown(event: PointerEvent) {
    if (!menuOpen) return;
    if ((event.target as HTMLElement).closest('.menu, .more')) return;
    menuOpen = false;
  }

  function onKeydown(event: KeyboardEvent) {
    if (event.key === 'Escape') {
      event.preventDefault();
      // Escape unwinds one layer at a time; putting the whole notebook away while
      // a menu is open would be one keystroke doing two things.
      if (menuOpen) {
        menuOpen = false;
        return;
      }
      void workspace.close();
      return;
    }
    if (!event.ctrlKey) return;

    if (event.key === 'n' || event.key === 'N') {
      event.preventDefault();
      void workspace.newCard();
    } else if (event.key === 'Tab') {
      event.preventDefault();
      void workspace.cycleCard(event.shiftKey ? -1 : 1);
    }
  }

  /** Suppressed except in text fields, where the native menu still carries
   * cut/copy/paste. */
  function onContextMenu(event: MouseEvent) {
    if (!(event.target as HTMLElement).closest('input, textarea')) event.preventDefault();
  }
</script>

<svelte:window
  onkeydown={onKeydown}
  oncontextmenu={onContextMenu}
  onpointerdown={onWindowPointerDown}
/>

<div class="stage">
  <div class="book">
    <!-- svelte-ignore a11y_no_static_element_interactions -->
    <div class="spine" onpointerdown={onDragHandle}>
      {#each [0, 1, 2, 3, 4] as ring (ring)}
        <span class="ring"></span>
      {/each}
    </div>

    <div class="page">
      <!-- svelte-ignore a11y_no_static_element_interactions -->
      <header class="head" onpointerdown={onDragHandle}>
        <span class="brand">
          <!-- The mascot in miniature: two ears and a face, at 15px. -->
          <svg class="mark" viewBox="0 0 24 24" aria-hidden="true">
            <path d="M6 9 4.5 3 10 6ZM18 9 19.5 3 14 6Z" />
            <ellipse cx="12" cy="14" rx="8.5" ry="7.5" />
            <circle class="mark-eye" cx="9.2" cy="13.4" r="1.5" />
            <circle class="mark-eye" cx="14.8" cy="13.4" r="1.5" />
          </svg>
          <span>Jotter</span>
        </span>

        <div class="head-actions">
          <button
            class="icon"
            class:on={workspace.pinned}
            onclick={() => workspace.togglePinned()}
            title={workspace.pinned ? '已固定：点击外部不会收起' : '固定面板（点击外部不收起）'}
            aria-pressed={workspace.pinned}
            aria-label="固定面板"
          >
            <Icon name="pin" />
          </button>
          <button
            class="icon more"
            onclick={() => (menuOpen = !menuOpen)}
            title="更多"
            aria-label="更多"
            aria-expanded={menuOpen}
          >
            <Icon name="dots" />
          </button>
          <button
            class="icon"
            onclick={() => workspace.close()}
            title="收起为小猫（Esc）"
            aria-label="收起"
          >
            <Icon name="x" />
          </button>

          {#if menuOpen}
            <!-- svelte-ignore a11y_no_static_element_interactions -->
            <div class="menu" onpointerleave={() => (menuOpen = false)}>
              <button
                onclick={() => {
                  menuOpen = false;
                  void ipc.hideWidget();
                }}
              >
                隐藏挂件<kbd>Ctrl+Alt+J</kbd>
              </button>
              <button class="danger" onclick={() => void ipc.quitApp()}>
                <Icon name="power" size={13} />退出 Jotter
              </button>
            </div>
          {/if}
        </div>
      </header>

      <CardTabs />
      <div class="paper"><ItemList /></div>
      <Composer />
      <Toolbar />
    </div>

    <Toast />
  </div>
</div>

<style>
  .stage {
    width: 100%;
    height: 100%;
    /* Transparent gutter the panel's drop shadow renders into. */
    padding: var(--bleed);
    animation: rise 190ms var(--ease);
  }

  @keyframes rise {
    from {
      opacity: 0;
      transform: scale(0.97);
    }
    to {
      opacity: 1;
      transform: scale(1);
    }
  }

  .book {
    position: relative;
    width: 100%;
    height: 100%;
    display: flex;
    border-radius: var(--r-panel);
    background: var(--paper);
    box-shadow:
      var(--shadow-panel),
      inset 0 0 0 1px var(--hairline);
    overflow: hidden;
    /* Rounded corners over a transparent window need the backdrop clipped. */
    isolation: isolate;
  }

  /* Ring-punched binding, and the widest part of the drag handle. */
  .spine {
    flex: none;
    width: 23px;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: space-evenly;
    padding: 12px 0;
    background: linear-gradient(
      160deg,
      color-mix(in oklab, var(--accent) 22%, var(--paper)),
      color-mix(in oklab, var(--accent-2) 16%, var(--paper))
    );
    border-right: 1px solid var(--hairline);
    cursor: grab;
  }

  .spine:active {
    cursor: grabbing;
  }

  .ring {
    width: 9px;
    height: 9px;
    border-radius: 50%;
    background: var(--paper);
    box-shadow:
      inset 0 1px 2px rgba(30, 25, 60, 0.28),
      0 1px 0 rgba(255, 255, 255, 0.5);
  }

  .page {
    flex: 1;
    min-width: 0;
    display: flex;
    flex-direction: column;
  }

  .head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex: none;
    height: 34px;
    padding: 0 6px 0 10px;
    cursor: grab;
  }

  .head:active {
    cursor: grabbing;
  }

  .brand {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    font-size: 11.5px;
    font-weight: 700;
    letter-spacing: 0.04em;
    color: var(--text-faint);
  }

  .mark {
    width: 15px;
    height: 15px;
    fill: color-mix(in oklab, var(--accent) 55%, var(--text-faint));
  }

  .mark-eye {
    fill: var(--paper);
  }

  .head-actions {
    position: relative;
    display: inline-flex;
    align-items: center;
    gap: 1px;
  }

  .icon {
    width: 24px;
    height: 24px;
    color: var(--text-faint);
  }

  .icon:hover {
    background: var(--surface-hover);
    color: var(--text);
  }

  .icon.on {
    color: var(--accent);
    background: color-mix(in oklab, var(--accent) 14%, transparent);
  }

  /* The written-on part of the page. A dotted grid rather than ruled lines:
     rows here wrap to whatever height the note needs, and ruled lines that do
     not line up with the text look like a mistake. */
  .paper {
    flex: 1;
    min-height: 0;
    display: flex;
    margin: 0 8px;
    border-radius: var(--r-card);
    background-image: radial-gradient(var(--paper-dot) 1px, transparent 1px);
    background-size: 15px 15px;
    background-position: 6px 6px;
  }

  .menu {
    position: absolute;
    top: 28px;
    right: 0;
    z-index: 20;
    min-width: 176px;
    padding: 4px;
    border-radius: var(--r-card);
    background: var(--surface);
    box-shadow:
      var(--shadow-panel),
      inset 0 0 0 1px var(--hairline);
  }

  .menu button {
    width: 100%;
    height: 28px;
    padding: 0 8px;
    justify-content: flex-start;
    gap: 7px;
    border-radius: 8px;
    font-size: 12px;
    color: var(--text-dim);
  }

  .menu button:hover {
    background: var(--surface-hover);
    color: var(--text);
  }

  .menu button.danger:hover {
    background: color-mix(in oklab, var(--danger) 14%, transparent);
    color: var(--danger);
  }

  .menu kbd {
    margin-left: auto;
    font: inherit;
    font-size: 10px;
    color: var(--text-faint);
  }
</style>
