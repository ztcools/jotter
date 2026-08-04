/** Mirrors the Rust `model` module. Kept hand-written: the surface is small and
 * a codegen step would cost more than it saves. */

export interface Item {
  id: string;
  text: string;
  /** Data URLs for display, loaded from disk paths after workspace load.
   *  Never persisted directly — the Rust side stores file paths instead. */
  images: string[];
  done: boolean;
  createdAt: number;
}

export interface Card {
  id: string;
  title: string;
  items: Item[];
  accent: number;
  createdAt: number;
  updatedAt: number;
}

export interface Point {
  x: number;
  y: number;
}

export interface Workspace {
  version: number;
  cards: Card[];
  activeCardId: string | null;
  pinned: boolean;
  ballPosition: Point | null;
}
