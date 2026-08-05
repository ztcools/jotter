<!-- The notebook page itself: one line per issue, tick to resolve, click the
     text to correct a typo. -->
<script lang="ts">
  import Icon from './Icon.svelte';
  import { workspace } from '../lib/store.svelte';
  import type { Item } from '../lib/types';

  let editingId = $state<string | null>(null);
  let scroller = $state<HTMLDivElement | null>(null);

  // Follow the tail as items are appended, the way a log view does. Reading
  // `length` is what registers the dependency.
  let count = $derived(workspace.items.length);
  $effect(() => {
    void count;
    requestAnimationFrame(() => scroller?.scrollTo({ top: scroller.scrollHeight }));
  });

  function commitEdit(item: Item, event: Event) {
    void workspace.editItem(item, (event.currentTarget as HTMLInputElement).value);
    editingId = null;
  }

  function onEditKey(event: KeyboardEvent) {
    if (event.key === 'Enter') {
      event.preventDefault();
      (event.currentTarget as HTMLInputElement).blur();
    } else if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      editingId = null;
    }
  }
</script>

<div class="list" bind:this={scroller}>
  {#if workspace.items.length === 0}
    <p class="empty">
      <!-- A pen, not a tick: on a card with nothing on it yet, "all done" is the
           opposite of what there is to say. -->
      <span class="glyph"><Icon name="pen" size={19} /></span>
      这张卡片还是空的<br />
      <em>在下面写下你发现的第一个问题</em>
    </p>
  {:else}
    {#each workspace.items as item (item.id)}
      <div class="row" class:done={item.done}>
        <button
          class="tick"
          onclick={() => workspace.toggleItem(item)}
          title={item.done ? '标为未解决' : '标为已解决'}
          aria-label={item.done ? '标为未解决' : '标为已解决'}
          aria-pressed={item.done}
        >
          {#if item.done}<Icon name="check" size={11} />{/if}
        </button>

        {#if editingId === item.id}
          <!-- svelte-ignore a11y_autofocus -->
          <input
            class="edit"
            value={item.text}
            maxlength="10000"
            autofocus
            onblur={(e) => commitEdit(item, e)}
            onkeydown={onEditKey}
          />
        {:else}
          {#if item.text}
            <button class="text" onclick={() => (editingId = item.id)} title="点击修改">
              {item.text}
            </button>
          {:else}
            <span class="text placeholder" aria-hidden="true">图片</span>
          {/if}
          <button
            class="kill"
            onclick={() => workspace.removeItem(item)}
            title="删除这条"
            aria-label="删除这条"
          >
            <Icon name="x" size={12} />
          </button>
        {/if}
      </div>

      {#if item.images.length > 0}
        <div class="thumbs">
          {#each item.images as src (src)}
            <img class="thumb" {src} alt="粘贴的截图" loading="lazy" />
          {/each}
        </div>
      {/if}
    {/each}
  {/if}
</div>

<style>
  .list {
    flex: 1;
    min-height: 0;
    overflow-y: auto;
    padding: 2px 8px 6px;
    display: flex;
    flex-direction: column;
    gap: 2px;
  }

  .empty {
    margin: auto;
    text-align: center;
    font-size: 12px;
    line-height: 1.9;
    color: var(--text-faint);
  }

  .empty em {
    font-style: normal;
    font-size: 11px;
    opacity: 0.8;
  }

  .glyph {
    display: grid;
    place-items: center;
    width: 40px;
    height: 40px;
    margin: 0 auto 8px;
    border-radius: var(--r-card);
    background: var(--surface-sunken);
    color: var(--text-faint);
  }

  .row {
    display: flex;
    align-items: flex-start;
    gap: 7px;
    padding: 5px 4px 5px 6px;
    border-radius: var(--r-card);
    transition: background-color var(--dur-fast) var(--ease);
  }

  .row:hover {
    background: var(--surface-sunken);
  }

  .tick {
    width: 16px;
    height: 16px;
    margin-top: 2px;
    flex: none;
    border-radius: 50%;
    color: #fff;
    box-shadow: inset 0 0 0 1.5px var(--hairline-strong);
    transition:
      background-color var(--dur-fast) var(--ease),
      box-shadow var(--dur-fast) var(--ease);
  }

  .tick:hover {
    box-shadow: inset 0 0 0 1.5px var(--accent);
  }

  .row.done .tick {
    background: linear-gradient(140deg, var(--accent), var(--accent-2));
    box-shadow: none;
  }

  .text {
    flex: 1;
    min-width: 0;
    justify-content: flex-start;
    text-align: left;
    font-size: 12.5px;
    line-height: 1.5;
    border-radius: 6px;
    /* Long notes wrap rather than truncate — you need to read the whole thing. */
    white-space: normal;
    overflow-wrap: anywhere;
    color: var(--text);
  }

  .text:active {
    transform: none;
  }

  .row.done .text {
    color: var(--text-faint);
    text-decoration: line-through;
    text-decoration-color: var(--text-faint);
  }

  .edit {
    flex: 1;
    min-width: 0;
    font-size: 12.5px;
    line-height: 1.5;
    padding: 1px 6px;
    border-radius: 7px;
    background: var(--surface);
    box-shadow: inset 0 0 0 1.5px var(--accent);
  }

  .kill {
    width: 18px;
    height: 18px;
    margin-top: 1px;
    flex: none;
    color: var(--text-faint);
    opacity: 0;
    transition: opacity var(--dur-fast) var(--ease);
  }

  .row:hover .kill {
    opacity: 1;
  }

  .kill:hover {
    color: var(--danger);
    background: color-mix(in oklab, var(--danger) 14%, transparent);
  }

  .placeholder {
    font-style: italic;
    opacity: 0.45;
    cursor: default;
  }

  .thumbs {
    display: flex;
    flex-wrap: wrap;
    gap: 4px;
    padding: 0 0 2px 29px;
  }

  .thumb {
    max-width: 100%;
    max-height: 48px;
    border-radius: 6px;
    box-shadow: 0 1px 3px rgba(20, 20, 45, 0.12);
    object-fit: contain;
    background: var(--surface-sunken);
  }
</style>
