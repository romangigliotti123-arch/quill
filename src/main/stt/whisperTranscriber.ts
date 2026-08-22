import { BrowserWindow, app, ipcMain } from 'electron';
import { MODEL_ORIGIN, speechLibraryPresent } from './modelProxy';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import type { Transcriber, TranscriberDelegate } from '../../core/contracts';
import type { QuillSettings } from '../../core/settings';

/// The main-process half of the speech engine.
///
/// Owns one hidden window, speaks to it over IPC, and presents the same
/// `Transcriber` contract the coordinator was written against on macOS —
/// prepare, start, stop, cancel, with partials arriving through a delegate.
/// Nothing downstream knows the recogniser changed.

export interface ModelProgress {
  file: string;
  progress: number;
  status: string;
}

export interface SpeechStatus {
  ready: boolean;
  device: 'webgpu' | 'wasm' | null;
  model: string | null;
  /// True when the GPU was asked for and the machine could not provide it. The
  /// user asked for a setting and did not get it, so they are told.
  fellBackToCPU: boolean;
  downloading: ModelProgress | null;
  lastError: string | null;
}

type Resolver<T> = { resolve: (value: T) => void };

/// The speech window's session, named once so `main.ts` can install the model
/// handler on it before the window is ever created.
export const SPEECH_PARTITION = 'quill-speech';

export class WhisperTranscriber implements Transcriber {
  delegate: TranscriberDelegate | null = null;

  private window: BrowserWindow | null = null;
  private ready: Promise<void> | null = null;
  private nextRequestId = 1;
  private readonly finals = new Map<number, Resolver<string>>();
  private readonly cancels = new Map<number, Resolver<void>>();
  private readonly deviceRequests = new Map<number, Resolver<{ id: string; label: string }[]>>();
  private status: SpeechStatus = {
    ready: false, device: null, model: null, fellBackToCPU: false,
    downloading: null, lastError: null,
  };
  private statusListeners: ((status: SpeechStatus) => void)[] = [];
  /// A dictation that has been asked to stop but whose final has not arrived.
  /// Guards `stop` against being called twice for one session.
  private stopping = false;

  constructor(
    private readonly settings: QuillSettings,
    /// Extra phrases to bias the recogniser with — the Dictionary, the snippet
    /// triggers, the transform triggers. Read per dictation, never captured, so
    /// a word added in the Dictionary reaches the very next thing you say.
    private readonly biasTerms: () => string[] = () => [],
  ) {
    ipcMain.on('stt:event', (_event, message: { channel: string; payload: unknown }) => {
      this.handleEvent(message.channel, message.payload);
    });
  }

  onStatus(listener: (status: SpeechStatus) => void): void {
    this.statusListeners.push(listener);
  }

  /// Download progress from the model proxy.
  ///
  /// Reported separately from the library's own `progress_callback` because
  /// this one counts bytes actually written to disk — the library's counts
  /// bytes it has been handed, which after the first launch is a file being
  /// read back at memory speed and reads as an instant 100%.
  noteDownload(progress: { file: string; received: number; total: number | null; done: boolean }): void {
    if (progress.done) {
      this.publishStatus({ downloading: null });
      return;
    }
    this.publishStatus({
      downloading: {
        file: progress.file,
        progress: progress.total ? (progress.received / progress.total) * 100 : 0,
        status: 'downloading',
      },
    });
  }

  get currentStatus(): SpeechStatus { return { ...this.status }; }

  private publishStatus(patch: Partial<SpeechStatus>): void {
    this.status = { ...this.status, ...patch };
    for (const listener of this.statusListeners) listener(this.currentStatus);
  }

  // MARK: - The window

