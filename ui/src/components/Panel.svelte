<!-- The expanded notebook. Fixed height by design: this is a capture surface for
     short findings, not an editor, and a small window stays out of the way of
     the UI being reviewed. -->
<script lang="ts">
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import CardTabs from './CardTabs.svelte';
  import Composer from './Composer.svelte';
  import Icon from './Icon.svelte';
  import ItemList from './ItemList.svelte';
  import Toast from './Toast.svelte';
  import Toolbar from './Toolbar.svelte';
  import * as ipc from '../lib/ipc';
  import { workspace } from '../lib/store.svelte';

  let menuOpen = $state(false);

  function onHeaderPointerDown(event: PointerEvent) {
    // Buttons inside the header handle their own presses.
    if (event.button !== 0 || (event.target as HTMLElement).closest('button')) return;
    void getCurrentWindow().startDragging();
  }
</script>

<div class="panel">
  <!-- The header is a window drag handle, not a control: pointer-only by
       nature, and every actual action inside it is a real button. -->
  <!-- svelte-ignore a11y_no_static_element_interactions -->
  <header class="head" onpointerdown={onHeaderPointerDown}>
    <span class="brand">
      <span class="mark"></span>
      Jotter
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
        class="icon"
        onclick={() => (menuOpen = !menuOpen)}
        title="更多"
        aria-label="更多"
        aria-expanded={menuOpen}
      >
        <Icon name="dots" />
      </button>
      <button
        class="icon"
        onclick={() => workspace.setExpanded(false)}
        title="收起为悬浮球（Esc）"
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
  <ItemList />
  <Composer />
  <Toolbar />
  <Toast />
</div>

<style>
  .panel {
    position: relative;
    width: 100%;
    height: 100%;
    display: flex;
    flex-direction: column;
    /* The transparent gutter the drop shadow renders into. */
    margin: 0;
    border-radius: var(--r-panel);
    background: var(--surface);
    box-shadow:
      var(--shadow-panel),
      inset 0 0 0 1px var(--hairline);
    overflow: hidden;
    /* Rounded corners on a transparent window need the backdrop clipped too. */
    isolation: isolate;
  }

  .head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex: none;
    height: 34px;
    padding: 0 6px 0 12px;
    cursor: grab;
  }

  .head:active {
    cursor: grabbing;
  }

  .brand {
    display: inline-flex;
    align-items: center;
    gap: 7px;
    font-size: 11.5px;
    font-weight: 700;
    letter-spacing: 0.04em;
    color: var(--text-faint);
  }

  .mark {
    width: 8px;
    height: 8px;
    border-radius: 3px;
    background: linear-gradient(140deg, var(--accent), var(--accent-2));
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
