<!-- Capture line. Enter commits and keeps focus, so a burst of findings can be
     typed without ever reaching for the mouse. -->
<script lang="ts">
  import { onMount } from 'svelte';
  import { listen } from '@tauri-apps/api/event';
  import Icon from './Icon.svelte';
  import { workspace } from '../lib/store.svelte';

  let value = $state('');
  let field = $state<HTMLInputElement | null>(null);
  /** Images queued for the next submission — local state so reactivity stays
   * within this component and never crosses module boundaries. */
  let pending = $state<string[]>([]);

  /** True while the caret is in some other field — an item being corrected. */
  function editingElsewhere() {
    const el = document.activeElement;
    return el !== null && el !== field && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA');
  }

  /** Puts the caret on the capture line.
   *
   * Focusing once at mount is not enough. The notebook window is created hidden
   * and from then on only hidden again, never destroyed, so nothing here
   * remounts on reopen — and the mount-time focus was refused anyway, because a
   * hidden webview cannot take it. The two together left every keystroke after
   * opening the notebook going to `body`. */
  function claimCaret() {
    if (!field || editingElsewhere()) return;
    field.focus();
    // The webview is granted focus a beat after the window is shown, so even a
    // well-timed first attempt can still be refused.
    if (document.activeElement !== field) setTimeout(() => field?.focus(), 140);
  }

  onMount(() => {
    claimCaret();
    let off: (() => void) | undefined;
    void listen<boolean>('panel-state', (event) => {
      if (event.payload) claimCaret();
    }).then((f) => (off = f));
    return () => off?.();
  });

  // Refocus when the active card changes, so switching cards leaves the caret
  // ready in the new one.
  let activeId = $derived(workspace.activeId);
  $effect(() => {
    void activeId;
    field?.focus();
  });

  // Discard pending images when the active card changes — they belong to the
  // card they were pasted on.  (Local $state resets naturally when this
  // component re-runs, so the assignment is deliberate and not a leak.)
  $effect(() => {
    void activeId;
    pending = [];
  });

  async function submit() {
    const text = value.trim();
    const imgs = pending.length > 0 ? [...pending] : undefined;
    if (!text && !imgs) return;
    // Snapshot captured; clear UI state before the await so the user can
    // start typing the next line immediately.
    value = '';
    pending = [];
    if (!(await workspace.addItem(text, imgs))) {
      value = text;
      pending = imgs ?? [];
    }
  }

  function onKeydown(event: KeyboardEvent) {
    if (event.key === 'Enter' && !event.isComposing) {
      event.preventDefault();
      void submit();
    }
  }

  /** Reads every image from the paste event into the local pending queue. */
  async function onPaste(event: ClipboardEvent) {
    const dt = event.clipboardData;
    if (!dt) return;
    for (let i = 0; i < dt.items.length; i++) {
      const item = dt.items[i];
      if (!item || !item.type.startsWith('image/')) continue;
      event.preventDefault();
      const blob = item.getAsFile();
      if (!blob) continue;
      const dataUrl = await new Promise<string>((resolve) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result as string);
        reader.readAsDataURL(blob);
      });
      pending = [...pending, dataUrl];
    }
  }
</script>

<!-- Coming back to a pinned notebook (Alt-Tab, or a click on its chrome) should
     also leave the caret ready, not on `body`. -->
<svelte:window onfocus={claimCaret} />

{#if pending.length > 0}
  <div class="queue">
    {#each pending as src, index (src)}
      <div class="chip">
        <img {src} alt="待提交截图" />
        <button
          class="drop"
          onclick={() => (pending = pending.filter((_, j) => j !== index))}
          title="移除此图片"
          aria-label="移除此图片"
        >
          <Icon name="x" size={10} />
        </button>
      </div>
    {/each}
    <span class="hint">按 Enter 提交</span>
  </div>
{/if}

<div class="composer" class:filled={value.length > 0}>
  <input
    bind:this={field}
    bind:value
    onkeydown={onKeydown}
    onpaste={onPaste}
    maxlength="10000"
    placeholder="记一个问题…"
    aria-label="记一个问题"
  />
  <button onclick={submit} disabled={value.trim().length === 0 && pending.length === 0} title="添加（Enter）" aria-label="添加">
    <Icon name="plus" size={14} />
  </button>
</div>

<style>
  .queue {
    display: flex;
    align-items: center;
    gap: 6px;
    flex: none;
    padding: 4px 10px 0;
    overflow-x: auto;
    scrollbar-width: none;
  }

  .queue::-webkit-scrollbar {
    display: none;
  }

  .chip {
    position: relative;
    flex: none;
    width: 44px;
    height: 44px;
    border-radius: 8px;
    overflow: hidden;
    box-shadow: 0 1px 3px rgba(20, 20, 45, 0.18);
  }

  .chip img {
    width: 100%;
    height: 100%;
    object-fit: cover;
  }

  .drop {
    position: absolute;
    top: 2px;
    right: 2px;
    width: 16px;
    height: 16px;
    padding: 0;
    border-radius: 50%;
    background: rgba(34, 34, 46, 0.78);
    color: #fff;
    opacity: 0;
    transition: opacity var(--dur-fast) var(--ease);
  }

  .chip:hover .drop {
    opacity: 1;
  }

  .drop:hover {
    background: var(--danger);
  }

  .hint {
    flex: none;
    font-size: 10.5px;
    color: var(--text-faint);
    white-space: nowrap;
  }

  .composer {
    display: flex;
    align-items: center;
    gap: 4px;
    flex: none;
    margin: 0 10px 8px;
    padding: 3px 3px 3px 11px;
    border-radius: var(--r-pill);
    background: var(--surface-sunken);
    box-shadow: inset 0 0 0 1.5px transparent;
    transition:
      box-shadow var(--dur) var(--ease),
      background-color var(--dur) var(--ease);
  }

  .composer:focus-within {
    background: var(--surface);
    box-shadow: inset 0 0 0 1.5px color-mix(in oklab, var(--accent) 55%, transparent);
  }

  input {
    flex: 1;
    min-width: 0;
    height: 28px;
    font-size: 12.5px;
  }

  input::placeholder {
    color: var(--text-faint);
  }

  button {
    width: 26px;
    height: 26px;
    flex: none;
    color: var(--text-faint);
  }

  .composer.filled button {
    background: linear-gradient(140deg, var(--accent), var(--accent-2));
    color: #fff;
  }

  /* The global focus ring would sit outside the pill; the pill itself is the
     affordance, so suppress it on the inner field. */
  input:focus-visible {
    outline: none;
  }
</style>
