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
  /** True while the cat is playing one burst of movement. Nothing in this window
   * animates continuously: on a transparent always-on-top window a running
   * animation costs a quarter to a half of a CPU core however small it is, and a
   * still one costs about a hundredth. See the animation note in `Cat.svelte`. */
  let stir = $state(false);

  /** Longer than the longest keyframe in `Cat.svelte`, so a burst is never cut
   * off part-way through a movement. */
  const BURST_MS = 1500;
  /** Gap between unprompted bursts, jittered so the cat does not tick like a
   * clock. At this duty cycle being alive costs about a point of one core more
   * than being still. */
  const IDLE_MIN_MS = 19_000;
  const IDLE_JITTER_MS = 11_000;

  let burstTimer: ReturnType<typeof setTimeout> | undefined;
  let idleTimer: ReturnType<typeof setTimeout> | undefined;

  /** Plays one burst, restarting it if one is already running.
   *
   * The class has to leave the DOM and come back for CSS keyframes to restart,
   * which is why this drops `stir` and sets it in the next frame rather than
   * simply assigning `true`. */
  function stirOnce() {
    // A hidden window composites nothing, and waking it to animate off-screen is
    // the one truly wasted frame. One gate for every trigger, so asking for
    // reduced motion really does mean a mascot that never moves.
    if (document.visibilityState === 'hidden') return;
    if (window.matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    clearTimeout(burstTimer);
    stir = false;
    requestAnimationFrame(() => {
      stir = true;
      burstTimer = setTimeout(() => (stir = false), BURST_MS);
    });
  }

  /** Chained timeouts rather than an interval, so the gap can be re-jittered
   * each time. */
  function scheduleIdleStir() {
    idleTimer = setTimeout(
      () => {
        stirOnce();
        scheduleIdleStir();
      },
      IDLE_MIN_MS + Math.random() * IDLE_JITTER_MS,
    );
  }

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
    // A new finding and the notebook opening are both worth a look up from the
    // cat; a finding being ticked off is not, or clearing a card would set the
    // mascot dancing.
    track<number>('badge', (count) => {
      if (count > badge) stirOnce();
      badge = count;
    });
    track<boolean>('panel-state', (open) => {
      panelOpen = open;
      stirOnce();
    });

    // First paint has no event to wait for; one snapshot read seeds the badge.
    void ipc
      .loadWorkspace()
      .then((ws) => {
        badge = ws.cards.reduce((sum, c) => sum + c.items.filter((i) => !i.done).length, 0);
      })
      .catch(() => {});

    // One burst on arrival, then on its own schedule: the cat stretches when the
    // widget appears.
    stirOnce();
    scheduleIdleStir();

    return () => {
      disposers.forEach((off) => off());
      clearTimeout(burstTimer);
      clearTimeout(idleTimer);
    };
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
    onpointerenter={stirOnce}
    title={label}
    aria-label={label}
    aria-pressed={panelOpen}
  >
    <Cat {pressed} {stir} open={panelOpen} />
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
     eye without the mascot having to shout. Static, not pulsing — the badge is
     usually non-zero, so a pulse here would be the one animation that runs all
     day, at a quarter of a core. */
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
    opacity: 0.62;
    pointer-events: none;
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
</style>
