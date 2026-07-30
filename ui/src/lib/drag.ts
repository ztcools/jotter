/**
 * Turning a press into either a window drag or a click.
 *
 * `startDragging` hands the pointer to the OS move loop, which never returns a
 * `pointerup` to the webview. A handle that calls it on `pointerdown` therefore
 * cannot tell a click from a drag — every click on that surface is swallowed,
 * and on Windows the activation churn of entering the move loop also blurs the
 * window, which for the notebook means it puts itself away on a plain click.
 *
 * Waiting for a few pixels of travel before handing over is what keeps both
 * gestures alive on the same surface. Both windows drag, so this lives here
 * rather than being written twice.
 */
import { getCurrentWindow } from '@tauri-apps/api/window';

/** Pointer travel, in CSS pixels, that separates a click from a drag. Small
 * enough that a deliberate drag never feels sticky, large enough to survive the
 * hand tremor in a click. */
export const DRAG_THRESHOLD = 4;

export interface PressHandlers {
  /** The press ended without ever crossing the threshold. */
  onClick?: () => void;
  /** The press became a window drag. */
  onDrag?: () => void;
  /** The press is over, whichever way it went. Always runs. */
  onEnd?: () => void;
}

/** Call from a `pointerdown` handler on a drag surface. */
export function pressToDrag(event: PointerEvent, handlers: PressHandlers = {}) {
  // Screen coordinates, not client: the window moves during a drag, so client
  // coordinates would measure the pointer against a moving frame.
  const originX = event.screenX;
  const originY = event.screenY;
  let dragging = false;

  const cleanup = () => {
    window.removeEventListener('pointermove', onMove);
    window.removeEventListener('pointerup', onUp);
    window.removeEventListener('pointercancel', onUp);
    handlers.onEnd?.();
  };

  const onMove = (move: PointerEvent) => {
    if (dragging) return;
    if (Math.hypot(move.screenX - originX, move.screenY - originY) <= DRAG_THRESHOLD) return;
    dragging = true;
    // Listeners come off before handing over: once the OS move loop owns the
    // pointer this webview stops seeing events, so anything still waiting for a
    // `pointerup` would wait forever.
    cleanup();
    handlers.onDrag?.();
    void getCurrentWindow().startDragging();
  };

  const onUp = () => {
    cleanup();
    if (!dragging) handlers.onClick?.();
  };

  window.addEventListener('pointermove', onMove);
  window.addEventListener('pointerup', onUp);
  window.addEventListener('pointercancel', onUp);
}
