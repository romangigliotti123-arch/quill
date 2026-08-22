import { app, net, type Session } from 'electron';
import { createWriteStream, existsSync, mkdirSync, renameSync, statSync, createReadStream } from 'node:fs';
import { dirname, join, normalize, sep } from 'node:path';
import { Readable } from 'node:stream';
import { dataDirectory } from '../../core/paths';

/// Where the speech model comes from, and why it does not come from the
/// renderer.
///
/// # The problem this solves
///
/// The first version let the speech window fetch the model straight from
/// Hugging Face. It does not work, and the reason is not a bug that can be
/// patched — it is structural. Hugging Face redirects every large file to
/// whichever CDN it is using this month: `cdn-lfs.huggingface.co` yesterday,
/// `cas-bridge.xethub.hf.co` last release, `us.aws.cdn.hf.co` today. A
/// `connect-src` that lists them is a list that goes stale, and the failure
/// when it does is a renderer that silently downloads nothing.
///
/// The alternatives were both worse. Widening the policy to `https:` gives a
/// window that runs downloaded WebAssembly the run of the internet. Turning
/// `webSecurity` off gives it the run of the filesystem too.
///
/// # What happens instead
///
/// The main process is the only thing that talks to the network, and it serves
/// what it fetched to the speech window — which lives in a session of its own
/// where `https` is intercepted, so it cannot reach the internet at all.
///
/// # Why an intercepted `https` origin and not a scheme of our own
///
/// It WAS a `quill://` scheme, and that silently broke the tokenizer.
///
/// `@huggingface/transformers` checks whether an optional file exists before
/// loading it, with a one-byte ranged GET — and that check begins
/// `if (!isValidUrl(url, ["http:", "https:"])) return null`. Under a custom
/// scheme every probe answers "does not exist", so the pipeline is built with
/// no tokenizer and no feature extractor, WITHOUT AN ERROR. The model weights
/// download, the pipeline constructs, and the first transcription dies on
/// `Cannot read properties of null (reading 'feature_extractor')` — 200 MB and
/// forty seconds away from the actual cause.
///
/// So the origin is `https://models.quill.invalid`, which the speech session
/// intercepts. `.invalid` is reserved by RFC 2606 and can never resolve, so if
/// this handler is ever missing the request fails instead of reaching a
/// stranger's server.
///
/// The isolation is now stronger than the policy it replaced: any https request
/// to any OTHER host from that window is refused by the handler itself, not by
/// a header the page would have to be trusted to respect.
///
/// Three things fall out of that, and all three are improvements rather than
/// consolations:
///
///  1. **The cache is a folder.** Models land in `<data>/models/…`, which the
///     user can see, copy to another machine, and delete. Before, they were in
///     Chromium's opaque Cache Storage, where "how much disk is this using" had
///     no answer and "erase everything" could not reach them.
///  2. **Offline is deterministic.** A file that is on disk is served from
///     disk, with no network call and no timeout to wait through. The second
///     launch of a machine with no connection behaves exactly like the first
///     launch of one with it.
///  3. **Progress is real.** The download is a stream this process owns, so the
///     percentage on screen is bytes actually written rather than a guess.

export interface ModelDownloadProgress {
  file: string;
  received: number;
  total: number | null;
  done: boolean;
}

type ProgressListener = (progress: ModelDownloadProgress) => void;

const listeners: ProgressListener[] = [];

export function onModelProgress(listener: ProgressListener): void {
  listeners.push(listener);
}

function report(progress: ModelDownloadProgress): void {
  for (const listener of listeners) listener(progress);
}

/// Where the three served trees live, packaged or not.
///
/// The asar makes this two guesses rather than one: `getAppPath()` points
/// inside the archive, and anything `electron-builder` was told to unpack sits
/// beside it under `app.asar.unpacked`. Resolving all three from the ONE root
/// that turned out to exist is what stops a build from finding the runtime and
/// missing the library.
let resolved: { runtimeRoot: string; appRoot: string; libraryRoot: string } | null = null;

