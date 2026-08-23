import { readFileSync } from 'node:fs';
import { BrowserWindow, app, globalShortcut, session } from 'electron';
import { decodeWav, resample } from '../core/wav';
import { ensureDataDirectory } from '../core/paths';
import { QuillSettings } from '../core/settings';
import { HistoryStore } from '../core/stores/history';
import { SnippetStore } from '../core/stores/snippets';
import { NoteStore } from '../core/stores/notes';
import { VocabularyBook } from '../core/stores/vocabulary';
import { StyleStore } from '../core/style/styleProfile';
import { TransformStore } from '../core/transforms/transforms';
import { FastCleaner } from '../core/cleanup/fastCleaner';
import { VocabularyCorrector } from '../core/cleanup/vocabularyCorrector';
import { AICleaner } from '../core/ai/aiCleaner';
import { NIMClient, loadNIMKey } from '../core/ai/nimClient';
import { CLEANUP_SYSTEM_PROMPT } from '../core/ai/prompts';
import { CommandRouter } from '../core/transforms/commandRouter';
import { HotkeyEngine, SettingsBindings } from './hotkey/hotkeyEngine';
import { SPEECH_PARTITION, WhisperTranscriber } from './stt/whisperTranscriber';
import { WindowWatcher } from './platform/windowWatcher';
import { TextInserter } from './injection/textInserter';
import { LiveTyper } from './injection/liveTyper';
import { InsertionUndo } from './injection/insertionUndo';
import { ClipboardSelectionReader } from './transforms/selectionReader';
import { TransformEngine } from './transforms/transformEngine';
import { DictationCoordinator } from './dictation/coordinator';
import { OverlayWindow } from './windows/overlayWindow';
import { DashboardWindow } from './windows/dashboardWindow';
import { TrayIcon } from './windows/trayIcon';
import { registerIPC } from './ipc';
import { MODEL_ORIGIN, installModelProtocol, onModelProgress } from './stt/modelProxy';

/// Boot.
///
/// One place where every seam is joined, and deliberately the only file that
/// knows about all of them. Everything below is constructed once, wired once,
/// and never looked up again — a subsystem that reaches for a singleton is a
/// subsystem that cannot be tested, which is the mistake the macOS build spent
/// an afternoon undoing.

// A second copy of a dictation app is not a second window, it is a second
// keyboard hook and a second microphone. Whichever instance loses raises the
// window of the one that won and exits.
//
// `app.exit` rather than `app.quit`: quit is a REQUEST that unwinds through the
// event loop, and everything below this line — the stores, the keyboard hook,
// the tray — is constructed before it lands. The loser of the race would spend
// a moment with a second global hook installed, which is the one thing this
// check exists to prevent. It also says so out loud: a launch that appears to
// do nothing at all is the single most confusing thing a tray app can do.
if (!app.requestSingleInstanceLock()) {
  // eslint-disable-next-line no-console
  console.log('[quill] another copy is already running; raising its window and exiting');
  app.exit(0);
}

// Electron's own userData is left where it is; Quill's data lives in a folder a
// person would look in, and `paths.ts` says why. This only makes sure it exists
// before any store tries to write.
ensureDataDirectory();

// Must happen before `app.whenReady`, which is a hard requirement of Electron's
// scheme registry rather than a style choice.
const settings = new QuillSettings();
const overlay = new OverlayWindow();
const dashboard = new DashboardWindow();
const tray = new TrayIcon();
const windows = new WindowWatcher();

let coordinator: DictationCoordinator | null = null;
let registerShortcuts: () => void = () => {};

app.on('second-instance', () => dashboard.show());

