import type { NumberStyle } from '../settings';
import { applyNumberStyle } from './numberStyle';
import { isLetter, isUppercase, trimPunctuation } from '../text/strings';

/// What kind of place the text is about to land in.
///
/// Every dictation app treats the destination as a single undifferentiated hole
/// to put words in, and the result is that dictating a shell command into a
/// terminal gives you `git status.` — with a full stop, which is not a command.
/// Dictating into a search field gives you `Melbourne weather.` Dictating a
/// commit message gives you a capital letter you then delete.
///
/// Quill already knows the answer: the injection path reads the frontmost
/// application to decide where it is safe to type. That fact was being used for
/// safety and thrown away for formatting.
export type AppContext = 'terminal' | 'query' | 'code' | 'prose';

export const APP_CONTEXTS: AppContext[] = ['terminal', 'query', 'code', 'prose'];

/// Executable and window-class names, per platform, matched case-insensitively.
///
/// The macOS build matched bundle identifiers, which do not exist anywhere else.
/// Windows has an executable name; X11 and Wayland have a window class, and
/// most toolkits set it to something recognisable. Both are what the window
/// watcher reports, so both are matched here against one list.
///
/// Deliberately a small list of things people actually use rather than an
/// attempt at completeness. A wrong guess here silently changes how someone's
/// words come out, so the default is prose — the conservative answer.
const TERMINALS = [
  // Windows
  'windowsterminal.exe', 'wt.exe', 'cmd.exe', 'powershell.exe', 'pwsh.exe',
  'conhost.exe', 'mintty.exe', 'alacritty.exe', 'wezterm-gui.exe', 'putty.exe',
  // Linux
  'gnome-terminal', 'gnome-terminal-server', 'konsole', 'xterm', 'urxvt',
  'alacritty', 'kitty', 'wezterm', 'wezterm-gui', 'terminator', 'tilix',
  'xfce4-terminal', 'foot', 'ghostty', 'st', 'sakura', 'guake', 'yakuake',
  'org.gnome.terminal', 'org.gnome.console', 'kgx',
  // macOS
  'terminal', 'iterm2', 'iterm', 'hyper',
];

const EDITORS = [
  // Windows
  'code.exe', 'code - insiders.exe', 'devenv.exe', 'rider64.exe', 'idea64.exe',
  'pycharm64.exe', 'webstorm64.exe', 'clion64.exe', 'goland64.exe',
  'sublime_text.exe', 'notepad++.exe', 'cursor.exe', 'zed.exe', 'nvim.exe',
  // Linux
  'code', 'code-insiders', 'codium', 'vscodium', 'sublime_text', 'gedit',
  'kate', 'nvim', 'vim', 'gvim', 'emacs', 'jetbrains-idea', 'jetbrains-pycharm',
  'jetbrains-webstorm', 'jetbrains-rider', 'zed', 'cursor', 'lapce', 'helix',
  // macOS
  'xcode', 'visual studio code', 'sublime text',
];

const BROWSERS = [
  'chrome.exe', 'msedge.exe', 'firefox.exe', 'brave.exe', 'opera.exe',
  'google-chrome', 'chromium', 'chromium-browser', 'firefox', 'brave-browser',
  'vivaldi-stable', 'microsoft-edge', 'safari', 'arc',
];

function matches(name: string, list: string[]): boolean {
  const lowered = name.toLowerCase();
  return list.some((candidate) => lowered === candidate || lowered.startsWith(`${candidate}.`)
    || lowered.endsWith(`/${candidate}`) || lowered.includes(candidate));
}

/// The application the text is about to be inserted into, from whatever the
/// platform's window watcher could tell us.
///
/// A browser is deliberately NOT `.query`. The address bar is a query and every
/// other field in a browser is prose, and there is no way to tell them apart
/// from outside — so a browser is prose, which is the conservative answer, and
/// the `.query` case is reserved for callers that genuinely know.
export function appContextOf(processOrClass: string | null | undefined): AppContext {
  if (!processOrClass) return 'prose';
  if (matches(processOrClass, TERMINALS)) return 'terminal';
  if (matches(processOrClass, EDITORS)) return 'code';
  if (matches(processOrClass, BROWSERS)) return 'prose';
  return 'prose';
}

