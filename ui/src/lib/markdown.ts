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

/** Plain text — one line per item, no card title, no timestamp, no Markdown.
 *  Used for clipboard copy so the user can paste straight into an agent chat. */
export function cardToPlainText(card: Card): string {
  return card.items
    .map((item) => item.text)
    .filter((t) => t.length > 0)
    .join('\n');
}

/** HTML for rich-text clipboard — plain text lines interleaved with embedded
 *  <img> tags so pasting into a chat window carries screenshots as well. */
export function cardToHtml(card: Card): string {
  const parts: string[] = [];
  for (const item of card.items) {
    if (item.text) {
      parts.push(`<p>${escapeHtml(item.text)}</p>`);
    }
    for (const src of item.images) {
      parts.push(`<img src="${escapeAttr(src)}" alt="截图" style="max-width:100%" />`);
    }
  }
  return parts.join('\n');
}

/** Returns true if any item in the card has an image. */
export function cardHasImages(card: Card): boolean {
  return card.items.some((item) => item.images.length > 0);
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

function escapeAttr(s: string): string {
  return escapeHtml(s).replace(/"/g, '&quot;');
}

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
