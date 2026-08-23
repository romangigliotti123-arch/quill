// The literal correction table, and the one list two passes have to share.
//
// In the macOS build both of these lived on `FastCleaner`. They are here
// instead because `vocabularyCorrector` needs `AMBIGUOUS_SPLITS` and
// `fastCleaner` needs `vocabularyCorrector`, and a cycle between two files that
// are both on the dictation path is a cycle that shows up as `undefined` at
// runtime rather than as an error at build time.
//
// The intent is unchanged and is load-bearing: adding an anchored entry below
// and adding the pair to `AMBIGUOUS_SPLITS` is ONE edit, deliberately.

/// Two-word spans whose split form is ordinary English, and whose letters
/// happen to spell a tool name.
///
/// The anchored entries in `CORRECTIONS` exist because the bare pair rewrites
/// sentences the user meant — "type script tags by hand", "a tail wind helped
/// the flight". But anchoring there only stops THAT pass. The vocabulary
/// corrector runs a step later, and its exact-letters branch fires on the bare
/// pair regardless: `normalise("type script") === "typescript"`, which is the
/// strongest evidence it has, so it returned before any of its own guards could
/// look at the sentence.
///
/// So the two layers share one list. A pair in here can only become a tool name
/// through an anchor below — never on its own.
export const AMBIGUOUS_SPLITS = new Set([
  'typescript',   // "type script tags by hand"
  'tailwind',     // "a tail wind helped the flight"
  'airtable',     // "the air table was covered in dust"
  'syncthing',    // "sync thing up later"
  'github',       // "get hub caps for the car"
  'youtube',      // "you tube of toothpaste"
  'linkedin',     // "linked in the email"
  'blackhole',    // "the black hole in the data"
  'homebrew',     // "a home brew kit"
]);

