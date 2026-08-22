import { isRealEnglishWord } from '../text/dictionary';
import { isLetter, isNumber } from '../text/strings';
import { bareWord, trailingPunctuation } from './numberStyle';

/// Turns an address said out loud into an address.
///
///     send it to roman gigliotti 123 at gmail dot com
///     -> send it to romangigliotti123@gmail.com
///
/// The real failure this was written for: "send it to the Gmail Grace Kingston
/// 20 at gmail.com" reached the document as prose, with the domain broken into
/// "gmail. Com" on top. The broken domain is fixed elsewhere; this is the rest
/// of it.
///
/// **It anchors on the domain, never on the word "at".** That is the whole
/// safety argument. "Meet me at the shop at four" has no domain and is never
/// even considered. Only once a domain is found does it look left for a local
/// part, and it refuses outright when the word in front of "at" is one that
/// ordinary English puts there — "I'll look at netlify.com later" must not
/// become "I'll look@netlify.com later".
///
/// Deleting or gluing words the user actually said is the failure mode this
/// whole area is scarred by, so every rule here is a refusal rather than a
/// guess.
export function formatSpokenEmails(text: string): string {
  const tokens = text.split(' ');
  if (tokens.length < 3) return text;

  let index = 0;
  while (index < tokens.length) {
    const token = tokens[index]!;
    if (bareWord(token).toLowerCase() !== 'at' || token.includes('@')) {
      index += 1;
      continue;
    }
    // An address the recogniser already assembled is finished.
    const domain = readDomain(tokens, index + 1);
    if (!domain) {
      index += 1;
      continue;
    }
    const local = readLocalPart(tokens, index);
    if (!local || !looksLikeAnAddress(local.text, local.words, local.stoppedOn, domain.text)) {
      index += 1;
      continue;
    }
    // Whatever punctuation closed the last domain token closes the address.
    const trailing = trailingPunctuation(tokens[domain.lastIndex]!);
    tokens.splice(
      local.firstIndex,
      domain.lastIndex - local.firstIndex + 1,
      `${local.text}@${domain.text}${trailing}`,
    );
    index = local.firstIndex + 1;
  }
  return tokens.join(' ');
}

interface Domain { text: string; lastIndex: number }

/// A domain starting at `start`, either already dotted ("gmail.com") or spoken
/// ("gmail dot com", "kass barbers dot com dot au"). Null when there is none,
/// which is the answer for almost every "at" in ordinary speech.
function readDomain(tokens: string[], start: number): Domain | null {
  if (start >= tokens.length) return null;

  // Already dotted. Requires a real-looking suffix so that "node.js" and "1.4"
  // cannot pass as somewhere to send mail.
  const first = bareWord(tokens[start]!);
  if (first.includes('.') && isDottedDomain(first)) {
    return { text: first.toLowerCase(), lastIndex: start };
  }

  // Spoken. Words up to the first "dot" are one label glued together — the
  // recogniser splits "kassbarbers" into "kass barbers" as readily as a name.
  let label = '';
  let index = start;
  while (index < tokens.length && bareWord(tokens[index]!).toLowerCase() !== 'dot') {
    const word = bareWord(tokens[index]!);
    if (!isNameLike(word) || label.length >= 40) return null;
    label += word;
    index += 1;
    // A label that runs on with no "dot" behind it is a sentence.
    if (index - start > 3) return null;
  }
  if (label.length === 0 || index >= tokens.length) return null;

  const parts = [label];
  let last = index;
  while (index < tokens.length && bareWord(tokens[index]!).toLowerCase() === 'dot') {
    if (index + 1 >= tokens.length) return null;
    const next = bareWord(tokens[index + 1]!);
    if (!isTopLevelDomain(next)) return null;
    parts.push(next);
    last = index + 1;
    index += 2;
  }
  if (parts.length < 2) return null;
  return { text: parts.join('.').toLowerCase(), lastIndex: last };
}

interface LocalPart {
  text: string;
  firstIndex: number;
  /// What ended the scan. `null` means it ran off the start of the text. This
  /// is the evidence the caller weighs: a local part that ends at "to" or
  /// "email" was introduced as an address; one that ends at "the" is a noun
  /// standing in front of an ordinary "at".
  stoppedOn: string | null;
  words: string[];
}

