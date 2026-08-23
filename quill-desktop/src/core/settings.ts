import { readFileSync, writeFileSync, mkdirSync, renameSync } from 'node:fs';
import { dirname } from 'node:path';
import { EventEmitter } from 'node:events';
import { dataFile } from './paths';

/// How a spoken number reaches the page.
export type NumberStyle = 'asHeard' | 'spellOutSmall' | 'alwaysDigits' | 'alwaysWords';

export const NUMBER_STYLES: NumberStyle[] = ['asHeard', 'spellOutSmall', 'alwaysDigits', 'alwaysWords'];

export function numberStyleLabel(style: NumberStyle): string {
  switch (style) {
    case 'asHeard': return 'Leave as heard';
    case 'spellOutSmall': return 'Spell out small numbers';
    case 'alwaysDigits': return 'Always digits';
    case 'alwaysWords': return 'Always words';
  }
}

export function numberStyleDetail(style: NumberStyle): string {
  switch (style) {
    case 'asHeard': return 'Whatever the recogniser wrote';
    case 'spellOutSmall': return '“four men”, but “15 years old”';
    case 'alwaysDigits': return '“4 men”, “25 people”';
    case 'alwaysWords': return '“four men”, “fifteen years old”';
  }
}

/// How long a dictation stays in the history before Quill deletes it.
///
/// Stored as a string case rather than a number of days so the file stays
/// readable and a future option cannot be confused with an old one.
export type HistoryRetention = 'day' | 'week' | 'month' | 'forever';

export const HISTORY_RETENTIONS: HistoryRetention[] = ['day', 'week', 'month', 'forever'];

export function retentionLabel(value: HistoryRetention): string {
  switch (value) {
    case 'day': return 'A day';
    case 'week': return 'A week';
    case 'month': return 'A month';
    case 'forever': return 'Forever';
  }
}

export function retentionDetail(value: HistoryRetention): string {
  switch (value) {
    case 'day': return 'Anything dictated more than a day ago is deleted.';
    case 'week': return 'Anything dictated more than a week ago is deleted.';
    case 'month': return 'Anything dictated more than a month ago is deleted.';
    case 'forever': return 'Nothing is ever deleted. Insights keeps every number.';
  }
}

export function retentionDays(value: HistoryRetention): number | null {
  switch (value) {
    case 'day': return 1;
    case 'week': return 7;
    case 'month': return 30;
    case 'forever': return null;
  }
}

/// The cutoff, or null when nothing expires.
///
/// Calendar days rather than 86,400-second ones: "a month ago" has to mean the
/// same wall-clock moment across the two days a year when a day is not 24 hours
/// long, or a record survives an hour longer than it should each October and
/// dies an hour early each April. Nobody would notice, which is exactly why it
/// should be right.
export function retentionCutoff(value: HistoryRetention, now: Date): Date | null {
  const days = retentionDays(value);
  if (days === null) return null;
  const cutoff = new Date(now.getTime());
  cutoff.setDate(cutoff.getDate() - days);
  return cutoff;
}

/// How text reaches the focused app.
///
/// New on this platform, and it exists because the honest answer differs by
/// operating system. macOS could synthesise arbitrary Unicode straight into an
/// app; X11 can too (through XTEST), Windows can through SendInput, and neither
/// of those is reachable from Node without a native module that ships a
/// prebuilt binary for the machine in front of you. Clipboard-and-paste works
/// everywhere, is one keystroke instead of hundreds, and is what the macOS
/// build already used as its PRIMARY path — see `textInserter.ts`.
export type InsertionStrategy = 'paste' | 'type';

export interface SettingsValues {
  /** Held down while speaking. A platform key name, not a keycode — see `hotkeyBinding.ts`. */
  holdKey: string;
  /** Tapped to start and stop hands-free. Same key as `holdKey` means double-tap. */
  toggleKey: string;
  /** `deviceId` from `navigator.mediaDevices`, or null to follow the system default. */
  inputDeviceId: string | null;
  /** Human-readable name of that device, kept so Settings can show it even when
   *  the device is unplugged and the id no longer resolves. */
  inputDeviceLabel: string | null;
  /** Type the words into the focused app as they are recognised, instead of
   *  pasting the finished sentence on key release. */
  liveText: boolean;
  /** Let the undo chord take back the sentence Quill just inserted. */
  undoChord: boolean;
  /** The accelerator for that chord. Electron syntax, e.g. "Control+Alt+Z". */
  undoChordAccelerator: string;
  numberStyle: NumberStyle;
  historyRetention: HistoryRetention;
  /** Let the model read the sentence, propose a fix of its own, and have
   *  `contextProjection` refuse anything that is not a same-sounding swap. */
  contextRecovery: boolean;
  insertionStrategy: InsertionStrategy;
  /** Which speech model to load. Bigger is more accurate and slower. */
  speechModel: string;
  /** Whether to run the model on the GPU. Falls back to CPU automatically when
   *  WebGPU is unavailable, which it is on a lot of Linux setups. */
  speechUseGPU: boolean;
  /** Start Quill when the machine starts. */
  launchAtLogin: boolean;
  /** Open the dashboard on launch, rather than only living in the tray. */
  showDashboardOnLaunch: boolean;
}

export const DEFAULT_ACCELERATOR_UNDO =
  process.platform === 'darwin' ? 'Alt+Backspace' : 'Control+Alt+Z';

