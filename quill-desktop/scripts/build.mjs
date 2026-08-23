#!/usr/bin/env node
// One build step for four bundles: the main process, three preloads, and the
// three renderers. esbuild rather than tsc-then-bundle because the whole point
// of a single command is that `npm start` is never the thing that is broken.

import { build, context } from 'esbuild';
import { cpSync, mkdirSync, rmSync, existsSync, readdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..');
const watch = process.argv.includes('--watch');
const tests = process.argv.includes('--tests');

const shared = {
  bundle: true,
  platform: 'node',
  target: 'node22',
  format: 'cjs',
  sourcemap: true,
  logLevel: 'info',
  // Electron and the native modules are resolved at runtime, never bundled.
  // `uiohook-napi` is an optional dependency on purpose: a machine where the
  // prebuilt binary is unavailable still gets a working app, minus push-to-talk.
  external: ['electron', 'uiohook-napi', '@huggingface/transformers'],
};

async function run(config) {
  if (watch) {
    const ctx = await context(config);
    await ctx.watch();
    return;
  }
  await build(config);
}

if (tests) {
  rmSync(join(root, 'dist-tests'), { recursive: true, force: true });
  mkdirSync(join(root, 'dist-tests'), { recursive: true });
  const testFiles = readdirSync(join(root, 'tests'))
    .filter((name) => name.endsWith('.test.ts'))
    .map((name) => join(root, 'tests', name));
  await build({
    ...shared,
    entryPoints: testFiles,
    outdir: join(root, 'dist-tests'),
    sourcemap: 'inline',
  });
  // The word list has to be findable from dist-tests too.
  mkdirSync(join(root, 'dist', 'data'), { recursive: true });
  cpSync(join(root, 'src', 'data'), join(root, 'dist', 'data'), { recursive: true });
  process.exit(0);
}

rmSync(join(root, 'dist'), { recursive: true, force: true });
mkdirSync(join(root, 'dist'), { recursive: true });

await run({
  ...shared,
  entryPoints: [join(root, 'src', 'main', 'main.ts')],
  outfile: join(root, 'dist', 'main', 'main.js'),
});

await run({
  ...shared,
  entryPoints: [
    join(root, 'src', 'preload', 'dashboard.ts'),
    join(root, 'src', 'preload', 'overlay.ts'),
    join(root, 'src', 'preload', 'stt.ts'),
  ],
  outdir: join(root, 'dist', 'preload'),
});

// Renderers run in a browser context. `@huggingface/transformers` is loaded
// from node_modules at runtime by the speech renderer rather than bundled: it
// pulls in onnxruntime-web with its own .wasm files, and bundling those into a
// single file is how the model backend silently stops loading.
const browser = {
  ...shared,
  platform: 'browser',
  target: 'chrome120',
  format: 'iife',
  external: [],
};
// `outfile` per bundle rather than one `outdir`: esbuild mirrors the source
// tree under an outdir, and the HTML that loads these sits one level up. A
// script tag that 404s renders a blank window with nothing in the console
// worth reading.
await run({ ...browser, entryPoints: [join(root, 'src', 'renderer', 'dashboard', 'dashboard.ts')], outfile: join(root, 'dist', 'renderer', 'dashboard.js') });
await run({ ...browser, entryPoints: [join(root, 'src', 'renderer', 'overlay', 'overlay.ts')], outfile: join(root, 'dist', 'renderer', 'overlay.js') });

// Static assets: HTML, CSS, the word list, the icons.
for (const [from, to] of [
  [join(root, 'src', 'renderer', 'dashboard', 'index.html'), join(root, 'dist', 'renderer', 'dashboard.html')],
  [join(root, 'src', 'renderer', 'dashboard', 'dashboard.css'), join(root, 'dist', 'renderer', 'dashboard.css')],
  [join(root, 'src', 'renderer', 'overlay', 'index.html'), join(root, 'dist', 'renderer', 'overlay.html')],
  [join(root, 'src', 'renderer', 'overlay', 'overlay.css'), join(root, 'dist', 'renderer', 'overlay.css')],
  [join(root, 'src', 'renderer', 'stt', 'index.html'), join(root, 'dist', 'renderer', 'stt.html')],
  [join(root, 'src', 'renderer', 'stt', 'stt.js'), join(root, 'dist', 'renderer', 'stt.js')],
]) {
  if (existsSync(from)) cpSync(from, to);
}

mkdirSync(join(root, 'dist', 'data'), { recursive: true });
cpSync(join(root, 'src', 'data'), join(root, 'dist', 'data'), { recursive: true });
console.log('[quill] build complete');
