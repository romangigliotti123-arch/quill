// The seams of the app. Every subsystem is written against these and nothing
// else, so any one of them can be swapped or faked in tests without the others
// noticing. Deliberately small — a seam that needs a paragraph to explain is a
// seam in the wrong place.

/// What the recogniser hands back.
export interface Transcript {
  /// Best text so far. For a volatile result this changes on the next update.
  text: string;
  /// True once this span is settled and will not be revised.
  isFinal: boolean;
}

export interface TranscriberDelegate {
  /// Called for every partial and final.
  didProduce(transcript: Transcript): void;
  didFail(error: string): void;
  /// The microphone went away part-way through, so there is no more audio
  /// coming. Distinct from `didFail` because there IS a transcript: whatever
  /// was heard before the device disappeared is real and must not be thrown
  /// away — it only has to stop being presented as the whole sentence.
  didLoseInput(): void;
  /// Live input level, 0…1, for the overlay's waveform. Part of the contract
  /// rather than a property of the concrete type because a HUD animating to
  /// nothing is the difference between an instrument and a decoration.
  didHearLevel(level: number): void;
}

export interface Transcriber {
  delegate: TranscriberDelegate | null;
  /// Warm the model. Called on hotkey-down, before audio, so the first word is
  /// not paying for model load.
  prepare(): Promise<void>;
  start(): Promise<void>;
  /// Returns the settled full text for the session.
  stop(): Promise<string>;
  cancel(): Promise<void>;
}

/// What the HUD is showing.
export type OverlayState =
  | { kind: 'hidden' }
  | { kind: 'listening'; level: number }
  | { kind: 'transcribing' }
  | { kind: 'inserted'; words: number }
  | { kind: 'error'; message: string };

export interface OverlayPresenting {
  show(state: OverlayState): void;
  hide(): void;
}

/// Every dictation stamps the same moments, so "is it fast enough" is
/// answerable from a log instead of a guess.
export class DictationTimeline {
  hotkeyDown: number | null = null;
  audioFirstBuffer: number | null = null;
  /// The first buffer with speech in it, rather than the first buffer.
  ///
  /// Without this, "time to first word" is one number covering three very
  /// different things: opening the microphone (ours), the pause before the
  /// person actually starts talking (theirs, and not a defect), and the
  /// recogniser deciding it has heard enough to guess (the model's). Measured
  /// on real dictations that number is 1216ms, and optimising it blind would
  /// mean trying to make somebody breathe faster.
  firstAudibleBuffer: number | null = null;
  firstPartial: number | null = null;
  /// The moment the key came back up — i.e. the moment the user stopped
  /// speaking and started waiting. Everything after this is latency they feel.
  hotkeyUp: number | null = null;
  finalTranscript: number | null = null;
  textInserted: number | null = null;

  private static ms(a: number | null, b: number | null): number | null {
    if (a === null || b === null) return null;
    return Math.round(b - a);
  }

  get timeToFirstWordMs(): number | null {
    return DictationTimeline.ms(this.hotkeyDown, this.firstPartial);
  }

  get finalToInsertedMs(): number | null {
    return DictationTimeline.ms(this.finalTranscript, this.textInserted);
  }

  /// **The number that decides the latency piece**: let go of the key, how long
  /// until the text is there.
  ///
  /// This is deliberately not `endToEndMs`. That one starts at key-*down*, so
  /// it includes however long the person spoke — a forty-second dictation
  /// scores forty seconds, and the median across a corpus of five-second clips
  /// reads as twelve. It is a fine diagnostic and a meaningless headline, and
  /// it was once shown on the Insights card under the label "key release to
  /// text on screen", which is this number and not that one.
  get releaseToInsertedMs(): number | null {
    return DictationTimeline.ms(this.hotkeyUp, this.textInserted);
  }

  /// How long speech actually ran, for words-per-minute and time-saved.
  get audioDurationMs(): number | null {
    return DictationTimeline.ms(this.audioFirstBuffer, this.finalTranscript);
  }

  /// Key-down to the first buffer off the microphone. The gap a person would
  /// have to wait through before speaking, if they had to wait at all.
  get micOpenMs(): number | null {
    return DictationTimeline.ms(this.hotkeyDown, this.audioFirstBuffer);
  }

  /// Microphone open → the user actually starts speaking. Not a defect and not
  /// ours to fix; recorded so it stops being counted as though it were.
  get speechOnsetMs(): number | null {
    return DictationTimeline.ms(this.audioFirstBuffer, this.firstAudibleBuffer);
  }

  /// Speech starts → the recogniser's first guess. THIS is the model latency,
  /// and the only part of "time to first word" that is worth tuning.
  get recogniserFirstWordMs(): number | null {
    return DictationTimeline.ms(this.firstAudibleBuffer, this.firstPartial);
  }

  /// Key-down to text. Kept because it is the honest measure of a whole
  /// interaction.
  get endToEndMs(): number | null {
    return DictationTimeline.ms(this.hotkeyDown, this.textInserted);
  }

  get logLine(): string {
    const f = (value: number | null): string => (value === null ? '—' : String(value));
    return `micOpen=${f(this.micOpenMs)}ms onset=${f(this.speechOnsetMs)}ms `
      + `recog=${f(this.recogniserFirstWordMs)}ms ttfw=${f(this.timeToFirstWordMs)}ms `
      + `release→insert=${f(this.releaseToInsertedMs)}ms `
      + `final→insert=${f(this.finalToInsertedMs)}ms e2e=${f(this.endToEndMs)}ms`;
  }
}
