/**
 * Makes webview failures visible after shipping.
 *
 * A release build has no menu bar and no devtools, so an uncaught exception here
 * is completely silent: the window simply stops updating. Both windows install
 * this first thing, which sends the failure to `Jotter.log` through Rust and
 * parks a copy on `window.__jotterErrors` for `scripts/acceptance.ps1` to read
 * over CDP.
 */

import * as ipc from './ipc';

declare global {
  interface Window {
    /** Created on first failure only, so its mere absence is the pass signal. */
    __jotterErrors?: string[];
  }
}

/** Enough to see a pattern, few enough that a render loop gone wrong cannot eat
 * the heap one error string at a time. */
const KEEP = 20;

function record(message: string, detail?: string) {
  const list = (window.__jotterErrors ??= []);
  if (list.length < KEEP) list.push(detail ? `${message} | ${detail}` : message);
  // Reporting is best-effort: if the IPC bridge is what broke, there is nothing
  // left to report through, and throwing from an error handler loses the
  // original failure.
  void ipc.reportError(message, detail).catch(() => {});
}

export function installErrorReporting(label: string): void {
  window.addEventListener('error', (event) => {
    const where = event.filename ? ` (${event.filename}:${event.lineno})` : '';
    record(`${label}: ${event.message}${where}`, event.error?.stack);
  });

  window.addEventListener('unhandledrejection', (event) => {
    const reason = event.reason;
    record(
      `${label}: unhandled rejection: ${reason instanceof Error ? reason.message : String(reason)}`,
      reason instanceof Error ? reason.stack : undefined,
    );
  });
}
