import type { SettingsValues } from '../../core/settings';
import type { InsightsMetrics, InsightsRange } from '../../core/insights/insightsMetrics';
import type { HarvestSuggestion } from '../../core/stores/vocabularyHarvest';
import type { DiagnosticsReport } from '../../main/ipc';
import type { SpeechStatus } from '../../main/stt/whisperTranscriber';
import type { NIMStatus } from '../../core/ai/nimClient';

/// The renderer's view of everything the main process will answer.
///
/// Typed against the same interfaces the main process uses, so a field renamed
/// in a store is a compile error here rather than an `undefined` on a screen.

export interface WireRecord {
  id: string;
  date: number;
  rawText: string;
  insertedText: string;
  wordCount: number;
  inputDevice: string | null;
  timings: {
    timeToFirstWordMs: number | null;
    finalToInsertedMs: number | null;
    endToEndMs: number | null;
    audioDurationMs: number | null;
    usedThoroughCleanup: boolean;
    releaseToInsertedMs: number | null;
    micOpenMs: number | null;
    speechOnsetMs: number | null;
    recogniserFirstWordMs: number | null;
  };
}

export interface WireSnippet {
  id: string;
  phrase: string;
  replacement: string;
  mode: 'anywhere' | 'alone';
  isEnabled: boolean;
  useCount: number;
  lastUsed: number | null;
  created: number;
}

export interface WireNote {
  id: string;
  title: string;
  body: string;
  created: number;
  modified: number;
  isPinned: boolean;
}

export interface WireTransform {
  id: string;
  name: string;
  instruction: string;
  triggers: string[];
  keywords: string[];
  accelerator: string | null;
  target: 'selection' | 'lastDictation' | 'automatic';
  offline: string;
  bounds: { minRatio: number; maxRatio: number; slack: number };
  preservesVocabulary: boolean;
  isEnabled: boolean;
  isBuiltIn: boolean;
  useCount: number;
  lastUsed: number | null;
  created: number;
}

export interface WireTrait { votes: Record<string, number>; lastObserved: number | null }

export interface WireStyleProfile {
  preset: 'neutral' | 'casual' | 'professional' | 'technical';
  appTones: Record<string, string>;
  isLearningEnabled: boolean;
  spelling: WireTrait;
  contractions: WireTrait;
  formality: WireTrait;
  oxfordComma: WireTrait;
  exclamations: WireTrait;
  sentenceLength: { total: number; count: number };
  phrasings: { from: string; to: string; count: number; lastObserved: number | null }[];
  correctionCount: number;
  modelAccepted: number;
  modelReverted: number;
  lastLearned: number | null;
}

export interface BindingOption { name: string; display: string; mayBeAltGr: boolean }

declare global {
  interface Window {
    quill: {
      platform: NodeJS.Platform;
      invoke(name: string, payload?: unknown): Promise<unknown>;
      on(
        channel: 'settings' | 'speech' | 'focus' | 'activity',
        handler: (payload: unknown) => void,
      ): void;
    };
  }
}

const call = <T>(name: string, payload?: unknown): Promise<T> =>
  window.quill.invoke(name, payload) as Promise<T>;

export const api = {
  platform: window.quill.platform,

  settings: {
    get: () => call<SettingsValues>('settings.get'),
    set: (patch: Partial<SettingsValues>) => call<SettingsValues>('settings.set', patch),
    captureHotkey: (capturing: boolean) => call<boolean>('settings.captureHotkey', { capturing }),
    bindings: () => call<BindingOption[]>('settings.bindings'),
  },

  speech: {
    status: () => call<SpeechStatus>('speech.status'),
    devices: () => call<{ id: string; label: string }[]>('speech.devices'),
    prepare: () => call<SpeechStatus>('speech.prepare'),
  },

  history: {
    list: () => call<WireRecord[]>('history.list'),
    insights: (range: InsightsRange) => call<InsightsMetrics>('history.insights', { range }),
  },

  vocabulary: {
    list: () => call<string[]>('vocabulary.list'),
    add: (term: string) => call<boolean>('vocabulary.add', term),
    remove: (term: string) => call<boolean>('vocabulary.remove', term),
    suggestions: () => call<HarvestSuggestion[]>('vocabulary.suggestions'),
  },

  snippets: {
    list: () => call<WireSnippet[]>('snippets.list'),
    upsert: (snippet: WireSnippet) => call<WireSnippet>('snippets.upsert', snippet),
    remove: (id: string) => call<boolean>('snippets.remove', id),
  },

  notes: {
    list: () => call<WireNote[]>('notes.list'),
    upsert: (note: WireNote) => call<WireNote>('notes.upsert', note),
    delete: (id: string) => call<boolean>('notes.delete', id),
  },

  style: {
    get: () => call<{ profile: WireStyleProfile; summary: string }>('style.get'),
    setPreset: (preset: string) => call<boolean>('style.setPreset', preset),
    setLearning: (enabled: boolean) => call<boolean>('style.setLearning', enabled),
    removePhrasing: (id: string) => call<boolean>('style.removePhrasing', id),
    forget: () => call<boolean>('style.forget'),
  },

  transforms: {
    list: () => call<WireTransform[]>('transforms.list'),
    upsert: (transform: WireTransform) => call<WireTransform>('transforms.upsert', transform),
    remove: (id: string) => call<boolean>('transforms.remove', id),
    run: (id: string) => call<{ kind: string; text?: string; reason?: string }>('transforms.run', id),
  },

  ai: {
    key: () => call<{ configured: boolean; fingerprint: string }>('ai.key'),
    setKey: (key: string) => call<{ configured: boolean; fingerprint: string }>('ai.setKey', key),
    status: () => call<NIMStatus>('ai.status'),
  },

  app: {
    diagnostics: () => call<DiagnosticsReport>('app.diagnostics'),
    dataSummary: () => call<{ name: string; bytes: number }[]>('app.dataSummary'),
    eraseEverything: () => call<string[]>('app.eraseEverything'),
    openDataDirectory: () => call<boolean>('app.openDataDirectory'),
    openExternal: (url: string) => call<boolean>('app.openExternal', url),
    toggleDictation: () => call<boolean>('app.toggleDictation'),
    relaunch: () => call<boolean>('app.relaunch'),
    quit: () => call<boolean>('app.quit'),
  },

  on: window.quill.on,
};

export type { SettingsValues, InsightsMetrics, InsightsRange, SpeechStatus, NIMStatus, DiagnosticsReport, HarvestSuggestion };
