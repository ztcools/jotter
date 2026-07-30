<!--
  The collapsed widget. One gesture handler serves two purposes: a press that
  travels more than a few pixels becomes an OS window drag, anything shorter is
  a click that opens the panel. Without the threshold, `startDragging` would
  swallow every click, since the OS drag loop takes over the pointer.
-->
<script lang="ts">
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import { workspace } from '../lib/store.svelte';

  /** Pointer travel, in CSS pixels, before a press counts as a drag. */
  const DRAG_THRESHOLD = 4;

  let pressed = $state(false);

  function onPointerDown(event: PointerEvent) {
    if (event.button !== 0) return;
    event.preventDefault();
    pressed = true;

    const originX = event.screenX;
    const originY = event.screenY;
    let dragging = false;

    const cleanup = () => {
      pressed = false;
      window.removeEventListener('pointermove', onMove);
      window.removeEventListener('pointerup', onUp);
      window.removeEventListener('pointercancel', onUp);
    };

    const onMove = (move: PointerEvent) => {
      if (dragging) return;
      const travelled = Math.hypot(move.screenX - originX, move.screenY - originY);
      if (travelled <= DRAG_THRESHOLD) return;
      dragging = true;
      cleanup();
      void getCurrentWindow().startDragging();
    };

    const onUp = () => {
      cleanup();
      if (!dragging) void workspace.setExpanded(true);
    };

    window.addEventListener('pointermove', onMove);
    window.addEventListener('pointerup', onUp);
    window.addEventListener('pointercancel', onUp);
  }
</script>

<div class="stage">
  <button
    class="ball"
    class:pressed
    onpointerdown={onPointerDown}
    title="Jotter — 单击展开，拖动移位（Ctrl+Alt+J）"
    aria-label="展开 Jotter 记录面板"
  >
    <svg viewBox="0 0 24 24" fill="none" aria-hidden="true">
      <path
        d="M7.5 4.5h9a1.5 1.5 0 0 1 1.5 1.5v12a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 6 18V6a1.5 1.5 0 0 1 1.5-1.5Z"
        fill="rgba(255,255,255,.22)"
      />
      <path
        d="m9 11.6 1.9 1.9L15.4 9"
        stroke="#fff"
        stroke-width="2.1"
        stroke-linecap="round"
        stroke-linejoin="round"
      />
      <path d="M9.2 16.4h5.6" stroke="rgba(255,255,255,.8)" stroke-width="1.8" stroke-linecap="round" />
    </svg>
    {#if workspace.totalOpen > 0}
      <span class="badge">{workspace.totalOpen > 99 ? '99+' : workspace.totalOpen}</span>
    {/if}
  </button>
</div>

<style>
  .stage {
    width: 100%;
    height: 100%;
    display: grid;
    place-items: center;
  }

  .ball {
    position: relative;
    width: 56px;
    height: 56px;
    border-radius: 50%;
    background: linear-gradient(140deg, var(--accent), var(--accent-2));
    box-shadow:
      var(--shadow-ball),
      inset 0 1px 0 rgba(255, 255, 255, 0.35),
      inset 0 -2px 6px rgba(0, 0, 0, 0.12);
    transition:
      transform var(--dur) var(--ease),
      box-shadow var(--dur) var(--ease);
  }

  .ball:hover {
    transform: scale(1.07);
    box-shadow:
      0 10px 26px rgba(60, 50, 160, 0.42),
      inset 0 1px 0 rgba(255, 255, 255, 0.4);
  }

  /* Overrides the global button:active scale so drag and click feel identical. */
  .ball.pressed,
  .ball:active {
    transform: scale(0.93);
  }

  .ball svg {
    width: 26px;
    height: 26px;
  }

  .badge {
    position: absolute;
    top: -2px;
    right: -2px;
    min-width: 19px;
    height: 19px;
    padding: 0 5px;
    border-radius: var(--r-pill);
    background: #fff;
    color: var(--accent);
    font-size: 11px;
    font-weight: 700;
    line-height: 19px;
    box-shadow: 0 1px 4px rgba(20, 20, 45, 0.28);
  }

  @media (prefers-color-scheme: dark) {
    .badge {
      background: #f2f2f7;
    }
  }
</style>