  private async ensureWindow(): Promise<BrowserWindow> {
    if (this.window && !this.window.isDestroyed()) {
      if (this.ready) await this.ready;
      return this.window;
    }
    const window = new BrowserWindow({
      show: false,
      width: 480,
      height: 240,
      // Never in the taskbar, never in the window list. It is a worker.
      skipTaskbar: true,
      webPreferences: {
        // A session of its own, because `https` is intercepted inside it. See
        // `modelProxy.ts`: this window believes it is fetching from
        // `models.quill.invalid` and every one of those requests is answered by
        // the main process from disk or from its own fetch. Doing that to the
        // default session would take the dashboard's network with it.
        partition: SPEECH_PARTITION,
        preload: join(__dirname, '..', 'preload', 'stt.js'),
        contextIsolation: true,
        nodeIntegration: false,
        sandbox: false,
        // On, and it costs nothing here: the only origin this window can reach
        // is one the main process serves.
        webSecurity: true,
        backgroundThrottling: false,
      },
    });
    this.window = window;
    // The speech window has no UI, so a failure inside it is invisible unless
    // it is forwarded. Every console line it writes lands in the app's own log,
    // which is what makes "the model would not load" a debuggable sentence
    // rather than a shrug.
    window.webContents.on('console-message', (event) => {
      // eslint-disable-next-line no-console
      console.log(`[quill/stt/console] ${event.message} (${event.sourceId}:${event.lineNumber})`);
    });
    this.ready = new Promise<void>((resolve) => {
      const listener = (_event: unknown, message: { channel: string }): void => {
        if (message.channel !== 'stt:up') return;
        ipcMain.off('stt:event', listener as never);
        resolve();
      };
      ipcMain.on('stt:event', listener as never);
    });
    // Loaded over the model origin rather than from disk. A `file://` page can
    // never be cross-origin isolated, and without that the inference backend is
    // stuck on one thread — which is the whole CPU path on a machine with no
    // WebGPU, and that is most Windows and Linux machines. See
    // `crossOriginHeaders` in `modelProxy.ts`.
    await window.loadURL(`${MODEL_ORIGIN}/app/stt.html`);
    await this.ready;
    return window;
  }

  /// Where the model library and its WebAssembly live.
  ///
  /// In a packaged build these are outside the asar — `electron-builder` is
  /// told to unpack them — because a renderer's ESM loader cannot read a
  /// file:// URL inside an archive, and the failure mode if it could not find
  /// them would be an app that transcribes nothing and says nothing.
  private modelOptions(): {
    model: string; device: 'webgpu' | 'wasm';
    libraryURL: string; wasmURL: string; modelHost: string;
  } {
    return {
      model: this.settings.current.speechModel,
      device: this.settings.current.speechUseGPU ? 'webgpu' : 'wasm',
      // Same origin as the page, so the module import survives the
      // `require-corp` policy that buys the threads.
      libraryURL: `${MODEL_ORIGIN}/lib/transformers.js`,
      // Everything the library FETCHES goes through the proxy: the WebAssembly
      // backend and every model file. An https origin rather than a scheme of
      // our own, because the library's file-exists probe refuses to run against
      // anything else — the note in `modelProxy.ts` has the whole story.
      wasmURL: `${MODEL_ORIGIN}/runtime/`,
      modelHost: `${MODEL_ORIGIN}/hf/`,
    };
  }

  private async command(message: Record<string, unknown>): Promise<void> {
    const window = await this.ensureWindow();
    if (window.isDestroyed()) return;
    window.webContents.send('stt:command', message);
  }

  // MARK: - Transcriber

  async prepare(): Promise<void> {
    const options = this.modelOptions();
    if (!speechLibraryPresent()) {
      this.publishStatus({
        lastError: 'The speech library is missing from this build. Reinstall Quill.',
      });
      this.delegate?.didFail('The speech library is missing from this build.');
      return;
    }
    await this.command({ command: 'prepare', options });
  }

  async start(): Promise<void> {
    this.stopping = false;
    // The Dictionary, the snippet triggers and the transform triggers, joined
    // into Whisper's `initial_prompt`. Capped, because prompt tokens are
    // decoded before any audio is and a 500-word prompt costs latency on every
    // dictation.
    const terms = this.biasTerms();
    const prompt = terms.length === 0 ? null : buildBiasPrompt(terms);
    await this.command({
      command: 'start',
      options: this.modelOptions(),
      deviceId: this.settings.inputDeviceId,
      prompt,
    });
  }

  async stop(): Promise<string> {
    if (this.stopping) return '';
    this.stopping = true;
    const id = this.nextRequestId;
    this.nextRequestId += 1;
    const answer = new Promise<string>((resolve) => {
      this.finals.set(id, { resolve });
      // The recogniser is not allowed to hold a dictation hostage. If the final
      // never arrives — a crashed renderer, a model that wedged — the caller
      // gets whatever it already has rather than waiting forever with a HUD
      // saying "Transcribing".
      setTimeout(() => {
        if (!this.finals.has(id)) return;
        this.finals.delete(id);
        resolve('');
      }, 20_000);
    });
    await this.command({ command: 'stop', id });
    return answer;
  }

  async cancel(): Promise<void> {
    this.stopping = false;
    const id = this.nextRequestId;
    this.nextRequestId += 1;
    const done = new Promise<void>((resolve) => {
      this.cancels.set(id, { resolve });
      setTimeout(() => {
        if (!this.cancels.has(id)) return;
        this.cancels.delete(id);
        resolve();
      }, 3_000);
    });
    await this.command({ command: 'cancel', id });
    return done;
  }

