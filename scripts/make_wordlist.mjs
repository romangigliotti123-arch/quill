#!/usr/bin/env node
// Builds src/data/words.txt.gz — the list behind `isRealEnglishWord`.
//
// This replaces a call to the operating system's spell checker, which does not
// exist on two of the three platforms Quill now runs on. See
// src/core/text/dictionary.ts for why that answer has to be deterministic
// rather than "whatever this machine happens to have installed".
//
// # What goes in
//
//   1. A base list of headwords. `/usr/share/dict/words` when it is there
//      (macOS ships Webster's 2nd, 235k entries; most Linux boxes have a
//      wamerican/wbritish list at the same path), otherwise the bundled
//      fallback below. Lowercased, letters only, two characters or more.
//   2. Inflections generated from those headwords by ordinary English rules —
//      plurals, past tense, participles, comparatives. Webster's has no
//      inflections at all, so without this step "apps", "repos", "backends"
//      and "runs" are all reported as non-words. That matters: a non-word is
//      exactly what unlocks the phonetic repair route in VocabularyCorrector,
//      so a missing plural is a standing licence to rewrite it.
//   3. British spellings for every American headword, via the same table the
//      Style profile uses. The macOS build shipped a bug where "colour",
//      "realise" and "organised" were reported as non-words on an Australian
//      user's machine because it asked "en" (US) first; there is no preferred
//      variant here, both are simply present.
//   4. Contractions, and the modern/technical vocabulary a 1934 dictionary has
//      never heard of but that any user of this app says constantly.
//
// # What is deliberately left in
//
// The archaic tail of Webster's — "wen", "soss", "haff". Leaving them in makes
// the corrector MORE reluctant, because a span containing a known word cannot
// take the sound-based route. Reluctant is the safe direction: a miss costs one
// correction, a wrong fire costs a sentence the user meant.

import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { gzipSync } from 'node:zlib';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, '..', 'src', 'data', 'words.txt.gz');

// MARK: - Base list

const systemLists = [
  '/usr/share/dict/words',
  '/usr/share/dict/american-english',
  '/usr/share/dict/british-english',
  '/usr/dict/words',
];

const base = new Set();
let sourced = 0;
for (const path of systemLists) {
  if (!existsSync(path)) continue;
  const text = readFileSync(path, 'utf8');
  for (const line of text.split('\n')) {
    const word = line.trim().toLowerCase();
    if (word.length < 2) continue;
    if (!/^[a-z]+$/.test(word)) continue;
    base.add(word);
  }
  sourced += 1;
}
if (sourced === 0) {
  console.warn('[quill] no system word list found — the built list will be the fallback only');
}

// MARK: - Inflections
//
// Ordinary English rules, applied to headwords short enough that the result is
// a word somebody might actually say. Over-generation is harmless here (a
// non-word marked as a word makes the corrector refuse to act) and
// under-generation is not, so the rules are generous.

function inflections(word) {
  if (word.length < 3 || word.length > 14) return [];
  const out = [];
  const last = word[word.length - 1];
  const penult = word[word.length - 2];
  const isVowel = (c) => 'aeiou'.includes(c);

  // Plural / third person.
  if (/(s|x|z|ch|sh)$/.test(word)) out.push(word + 'es');
  else if (last === 'y' && !isVowel(penult)) out.push(word.slice(0, -1) + 'ies');
  else out.push(word + 's');

  // Past tense and past participle.
  if (last === 'e') out.push(word + 'd');
  else if (last === 'y' && !isVowel(penult)) out.push(word.slice(0, -1) + 'ied');
  else out.push(word + 'ed');

  // Present participle.
  if (last === 'e' && penult !== 'e') out.push(word.slice(0, -1) + 'ing');
  else out.push(word + 'ing');

  // Agent and comparatives, only for short stems where they read as English.
  if (word.length <= 8) {
    if (last === 'e') {
      out.push(word + 'r', word + 'st');
    } else if (last === 'y' && !isVowel(penult)) {
      out.push(word.slice(0, -1) + 'ier', word.slice(0, -1) + 'iest');
    } else {
      out.push(word + 'er', word + 'est');
    }
    out.push(word + 'ly');
  }
  return out;
}

// MARK: - British spellings
//
// The same rules as src/core/style/orthography.ts, applied in reverse so both
// spellings end up present.

function britishVariants(word) {
  const out = [];
  if (word.endsWith('ize') && word.length >= 6) out.push(word.slice(0, -3) + 'ise');
  if (word.endsWith('ized') && word.length >= 7) out.push(word.slice(0, -4) + 'ised');
  if (word.endsWith('izing') && word.length >= 8) out.push(word.slice(0, -5) + 'ising');
  if (word.endsWith('ization') && word.length >= 10) out.push(word.slice(0, -7) + 'isation');
  if (word.endsWith('yze') && word.length >= 6) out.push(word.slice(0, -3) + 'yse');
  if (word.endsWith('yzed') && word.length >= 7) out.push(word.slice(0, -4) + 'ysed');
  if (word.endsWith('yzing') && word.length >= 8) out.push(word.slice(0, -5) + 'ysing');
  if (word.endsWith('or') && word.length >= 5) out.push(word.slice(0, -2) + 'our');
  if (word.endsWith('ors') && word.length >= 6) out.push(word.slice(0, -3) + 'ours');
  if (word.endsWith('er') && word.length >= 5) out.push(word.slice(0, -2) + 're');
  if (word.endsWith('ers') && word.length >= 6) out.push(word.slice(0, -3) + 'res');
  if (word.endsWith('og') && word.length >= 6) out.push(word.slice(0, -2) + 'ogue');
  if (word.endsWith('ense') && word.length >= 6) out.push(word.slice(0, -4) + 'ence');
  return out;
}

