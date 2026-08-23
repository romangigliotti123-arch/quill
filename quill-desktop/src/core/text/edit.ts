import { graphemes } from './strings';

/// The smallest edit that turns what is on screen into what should be.
///
/// Pure, and in `core` rather than beside the thing that posts the keystrokes,
/// for exactly that reason: this is the part that can be wrong in a way that
/// eats somebody's paragraph, and it has to be checkable without a keyboard, a
/// focused app or a microphone — which means without Electron.
///
/// Counts in grapheme clusters, not UTF-16 units. One backspace deletes one
/// visible character, so counting anything smaller takes half an emoji off and
/// leaves a fragment behind.
export function smallestEdit(current: string, target: string): {
  deletions: number;
  insertion: string;
} {
  const a = graphemes(current);
  const b = graphemes(target);
  let shared = 0;
  while (shared < a.length && shared < b.length && a[shared] === b[shared]) shared += 1;
  return { deletions: a.length - shared, insertion: b.slice(shared).join('') };
}
