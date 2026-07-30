#!/usr/bin/env node
/**
 * Generates every app/tray icon asset from a single vector definition.
 *
 * Rendering is done with signed-distance fields so the output is properly
 * antialiased at every size without shipping a rasteriser dependency.
 * Outputs PNGs (minimal encoder over node:zlib) and a DIB-payload .ico —
 * DIB rather than PNG-in-ICO because `tauri-winres` embeds the file verbatim
 * and older Windows resource loaders reject PNG entries.
 */
import { deflateSync } from 'node:zlib';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const OUT_DIR = join(dirname(fileURLToPath(import.meta.url)), '..', 'src-tauri', 'icons');

// ---------------------------------------------------------------- vector art

const INDIGO = [0x63, 0x66, 0xf1];
const VIOLET = [0x8b, 0x5c, 0xf6];

const mix = (a, b, t) => a.map((v, i) => Math.round(v + (b[i] - v) * t));

/** Signed distance to a rounded rectangle centred at (cx, cy). */
function sdRoundRect(px, py, cx, cy, hw, hh, r) {
  const qx = Math.abs(px - cx) - (hw - r);
  const qy = Math.abs(py - cy) - (hh - r);
  const ox = Math.max(qx, 0);
  const oy = Math.max(qy, 0);
  return Math.hypot(ox, oy) + Math.min(Math.max(qx, qy), 0) - r;
}

/** Signed distance to a thick line segment (a capsule). */
function sdCapsule(px, py, ax, ay, bx, by, r) {
  const dx = bx - ax;
  const dy = by - ay;
  const len2 = dx * dx + dy * dy || 1;
  let t = ((px - ax) * dx + (py - ay) * dy) / len2;
  t = Math.max(0, Math.min(1, t));
  return Math.hypot(px - ax - dx * t, py - ay - dy * t) - r;
}

/** Renders the icon into a straight-alpha RGBA buffer of the given size. */
function render(size) {
  const buf = Buffer.alloc(size * size * 4, 0);
  const u = size; // all geometry below is expressed in 0..1 of the canvas
  const aa = 1.0; // antialiasing width, in pixels

  // Geometry: a note card with a check mark and two text lines.
  const card = { cx: 0.5, cy: 0.5, hw: 0.345, hh: 0.345, r: 0.115 };
  const lines = [
    // check mark, drawn as two capsules
    { a: [0.325, 0.475], b: [0.435, 0.585], r: 0.045 },
    { a: [0.435, 0.585], b: [0.665, 0.355], r: 0.045 },
    // two text lines below
    { a: [0.335, 0.695], b: [0.665, 0.695], r: 0.036 },
    { a: [0.335, 0.79], b: [0.565, 0.79], r: 0.036 },
  ];

  const put = (i, rgb, a) => {
    if (a <= 0) return;
    const da = buf[i + 3] / 255;
    const outA = a + da * (1 - a);
    if (outA <= 0) return;
    for (let c = 0; c < 3; c++) {
      const dc = buf[i + c] / 255;
      buf[i + c] = Math.round(((rgb[c] / 255) * a + dc * da * (1 - a)) / outA * 255);
    }
    buf[i + 3] = Math.round(outA * 255);
  };

  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const px = x + 0.5;
      const py = y + 0.5;
      const i = (y * size + x) * 4;

      const dCard = sdRoundRect(px, py, card.cx * u, card.cy * u, card.hw * u, card.hh * u, card.r * u);
      const covCard = Math.max(0, Math.min(1, 0.5 - dCard / aa));
      if (covCard > 0) {
        // diagonal gradient across the card face
        const t = Math.max(0, Math.min(1, (px / u + py / u - 0.31) / 0.69));
        put(i, mix(INDIGO, VIOLET, t), covCard);
      }

      let covInk = 0;
      for (const l of lines) {
        const d = sdCapsule(px, py, l.a[0] * u, l.a[1] * u, l.b[0] * u, l.b[1] * u, l.r * u);
        covInk = Math.max(covInk, Math.max(0, Math.min(1, 0.5 - d / aa)));
      }
      // ink only ever sits on the card, so clip it to the card silhouette
      if (covInk > 0) put(i, [255, 255, 255], covInk * covCard * 0.96);
    }
  }
  return buf;
}