/// The address's local part, read backwards from the token before "at".
///
/// Bounded at six tokens, but the bound is a safety net rather than the rule —
/// the stop words are what actually decide. "send it to the Gmail Grace
/// Kingston 20 at gmail.com" stops at "Gmail", because there the provider's
/// name describes the service rather than forming part of the address.
function readLocalPart(tokens: string[], at: number): LocalPart | null {
  const collected: string[] = [];
  let index = at - 1;
  let firstIndex = at;
  let stoppedOn: string | null = null;

  while (index >= 0 && collected.length < 6) {
    const raw = tokens[index]!;
    // A full stop, question mark or exclamation ends the sentence and so ends
    // any address inside it. A comma is only a spoken pause.
    if (raw.endsWith('.') || raw.endsWith('?') || raw.endsWith('!')) {
      stoppedOn = '.';
      break;
    }
    const word = bareWord(raw);
    if (word.length === 0) { stoppedOn = ''; break; }
    if (LOCAL_PART_STOP_WORDS.has(word.toLowerCase())) {
      stoppedOn = word.toLowerCase();
      break;
    }
    if (!isNameLike(word) && word.toLowerCase() !== 'dot') {
      stoppedOn = word.toLowerCase();
      break;
    }
    collected.push(word);
    firstIndex = index;
    index -= 1;
  }

  if (collected.length === 0) return null;

  let out = '';
  for (const word of [...collected].reverse()) {
    if (word.toLowerCase() === 'dot') {
      // A leading or doubled dot is not something anyone said.
      if (out.length === 0 || out.endsWith('.')) return null;
      out += '.';
    } else {
      out += SPOKEN_DIGITS[word.toLowerCase()] ?? word.toLowerCase();
    }
  }
  if (out.length < 2 || out.endsWith('.')) return null;
  if (!Array.from(out).some((c) => isLetter(c) || isNumber(c))) return null;
  return {
    text: out,
    firstIndex,
    stoppedOn,
    words: [...collected].reverse().map((word) => word.toLowerCase()),
  };
}

/// Tokens that introduce an address. A local part that ends at one of these was
/// announced as an address; one that ends at "the" is a noun standing in front
/// of an ordinary English "at".
const ADDRESS_INTRODUCERS = new Set([
  'to', 'send', 'sent', 'sends', 'sending', 'email', 'emailed', 'mail',
  'mailed', 'invoice', 'invoiced', 'forward', 'forwarded', 'cc', 'bcc',
  'contact', 'reach', 'ping', 'message', 'messaged', 'write', 'wrote',
  'address', 'addresses', '.', '',
]);

/// Domains that are only ever mail hosts. Nobody reads documentation at
/// gmail.com, so the host alone is enough evidence.
const MAIL_HOSTS = new Set([
  'gmail.com', 'googlemail.com', 'outlook.com', 'hotmail.com', 'yahoo.com',
  'icloud.com', 'me.com', 'mac.com', 'proton.me', 'protonmail.com',
  'live.com', 'aol.com', 'yandex.com', 'fastmail.com', 'gmx.com', 'zoho.com',
]);

/// Whether "<local> at <domain>" is an address rather than a noun in front of
/// an ordinary "at".
///
/// One piece of positive evidence is required. Refusing costs a spoken address
/// the user can fix; joining wrongly puts a fabricated email address into their
/// document.
function looksLikeAnAddress(
  local: string,
  words: string[],
  stoppedOn: string | null,
  domain: string,
): boolean {
  // 1. It was introduced as one — "send it to noah at gmail dot com", or it
  //    began the sentence.
  if (ADDRESS_INTRODUCERS.has(stoppedOn ?? '')) return true;
  // 2. The domain is a mail host and nothing else.
  if (MAIL_HOSTS.has(domain.toLowerCase())) return true;
  // 3. The local part is not ordinary English: a digit, an internal dot, or a
  //    word the dictionary does not know. "docs" and "form" are words;
  //    "romangigliotti" and "nkass" are not.
  if (Array.from(local).some(isNumber)) return true;
  if (local.slice(0, -1).includes('.')) return true;
  // Checked WORD BY WORD, not on the joined result. "booking form" joins to
  // "bookingform", which no dictionary knows — so testing the joined string
  // called every two-word noun phrase an address, which is the bug wearing a
  // different hat.
  const spoken = words.filter((word) => word !== 'dot');
  if (spoken.length === 0) return false;
  return spoken.some((word) => !isRealEnglishWord(word));
}

