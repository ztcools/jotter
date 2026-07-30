/** Rendering for copy and export. Lives on this side of the IPC boundary
 * because it needs the user's locale and timezone, which the Rust side would
 * only be able to approximate. */

import type { Card } from './types';

const stamp = (ms: number) =>
  new Date(ms).toLocaleString(undefined, {
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
  });

/** GitHub-flavoured task list — pastes cleanly into an issue or a PR comment. */
export function cardToMarkdown(card: Card): string {
  const lines = [`## ${card.title}`, '', `_${stamp(card.updatedAt)}_`, ''];
  if (card.items.length === 0) {
    lines.push('_（暂无记录）_');
  } else {
    for (const item of card.items) {
      lines.push(`- [${item.done ? 'x' : ' '}] ${item.text}`);
    }
  }
  return lines.join('\n') + '\n';
}

export function allCardsToMarkdown(cards: Card[]): string {
  return cards.map(cardToMarkdown).join('\n---\n\n');
}

/** Filesystem-safe filename suggestion for the save dialog. */
export function exportFilename(card: Card): string {
  const date = new Date()
    .toLocaleDateString('sv-SE') // ISO-shaped, locale-safe
    .replaceAll('-', '');
  const slug = card.title.replace(/[\\/:*?"<>|\s]+/g, '-').replace(/^-+|-+$/g, '');
  return `${slug || 'jotter'}-${date}.md`;
}