// -------------------------------------------------------------- PNG encoder

function crc32(buf) {
  let c = ~0;
  for (let i = 0; i < buf.length; i++) {
    c ^= buf[i];
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
  }
  return ~c >>> 0;
}

function chunk(type, data) {
  const out = Buffer.alloc(8 + data.length + 4);
  out.writeUInt32BE(data.length, 0);
  out.write(type, 4, 'ascii');
  data.copy(out, 8);
  out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
  return out;
}

function encodePng(rgba, size) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(size, 0);
  ihdr.writeUInt32BE(size, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 6; // colour type: truecolour with alpha
  const stride = size * 4;
  const raw = Buffer.alloc((stride + 1) * size);
  for (let y = 0; y < size; y++) {
    raw[y * (stride + 1)] = 0; // filter: none
    rgba.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// -------------------------------------------------------------- ICO encoder

/** BITMAPINFOHEADER + bottom-up BGRA pixels + empty AND mask. */
function encodeDib(rgba, size) {
  const header = Buffer.alloc(40);
  header.writeUInt32LE(40, 0);
  header.writeInt32LE(size, 4);
  header.writeInt32LE(size * 2, 8); // XOR bitmap plus AND mask
  header.writeUInt16LE(1, 12);
  header.writeUInt16LE(32, 14);
  const pixels = Buffer.alloc(size * size * 4);
  for (let y = 0; y < size; y++) {
    const src = (size - 1 - y) * size * 4;
    for (let x = 0; x < size; x++) {
      const s = src + x * 4;
      const d = (y * size + x) * 4;
      pixels[d] = rgba[s + 2];
      pixels[d + 1] = rgba[s + 1];
      pixels[d + 2] = rgba[s];
      pixels[d + 3] = rgba[s + 3];
    }
  }
  const maskStride = Math.ceil(size / 32) * 4;
  return Buffer.concat([header, pixels, Buffer.alloc(maskStride * size)]);
}

function encodeIco(entries) {
  const dir = Buffer.alloc(6 + entries.length * 16);
  dir.writeUInt16LE(0, 0);
  dir.writeUInt16LE(1, 2); // type: icon
  dir.writeUInt16LE(entries.length, 4);
  let offset = dir.length;
  const blobs = [];
  entries.forEach((e, i) => {
    const p = 6 + i * 16;
    dir[p] = e.size >= 256 ? 0 : e.size;
    dir[p + 1] = e.size >= 256 ? 0 : e.size;
    dir.writeUInt16LE(1, p + 4);
    dir.writeUInt16LE(32, p + 6);
    dir.writeUInt32LE(e.data.length, p + 8);
    dir.writeUInt32LE(offset, p + 12);
    offset += e.data.length;
    blobs.push(e.data);
  });
  return Buffer.concat([dir, ...blobs]);
}

// ------------------------------------------------------------------- driver

mkdirSync(OUT_DIR, { recursive: true });

const PNG_TARGETS = [
  [32, '32x32.png'],
  [64, 'tray.png'],
  [128, '128x128.png'],
  [256, '128x128@2x.png'],
  [512, 'icon.png'],
];
// Capped at 128: a 256x256 DIB entry alone costs 256 KB of the final binary,
// and Windows upscales 128 cleanly for the rare 256 slot.
const ICO_SIZES = [16, 24, 32, 48, 64, 128];

const cache = new Map();
const raster = (n) => {
  if (!cache.has(n)) cache.set(n, render(n));
  return cache.get(n);
};

for (const [size, name] of PNG_TARGETS) {
  writeFileSync(join(OUT_DIR, name), encodePng(raster(size), size));
  console.log(`  ${name} (${size}x${size})`);
}

writeFileSync(
  join(OUT_DIR, 'icon.ico'),
  encodeIco(ICO_SIZES.map((size) => ({ size, data: encodeDib(raster(size), size) }))),
);
console.log(`  icon.ico (${ICO_SIZES.join(', ')})`);
