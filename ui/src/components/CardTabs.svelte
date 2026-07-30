<!-- Horizontal card switcher. Click to switch, double-click to rename, and a
     hover-revealed cross to delete once more than one card exists. -->
<script lang="ts">
  import { onMount } from 'svelte';
  import { listen } from '@tauri-apps/api/event';
  import Icon from './Icon.svelte';
  import { workspace } from '../lib/store.svelte';

  let editingId = $state<string | null>(null);
  let confirmingId = $state<string | null>(null);
  let strip = $state<HTMLDivElement | null>(null);

  // Putting the notebook away hides its window without destroying it, so both of
  // these would otherwise still be set on reopen — and a delete confirmation
  // that outlives the session it was armed in means the next click on that cross
  // removes a card without asking.
  onMount(() => {
    let off: (() => void) | undefined;
    void listen('panel-state', () => {
      confirmingId = null;
      editingId = null;
    }).then((f) => (off = f));
    return () => off?.();
  });

  function startRename(id: string) {
    confirmingId = null;
    editingId = id;
  }

  function commitRename(id: string, event: Event) {
    const input = event.currentTarget as HTMLInputElement;
    void workspace.renameCard(id, input.value);
    editingId = null;
  }

  function onRenameKey(event: KeyboardEvent) {
    if (event.key === 'Enter') {
      event.preventDefault();
      (event.currentTarget as HTMLInputElement).blur();
    } else if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation(); // keep Escape from collapsing the whole panel
      editingId = null;
    }
  }

  async function onNew() {
    await workspace.newCard();
    // Let the DOM settle before scrolling the freshly added chip into view.
    requestAnimationFrame(() => strip?.scrollTo({ left: strip.scrollWidth, behavior: 'smooth' }));
  }

  async function onDelete(id: string) {
    if (confirmingId !== id) {
      confirmingId = id;
      return;
    }
    confirmingId = null;
    await workspace.removeCard(id);
  }
</script>

<!-- pointerleave only cancels a pending delete confirmation; keyboard users cancel
     with Escape or by activating anything else, so no role is warranted. -->
<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="tabs" bind:this={strip} onpointerleave={() => (confirmingId = null)}>
  {#each workspace.cards as card (card.id)}
    {@const active = card.id === workspace.activeId}
    {@const open = card.items.filter((i) => !i.done).length}
    <div class="chip" class:active class:confirming={confirmingId === card.id}>
      {#if editingId === card.id}
        <!-- svelte-ignore a11y_autofocus -->
        <input
          class="rename"
          value={card.title}
          maxlength="60"
          autofocus
          onblur={(e) => commitRename(card.id, e)}
          onkeydown={onRenameKey}
        />
      {:else}
        <button
          class="label"
          style:--chip-accent="var(--a{card.accent % 6})"
          onclick={() => workspace.selectCard(card.id)}
          ondblclick={() => startRename(card.id)}
          title={`${card.title} — 双击重命名`}
        >
          <span class="dot"></span>
          <span class="text">{card.title}</span>
          {#if open > 0}<span class="count">{open}</span>{/if}
        </button>
        {#if workspace.cards.length > 1}
          <button
            class="kill"
            onclick={() => onDelete(card.id)}
            title={confirmingId === card.id ? '再点一次确认删除' : '删除卡片'}
            aria-label="删除卡片"
          >
            <Icon name={confirmingId === card.id ? 'trash' : 'x'} size={11} />
          </button>
        {/if}
      {/if}
    </div>
  {/each}

  <button class="add" onclick={onNew} title="新建卡片（Ctrl+N）" aria-label="新建卡片">
    <Icon name="plus" size={14} />
  </button>
</div>

<style>
  .tabs {
    display: flex;
    align-items: center;
    gap: 5px;
    padding: 0 10px 8px;
    overflow-x: auto;
    overflow-y: hidden;
    scrollbar-width: none;
    flex: none;
  }

  .tabs::-webkit-scrollbar {
    display: none;
  }

  .chip {
    position: relative;
    display: flex;
    align-items: center;
    flex: none;
    border-radius: var(--r-pill);
    background: var(--surface-sunken);
    transition: background-color var(--dur-fast) var(--ease);
  }

  .chip:hover {
    background: var(--surface-hover);
  }

  .chip.active {
    background: color-mix(in oklab, var(--accent) 15%, transparent);
  }

  .chip.confirming {
    background: color-mix(in oklab, var(--danger) 20%, transparent);
  }

  .label {
    max-width: 132px;
    height: 26px;
    padding: 0 10px;
    border-radius: var(--r-pill);
    font-size: 12px;
    color: var(--text-dim);
  }

  .chip.active .label {
    color: var(--text);
    font-weight: 600;
  }

  .label:active {
    transform: none; /* chips are small; the global press-scale reads as a glitch */
  }

  .dot {
    width: 6px;
    height: 6px;
    border-radius: 50%;
    background: var(--chip-accent);
    flex: none;
    opacity: 0.55;
    transition: opacity var(--dur-fast) var(--ease);
  }

  .chip.active .dot {
    opacity: 1;
  }

  .text {
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .count {
    font-size: 10px;
    font-weight: 700;
    color: var(--text-faint);
    font-variant-numeric: tabular-nums;
  }

  .chip.active .count {
    color: var(--accent);
  }

  .kill {
    width: 0;
    height: 26px;
    overflow: hidden;
    color: var(--text-faint);
    opacity: 0;
    transition:
      width var(--dur-fast) var(--ease),
      opacity var(--dur-fast) var(--ease);
  }

  .chip:hover .kill,
  .chip.confirming .kill {
    width: 20px;
    opacity: 1;
    padding-right: 4px;
  }

  .kill:hover,
  .chip.confirming .kill {
    color: var(--danger);
  }

  .rename {
    width: 132px;
    height: 26px;
    padding: 0 10px;
    font-size: 12px;
    font-weight: 600;
    border-radius: var(--r-pill);
    background: var(--surface);
    box-shadow: inset 0 0 0 1.5px var(--accent);
  }

  .add {
    width: 26px;
    height: 26px;
    flex: none;
    color: var(--text-dim);
    background: var(--surface-sunken);
  }

  .add:hover {
    background: color-mix(in oklab, var(--accent) 16%, transparent);
    color: var(--accent);
  }
</style>
