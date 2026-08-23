import { BrowserWindow, app, ipcMain, shell } from 'electron';
import { QuillSettings, type SettingsValues } from '../core/settings';
import { HistoryStore, type DictationRecord } from '../core/stores/history';
import { SnippetStore, type Snippet } from '../core/stores/snippets';
import { NoteStore, type Note } from '../core/stores/notes';
import { VocabularyBook } from '../core/stores/vocabulary';
import { harvestSuggestions } from '../core/stores/vocabularyHarvest';
import {
  StyleStore, type StyleProfile, type StylePreset, styleSummaryLine,
} from '../core/style/styleProfile';
import { TransformStore, type Transform } from '../core/transforms/transforms';
import { computeInsights, type InsightsRange } from '../core/insights/insightsMetrics';
import { dataDirectory, dataSummary, eraseEverything } from '../core/paths';
import { dictionaryIsLoaded, dictionarySize } from '../core/text/dictionary';
import { loadNIMKey, nimKeyFingerprint, saveNIMKey, type NIMStatus } from '../core/ai/nimClient';
import type { WhisperTranscriber, SpeechStatus } from './stt/whisperTranscriber';
import type { DictationCoordinator } from './dictation/coordinator';
import type { WindowWatcher } from './platform/windowWatcher';
import { keyboardIsAvailable } from './platform/keyboard';
import type { TransformEngine } from './transforms/transformEngine';
import { bindingDisplayName, bindingNamed, bindingMayBeAltGr, ASSIGNABLE_BINDINGS } from '../core/hotkey/binding';

/// Everything the dashboard is allowed to ask for.
///
/// One `invoke` channel with a discriminated payload rather than thirty
/// channels, so the preload stays four lines and the surface a compromised
/// renderer could reach is enumerable by reading one file. Every handler here
/// is a read or a write the user could perform through the UI anyway — nothing
/// here executes a path, spawns a process, or reads a file the user did not
/// name.

export interface DiagnosticsReport {
  version: string;
  electron: string;
  platform: string;
  arch: string;
  sessionType: string | null;
  dataDirectory: string;
  keyboardHook: boolean;
  focusTracking: { working: boolean; reason: string | null; active: string | null };
  dictionary: { loaded: boolean; words: number };
  speech: SpeechStatus;
  aiKey: { configured: boolean; fingerprint: string };
  files: { name: string; bytes: number }[];
}

export interface Wiring {
  settings: QuillSettings;
  history: HistoryStore;
  snippets: SnippetStore;
  notes: NoteStore;
  vocabulary: VocabularyBook;
  style: StyleStore;
  transforms: TransformStore;
  speech: WhisperTranscriber;
  windows: WindowWatcher;
  engine: TransformEngine;
  coordinator: () => DictationCoordinator | null;
  nimStatus: () => Promise<NIMStatus>;
  onSettingsChanged: () => void;
  relaunch: () => void;
}

