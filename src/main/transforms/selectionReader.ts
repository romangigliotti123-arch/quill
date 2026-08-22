import { appContextOf } from '../../core/cleanup/appContext';
import {
  captureClipboard, readClipboardText, restoreClipboard, snapshotIsFaithful, writeClipboard,
} from '../injection/clipboardSnapshot';
import { delay, keyboardIsAvailable, postCopy } from '../platform/keyboard';
import type { WindowWatcher } from '../platform/windowWatcher';

/// What is selected in the focused app, if anything.
export type SelectionReading =
  | { kind: 'selected'; text: string }
  | { kind: 'empty' }
  | { kind: 'unavailable'; reason: string };

export interface SelectionReading_ {
  readSelection(): Promise<SelectionReading>;
}

/// Reads the focused app's selection through the clipboard.
///
/// # Why not the Accessibility API
///
/// Because there isn't one. macOS could ask `AXSelectedText` and get an answer
/// from well-behaved apps; Windows has UI Automation, which needs a native
/// binding; Linux has AT-SPI, which needs a D-Bus client and an accessibility
/// stack the user may not have enabled. Nothing spans the three.
///
/// What does span the three is the copy key, and a copy is a genuinely better
/// reading than AX in the apps where it mattered — AX in Electron apps returns
/// success and the wrong text, which is the worst failure shape available.
///
/// # The two costs, both handled
///
/// **It touches the clipboard.** So the user's contents are captured first and
/// put back afterwards, and a clipboard holding something that cannot be copied
/// out is left strictly alone (the read fails instead).
///
/// **Ctrl+C in a terminal is SIGINT.** A "read the selection" step that kills
/// the user's running build is not a trade worth making for a transform, so
/// terminals report `unavailable` and the transform falls back to the last
/// dictation.
export class ClipboardSelectionReader implements SelectionReading_ {
  constructor(private readonly windows: WindowWatcher | null = null) {}

  async readSelection(): Promise<SelectionReading> {
    if (!keyboardIsAvailable()) {
      return {
        kind: 'unavailable',
        reason: 'Quill cannot read the selection on this machine, because the input library '
          + 'did not install.',
      };
    }
    const process = this.windows?.active?.process ?? null;
    if (appContextOf(process) === 'terminal') {
      return {
        kind: 'unavailable',
        reason: 'Quill will not press Ctrl+C in a terminal to read the selection — that would '
          + 'interrupt whatever is running. Select the text somewhere else, or use the last '
          + 'dictation instead.',
      };
    }

    const before = captureClipboard();
    if (!snapshotIsFaithful(before)) {
      return {
        kind: 'unavailable',
        reason: 'Your clipboard holds something Quill cannot put back, so it did not touch it.',
      };
    }

    // A sentinel rather than an empty clipboard, so "the copy did nothing"
    // (there is no selection) can be told from "the copy produced an empty
    // string" — which some apps do for a selection of whitespace.
    const sentinel = `quill-selection-probe-${Date.now()}`;
    if (!writeClipboard(sentinel)) {
      restoreClipboard(before);
      return { kind: 'unavailable', reason: 'Quill could not use the clipboard to read the selection.' };
    }

    postCopy();
    await delay(90);
    const copied = readClipboardText();
    restoreClipboard(before);

    if (copied === sentinel) return { kind: 'empty' };
    if (copied.trim().length === 0) return { kind: 'empty' };
    return { kind: 'selected', text: copied };
  }
}

/// A reader that always says there is nothing selected. For tests, and for the
/// platforms where the copy probe is refused.
export class NoSelectionReader implements SelectionReading_ {
  async readSelection(): Promise<SelectionReading> {
    return { kind: 'empty' };
  }
}
