<!--
  Root shell. Owns two things only: the bridge to Rust-initiated state changes,
  and the panel-level keyboard shortcuts.
-->
<script lang="ts">
  import { onMount } from 'svelte';
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import Ball from './components/Ball.svelte';
  import Panel from './components/Panel.svelte';
  import { workspace } from './lib/store.svelte';

  onMount(() => {
    void workspace.load();

    const win = getCurrentWindow();
    const disposers: Array<() => void> = [];
    // Tray clicks, the global shortcut and focus loss all change state in Rust;
    // these events are how the UI finds out.
    void win
      .listen<boolean>('panel-state', (event) => workspace.syncExpanded(event.payload))
      .then((off) => disposers.push(off));
    void win
      .listen('workspace-changed', () => void workspace.load())
      .then((off) => disposers.push(off));

    return () => disposers.forEach((off) => off());
  });

  function onKeydown(event: KeyboardEvent) {
    if (!workspace.expanded) return;

    if (event.key === 'Escape') {
      event.preventDefault();
      void workspace.setExpanded(false);
      return;
    }
    if (!event.ctrlKey) return;

    if (event.key === 'n' || event.key === 'N') {
      event.preventDefault();
      void workspace.newCard();
    } else if (event.key === 'Tab') {
      event.preventDefault();
      void workspace.cycleCard(event.shiftKey ? -1 : 1);
    }
  }
</script>

<svelte:window onkeydown={onKeydown} />

{#if workspace.expanded}
  <div class="stage panel-stage">
    <Panel />
  </div>
{:else}
  <Ball />
{/if}

<style>
  /* Every root surface leaves a transparent gutter for its own drop shadow;
     without it the shadow would be clipped by the window edge. */
  .stage {
    width: 100%;
    height: 100%;
    padding: var(--bleed);
  }

  .panel-stage {
    animation: rise 180ms var(--ease);
  }

  @keyframes rise {
    from {
      opacity: 0;
      transform: scale(0.96);
    }
    to {
      opacity: 1;
      transform: scale(1);
    }
  }
</style>
