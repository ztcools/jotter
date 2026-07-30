<!--
  Root of the mascot window.

  Two responsibilities: turn a press into either a window drag or a panel
  toggle, and mirror the two facts Rust pushes at it — how many findings are
  still open, and whether the notebook is showing.

  It deliberately does not import the workspace store. This window is on screen
  the entire time the app runs, so it holds one number instead of the whole
  document, and the badge stays correct no matter who changed the data (the
  panel, the tray, or the global shortcut).
-->
<script lang="ts">
  import { onMount } from 'svelte';
  import { listen } from '@tauri-apps/api/event';
  import Cat from './components/Cat.svelte';
  import { pressToDrag } from './lib/drag';
  import * as ipc from './lib/ipc';

  let pressed = $state(false);
  let panelOpen = $state(false);
  let badge = $state(0);

  let label = $derived(
    panelOpen
      ? '点击收起记事本 · 拖动可移动'
      : badge > 0
        ? `还有 ${badge} 条未解决 · 点击打开记事本，拖动可移动`
        : 'Jotter — 点击打开记事本，拖动可移动（Ctrl+Alt+J）',
  );

  onMount(() => {
    // `app.emit` broadcasts, so a global listener is the right scope here: these
    // events originate in Rust and are not addressed to this webview.
    const disposers: Array<() => void> = [];
    const track = <T,>(event: string, run: (payload: T) => void) => {
      void listen<T>(event, (e) => run(e.payload)).then((off) => disposers.push(off));
    };
    track<number>('badge', (count) => (badge = count));
    track<boolean>('panel-state', (open) => (panelOpen = open));

    // First paint has no event to wait for; one snapshot read seeds the badge.
    void ipc
      .loadWorkspace()
      .then((ws) => {
        badge = ws.cards.reduce((sum, c) => sum + c.items.filter((i) => !i.done).length, 0);
      })
      .catch(() => {});

    return () => disposers.forEach((off) => off());
  });

  function onPointerDown(event: PointerEvent) {
    if (event.button !== 0) return;
    event.preventDefault();
    pressed = true;
    // Only a click toggles the notebook — dragging the cat moves it and leaves
    // the notebook exactly as it was, open or shut.
    pressToDrag(event, {
      // `onEnd` also runs when the drag is handed to the OS, where no
      // `pointerup` ever comes back; without it the cat stays squashed for good.
      onEnd: () => (pressed = false),
      onClick: () => void ipc.togglePanel(),
    });
  }
</script>

<!-- A desktop widget with a browser context menu looks broken; the tray icon is
     the menu. -->
<svelte:window oncontextmenu={(e: Event) => e.preventDefault()} />

<div class="stage">
  <button
    class="hit"
    class:lit={badge > 0}
    onpointerdown={onPointerDown}
    title={label}
    aria-label={label}
    aria-pressed={panelOpen}
  >
    <Cat {pressed} open={panelOpen} />
    {#if badge > 0}
      <span class="badge">{badge > 99 ? '99+' : badge}</span>
    {/if}
  </button>
</div>

<style>
  .stage {
    width: 100%;
    height: 100%;
    display: grid;
    place-items: center;
    /* The mascot's own drop shadow renders into this gutter. */
    padding: calc(var(--bleed) - 2px);
  }

  .hit {
    position: relative;
    width: 100%;
    height: 100%;
    padding: 0;
    border-radius: 50%;
    background: none;
    cursor: pointer;
  }

  /* The global press-scale would fight the mascot's own squash. */
  .hit:active:not(:disabled) {
    transform: none;
  }

  .hit:focus-visible {
    outline: 2px solid var(--accent);
    outline-offset: -2px;
  }

  /* A faint halo while anything is unresolved: readable from the corner of the
     eye without the mascot having to shout. */
  .lit::before {
    content: '';
    position: absolute;
    inset: 14% 6% 4%;
    border-radius: 50%;
    background: radial-gradient(
      circle,
      color-mix(in oklab, var(--accent) 30%, transparent) 0%,
      transparent 70%
    );
    animation: pulse 2.8s var(--ease) infinite alternate;
    pointer-events: none;
  }

  @keyframes pulse {
    from {
      opacity: 0.35;
    }
    to {
      opacity: 0.8;
    }
  }

  .badge {
    position: absolute;
    top: 2px;
    right: 0;
    min-width: 18px;
    height: 18px;
    padding: 0 5px;
    display: grid;
    place-items: center;
    border-radius: var(--r-pill);
    background: linear-gradient(140deg, var(--accent), var(--accent-2));
    box-shadow:
      0 2px 6px rgba(40, 30, 90, 0.35),
      0 0 0 2px rgba(255, 255, 255, 0.9);
    font-size: 10.5px;
    font-weight: 700;
    line-height: 1;
    color: #fff;
    font-variant-numeric: tabular-nums;
  }

  @media (prefers-color-scheme: dark) {
    .badge {
      box-shadow:
        0 2px 6px rgba(0, 0, 0, 0.5),
        0 0 0 2px rgba(28, 28, 36, 0.9);
    }
  }

  @media (prefers-reduced-motion: reduce) {
    .lit::before {
      animation: none;
      opacity: 0.55;
    }
  }
</style>