export function registerIPC(wiring: Wiring): void {
  const send = (channel: string, payload: unknown): void => {
    for (const window of BrowserWindow.getAllWindows()) {
      if (window.isDestroyed()) continue;
      window.webContents.send(channel, payload);
    }
  };

  wiring.settings.on('changed', (values: SettingsValues) => {
    send('quill:settings', values);
    wiring.onSettingsChanged();
  });
  wiring.speech.onStatus((status) => send('quill:speech', status));
  wiring.windows.onChange((window) => send('quill:focus', window));

  ipcMain.handle('quill:invoke', async (_event, request: { name: string; payload?: unknown }) => {
    const { name } = request;
    const payload = request.payload as never;
    switch (name) {
      // MARK: Settings
      case 'settings.get':
        return wiring.settings.current;
      case 'settings.set': {
        const patch = payload as Partial<SettingsValues>;
        wiring.settings.update((values) => Object.assign(values, patch));
        return wiring.settings.current;
      }
      case 'settings.captureHotkey': {
        wiring.settings.isCapturingHotkey = (payload as { capturing: boolean }).capturing;
        return true;
      }
      case 'settings.bindings':
        return ASSIGNABLE_BINDINGS.map((name_) => {
          const binding = bindingNamed(name_);
          return {
            name: name_,
            display: bindingDisplayName(binding),
            mayBeAltGr: bindingMayBeAltGr(binding),
          };
        });

      // MARK: Speech
      case 'speech.status':
        return wiring.speech.currentStatus;
      case 'speech.devices':
        return wiring.speech.devices();
      case 'speech.prepare':
        await wiring.speech.prepare();
        return wiring.speech.currentStatus;

      // MARK: History
      case 'history.list':
        return encodeRecords(wiring.history.all);
      case 'history.insights': {
        const range = (payload as { range?: InsightsRange } | undefined)?.range ?? 'month';
        return computeInsights(wiring.history.all, {
          vocabulary: wiring.vocabulary.current,
          range,
        });
      }

      // MARK: Dictionary
      case 'vocabulary.list':
        return wiring.vocabulary.terms;
      case 'vocabulary.add':
        return wiring.vocabulary.add(String(payload));
      case 'vocabulary.remove':
        return wiring.vocabulary.remove(String(payload));
      case 'vocabulary.suggestions':
        return harvestSuggestions({ existing: wiring.vocabulary.current });

      // MARK: Snippets
      case 'snippets.list':
        return encodeSnippets(wiring.snippets.ordered);
      case 'snippets.upsert':
        return encodeSnippet(wiring.snippets.upsert(decodeSnippet(payload)));
      case 'snippets.remove':
        wiring.snippets.remove(String(payload));
        return true;

      // MARK: Notes
      case 'notes.list':
        return encodeNotes(wiring.notes.all);
      case 'notes.upsert':
        return encodeNote(wiring.notes.upsert(decodeNote(payload)));
      case 'notes.delete':
        wiring.notes.delete(String(payload));
        return true;

      // MARK: Style
      case 'style.get': {
        const profile = wiring.style.profile;
        return { profile: encodeProfile(profile), summary: styleSummaryLine(profile) };
      }
      case 'style.setPreset':
        wiring.style.update((profile) => { profile.preset = payload as StylePreset; });
        return true;
      case 'style.setLearning':
        wiring.style.update((profile) => { profile.isLearningEnabled = payload as boolean; });
        return true;
      case 'style.removePhrasing':
        wiring.style.update((profile) => {
          profile.phrasings = profile.phrasings.filter(
            (phrasing) => `${phrasing.from}→${phrasing.to}` !== String(payload),
          );
        });
        return true;
      case 'style.forget':
        wiring.style.update((profile) => {
          profile.spelling = { votes: {}, lastObserved: null };
          profile.contractions = { votes: {}, lastObserved: null };
          profile.formality = { votes: {}, lastObserved: null };
          profile.oxfordComma = { votes: {}, lastObserved: null };
          profile.exclamations = { votes: {}, lastObserved: null };
          profile.sentenceLength = { total: 0, count: 0 };
          profile.phrasings = [];
          profile.correctionCount = 0;
          profile.lastLearned = null;
        });
        return true;

      // MARK: Transforms
      case 'transforms.list':
        return encodeTransforms(wiring.transforms.ordered);
      case 'transforms.upsert':
        return encodeTransform(wiring.transforms.upsert(decodeTransform(payload)));
      case 'transforms.remove':
        wiring.transforms.remove(String(payload));
        return true;
      case 'transforms.run': {
        const transform = wiring.transforms.transform(String(payload));
        if (!transform) return { kind: 'failed', reason: 'That transform no longer exists.' };
        const outcome = await wiring.engine.runTransform(transform);
        return outcome.kind === 'done'
          ? { kind: 'done', text: outcome.success.text, via: outcome.success.via }
          : outcome;
      }

      // MARK: AI
      case 'ai.key':
        return keyReport();
      case 'ai.setKey':
        saveNIMKey(String(payload));
        return keyReport();
      case 'ai.status':
        return wiring.nimStatus();

      // MARK: App
      case 'app.diagnostics':
        return diagnostics(wiring);
      case 'app.dataSummary':
        return dataSummary();
      case 'app.eraseEverything': {
        const removed = eraseEverything();
        // Nothing in memory is touched, and that is on purpose: every store
        // holds its records in memory and writes the whole file on the next
        // change, so a running Quill would put its history back within a
        // dictation. The only honest way to finish this is to relaunch.
        setTimeout(() => wiring.relaunch(), 400);
        return removed;
      }
      case 'app.openDataDirectory':
        void shell.openPath(dataDirectory());
        return true;
      case 'app.openExternal': {
        // Only ever https, and only ever a URL the app itself put in the UI.
        // A renderer that could ask the shell to open anything is a renderer
        // that can run a program.
        const url = String(payload);
        if (!/^https:\/\//.test(url)) return false;
        void shell.openExternal(url);
        return true;
      }
      case 'app.toggleDictation':
        wiring.coordinator()?.toggleHandsFree();
        return true;
      case 'app.relaunch':
        wiring.relaunch();
        return true;
      case 'app.quit':
        app.quit();
        return true;

      default:
        throw new Error(`unknown request ${name}`);
    }
  });

  function keyReport(): { configured: boolean; fingerprint: string } {
    const key = loadNIMKey();
    return {
      configured: key !== null,
      fingerprint: key ? nimKeyFingerprint(key) : '',
    };
  }
}

function diagnostics(wiring: Wiring): DiagnosticsReport {
  const key = loadNIMKey();
  return {
    version: app.getVersion(),
    electron: process.versions.electron ?? '',
    platform: `${process.platform} ${process.getSystemVersion?.() ?? ''}`.trim(),
    arch: process.arch,
    sessionType: process.env.XDG_SESSION_TYPE ?? null,
    dataDirectory: dataDirectory(),
    keyboardHook: keyboardIsAvailable(),
    focusTracking: {
      working: wiring.windows.active !== null,
      reason: wiring.windows.reason,
      active: wiring.windows.active?.process ?? null,
    },
    dictionary: { loaded: dictionaryIsLoaded(), words: dictionarySize() },
    speech: wiring.speech.currentStatus,
    aiKey: { configured: key !== null, fingerprint: key ? nimKeyFingerprint(key) : '' },
    files: dataSummary(),
  };
}

// MARK: - Wire encoding
//
// `Date` survives Electron's structured clone, but the renderer's own code is
// simpler when every timestamp is a number — one representation, no
// `instanceof Date` checks scattered through the view layer.

function encodeRecords(records: DictationRecord[]): unknown[] {
  return records.map((record) => ({ ...record, date: record.date.getTime() }));
}

function encodeSnippet(snippet: Snippet): unknown {
  return {
    ...snippet,
    lastUsed: snippet.lastUsed?.getTime() ?? null,
    created: snippet.created.getTime(),
  };
}
function encodeSnippets(snippets: Snippet[]): unknown[] { return snippets.map(encodeSnippet); }

function decodeSnippet(raw: unknown): Snippet {
  const value = raw as Record<string, unknown>;
  return {
    id: String(value.id),
    phrase: String(value.phrase ?? ''),
    replacement: String(value.replacement ?? ''),
    mode: value.mode === 'alone' ? 'alone' : 'anywhere',
    isEnabled: value.isEnabled !== false,
    useCount: Number(value.useCount ?? 0),
    lastUsed: value.lastUsed ? new Date(Number(value.lastUsed)) : null,
    created: value.created ? new Date(Number(value.created)) : new Date(),
  };
}

function encodeNote(note: Note): unknown {
  return { ...note, created: note.created.getTime(), modified: note.modified.getTime() };
}
function encodeNotes(notes: Note[]): unknown[] { return notes.map(encodeNote); }

function decodeNote(raw: unknown): Note {
  const value = raw as Record<string, unknown>;
  return {
    id: String(value.id),
    title: String(value.title ?? ''),
    body: String(value.body ?? ''),
    created: value.created ? new Date(Number(value.created)) : new Date(),
    modified: value.modified ? new Date(Number(value.modified)) : new Date(),
    isPinned: value.isPinned === true,
  };
}

function encodeTransform(transform: Transform): unknown {
  return {
    ...transform,
    lastUsed: transform.lastUsed?.getTime() ?? null,
    created: transform.created.getTime(),
  };
}
function encodeTransforms(transforms: Transform[]): unknown[] {
  return transforms.map(encodeTransform);
}

function decodeTransform(raw: unknown): Transform {
  const value = raw as Record<string, unknown>;
  return {
    id: String(value.id),
    name: String(value.name ?? ''),
    instruction: String(value.instruction ?? ''),
    triggers: Array.isArray(value.triggers) ? (value.triggers as string[]) : [],
    keywords: Array.isArray(value.keywords) ? (value.keywords as string[]) : [],
    accelerator: typeof value.accelerator === 'string' && value.accelerator.length > 0
      ? value.accelerator : null,
    target: value.target === 'selection' || value.target === 'lastDictation'
      ? value.target : 'automatic',
    offline: (value.offline ?? 'none') as Transform['offline'],
    bounds: (value.bounds ?? { minRatio: 0.6, maxRatio: 1.6, slack: 24 }) as Transform['bounds'],
    preservesVocabulary: value.preservesVocabulary !== false,
    isEnabled: value.isEnabled !== false,
    isBuiltIn: value.isBuiltIn === true,
    useCount: Number(value.useCount ?? 0),
    lastUsed: value.lastUsed ? new Date(Number(value.lastUsed)) : null,
    created: value.created ? new Date(Number(value.created)) : new Date(),
  };
}

function encodeProfile(profile: StyleProfile): unknown {
  return {
    ...profile,
    lastLearned: profile.lastLearned?.getTime() ?? null,
    spelling: encodeTrait(profile.spelling),
    contractions: encodeTrait(profile.contractions),
    formality: encodeTrait(profile.formality),
    oxfordComma: encodeTrait(profile.oxfordComma),
    exclamations: encodeTrait(profile.exclamations),
    phrasings: profile.phrasings.map((phrasing) => ({
      ...phrasing,
      lastObserved: phrasing.lastObserved?.getTime() ?? null,
    })),
  };
}

function encodeTrait(trait: StyleProfile['spelling']): unknown {
  return { votes: trait.votes, lastObserved: trait.lastObserved?.getTime() ?? null };
}