// MARK: - The words a 1934 dictionary has never heard of
//
// Everything below is a word someone dictating in 2026 says out loud, that is
// ordinary English rather than a proper noun, and that is therefore something
// the corrector must NOT try to repair. Proper nouns belong in the user's own
// Dictionary, not here.

const modern = `
app apps email emails online offline website websites internet download downloads
upload uploads login logout username password passwords laptop laptops smartphone
smartphones software hardware webpage webpages blog blogs blogger podcast podcasts
newsletter dashboard dashboards workflow workflows onboarding checkout signup
freelance freelancer freelancers startup startups ecommerce
backend frontend fullstack runtime toolchain codebase repo repos filename filenames
username hostname timestamp timestamps changelog changelogs metadata boolean
config configs env envs auth cache caching cached cached rollback rollout deploy
deploys deployment deployments refactor refactors refactored refactoring linter
linters lint lints debug debugger debugging async await callback callbacks
middleware endpoint endpoints webhook webhooks payload payloads schema schemas
namespace namespaces enum enums struct structs iterable serialise serialize
deserialise deserialize
wifi bluetooth usb webcam microphone microphones headphone headphones headset
touchpad trackpad screenshot screenshots screencast emoji emojis gif gifs
video videos audio playlist playlists streaming stream streams livestream
selfie meme memes hashtag hashtags retweet unfollow unfollowed followers
texting texted messaging messaged chatting
covid vaccine vaccines lockdown lockdowns telehealth
uber ubers rideshare airbnb crowdfunding crowdfunded subreddit
ok okay yeah yep nope nah hey hi hiya gonna wanna gotta kinda sorta cheers
mate mates heaps reckon arvo servo brekkie barbie bogan dunno lemme gimme
totally basically literally honestly obviously seriously actually anyway anyways
whatever whenever wherever whoever however
todo todos faq faqs asap diy ceo cto cfo hr pr roi kpi seo saas api apis sdk sdks
url urls uri uris html css js json yaml csv pdf pdfs png jpg jpeg svg mp3 mp4
sms otp pin qr vpn dns ip ssl tls http https ftp ssh cli gui ui ux ide os
smartwatch wearables biometrics
` .split(/\s+/).filter(Boolean);

const contractions = `
i'm i've i'll i'd you're you've you'll you'd he's he'll he'd she's she'll she'd
it's it'll we're we've we'll we'd they're they've they'll they'd that's there's
here's what's who's where's when's how's let's isn't aren't wasn't weren't
haven't hasn't hadn't don't doesn't didn't won't wouldn't can't couldn't
shouldn't mustn't shan't ain't y'all o'clock
`.split(/\s+/).filter(Boolean);

// A short fallback for a machine with no system list at all. Not a dictionary —
// enough that the guards behave sanely rather than treating every word as a
// mishearing.
const fallbackCore = `
the be to of and a in that have i it for not on with he as you do at this but his
by from they we say her she or an will my one all would there their what so up out
if about who get which go me when make can like time no just him know take people
into year your good some could them see other than then now look only come its over
think also back after use two how our work first well way even new want because any
these give day most us is are was were been has had did does said made
`.split(/\s+/).filter(Boolean);

// MARK: - Build

const words = new Set();
const add = (w) => {
  const word = String(w).toLowerCase().trim();
  if (word.length >= 1 && /^[a-z'’-]+$/.test(word)) words.add(word);
};

for (const word of base.size > 0 ? base : fallbackCore) add(word);
for (const word of modern) add(word);
for (const word of contractions) add(word);
for (const word of fallbackCore) add(word);

const headwords = [...words];
for (const word of headwords) {
  if (!/^[a-z]+$/.test(word)) continue;
  for (const form of inflections(word)) add(form);
  for (const form of britishVariants(word)) add(form);
}
// One more inflection pass over the British spellings, so "organised" and
// "organising" exist alongside "organise".
for (const word of [...words]) {
  if (!/(ise|yse|our|re|ence)$/.test(word)) continue;
  for (const form of inflections(word)) add(form);
}

const sorted = [...words].sort();
mkdirSync(dirname(out), { recursive: true });
const packed = gzipSync(Buffer.from(sorted.join('\n'), 'utf8'), { level: 9 });
writeFileSync(out, packed);

console.log(
  `[quill] wrote ${out}\n` +
    `        ${sorted.length.toLocaleString()} words, ${(packed.length / 1024 / 1024).toFixed(2)} MB gzipped\n` +
    `        base list${sourced === 1 ? '' : 's'}: ${sourced}`,
);
