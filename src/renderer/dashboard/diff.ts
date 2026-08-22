import { h } from './dom';

/// A word-level diff, for showing what the cleanup pass changed.
///
/// The same longest-common-subsequence the insights tally uses, but rendered
/// rather than counted. Tokens are compared on a normalised form — lowercased,
/// outer punctuation stripped — so a full stop the cleaner added does not paint
/// the whole sentence as changed, which is what a character diff does to
/// dictation and why this is a word diff.

function key(token: string): string {
  return token.toLowerCase().replace(/^[^\p{L}\p{N}']+|[^\p{L}\p{N}']+$/gu, '');
}

export function diffWords(before: string, after: string): DocumentFragment {
  // Words only, with the whitespace dropped and one space put back between the
  // pieces on the way out.
  //
  // Keeping whitespace as its own token was the obvious thing and it renders
  // badly: a run of deletions followed by a run of insertions consumes the
  // separators asymmetrically, and the two runs come out welded together —
  // "dot aunoah@kassbarbers.com.au". This pane is an annotation of what
  // changed, not a reproduction of the original spacing, so a single space
  // between pieces is both correct and readable.
  const a = before.split(/\s+/).filter((piece) => piece.length > 0);
  const b = after.split(/\s+/).filter((piece) => piece.length > 0);
  const ka = a.map(key);
  const kb = b.map(key);

  const lengths: number[][] = [];
  for (let i = 0; i <= a.length; i += 1) lengths.push(new Array<number>(b.length + 1).fill(0));
  for (let i = a.length - 1; i >= 0; i -= 1) {
    for (let j = b.length - 1; j >= 0; j -= 1) {
      lengths[i]![j] = ka[i] === kb[j]
        ? lengths[i + 1]![j + 1]! + 1
        : Math.max(lengths[i + 1]![j]!, lengths[i]![j + 1]!);
    }
  }

  const out = document.createDocumentFragment();
  let first = true;
  const emit = (node: Node): void => {
    if (!first) out.appendChild(document.createTextNode(' '));
    first = false;
    out.appendChild(node);
  };

  let i = 0;
  let j = 0;
  while (i < a.length && j < b.length) {
    if (ka[i] === kb[j]) {
      // The token survived, but its punctuation or case may not have. Showing
      // the AFTER form is right: this pane is "what was typed", annotated with
      // what changed, not a replay of the raw transcript.
      emit(document.createTextNode(b[j]!));
      i += 1;
      j += 1;
    } else if (lengths[i + 1]![j]! >= lengths[i]![j + 1]!) {
      emit(h('del', {}, a[i]!));
      i += 1;
    } else {
      emit(h('ins', {}, b[j]!));
      j += 1;
    }
  }
  while (i < a.length) { emit(h('del', {}, a[i]!)); i += 1; }
  while (j < b.length) { emit(h('ins', {}, b[j]!)); j += 1; }
  return out;
}