function roots(): { runtimeRoot: string; appRoot: string; libraryRoot: string } {
  if (resolved) return resolved;
  const candidates = [
    join(app.getAppPath(), 'node_modules'),
    join(app.getAppPath().replace(/app\.asar$/, 'app.asar.unpacked'), 'node_modules'),
  ];
  const modules = candidates.find((path) => existsSync(join(path, 'onnxruntime-web', 'dist')))
    ?? candidates[0]!;
  resolved = {
    runtimeRoot: join(modules, 'onnxruntime-web', 'dist'),
    libraryRoot: join(modules, '@huggingface', 'transformers', 'dist'),
    appRoot: join(__dirname, '..', 'renderer'),
  };
  return resolved;
}

/// Whether the speech library is actually in this build.
///
/// Checked before anything is asked of the speech window, because the symptom
/// otherwise is a 404 on a module import inside a hidden window — invisible
/// unless someone is reading the log.
export function speechLibraryPresent(): boolean {
  return existsSync(join(roots().libraryRoot, 'transformers.js'));
}

/// The origin the speech window believes it is talking to.
///
/// Nothing resolves it. See the note above: `.invalid` cannot exist, and the
/// session handler answers every request to it from disk or from a fetch this
/// process makes.
export const MODEL_ORIGIN = 'https://models.quill.invalid';

export function modelDirectory(): string {
  return join(dataDirectory(), 'models');
}

/// Everything the model cache holds, for the Settings screen and for a person
/// wondering where 80 MB went.
export function modelCacheSize(): number {
  const root = modelDirectory();
  let total = 0;
  const walk = (path: string): void => {
    let entries: string[];
    try {
      // eslint-disable-next-line @typescript-eslint/no-var-requires, global-require
      entries = require('node:fs').readdirSync(path) as string[];
    } catch {
      return;
    }
    for (const entry of entries) {
      const child = join(path, entry);
      try {
        const stats = statSync(child);
        if (stats.isDirectory()) walk(child);
        else total += stats.size;
      } catch {
        continue;
      }
    }
  };
  walk(root);
  return total;
}

/// Called after `app.whenReady`, with the speech window's own session.
///
/// NOT the default session. This intercepts `https` wholesale, which is exactly
/// right for a window that must have no network and exactly wrong for anything
/// else.
export function installModelProtocol(ses: Session): void {
  const { runtimeRoot, appRoot, libraryRoot } = roots();

  ses.protocol.handle('https', async (request) => {
    const url = new URL(request.url);
    if (`${url.protocol}//${url.host}` !== MODEL_ORIGIN) {
      // The guarantee, enforced here rather than asked for in a header.
      trace('block', request.url, 403);
      return new Response('this window has no network', { status: 403 });
    }
    const path = decodeURIComponent(url.pathname);
    // `/app/<file>` — the speech page itself, and `/lib/<file>` — the library.
    //
    // Served from here rather than loaded off disk so the page has an ORIGIN,
    // which is what buys WebAssembly threads. See `crossOriginHeaders`.
    if (path.startsWith('/app/')) return serveLocal(appRoot, path.slice('/app/'.length));
    if (path.startsWith('/lib/')) return serveLocal(libraryRoot, path.slice('/lib/'.length));
    // `/runtime/<file>` — the WebAssembly the inference backend loads.
    if (path.startsWith('/runtime/')) return serveRuntime(runtimeRoot, path.slice('/runtime/'.length));
    // `/hf/<repo>/resolve/<rev>/<file>` — the model.
    if (path.startsWith('/hf/')) return serveModel(path.slice('/hf/'.length), request.headers.get('range'));
    return new Response('not found', { status: 404 });
  });
}

/// A path from a URL, made safe to join onto a directory.
///
/// Rejects anything that climbs out. The requests come from a page we wrote, so
/// this is belt and braces — but it is the one check whose absence turns a
/// caching proxy into an arbitrary-file-read.
function safeRelativePath(pathname: string): string | null {
  const trimmed = pathname.replace(/^\/+/, '');
  if (trimmed.length === 0) return null;
  const normalised = normalize(trimmed);
  if (normalised.startsWith('..') || normalised.includes(`..${sep}`)) return null;
  if (normalised.includes('\0')) return null;
  return normalised;
}