/// Whether a sentence should be given a capital letter at the front.
///
/// A code editor keeps its capitals, and that is a reversal. The reasoning for
/// suppressing them was sound and the evidence against it is better: an editor
/// is not only an editor. Prose dictated into a chat panel inside VS Code all
/// day came out lower-cased — "one thing I want you to do is…", four in a row.
/// The rule was right about code and wrong about the place it is actually used.
///
/// A terminal still gets none, because that is where suppression earns its
/// place: `Git status` is not a command.
export function capitalisesSentences(context: AppContext): boolean {
  return context === 'code' || context === 'prose';
}

/// Whether a trailing full stop is welcome.
///
/// This is the one that bites hardest. `npm run build.` is not a command, and
/// the full stop has to be found and deleted every single time — exactly the
/// kind of small tax that makes someone stop using dictation without ever being
/// able to say why.
export function keepsTrailingFullStop(context: AppContext): boolean {
  return context === 'code' || context === 'prose';
}

/// Whether a spoken number should be restyled for this destination.
///
/// Only prose. "Spell out small numbers" is a writing convention, and a shell
/// command, a search box and a source file are not writing — `git log -3`
/// becoming `git log -three` is not a style preference, it is a broken command.
export function stylesNumbers(context: AppContext): boolean {
  return context === 'prose';
}

export function contextTitle(context: AppContext): string {
  switch (context) {
    case 'terminal': return 'Terminal';
    case 'query': return 'Search field';
    case 'code': return 'Code editor';
    case 'prose': return 'Everything else';
  }
}

export function contextExplanation(context: AppContext): string {
  switch (context) {
    case 'terminal': return 'No capital, no full stop — a command is not a sentence.';
    case 'query': return 'No full stop; a query does not end in one.';
    case 'code': return 'Full punctuation and sentence casing — an editor is not only code.';
    case 'prose': return 'Full punctuation and sentence casing.';
  }
}

/// Applies the destination's conventions to already-cleaned text.
///
/// Runs last, after the deterministic cleanup and after any model pass, because
/// it is the only step that knows something the others cannot: where the words
/// are going. It only ever *removes* decoration that the cleanup added — never
/// adds anything, never reorders, never touches a word. The worst it can do is
/// leave text exactly as the cleanup produced it.
///
/// `numbers` defaults to `asHeard` so that every caller which has no opinion,
/// and every test which is not about numbers, sees exactly what it saw before.
export function applyAppContext(
  text: string,
  context: AppContext,
  numbers: NumberStyle = 'asHeard',
): string {
  let out = text;
  if (stylesNumbers(context)) out = applyNumberStyle(out, numbers);
  if (!keepsTrailingFullStop(context)) {
    // Only a full stop, and only one, and only at the very end. A question mark
    // is information — "did the build pass?" means something a full stop does
    // not — and an ellipsis is deliberate.
    if (out.endsWith('.') && !out.endsWith('..')) out = out.slice(0, -1);
  }
  if (!capitalisesSentences(context)) out = lowercasingFirstLetterIfSafe(out);
  return out;
}

/// Undoes the cleanup's opening capital, unless the first word looks like it
/// wanted one.
///
/// A name at the start of a command is common — `Docker ps`, `Netlify deploy` —
/// and the vocabulary corrector may deliberately have capitalised it moments
/// earlier. So a word that is capitalised in the middle of the text too, or a
/// word that is not plain lowercase-able, is left alone. Getting this wrong in
/// the safe direction means an unwanted capital; getting it wrong in the unsafe
/// direction means mangling a proper noun.
export function lowercasingFirstLetterIfSafe(text: string): string {
  const first = text[0];
  if (!first || !isUppercase(first)) return text;
  const pieces = text.split(' ').filter((piece) => piece.length > 0);
  const firstWord = pieces[0];
  if (!firstWord) return text;
  // ALL CAPS is an acronym: NPM, SSH, API. Leave it.
  if (firstWord.length > 1 && Array.from(firstWord).every((c) => !isLetter(c) || isUppercase(c))) {
    return text;
  }
  // The same word capitalised again later is a name, not a sentence start.
  const bare = trimPunctuation(firstWord);
  if (pieces.slice(1).some((piece) => piece.startsWith(bare))) return text;
  return first.toLowerCase() + text.slice(1);
}
