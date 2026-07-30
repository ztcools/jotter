<!-- Transient feedback. The window has no devtools and no status bar, so this is
     the only channel for "copied" and for IPC failures. -->
<script lang="ts">
  import { fly } from 'svelte/transition';
  import { toasts } from '../lib/store.svelte';
</script>

{#if toasts.message}
  <div class="toast" class:error={toasts.tone === 'error'} transition:fly={{ y: 8, duration: 160 }}>
    {toasts.message}
  </div>
{/if}

<style>
  .toast {
    position: absolute;
    left: 14px;
    right: 14px;
    bottom: 46px;
    z-index: 10;
    padding: 7px 11px;
    border-radius: var(--r-card);
    font-size: 11.5px;
    text-align: center;
    color: #fff;
    background: rgba(34, 34, 46, 0.94);
    box-shadow: 0 6px 18px rgba(20, 20, 45, 0.28);
    /* Long error strings must not push the panel around. */
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .toast.error {
    background: var(--danger);
  }
</style>