/// The headers that turn one thread into as many as the machine has.
///
/// WebAssembly threads need `SharedArrayBuffer`, which needs the page to be
/// cross-origin isolated, which needs these two headers — which a `file://`
/// page cannot have at all. That is why the speech page is SERVED rather than
/// loaded from disk: an origin is the price of admission, and the difference it
/// buys on the CPU path is several times over.
///
/// `require-corp` then means every subresource must opt in, which is why
/// `Cross-Origin-Resource-Policy` is on everything this handler returns.
function crossOriginHeaders(document: boolean): Record<string, string> {
  return {
    'Cross-Origin-Resource-Policy': 'same-origin',
    ...(document ? {
      'Cross-Origin-Opener-Policy': 'same-origin',
      'Cross-Origin-Embedder-Policy': 'require-corp',
      // Set here rather than through `webRequest`, because a response this
      // handler returns never passes through `onHeadersReceived` — the page was
      // running with NO policy at all until this line, and said so only in a
      // security warning nobody reads.
      'Content-Security-Policy': [
        `default-src 'self' ${MODEL_ORIGIN}`,
        `script-src 'self' ${MODEL_ORIGIN} 'wasm-unsafe-eval' blob:`,
        `worker-src 'self' ${MODEL_ORIGIN} blob:`,
        "style-src 'self' 'unsafe-inline'",
        "img-src 'self' data:",
        // The microphone arrives as a blob URL.
        "media-src 'self' blob:",
        `connect-src 'self' ${MODEL_ORIGIN} blob: data:`,
      ].join('; '),
    } : {}),
  };
}

const CONTENT_TYPES: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json',
  '.wasm': 'application/wasm',
};

async function serveLocal(root: string, pathname: string): Promise<Response> {
  const relative = safeRelativePath(pathname);
  if (!relative) return new Response('bad path', { status: 400 });
  const file = join(root, relative);
  if (!existsSync(file)) { trace('miss', pathname, 404); return new Response('not found', { status: 404 }); }
  const extension = relative.slice(relative.lastIndexOf('.'));
  return new Response(Readable.toWeb(createReadStream(file)) as ReadableStream<Uint8Array>, {
    status: 200,
    headers: {
      'Content-Type': CONTENT_TYPES[extension] ?? 'application/octet-stream',
      'Content-Length': String(statSync(file).size),
      ...crossOriginHeaders(extension === '.html'),
    },
  });
}

async function serveRuntime(root: string, pathname: string): Promise<Response> {
  const relative = safeRelativePath(pathname);
  if (!relative) return new Response('bad path', { status: 400 });
  const file = join(root, relative);
  if (!existsSync(file)) return new Response('not found', { status: 404 });
  return fileResponse(file);
}

async function serveModel(pathname: string, range: string | null): Promise<Response> {
  const relative = safeRelativePath(pathname);
  if (!relative) return new Response('bad path', { status: 400 });

  const cached = join(modelDirectory(), relative);
  if (existsSync(cached)) {
    if (range) { trace('probe', relative, 206); return probeResponse(statSync(cached).size); }
    trace('cache', relative, 200);
    return fileResponse(cached);
  }

  // A ranged request is the library asking whether a file EXISTS, not asking
  // for the file. Answering it by downloading is how a metadata check on a
  // 200 MB weights file turns into a 200 MB download that is then thrown away.
  // The range is forwarded, and whatever comes back is passed straight through
  // without being cached — a one-byte slice is not a model.
  if (range) {
    try {
      const head = await net.fetch(`https://huggingface.co/${relative.split(sep).join('/')}`, {
        headers: { Range: range },
        redirect: 'follow',
      });
      trace('probe', relative, head.status);
      return new Response(head.body, { status: head.status, headers: head.headers });
    } catch (error) {
      trace('probe', relative, 502, String(error));
      return new Response(String(error), { status: 502 });
    }
  }

  const remote = `https://huggingface.co/${relative.split(sep).join('/')}`;
  let response: Response;
  try {
    // `net.fetch` rather than the global one: it uses Chromium's network stack,
    // so it follows the redirect chain to whichever CDN Hugging Face is using
    // and honours the system proxy — which a laptop on a corporate network
    // needs and `undici` would not see.
    response = await net.fetch(remote, { redirect: 'follow' });
  } catch (error) {
    // A missing file that the library was only probing for — it asks for
    // several quantisation variants and uses the first that exists — must come
    // back as a 404, not as an exception, or the caller reports "failed to
    // fetch" for a file it never needed.
    trace('error', relative, 502, String(error));
    return new Response(String(error), { status: 502 });
  }
  if (!response.ok || !response.body) {
    trace('miss', relative, response.status);
    return new Response(response.statusText, { status: response.status });
  }
  trace('fetch', relative, 200);

  const total = Number.parseInt(response.headers.get('content-length') ?? '', 10);
  const name = relative.split(sep).pop() ?? relative;
  return new Response(teeToDisk(response.body, cached, name, Number.isFinite(total) ? total : null), {
    status: 200,
    headers: {
      'Content-Type': response.headers.get('content-type') ?? 'application/octet-stream',
      ...(Number.isFinite(total) ? { 'Content-Length': String(total) } : {}),
      ...crossOriginHeaders(false),
    },
  });
}

