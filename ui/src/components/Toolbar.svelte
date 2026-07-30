<!-- One-click copy and one-click export, plus the housekeeping actions. -->
<script lang="ts">
  import { save } from '@tauri-apps/plugin-dialog';
  import Icon from './Icon.svelte';
  import * as ipc from '../lib/ipc';
  import { allCardsToMarkdown, cardToMarkdown, exportFilename } from '../lib/markdown';
  import { toasts, workspace } from '../lib/store.svelte';

  let busy = $state(false);

  async function copy() {
    const card = workspace.active;
    if (!card) return;
    try {
      await ipc.copyText(cardToMarkdown(card));
      toasts.show(`已复制「${card.title}」${card.items.length} 条`);
    } catch (err) {
      toasts.show(`复制失败：${String(err)}`, 'error');
    }
  }

  /**
   * Exports the current card, or every card when Shift is held.
   *
   * The native save dialog steals focus, which the Rust side would read as
   * "clicked away" and collapse the panel — hence the suspend bracket.
   */
  async function exportFile(event: MouseEvent) {
    const card = workspace.active;
    if (!card || busy) return;
    const all = event.shiftKey && workspace.cards.length > 1;

    busy = true;
    try {
      await ipc.suspendAutoCollapse(true);
      const path = await save({
        defaultPath: all ? `jotter-all-${exportFilename(card)}` : exportFilename(card),
        filters: [
          { name: 'Markdown', extensions: ['md'] },
          { name: '纯文本', extensions: ['txt'] },
        ],
      });
      if (!path) return;
      await ipc.writeTextFile(
        path,
        all ? allCardsToMarkdown(workspace.cards) : cardToMarkdown(card),
      );
      toasts.show(all ? `已导出全部 ${workspace.cards.length} 张卡片` : '已导出文件');
    } catch (err) {
      toasts.show(`导出失败：${String(err)}`, 'error');
    } finally {
      await ipc.suspendAutoCollapse(false).catch(() => {});
      busy = false;
    }
  }
</script>

<footer class="bar">
  <button class="act" onclick={copy} title="复制为 Markdown 清单">
    <Icon name="copy" />
    <span>复制</span>
  </button>
  <button
    class="act"
    onclick={exportFile}
    disabled={busy}
    title="导出为文件（按住 Shift 导出全部卡片）"
  >
    <Icon name="export" />
    <span>导出</span>
  </button>
  <!-- Labelled rather than icon-only: the double-check glyph on its own reads as
       "mark everything done", which is the opposite of what this does. -->
  <button class="act" onclick={() => workspace.clearDone()} title="清除本卡片中已解决的条目">
    <Icon name="check-all" />
    <span>清理</span>
  </button>

  <span class="spacer"></span>
  <span class="stat" title="未解决 / 全部">
    {workspace.openCount}<i>/</i>{workspace.items.length}
  </span>
</footer>

<style>
  .bar {
    display: flex;
    align-items: center;
    gap: 4px;
    flex: none;
    height: 38px;
    padding: 0 8px 0 10px;
    border-top: 1px solid var(--hairline);
  }

  .act {
    height: 26px;
    padding: 0 9px;
    font-size: 11.5px;
    color: var(--text-dim);
  }

  .act:hover:not(:disabled) {
    background: var(--surface-hover);
    color: var(--text);
  }

  .spacer {
    flex: 1;
  }

  .stat {
    font-size: 11px;
    font-weight: 600;
    color: var(--text-faint);
    font-variant-numeric: tabular-nums;
    padding-right: 4px;
  }

  .stat i {
    font-style: normal;
    opacity: 0.5;
    margin: 0 1px;
  }
</style>