export function defaultSettings(): SettingsValues {
  return {
    holdKey: 'AltRight',
    toggleKey: 'AltRight',
    inputDeviceId: null,
    inputDeviceLabel: null,
    liveText: true,
    undoChord: true,
    undoChordAccelerator: DEFAULT_ACCELERATOR_UNDO,
    numberStyle: 'spellOutSmall',
    historyRetention: 'month',
    contextRecovery: true,
    insertionStrategy: 'paste',
    speechModel: 'onnx-community/whisper-base.en',
    speechUseGPU: true,
    launchAtLogin: false,
    showDashboardOnLaunch: true,
  };
}

/// Everything about Quill a user is allowed to change, in one place, on disk.
///
/// Values are read live rather than cached by their consumers. Changing the
/// dictation key takes effect on the next key press, not the next launch; that
/// is the difference between a setting and a preference file.
export class QuillSettings extends EventEmitter {
  private readonly url: string;
  private values: SettingsValues;
  private capturing = false;

  /// Tests pass their own path. A self-test that rewrites the real settings
  /// file would change the app under the person running it.
  constructor(url: string = QuillSettings.defaultURL()) {
    super();
    this.url = url;
    this.values = defaultSettings();
    this.load();
  }

  /// Overridable, because a measurement run has no business editing the
  /// settings of the person it is measuring.
  static defaultURL(): string {
    const override = process.env.QUILL_SETTINGS_FILE;
    if (override && override.length > 0) return override;
    return dataFile('settings.json');
  }

  private static shared: QuillSettings | null = null;
  static instance(): QuillSettings {
    if (!QuillSettings.shared) QuillSettings.shared = new QuillSettings();
    return QuillSettings.shared;
  }

  get current(): SettingsValues {
    return { ...this.values };
  }

  get holdKey(): string { return this.values.holdKey; }
  get toggleKey(): string { return this.values.toggleKey; }
  get inputDeviceId(): string | null { return this.values.inputDeviceId; }
  get liveText(): boolean { return this.values.liveText; }
  get undoChord(): boolean { return this.values.undoChord; }
  get numberStyle(): NumberStyle { return this.values.numberStyle; }
  get historyRetention(): HistoryRetention { return this.values.historyRetention; }
  get contextRecovery(): boolean { return this.values.contextRecovery; }
  get insertionStrategy(): InsertionStrategy { return this.values.insertionStrategy; }

  /// True when one key does both jobs, which is the default and means
  /// push-to-talk is reached by double-tapping rather than by a key of its own.
  get toggleSharesHoldKey(): boolean {
    return this.values.holdKey === this.values.toggleKey;
  }

  /// Set while the Settings screen is listening for a new binding.
  ///
  /// Without it, pressing the key you are trying to assign starts a dictation
  /// into the settings window — the recorder and the engine are watching the
  /// same physical key press, and only one of them should win.
  get isCapturingHotkey(): boolean { return this.capturing; }
  set isCapturingHotkey(value: boolean) { this.capturing = value; }

  update(mutate: (values: SettingsValues) => void): void {
    const copy = { ...this.values };
    mutate(copy);
    if (JSON.stringify(copy) === JSON.stringify(this.values)) return;
    this.values = copy;
    this.save();
    this.emit('changed', this.current);
  }

  set<K extends keyof SettingsValues>(key: K, value: SettingsValues[K]): void {
    this.update((v) => {
      v[key] = value;
    });
  }

  private load(): void {
    let raw: string;
    try {
      raw = readFileSync(this.url, 'utf8');
    } catch {
      return;
    }
    let parsed: unknown;
    try {
      parsed = JSON.parse(raw);
    } catch {
      // A settings file written by an older build, or half-written during a
      // crash, must never stop the app launching. Defaults, and the file is
      // left alone until something actually changes.
      return;
    }
    if (!parsed || typeof parsed !== 'object') return;
    const stored = parsed as Partial<SettingsValues>;
    const fallback = defaultSettings();
    const merged: SettingsValues = { ...fallback };
    for (const key of Object.keys(fallback) as (keyof SettingsValues)[]) {
      const value = stored[key];
      if (value === undefined) continue;
      // Every field is validated on decode so a value this build does not
      // recognise falls back to the default rather than throwing the whole
      // settings file away. It matters most for retention — the consequence of
      // losing that one is that the app starts deleting on a schedule the user
      // did not pick.
      if (typeof value !== typeof fallback[key] && value !== null) continue;
      (merged as unknown as Record<string, unknown>)[key] = value;
    }
    if (!NUMBER_STYLES.includes(merged.numberStyle)) merged.numberStyle = fallback.numberStyle;
    if (!HISTORY_RETENTIONS.includes(merged.historyRetention)) {
      merged.historyRetention = fallback.historyRetention;
    }
    if (merged.insertionStrategy !== 'paste' && merged.insertionStrategy !== 'type') {
      merged.insertionStrategy = fallback.insertionStrategy;
    }
    this.values = merged;
  }

  private save(): void {
    try {
      mkdirSync(dirname(this.url), { recursive: true });
      const temporary = `${this.url}.tmp`;
      writeFileSync(temporary, JSON.stringify(this.values, Object.keys(this.values).sort(), 2));
      renameSync(temporary, this.url);
    } catch (error) {
      // eslint-disable-next-line no-console
      console.error('[quill] could not write settings', error);
    }
  }
}