app.whenReady().then(() => {
  const speechSession = session.fromPartition(SPEECH_PARTITION);
  installModelProtocol(speechSession);

  // Two policies, because there are two kinds of window here and giving them
  // one policy means giving the looser one to both.
  //
  // The dashboard and the overlay display the user's own text and reach nothing
  // at all. The speech window runs WebAssembly compiled from a downloaded model
  // and fetches from the one origin the main process serves — which is not a
  // real host and cannot resolve, so this line is a second lock on a door that
  // `modelProxy.ts` has already bolted.
  applyPolicy(session.defaultSession, "default-src 'self'; "
    + "script-src 'self'; style-src 'self' 'unsafe-inline'; "
    + "img-src 'self' data:; media-src 'self' blob:; "
    + "connect-src 'self' data:");
  applyPolicy(speechSession, "default-src 'self'; "
    + `script-src 'self' ${MODEL_ORIGIN} 'wasm-unsafe-eval' blob:; `
    + `worker-src 'self' ${MODEL_ORIGIN} blob:; `
    + "style-src 'self' 'unsafe-inline'; "
    + "img-src 'self' data:; "
    // The microphone stream is a blob URL, and without this the capture graph
    // is refused with a policy violation that names no microphone.
    + "media-src 'self' blob:; "
    + `connect-src 'self' ${MODEL_ORIGIN} blob: data:`);

  // The microphone is asked for by the speech window and nothing else. Every
  // other permission — camera, location, notifications, MIDI — is refused
  // outright rather than left to whatever Chromium's default happens to be.
  //
  // `media` covers audio and video together, so the media types are checked as
  // well: a window that can quietly turn a camera on is not a thing a dictation
  // app should be able to become through one careless edit.
  session.defaultSession.setPermissionRequestHandler((_contents, permission, callback, details) => {
    if (permission !== 'media') { callback(false); return; }
    const types = (details as { mediaTypes?: string[] }).mediaTypes ?? ['audio'];
    callback(types.every((type) => type === 'audio'));
  });

  const stores = {
    history: new HistoryStore(),
    snippets: SnippetStore.shared(),
    notes: NoteStore.shared(),
    vocabulary: VocabularyBook.shared(),
    style: StyleStore.shared(),
    transforms: TransformStore.shared(),
  };

  // The Dictionary, the snippet triggers and the transform triggers, all read
  // per dictation rather than captured — a word added in the Dictionary has to
  // reach the very next thing you say, which is the bug the macOS build shipped
  // and then had to design out of four separate places.
  const biasTerms = (): string[] => [
    ...stores.vocabulary.terms,
    ...stores.snippets.phrases,
    ...stores.transforms.phrases,
  ];

  const speech = new WhisperTranscriber(settings, biasTerms);
  // The download is a stream the main process owns, so the percentage on screen
  // is bytes actually written rather than a guess.
  onModelProgress((progress) => speech.noteDownload(progress));
  const inserter = new TextInserter();
  const liveTyper = new LiveTyper(windows);
  const undo = new InsertionUndo(windows);
  const hotkey = new HotkeyEngine(new SettingsBindings(settings));

  // The AI layer is optional in the strongest sense: with no key the cleaner
  // never reaches for the network, and every screen that mentions it says so.
  const nim = new NIMClient({
    systemPrompt: CLEANUP_SYSTEM_PROMPT,
    vocabulary: stores.vocabulary.terms,
  });
  const cleaner = new AICleaner({
    client: nim,
    fast: new FastCleaner(new VocabularyCorrector({ book: stores.vocabulary })),
    book: stores.vocabulary,
    style: () => stores.style.profile,
  });

  const engine = new TransformEngine({
    store: stores.transforms,
    completer: loadNIMKey() === null ? null : nim,
    selection: new ClipboardSelectionReader(windows),
    inserter,
    vocabulary: () => stores.vocabulary.terms,
    lastDictation: () => coordinator?.lastInsertion ?? null,
  });

  coordinator = new DictationCoordinator({
    hotkey,
    transcriber: speech,
    inserter,
    overlay,
    cleaner,
    history: stores.history,
    snippets: stores.snippets,
    settings,
    liveTyper,
    undo,
    windows,
    transforms: { router: new CommandRouter(), engine },
  });

  coordinator.onActivity = (activity) => {
    dashboard.send('quill:activity', activity);
    tray.rebuild(trayActions);
  };

  const trayActions = {
    toggleDashboard: () => dashboard.toggle(),
    toggleDictation: () => coordinator?.toggleHandsFree(),
    isRecording: () => coordinator?.isBusy ?? false,
    undo: () => { void coordinator?.requestUndo(); },
    hasUndo: () => undo.isArmed,
    quit: () => { quitting = true; app.quit(); },
  };

  windows.start();
  tray.create(trayActions);

  registerIPC({
    settings,
    history: stores.history,
    snippets: stores.snippets,
    notes: stores.notes,
    vocabulary: stores.vocabulary,
    style: stores.style,
    transforms: stores.transforms,
    speech,
    windows,
    engine,
    coordinator: () => coordinator,
    nimStatus: () => nim.status(),
    onSettingsChanged: () => { registerShortcuts(); applyLoginItem(); },
    relaunch: () => { app.relaunch(); quitting = true; app.exit(0); },
  });

  /// The shortcuts that are registered globally rather than watched.
  ///
  /// A global accelerator is CONSUMED by the OS, which the keyboard hook cannot
  /// do — so anything that must not also reach the focused app has to be one of
  /// these. That is the undo chord (a delete that fires twice is worse than no
  /// feature) and every transform chord (a chord that also types its letter is
  /// unusable).
  ///
  /// The dictation key itself is deliberately NOT here: a global accelerator
  /// cannot express a bare modifier, cannot tell a hold from a tap, and cannot
  /// report a key-up. That is the whole reason Quill watches the keyboard.
  registerShortcuts = (): void => {
    globalShortcut.unregisterAll();
    const values = settings.current;

    if (values.undoChord && values.undoChordAccelerator.length > 0) {
      register(values.undoChordAccelerator, () => { void coordinator?.requestUndo(); });
    }

    // A way in that does not depend on a tray icon the desktop may refuse to
    // draw. On GNOME under Wayland this is frequently the only one.
    register(process.platform === 'darwin' ? 'Command+Alt+Q' : 'Control+Alt+Q',
      () => dashboard.show());

    for (const transform of stores.transforms.enabled) {
      if (!transform.accelerator) continue;
      register(transform.accelerator, () => {
        void (async () => {
          // A chord and a spoken trigger go through the same engine, so the two
          // cannot behave differently — and the engine is the thing that
          // refuses to touch the document until it has a result.
          overlay.show({ kind: 'transcribing' });
          const outcome = await engine.runTransform(transform);
          overlay.show(outcome.kind === 'done'
            ? { kind: 'inserted', words: outcome.success.text.split(/\s+/).filter(Boolean).length }
            : { kind: 'error', message: outcome.reason });
          setTimeout(() => overlay.hide(), outcome.kind === 'done' ? 900 : 2_200);
        })();
      });
    }
  };

  // A transform edited in the dashboard may have gained or lost a chord.
  stores.transforms.onChange(() => registerShortcuts());

  coordinator.start();
  registerShortcuts();
  applyLoginItem();

  // Warm the model in the background rather than on the first key press. A
  // first dictation that pays for a 100 MB download while the user holds a key
  // is a first impression of an app that does not work.
  setTimeout(() => { void speech.prepare(); }, 1_500);

  if (settings.current.showDashboardOnLaunch) dashboard.show();

  // See `DashboardWindow.capture`. Development only, and it quits when done so
  // a capture run cannot leave a stray copy holding the keyboard hook.
  // A one-shot DOM probe. `QUILL_PROBE=<expression>` evaluates it in the
  // dashboard and prints the result — the smallest instrument that answers "why
  // does that element look wrong" without a human at the screen.
  const probe = process.env.QUILL_PROBE;
  if (probe) {
    dashboard.show();
    setTimeout(() => {
      void dashboard.evaluate(probe).then((value) => {
        // eslint-disable-next-line no-console
        console.log('[quill/probe]', JSON.stringify(value, null, 2));
        quitting = true;
        app.exit(0);
      });
    }, 2_500);
  }

  // The speech engine, verified without a microphone.
  //
  // `QUILL_TRANSCRIBE=<file.wav>` transcribes that file and prints the text.
  // This is the only way to answer "does dictation work on this machine" on a
  // build agent, and the only check that exercises the whole chain at once: the
  // model download, the model proxy, the WebAssembly that packaging is
  // allowed to trim, and the model itself.
  const transcribeFile = process.env.QUILL_TRANSCRIBE;
  if (transcribeFile) {
    void (async () => {
      const started = Date.now();
      try {
        const audio = decodeWav(new Uint8Array(readFileSync(transcribeFile)));
        const samples = resample(audio.samples, audio.sampleRate, 16_000);
        const text = await speech.transcribeSamples(samples);
        // eslint-disable-next-line no-console
        console.log('[quill/transcribe]', JSON.stringify({
          file: transcribeFile,
          sourceRate: audio.sampleRate,
          channels: audio.channels,
          seconds: Number((samples.length / 16_000).toFixed(2)),
          elapsedMs: Date.now() - started,
          text,
        }, null, 2));
        // A non-zero exit on empty text, so this is usable as a CI check rather
        // than only as something to read. Every way the speech engine can fail
        // ends in an empty string — a model that would not load, a proxy that
        // 404s, a decoder the runtime cannot build a session for.
        quitting = true;
        app.exit(text.trim().length > 0 ? 0 : 2);
        return;
      } catch (error) {
        // eslint-disable-next-line no-console
        console.error('[quill/transcribe] failed:', error);
        quitting = true;
        app.exit(1);
      }
    })();
  }

  const captureTo = process.env.QUILL_CAPTURE;
  if (captureTo) {
    dashboard.show();
    setTimeout(() => {
      void dashboard.capture(captureTo, [
        'insights', 'dictation', 'dictionary', 'snippets', 'style',
        'transforms', 'notetaker', 'scratchpad', 'settings', 'help',
      ]).then(() => { quitting = true; app.exit(0); });
    }, 2_500);
  }

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) dashboard.show();
  });
});

