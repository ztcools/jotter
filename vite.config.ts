import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

/**
 * The frontend lives in `ui/` and builds into `dist/`, which is what
 * `src-tauri/tauri.conf.json` embeds. Port 1420 is fixed because the Tauri dev
 * config points at it explicitly.
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
  },
});
