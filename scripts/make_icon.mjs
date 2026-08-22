#!/usr/bin/env node
// Writes build/icon.png — the one file electron-builder needs to derive an
// .icns, an .ico and every Linux size.
//
// Plain node, no rasteriser, no Electron. The mark is drawn as pixels by
// src/core/mark.ts and encoded by src/core/png.ts, for the reasons written at
// the top of both: nativeImage does not rasterise SVG and does not say so, and
// three icon files that can drift apart is not an identity.

import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');

// The two modules are TypeScript and this is plain node, so they are compiled
// here rather than depending on a build having been run first. Packaging must
// not be able to produce an app with last week's icon in it.
await build({
  entryPoints: [join(root, 'src', 'core', 'mark.ts'), join(root, 'src', 'core', 'png.ts')],
  outdir: join(root, 'dist', 'build-tools'),
  platform: 'node',
  format: 'esm',
  outExtension: { '.js': '.mjs' },
  bundle: true,
  logLevel: 'warning',
});
const { drawMark } = await import(join(root, 'dist', 'build-tools', 'mark.mjs'));
const { encodePNG } = await import(join(root, 'dist', 'build-tools', 'png.mjs'));

const SIZE = 1024;
const pixels = drawMark({
  size: SIZE,
  tile: true,
  // The same teal the HUD and the dashboard accent use. One colour, three
  // places, declared once.
  tileColour: [59, 109, 110],
  barColour: [255, 255, 255],
});

const out = join(here, '..', 'build');
mkdirSync(out, { recursive: true });
writeFileSync(join(out, 'icon.png'), encodePNG(pixels, SIZE, SIZE));
console.log(`[quill] wrote build/icon.png (${SIZE}x${SIZE})`);