function applyPolicy(ses: Electron.Session, policy: string): void {
  ses.webRequest.onHeadersReceived((details, callback) => {
    callback({
      responseHeaders: { ...details.responseHeaders, 'Content-Security-Policy': [policy] },
    });
  });
}

function register(accelerator: string, handler: () => void): void {
  try {
    if (!globalShortcut.register(accelerator, handler)) {
      // eslint-disable-next-line no-console
      console.warn(`[quill] ${accelerator} is already taken by another application`);
    }
  } catch (error) {
    // eslint-disable-next-line no-console
    console.warn(`[quill] ${accelerator} could not be registered`, error);
  }
}

function applyLoginItem(): void {
  try {
    app.setLoginItemSettings({
      openAtLogin: settings.current.launchAtLogin,
      // Starting hidden is the point of a login item for an app that lives in
      // the tray: a dashboard that opens itself every time you turn the machine
      // on is a dashboard you will turn off.
      openAsHidden: true,
      args: ['--hidden'],
    });
  } catch (error) {
    // eslint-disable-next-line no-console
    console.warn('[quill] could not set the login item', error);
  }
}

/// Closing the last window is not quitting.
///
/// The whole app is a key you hold; a dashboard is where you go to look at it.
/// Quitting when the window closes would mean the dictation key stops working
/// because somebody tidied their desktop.
let quitting = false;
app.on('before-quit', () => { quitting = true; });
app.on('window-all-closed', () => {
  if (quitting) app.quit();
});

app.on('will-quit', () => {
  globalShortcut.unregisterAll();
  windows.stop();
  tray.dispose();
  overlay.dispose();
});