/// Streams the body to the caller and to disk at the same time.
///
/// Written to a `.part` and renamed at the end, so an interrupted download can
/// never be mistaken for a complete model — the next launch would load a
/// truncated ONNX file and fail somewhere far away from the cause.
function teeToDisk(
  body: ReadableStream<Uint8Array>,
  destination: string,
  name: string,
  total: number | null,
): ReadableStream<Uint8Array> {
  mkdirSync(dirname(destination), { recursive: true });
  const temporary = `${destination}.part`;
  const file = createWriteStream(temporary);
  const reader = body.getReader();
  let received = 0;

  return new ReadableStream<Uint8Array>({
    async pull(controller) {
      const { done, value } = await reader.read();
      if (done) {
        await new Promise<void>((resolve) => file.end(resolve));
        try {
          renameSync(temporary, destination);
        } catch {
          /* a concurrent request finished first; its copy is as good as ours */
        }
        report({ file: name, received, total, done: true });
        controller.close();
        return;
      }
      file.write(value);
      received += value.byteLength;
      report({ file: name, received, total, done: false });
      controller.enqueue(value);
    },
    cancel(reason) {
      void reader.cancel(reason);
      file.destroy();
    },
  });
}

/// The answer to "does this exist and how big is it", for a file already here.
function probeResponse(size: number): Response {
  return new Response(new Uint8Array(1), {
    status: 206,
    headers: {
      'Content-Range': `bytes 0-0/${size}`,
      'Content-Length': '1',
      'Accept-Ranges': 'bytes',
      ...crossOriginHeaders(false),
    },
  });
}

function fileResponse(path: string): Response {
  const size = statSync(path).size;
  const stream = Readable.toWeb(createReadStream(path)) as ReadableStream<Uint8Array>;
  return new Response(stream, {
    status: 200,
    headers: {
      'Content-Length': String(size),
      'Content-Type': contentType(path),
      ...crossOriginHeaders(false),
    },
  });
}

function contentType(path: string): string {
  if (path.endsWith('.json')) return 'application/json';
  if (path.endsWith('.wasm')) return 'application/wasm';
  if (path.endsWith('.mjs') || path.endsWith('.js')) return 'text/javascript';
  if (path.endsWith('.txt')) return 'text/plain';
  return 'application/octet-stream';
}

/// Every request the model layer makes, when `QUILL_PROXY_LOG` is set.
///
/// The instrument that found a pipeline building "successfully" with a null
/// feature extractor: the ONNX weights arrived and three small JSON files did
/// not, and nothing anywhere said so.
function trace(kind: string, path: string, status: number, detail = ''): void {
  if (!process.env.QUILL_PROXY_LOG) return;
  // eslint-disable-next-line no-console
  console.log(`[quill/proxy] ${status} ${kind.padEnd(5)} ${path}${detail ? ` ${detail}` : ''}`);
}
