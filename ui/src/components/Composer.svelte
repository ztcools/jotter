<!-- Capture line. Enter commits and keeps focus, so a burst of findings can be
     typed without ever reaching for the mouse. -->
<script lang="ts">
  import Icon from './Icon.svelte';
  import { workspace } from '../lib/store.svelte';

  let value = $state('');
  let field = $state<HTMLInputElement | null>(null);

  // Refocus when the active card changes, so switching cards leaves the caret
  // ready in the new one.
  let activeId = $derived(workspace.activeId);
  $effect(() => {
    void activeId;
    field?.focus();
  });

  async function submit() {
    const text = value.trim();
    if (!text) return;
    // Cleared up front so the next line can be typed straight away, and put
    // back if the write failed — losing a just-typed note is the one failure
    // this app cannot afford.
    value = '';
    if (!(await workspace.addItem(text))) value = text;
  }

  function onKeydown(event: KeyboardEvent) {
    if (event.key === 'Enter' && !event.isComposing) {
      event.preventDefault();
      void submit();
    }
  }
</script>

<div class="composer" class:filled={value.length > 0}>
  <input
    bind:this={field}
    bind:value
    onkeydown={onKeydown}
    maxlength="500"
    placeholder="记一个问题…"
    aria-label="记一个问题"
  />
  <button onclick={submit} disabled={value.trim().length === 0} title="添加（Enter）" aria-label="添加">
    <Icon name="plus" size={14} />
  </button>
</div>

<style>
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
