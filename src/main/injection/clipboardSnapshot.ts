import { clipboard, nativeImage, type NativeImage } from 'electron';

/// A detached copy of the clipboard's contents.
///
/// Detached is the whole point. The bytes are copied out eagerly, so what goes
/// back is what was there rather than a handle to something that has since been
/// cleared.
///
/// # What changed from the macOS build
///
/// That one enumerated every pasteboard item and every flavour of each, which
/// is the honest way to capture a clipboard holding several representations at
/// once. Electron's clipboard is flatter: it exposes text, HTML, RTF, an image
/// and a bookmark, and nothing else. So the capture is those five, and
/// `isFaithful` reports whether anything was on the board that we could not
/// read — in which case the caller must not paste at all, because clearing a
/// clipboard we cannot restore is worse than typing slowly.
///
/// The other change is the safety check before restoring. macOS has a
/// `changeCount` that ticks on every write, and the macOS build learned the
/// hard way that it is the wrong question: clipboard managers poll the board
/// and touch it, every touch bumps the counter, and Quill read that as "the
/// user copied something new" and declined to restore — leaving the dictation
/// on the clipboard and the user's own copy gone, permanently, on every single
/// dictation. The fix there was to ask about CONTENT instead. Electron has no
/// changeCount to be misled by, so content is all there is, and content is the
/// question that was right anyway.

export interface ClipboardSnapshot {
  text: string | null;
  html: string | null;
  rtf: string | null;
  image: NativeImage | null;
  /// Formats that were present and are not among the five above. A non-empty
  /// list means the snapshot is not faithful.
  unreadableFormats: string[];
}

/// Formats that are always present alongside plain text and carry nothing extra
/// — restoring text restores them. Listing them keeps `isFaithful` from
/// reporting a perfectly ordinary text clipboard as unrecoverable.
const REDUNDANT_FORMATS = [
  'text/plain', 'text/plain;charset=utf-8', 'public.utf8-plain-text',
  'public.utf16-external-plain-text', 'CF_UNICODETEXT', 'CF_TEXT', 'CF_OEMTEXT',
  'UTF8_STRING', 'STRING', 'TEXT', 'COMPOUND_TEXT',
  'text/html', 'public.html', 'HTML Format',
  'public.rtf', 'text/rtf', 'Rich Text Format',
  'image/png', 'image/jpeg', 'image/tiff', 'public.png', 'public.tiff', 'CF_DIB', 'CF_DIBV5',
  'public.url', 'public.url-name',
  // Clipboard managers and the transient convention. Present on a board we
  // wrote ourselves; not data anybody would miss.
  'org.nspasteboard.TransientType', 'org.nspasteboard.ConcealedType',
  'com.apple.cocoa.pasteboard.find', 'Clipboard Viewer Ignore',
];

export function captureClipboard(): ClipboardSnapshot {
  const formats = safeFormats();
  const image = clipboard.readImage();
  return {
    text: nonEmpty(clipboard.readText()),
    html: nonEmpty(clipboard.readHTML()),
    rtf: nonEmpty(clipboard.readRTF()),
    image: image.isEmpty() ? null : image,
    unreadableFormats: formats.filter((format) => !REDUNDANT_FORMATS.includes(format)),
  };
}

/// True when everything on the clipboard came back readable.
///
/// An unfaithful snapshot must not be used: restoring it clears a clipboard
/// that was not empty and puts back less than was there. The caller's answer is
/// to leave the clipboard alone entirely, not to restore what it has.
export function snapshotIsFaithful(snapshot: ClipboardSnapshot): boolean {
  return snapshot.unreadableFormats.length === 0;
}

export function snapshotIsEmpty(snapshot: ClipboardSnapshot): boolean {
  return snapshot.text === null && snapshot.html === null
    && snapshot.rtf === null && snapshot.image === null;
}

/// Returns false when there was nothing to put back, so the caller can tell
/// "restored the user's clipboard" from "left it empty because it was empty".
export function restoreClipboard(snapshot: ClipboardSnapshot): boolean {
  if (snapshotIsEmpty(snapshot)) {
    clipboard.clear();
    return false;
  }
  const payload: Parameters<typeof clipboard.write>[0] = {};
  if (snapshot.text !== null) payload.text = snapshot.text;
  if (snapshot.html !== null) payload.html = snapshot.html;
  if (snapshot.rtf !== null) payload.rtf = snapshot.rtf;
  if (snapshot.image !== null) payload.image = snapshot.image;
  try {
    clipboard.write(payload);
    return true;
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error('[quill] could not restore the clipboard', error);
    return false;
  }
}

/// Whether putting the user's clipboard back would destroy something they have
/// since copied.
///
/// The question is about CONTENT. If the board still holds exactly what Quill
/// wrote, then whatever else touched it did not put anything there the user
/// wants — restoring is safe. If it holds something else, someone did, and it
/// is not ours to overwrite.
export function restoreIsSafe(ourText: string, currentText: string | null): boolean {
  return currentText === ourText;
}

/// Puts `text` on the clipboard and reads it straight back.
///
/// The read-back is not paranoia: a write reporting success while the clipboard
/// holds something else is exactly how text disappears.
export function writeClipboard(text: string): boolean {
  try {
    clipboard.writeText(text);
    return clipboard.readText() === text;
  } catch (error) {
    // eslint-disable-next-line no-console
    console.error('[quill] could not write to the clipboard', error);
    return false;
  }
}

export function readClipboardText(): string {
  try {
    return clipboard.readText();
  } catch {
    return '';
  }
}

function nonEmpty(value: string): string | null {
  return value.length === 0 ? null : value;
}

function safeFormats(): string[] {
  try {
    return clipboard.availableFormats();
  } catch {
    return [];
  }
}

export { nativeImage };