  /// Transcribe audio handed in from outside, with no microphone involved.
  ///
  /// The instrument behind `QUILL_TRANSCRIBE`. Every other path through this
  /// class needs a person holding a key and speaking into a real device, which
  /// no build machine has — so on Windows and Linux the speech engine could
  /// only ever be verified by someone sitting in front of it. This runs the
  /// same pipeline, the same model proxy and the same model over a file,
  /// which makes "does speech work on this platform" a command rather than a
  /// favour.
  async transcribeSamples(samples: Float32Array, timeoutMs = 300_000): Promise<string> {
    const id = this.nextRequestId;
    this.nextRequestId += 1;
    const answer = new Promise<string>((resolve) => {
      this.finals.set(id, { resolve });
      setTimeout(() => {
        if (!this.finals.has(id)) return;
        this.finals.delete(id);
        resolve('');
      }, timeoutMs);
    });
    await this.command({
      command: 'samples',
      id,
      options: this.modelOptions(),
      // A plain array, because the structured clone across the IPC boundary
      // handles one and hands a typed array over as an object with numeric
      // keys — which arrives as a Float32Array of length zero.
      samples: Array.from(samples),
    });
    return answer;
  }

  /// The microphones this machine has, as the browser sees them.
  ///
  /// Labels only appear once microphone permission has been granted, which is
  /// why Settings shows "Grant access to see device names" rather than an
  /// unexplained list of hex ids.
  async devices(): Promise<{ id: string; label: string }[]> {
    const id = this.nextRequestId;
    this.nextRequestId += 1;
    const answer = new Promise<{ id: string; label: string }[]>((resolve) => {
      this.deviceRequests.set(id, { resolve });
      setTimeout(() => {
        if (!this.deviceRequests.has(id)) return;
        this.deviceRequests.delete(id);
        resolve([]);
      }, 4_000);
    });
    await this.command({ command: 'devices', id });
    return answer;
  }

  // MARK: - Events

  private handleEvent(channel: string, payload: unknown): void {
    switch (channel) {
      case 'stt:level':
        this.delegate?.didHearLevel(typeof payload === 'number' ? payload : 0);
        return;
      case 'stt:partial': {
        const { text, isFinal } = payload as { text: string; isFinal: boolean };
        this.delegate?.didProduce({ text, isFinal });
        return;
      }
      case 'stt:final': {
        const { id, text } = payload as { id: number; text: string };
        const waiter = this.finals.get(id);
        this.finals.delete(id);
        waiter?.resolve(text);
        return;
      }
      case 'stt:cancelled': {
        const { id } = payload as { id: number };
        const waiter = this.cancels.get(id);
        this.cancels.delete(id);
        waiter?.resolve();
        return;
      }
      case 'stt:devices': {
        const { id, devices } = payload as { id: number; devices: { id: string; label: string }[] };
        const waiter = this.deviceRequests.get(id);
        this.deviceRequests.delete(id);
        waiter?.resolve(devices);
        return;
      }
      case 'stt:inputLost':
        this.delegate?.didLoseInput();
        return;
      case 'stt:error': {
        const message = String(payload);
        this.publishStatus({ lastError: message });
        this.delegate?.didFail(message);
        return;
      }
      case 'stt:ready': {
        const { device, model, fellBack } = payload as {
          device: 'webgpu' | 'wasm'; model: string; fellBack?: boolean;
        };
        this.publishStatus({
          ready: true, device, model, fellBackToCPU: fellBack === true,
          downloading: null, lastError: null,
        });
        return;
      }
      case 'stt:progress':
        this.publishStatus({ downloading: payload as ModelProgress });
        return;
      case 'stt:started':
      case 'stt:up':
        return;
      case 'stt:log':
        // eslint-disable-next-line no-console
        console.log('[quill/stt]', payload);
        return;
      default:
        return;
    }
  }

  dispose(): void {
    if (this.window && !this.window.isDestroyed()) this.window.destroy();
    this.window = null;
  }
}

/// Whisper's `initial_prompt` is a *hint about the domain*, not a word list to
/// match against, and it is decoded before the audio — so it is capped, and the
/// terms are joined as a plausible sentence rather than a bare list.
///
/// This is the biasing channel Apple's recogniser accepted and then ignored:
/// measured on the macOS build, the same audio with 0 contextual strings and
/// with 25 produced byte-identical text. Whisper's actually works, which is why
/// the Dictionary is fed to it here and was fed to the corrector alone there.
export function buildBiasPrompt(terms: string[], limit = 220): string {
  let out = '';
  for (const term of terms) {
    const next = out.length === 0 ? term : `${out}, ${term}`;
    if (next.length > limit) break;
    out = next;
  }
  return out.length === 0 ? '' : `Terms that may appear: ${out}.`;
}