/// Mishearings this recogniser produces, corrected literally.
///
/// Keys are compared lowercased and matched on word boundaries.
export const CORRECTIONS: Record<string, string> = {
  'next fulfilment': 'nxt fulfilment',
  graphite: 'graphify',
  nebula: 'Nebula',
  vesper: 'Vesper',
  'block craft': 'blockcraft',
  'fire store': 'Firestore',
  // "a Firestore backend" came back as "a fire stall back end". The vowel moves
  // depending on how fast it is said, and neither "fire stall" nor "fire store"
  // is a phrase with an ordinary meaning to protect.
  'fire stall': 'Firestore',
  // Same paragraph, different manglings — which is itself the finding: the
  // recogniser does not fail the same way twice.
  //   "Syncthing is finally"  -> "Sing thinking is finally"
  //   "in TypeScript over"    -> "in Types Group over"
  //
  // Netlify is NOT here, and that is the interesting omission. It came back as
  // "not a fly" and then as "going to fly", and "not a fly" is ordinary English
  // — measured firing inside "there is a fly in the kitchen and it will not
  // leave". An entry for it would rewrite that sentence.
  'sing thinking': 'Syncthing',
  'types group': 'TypeScript',
  'note js version': 'Node.js version',
  'note. js version': 'Node.js version',
  // "the old Node.js version" -> "the old no.JS version". The recogniser writes
  // the spoken "node" as the abbreviation "no.". Anchored on "version" and
  // "server" because a bare "no js" could be someone answering a question about
  // JavaScript.
  'no. js version': 'Node.js version',
  'no js version': 'Node.js version',
  'no. js server': 'Node.js server',
  'no js server': 'Node.js server',
  'net lify': 'Netlify',
  'craigie burn': 'Craigieburn',
  'swift ui': 'SwiftUI',
  'mac os': 'macOS',
  'i os': 'iOS',

  // Observed manglings the fuzzy corrector CANNOT reach, and why each is
  // unreachable rather than merely missed:
  //
  //   "course"    for CORS   — "course" is real English, so the guard that
  //                            stops the corrector rewriting words he meant
  //                            refuses it, correctly.
  //   "vespa"     for Vesper — same; "vespa" is a word.
  //   "sq light"  for SQLite — scores 0.57 against the term, far below the
  //                            0.85 bar, and lowering that bar is exactly what
  //                            let "build a bed" become "Builda Bed".
  //   "neglified" for Netlify — 0.56 by letters and no closer by sound.
  //
  // A literal table can fix all four because it asks a different question: not
  // "is this span near a term" but "is this exact string one the recogniser has
  // been watched producing". The two that are real English are anchored on the
  // word that followed them, so they cannot fire on the ordinary meaning.
  'course headers': 'CORS headers',
  'no course policy': 'no CORS policy',
  'vespa is the': 'Vesper is the',
  'sq light': 'SQLite',
  'sq lite': 'SQLite',
  neglified: 'Netlify',
  netterfly: 'Netlify',

  // Compound tool names the recogniser splits into two ordinary words.
  //
  // SAFE UNANCHORED — the split form is not a phrase anyone says with its
  // ordinary meaning.
  'git hub': 'GitHub',
  gethub: 'GitHub',
  'post gres': 'Postgres',
  'cloud flare': 'Cloudflare',
  'chat gpt': 'ChatGPT',
  'chat g p t': 'ChatGPT',
  'web pack': 'webpack',
  'vs code': 'VS Code',
  'node js': 'Node.js',
  'next js': 'Next.js',
  'three js': 'Three.js',

  // NEEDS AN ANCHOR — the split form IS ordinary English, so the bare pair
  // would rewrite sentences the user meant. Each was caught firing on real
  // prose before the anchor was added:
  //
  //     "I need to get hub caps for the car" -> "I need to GitHub caps…"
  //     "you tube of toothpaste"             -> "YouTube of toothpaste"
  //     "a tail wind helped the flight"      -> "a Tailwind helped…"
  //     "the air table was covered in dust"  -> "the Airtable was covered…"
  //     "type script tags by hand"           -> "TypeScript tags by hand"
  //     "sync thing up later"                -> "Syncthing up later"
  //
  // "to get hub" is deliberately absent: it fires inside "I need to get hub
  // caps for the car".
  'on get hub': 'on GitHub',
  'get hub repo': 'GitHub repo',
  'get hub actions': 'GitHub actions',
  'get hub pages': 'GitHub pages',
  'push to get hub': 'push to GitHub',
  'pushed to get hub': 'pushed to GitHub',
  'it to get hub': 'it to GitHub',
  'up to get hub': 'up to GitHub',
  'in type script': 'in TypeScript',
  'type script file': 'TypeScript file',
  'to you tube': 'to YouTube',
  'you tube video': 'YouTube video',
  'linked in profile': 'LinkedIn profile',
  'sink thing': 'Syncthing',
  'sync thing is': 'Syncthing is',
  'with tail wind': 'with Tailwind',
  'tail wind css': 'Tailwind CSS',
  'in air table': 'in Airtable',
  'air table base': 'Airtable base',

  // Homophones, but only where the phrase decides the answer.
  //
  // Two rules for what may go in here, both learned the hard way.
  //
  // First, ANCHORED ONLY. A bare "flower" -> "flour" would rewrite every
  // sentence about flowers. Each key below is a fixed phrase where one spelling
  // is simply wrong: nobody writes "hey fever" or "principle developer".
  //
  // Second, PHRASES PEOPLE SAY. Corpus-only failures are not eligible:
  // "peppered flower" -> "peppered flour" would move a benchmark and change
  // nothing for anyone who is not dictating nineteenth-century prose.
  'hey fever': 'hay fever',
  'principle developer': 'principal developer',
  'principle engineer': 'principal engineer',
  'principle amount': 'principal amount',
  'in principal': 'in principle',
  'discrete about': 'discreet about',
  'stationary shop': 'stationery shop',
  'complimentary colours': 'complementary colours',
  'complimentary colors': 'complementary colors',
  'compliments each other': 'complements each other',
  'affect on the': 'effect on the',
  'affect of the': 'effect of the',
  'the affect was': 'the effect was',
  'no affect on': 'no effect on',
  'side affects': 'side effects',
  'your welcome': "you're welcome",
  'loosing the': 'losing the',
  // Deliberately absent, and each for a reason:
  //   "loose the" -> "lose the"      — "loose the reins" is correct English.
  //   "peace/piece of mind"          — both are real phrases with different
  //                                    meanings; the audio cannot tell them
  //                                    apart and neither can a table.
  //   "led"/"lead", "its"/"it's"     — decided by grammar, not by a fixed
  //                                    phrase. That is the model pass's job.
};
