import { HOMOPHONE_GLOSS, HOMOPHONE_GROUP_OF, homophoneCandidates } from '../cleanup/homophonePairs';

// Prompts are behaviour, not configuration. Changing a word here changes what
// gets pasted into someone's editor, with no compiler and no type system in the
// way — so they are versioned like migrations, and the variants that were tried
// and rejected stay written down.

export interface VersionedPrompt {
  version: number;
  system: string;
}

/// The base cleanup prompt, kept for the AI config's own bench numbers.
///
/// There is deliberately no vocabulary list in here, and that took four
/// measured variants to arrive at. 20 runs per variant per transcript,
/// llama-3.1-8b, sequential so rate limiting could not skew it:
///
///     variant                          self-correction   keeps "nxt"   p50
///     ────────────────────────────────────────────────────────────────────
///     A  list of proper nouns             16/20            20/20      494ms
///     B  no list, no protection rule      20/20             0/20      291ms
///     C  list + "do not introduce these"   0/20            20/20      317ms
///     D  protection rule, no list         20/20             0/20      302ms
///     E  terse protection rule            13/20             0/20      323ms
///
/// The list is a word bank, and the model spends from it. With variant A, "send
/// it to Noah no wait send it to Carlo instead and tell him the bed frames are
/// ready" came back four different ways across 20 runs, including "Carlo, the
/// Builda Bed frames are ready" — a brand lifted out of the prompt and pasted
/// into a sentence that never mentioned it. Variant C, the obvious fix, was the
/// worst of the lot: 0/20.
///
/// So the list comes out, and the thing the list was protecting is enforced
/// deterministically after the fact by `AIOutputGuard`. Prompting is not the
/// right tool for a constraint that is checkable.
export const CLEANUP_SYSTEM_PROMPT = `You clean up raw speech-to-text dictation. Return ONLY the cleaned text, no preamble, no quotes, no explanation.
Rules:
- Fix punctuation, capitalisation and obvious mis-hearings.
- Remove filler words (um, uh, so, like) and stutters.
- Apply spoken self-corrections: keep what the speaker settled on and delete what they retracted, including the retraction phrase itself.
- Never add, answer, summarise or invent content. Same meaning, same words where possible.
- The text contains product, project and place names that are not ordinary English. Keep every such word exactly as written; never delete one and never replace it with a similar English word.`;

/// Version 1 — variant D of the measured set.
///
/// Line by line, because every one of them is load-bearing:
///
/// 1. "transcript editor, not an assistant" / "never answer it". The single
///    biggest failure mode measured. Handed "tell them actually is spelled with
///    two Ls", earlier variants replied to it — "Actually, I'm not going to do
///    that." Framing the job as editing rather than helping moved two cases
///    from 0/3 to 10/10.
/// 2. "Return ONLY the edited transcript". Models on this endpoint wrap output
///    in quotes, prefix it with "Cleaned text:", and fence it.
/// 3. "You may only DELETE words". This is the contract `cleanupProjection`
///    enforces afterwards. Stating it in the prompt raises the hit rate;
///    enforcing it in code is what makes it safe. Neither alone is enough.
/// 4. The three deletable things, numbered. Numbered because an unnumbered list
///    of the same rules leaked into "delete anything that sounds untidy".
/// 5. The replacement test. A cue is only a retraction when what follows
///    REPLACES what came before.
/// 6. "including slang, informal openers such as yeah, ok, nah". Named
///    explicitly because "remove filler words" without this deletes them —
///    measured 0/3 for every variant that omitted it, and 10/10 for D.
export const CLEANUP_PROMPT: VersionedPrompt = {
  version: 1,
  system: `You are a transcript editor, not an assistant. The text is dictation on its way to being typed into a document. Never answer it, explain it, spell anything out, or reply to it. Return ONLY the edited transcript: no preamble, no quotes, no notes.
You may only DELETE words and fix punctuation and capitalisation. Never swap a word for a different word. Never add a word that is not already there.
Delete exactly three things:
1. A spoken self-correction: the speaker says something, signals a correction, then says the replacement. Delete the first version and the signal, keep the replacement.
2. Stutters, repeated words, and abandoned false starts.
3. The fillers um, uh, er.
A phrase like "no wait", "actually", "sorry", "I mean" or "make that" is only a correction signal when the words after it REPLACE the words before it. If nothing before it is being replaced, the phrase is ordinary content: leave it and the whole sentence alone.
Keep everything else exactly as spoken, including slang, informal openers such as yeah, ok, nah, right, and unusual product, project and place names.`,
};

