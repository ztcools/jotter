import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

/**
 * The frontend lives in `ui/` and builds into `dist/`, which is what
 * `src-tauri/tauri.conf.json` embeds. Port 1420 is fixed because the Tauri dev
 * config points at it explicitly.
 *
 * Two documents ship, one per window: `index.html` is the mascot and
 * `panel.html` is the notebook, which Rust loads as
 * `WebviewUrl::App("panel.html")`. They are listed explicitly because Vite's
 * implicit single entry would build `index.html` alone — and that same list is
 * what keeps `preview.html`, the browser-only design harness, out of the
 * shipped bundle.
 */
export default defineConfig({
  root: 'ui',
  plugins: [svelte()],
  clearScreen: false,
  server: {
    port: 1420,
    strictPort: true,
    host: '127.0.0.1',
    watch: { ignored: ['**/src-tauri/**'] },
  },
  build: {
    outDir: '../dist',
    emptyOutDir: true,
    // WebView2 on supported Windows builds is well past this; keeps output lean.
    target: 'chrome110',
    cssCodeSplit: false,
    sourcemap: false,
    reportCompressedSize: false,
    rollupOptions: {
      // Resolved against the working directory (not `root`), and kept as plain
      // strings rather than `fileURLToPath` so this config needs no Node type
      // definitions. Vite still strips the `ui/` prefix in the output, so the
      // documents land at `dist/index.html` and `dist/panel.html`.
      input: { ball: 'ui/index.html', panel: 'ui/panel.html' },
    },
  },
});