/// Words that end a local part when read backwards.
///
/// Two kinds, and both are needed. The verbs and prepositions are what stop
/// "I'll look at netlify.com" becoming an address — English puts them in front
/// of "at" constantly and an address never does. The provider names are what
/// stop "send it to the Gmail Grace Kingston 20 at gmail.com" from swallowing
/// the word Gmail into the name.
export const LOCAL_PART_STOP_WORDS = new Set([
  // Determiners, pronouns and prepositions. "at" is in here because a sentence
  // can hold two of them — "email me at roman dot gigliotti at outlook dot com"
  // — and without it the first one is read as a name.
  'the', 'a', 'an', 'to', 'my', 'your', 'his', 'her', 'their', 'our', 'its',
  'this', 'that', 'these', 'those', 'it', 'them', 'us', 'me', 'him',
  'and', 'or', 'but', 'of', 'in', 'on', 'for', 'with', 'from', 'by', 'at',
  // The verbs that introduce a recipient. Without them "invoice noah at
  // kassbarbers.com.au" addresses mail to invoicenoah.
  'send', 'sent', 'sends', 'sending', 'invoice', 'invoiced', 'forward',
  'forwarded', 'cc', 'bcc', 'contact', 'reach', 'ping', 'message', 'messaged',
  'write', 'wrote', 'text', 'texted', 'call', 'called', 'add', 'invite',
  'invited', 'notify', 'notified', 'tell', 'told', 'ask', 'asked', 'give',
  // Talking ABOUT an address rather than giving one. "for example, if I say
  // Roman Gigliotti, 123, at gmail.com" came out as
  // "if isayromangigliotti123@gmail.com" — the verb and the pronoun glued onto
  // the front of the name.
  'i', 'we', 'you', 'he', 'she', 'they', 'who',
  'say', 'says', 'said', 'saying', 'mention', 'mentions', 'mentioned',
  'spell', 'spells', 'spelled', 'spelt', 'type', 'typed', 'hear', 'heard',
  'put', 'puts', 'read', 'reads', 'example', 'like',
  // Verbs English puts in front of "at". Without these the step reads the verb
  // as a name and glues it to the domain.
  'look', 'looks', 'looked', 'looking', 'meet', 'meets', 'met', 'meeting',
  'stay', 'stayed', 'staying', 'arrive', 'arrived', 'arriving',
  'work', 'works', 'worked', 'working', 'live', 'lives', 'lived', 'living',
  'sit', 'sits', 'sat', 'stand', 'stood', 'stop', 'stopped', 'wait', 'waited',
  'start', 'started', 'point', 'pointed', 'glance', 'glanced', 'stare', 'stared',
  'laugh', 'laughed', 'shout', 'shouted', 'aim', 'aimed', 'host', 'hosted',
  'hosts', 'hosting', 'is', 'was', 'are', 'were', 'be', 'been', 'am',
  'available', 'here', 'there', 'home', 'back', 'again', 'now', 'later',
  // The service, not the address.
  'email', 'e-mail', 'mail', 'gmail', 'googlemail', 'outlook', 'hotmail',
  'yahoo', 'icloud', 'proton', 'protonmail', 'inbox', 'address',
]);

/// Number words that mean a digit when they sit inside an address. "roman
/// gigliotti one two three" is a person spelling out their own email.
export const SPOKEN_DIGITS: Record<string, string> = {
  zero: '0', oh: '0', one: '1', two: '2', three: '3', four: '4',
  five: '5', six: '6', seven: '7', eight: '8', nine: '9',
};

/// Letters, digits, and nothing else. Deliberately excludes anything already
/// carrying punctuation, because that is a sentence doing something else.
function isNameLike(word: string): boolean {
  return word.length > 0 && Array.from(word).every((c) => isLetter(c) || isNumber(c));
}

/// A suffix that could be a real top-level domain: two to six letters. Rules
/// out "dot 4" and "dot something-with-punctuation".
function isTopLevelDomain(word: string): boolean {
  return word.length >= 2 && word.length <= 6 && Array.from(word).every(isLetter);
}

/// Dotted names that are not places you can send mail.
export const NON_MAIL_SUFFIXES = new Set(['js', 'ts', 'py', 'rb', 'sh', 'md', 'json', 'swift']);

/// "gmail.com" and "kassbarbers.com.au" yes; "node.js" and "1.4" no.
///
/// The ".js" exclusion is why this is a list rather than a shape test: three.js
/// and node.js are exactly the shape of a domain, they are named in dictation
/// constantly, and nobody sends mail to them.
function isDottedDomain(word: string): boolean {
  const labels = word.toLowerCase().split('.');
  if (labels.length < 2) return false;
  if (!labels.every((label) => label.length > 0
    && Array.from(label).every((c) => isLetter(c) || isNumber(c) || c === '-'))) return false;
  // Every label but the last must contain a letter, so "1.4" is not a domain.
  if (!labels.slice(0, -1).every((label) => Array.from(label).some(isLetter))) return false;
  const tld = labels[labels.length - 1]!;
  if (!isTopLevelDomain(tld)) return false;
  return !NON_MAIL_SUFFIXES.has(tld);
}