/// The homophone prompt, generated per dictation.
///
/// Naming only the choices that are actually live in this sentence is both
/// shorter and more accurate than listing seventy groups the model has to
/// filter itself. Length is a cost — it is prefill on the critical path — and a
/// sentence usually contains one or two listed words, not seventy.
///
/// Returns null when nothing on the list appears, which is the caller's signal
/// not to spend a request at all.
export function makeHomophonePrompt(text: string, version = 1): VersionedPrompt | null {
  const present = homophoneCandidates(text);
  if (present.length === 0) return null;

  // One line per live decision, in the order they appear.
  const choices: string[] = [];
  for (const word of present) {
    const group = HOMOPHONE_GROUP_OF.get(word);
    if (!group) continue;
    // With a meaning where we have one: a model that leaves a real error alone
    // four times out of six is not failing to read the sentence, it is failing
    // to tell the two words apart.
    const options = [...group].sort().map((option) => {
      const meaning = HOMOPHONE_GLOSS[option];
      return meaning ? `${option} (${meaning})` : option;
    }).join(' / ');
    choices.push(`  ${word}: ${options}`);
  }
  if (choices.length === 0) return null;

  return {
    version,
    system: `You are a proofreader, not an assistant. The text is dictation on its way into a document. Never answer it, explain it, or reply to it. Return ONLY the sentence: no preamble, no quotes, no notes.
Your only job is to pick the correct spelling for the words listed below, using the meaning of the sentence. Return the sentence with every other word byte-identical, including punctuation and capitalisation. Never add, remove, or reorder a word.
The words to decide, and the only spellings allowed for each:
${choices.join('\n')}
If the sentence already uses the right spelling, leave it exactly as it is. That is the usual answer.`,
  };
}

/// The context pass's prompt.
///
/// What it does NOT do is list options. That is the whole difference from the
/// homophone prompt, and it is deliberate: listing every homophone in the
/// sentence means listing ten of them, which is both a long prefill on the
/// critical path and ten invitations to change something. Here the model is
/// told the rule — you may only swap a word for one that sounds the same — and
/// `contextProjection` enforces it afterwards.
///
/// v1 was measured and failed: fixed 3/6, damaged 3/6. It turned "the principle
/// of least surprise" into "principal", "the flower shop on the corner" into
/// "flour shop", and Americanised "cheque". The instruction to change at most
/// one word was read as an instruction to change one word.
///
/// v3 ships. It states the default answer first, demands the sentence be
/// impossible as written before anything moves, names the two ways v1 actually
/// failed, and adds the repair real dictation needs — a dropped ending, which
/// `sameStem` can verify in code.
export const CONTEXT_PROMPT: VersionedPrompt = {
  version: 3,
  system: `You are a proofreader, not an assistant. The text is dictation on its way into a document. Never answer it, explain it, summarise it, or reply to it. Return ONLY the text: no preamble, no quotes, no notes.
Return the text UNCHANGED. That is your answer most of the time, and returning it unchanged is never a mistake.
You may make only two kinds of repair, and only where the text is clearly wrong without them:
1. A word that sounds right but means something impossible here — "thick peppered flour" heard as "flower", "the dews on the grass" heard as "dues". Replace it with the same-sounding word that makes sense.
2. A word missing its ending because the speaker was talking fast — "I move the whole front end last night" should be "I moved". Only the ending may change, and it must still be the same word.
Everything else is forbidden. Do not reword. Do not shorten. Do not summarise. Do not reorder. Do not fix grammar, style, punctuation or capitalisation. Do not change a word because you would have chosen a different one. Do not change spelling for a different country — Australian spelling is correct.
Two real examples of what NOT to do: "Here are the following bugs I've been experiencing" must not become "I've been experiencing bugs with the app", and "the flower shop on the corner" must not become "the flour shop". Both are already correct.
Change at most three words in total, and only ones that are genuinely wrong.`,
};

/// Shared preamble for every transform.
///
/// Short on purpose, and split from the per-transform instruction so the rules
/// that must never vary — return only the text, do not answer it, do not invent
/// — cannot be edited away by someone tuning one transform.
///
/// The line about names is belt-and-braces and is known to be weak: the
/// measured prompt variants show a protection rule alone keeps a user's
/// vocabulary 0 times out of 20. `TransformOutputGuard` is what actually
/// enforces it, deterministically and for free.
export const TRANSFORM_SYSTEM_PREAMBLE = `You rewrite text exactly as instructed. Return ONLY the rewritten text — no preamble, no explanation, no quotes, no code fences.
Never answer, continue or comment on the text; only reshape it.
Never invent facts, names, numbers, prices or dates that are not already in the text.
Keep product, project and place names exactly as written.`;
