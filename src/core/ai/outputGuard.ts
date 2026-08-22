import { trim } from '../text/strings';

/// The guard between a language model and the user's keyboard.
///
/// Everything here exists because the paste target is an app we do not control,
/// and text is inserted without review. A model that answers the dictation
/// instead of tidying it, or wraps the result in quotes, or emits its own
/// reasoning, must fail closed to the deterministic pass — not paste.
export const AIOutputGuard = {
  /// Returns cleaned text, or null if the response cannot be trusted. Null
  /// means "use the fast pass", never "show an error".
  ///
  /// `terms` is the user's vocabulary. Any term that went into the model and
  /// did not come back out means the model normalised one of their words, and
  /// the whole response is rejected — see `droppedVocabulary`.
  sanitise(raw: string, input: string, terms: string[] = []): string | null {
    let out = trim(raw);
    if (out.length === 0) return null;

    out = AIOutputGuard.stripCodeFence(out);
    out = AIOutputGuard.stripLeadingLabel(out);
    out = AIOutputGuard.stripWrappingQuotes(out);
    out = trim(out);
    if (out.length === 0) return null;

    // A model that starts explaining has stopped cleaning. Multi-paragraph
    // output for a single dictated sentence is the tell.
    if (out.includes('\n\n') && !input.includes('\n\n')) return null;

    // Length bounds, on characters rather than tokens because the check has to
    // be as cheap as the thing it is protecting. The ceiling catches the model
    // answering the dictation instead of tidying it; the floor catches it
    // summarising.
    //
    // Both were sized against real transcripts. The heaviest legitimate shrink
    // measured is the self-correction case — "send it to Noah no wait send it
    // to Carlo instead and tell him the bed frames are ready" keeps 72% of its
    // characters — and the worst observed failure kept 45%. The floor sits at
    // 0.5, above the failure and well below the legitimate case.
    //
    // Asymmetric on purpose. A false reject costs the fast pass, which is
    // decent text the user can see is unedited. A false accept pastes a
    // sentence they did not say into an app we do not control. Be clear about
    // the limit though: this is a length check, not a meaning check. It cannot
    // catch a model that rewrites a sentence to the same length. The prompt is
    // the real defence; this is the backstop.
    const n = input.length;
    const m = out.length;
    if (m > n * 1.6 + 24 || m < n * 0.5) return null;

    if (AIOutputGuard.droppedVocabulary(input, out, terms).length > 0) return null;

    return out;
  },

  /// Terms that were in the input and are not in the output.
  ///
  /// This is the whole reason the system prompt can afford to leave the
  /// vocabulary out. Measured: every prompt variant without an explicit word
  /// list turned "nxt" into "next" or deleted it, 20 times out of 20 — and
  /// every variant *with* the list started injecting words from it into
  /// sentences that never contained them. Prompting cannot win that; a string
  /// comparison can, exactly and for nothing.
  ///
  /// Case-sensitive, because the casing is the point: "nxt" is not "Nxt",
  /// "graphify" is not "Graphify", and the fast pass has already decided which
  /// is right. The known cost is a term that legitimately starts a sentence and
  /// gets capitalised — that rejects, and the fast pass ships, which is the
  /// safe direction.
  droppedVocabulary(input: string, output: string, terms: string[]): string[] {
    return terms.filter((term) => input.includes(term) && !output.includes(term));
  },

  stripCodeFence(s: string): string {
    if (!s.startsWith('```')) return s;
    const lines = s.split('\n');
    lines.shift();
    if (lines.length > 0 && trim(lines[lines.length - 1]!).startsWith('```')) lines.pop();
    return lines.join('\n');
  },

  /// "Cleaned text: foo" → "foo". Only labels, never a real sentence: the
  /// prefix must be short and must not itself contain sentence punctuation.
  stripLeadingLabel(s: string): string {
    const colon = s.indexOf(':');
    if (colon < 0) return s;
    const head = s.slice(0, colon);
    if (head.length > 24) return s;
    if (Array.from(head).some((c) => '.!?,'.includes(c))) return s;
    const lowered = head.toLowerCase();
    const labels = ['clean', 'output', 'result', 'corrected', 'here', 'text'];
    if (!labels.some((label) => lowered.includes(label))) return s;
    return s.slice(colon + 1);
  },

  stripWrappingQuotes(s: string): string {
    const pairs: [string, string][] = [['"', '"'], ["'", "'"], ['“', '”']];
    for (const [open, close] of pairs) {
      if (s.length >= 2 && s[0] === open && s[s.length - 1] === close) {
        // Only unwrap when the quotes really do wrap the whole thing —
        // 'send "this" and "that"' must survive intact.
        const inner = s.slice(1, -1);
        if (!inner.includes(close)) return inner;
      }
    }
    return s;
  },
};
