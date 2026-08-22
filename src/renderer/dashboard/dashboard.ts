import { api, type SettingsValues, type SpeechStatus } from './bridge';
import { clear, h, message, pageHead } from './dom';
import { brandMark, icon } from './icons';
import { renderInsights } from './sections/insights';
import { renderDictation } from './sections/dictation';
import { renderDictionary } from './sections/dictionary';
import { renderSnippets } from './sections/snippets';
import { renderStyle } from './sections/style';
import { renderTransforms } from './sections/transforms';
import { renderScratchpad } from './sections/scratchpad';
import { renderSettings } from './sections/settings';
import { renderHelp } from './sections/help';

/// The dashboard's information architecture.
///
/// The order is the one a dictation user actually moves through — what you
/// said, what it heard, how it writes, where it goes — ranked by what it is
/// worth to somebody who just wants the app to work, which is not the order the
/// features were built in.
///
/// Insights leads because it is the only screen that answers "is this thing
/// actually helping me": the one you open on purpose, rather than the one you
/// land on. Dictation is second, because it is the record of what you said and
/// the place you go to recover something. Then the two that make the app better
/// the more you use them, then the tuning, then the two a person can go a month
/// without opening.

interface Section {
  id: string;
  title: string;
  render: (root: HTMLElement) => Promise<void> | void;
  footer?: boolean;
}

const SECTIONS: Section[] = [
  { id: 'insights', title: 'Insights', render: renderInsights },
  { id: 'dictation', title: 'Dictation', render: renderDictation },
  { id: 'dictionary', title: 'Dictionary', render: renderDictionary },
  { id: 'snippets', title: 'Snippets', render: renderSnippets },
  { id: 'style', title: 'Style', render: renderStyle },
  { id: 'transforms', title: 'Transforms', render: renderTransforms },
  { id: 'notetaker', title: 'Notetaker', render: renderNotetaker },
  { id: 'scratchpad', title: 'Scratchpad', render: renderScratchpad },
  { id: 'settings', title: 'Settings', render: renderSettings, footer: true },
  { id: 'help', title: 'Help', render: renderHelp, footer: true },
];

const sidebar = document.getElementById('sidebar') as HTMLElement;
const content = document.getElementById('content') as HTMLElement;

let current = 'insights';
let settings: SettingsValues | null = null;
let speech: SpeechStatus | null = null;
let activity: 'idle' | 'listening' | 'transcribing' = 'idle';

function stateLine(): string {
  if (activity === 'listening') return 'Listening…';
  if (activity === 'transcribing') return 'Transcribing…';
  if (speech?.downloading) return `Downloading model ${Math.round(speech.downloading.progress)}%`;
  if (speech && !speech.ready) return 'Model not loaded';
  return 'Ready';
}

function drawSidebar(): void {
  clear(sidebar);

  sidebar.appendChild(h('div', { class: 'brand' },
    h('div', { class: 'mark' }, brandMark()),
    h('div', {},
      h('div', { class: 'name' }, 'Quill'),
      h('div', { class: 'state' }, stateLine()))));

  for (const section of SECTIONS.filter((candidate) => !candidate.footer)) {
    sidebar.appendChild(navRow(section));
  }
  sidebar.appendChild(h('div', { class: 'nav-spacer' }));
  sidebar.appendChild(h('div', { class: 'nav-rule' }));
  for (const section of SECTIONS.filter((candidate) => candidate.footer)) {
    sidebar.appendChild(navRow(section));
  }
}

function navRow(section: Section): HTMLElement {
  return h('button', {
    class: 'nav-row',
    'aria-current': section.id === current ? 'page' : undefined,
    onClick: () => { void go(section.id); },
  },
    h('span', { class: 'glyph' }, icon(section.id)),
    h('span', {}, section.title));
}

async function go(id: string): Promise<void> {
  const section = SECTIONS.find((candidate) => candidate.id === id);
  if (!section) return;
  current = id;
  window.location.hash = id;
  drawSidebar();
  clear(content);
  content.scrollTop = 0;
  try {
    await section.render(content);
  } catch (error) {
    // A screen that throws must not leave a blank pane with nothing to act on.
    clear(content);
    content.appendChild(pageHead(section.title));
    content.appendChild(message({
      title: 'This screen could not be drawn.',
      body: String(error),
      action: { label: 'Try again', onClick: () => { void go(id); } },
    }));
  }
}

function renderNotetaker(root: HTMLElement): void {
  clear(root);
  root.appendChild(pageHead('Notetaker'));
  root.appendChild(message({
    title: 'Not built yet',
    // Written for the person reading it, not for whoever built it. Three
    // things, in the language of someone who wants to record a meeting.
    body: 'Quill cannot sit in on a meeting yet. Three things have to land first.',
    steps: [
      'Hearing the other side of the call, not just your microphone.',
      'Knowing from your calendar when a meeting starts.',
      'Telling one voice from another in the transcript.',
    ],
  }));
}

async function boot(): Promise<void> {
  settings = await api.settings.get();
  speech = await api.speech.status();

  api.on('settings', (payload) => {
    settings = payload as SettingsValues;
    // Re-render the current screen only when it is one that shows a setting.
    if (current === 'settings') void go('settings');
  });
  api.on('speech', (payload) => {
    const next = payload as SpeechStatus;
    // The sidebar shows the download percentage, so it redraws every tick. The
    // screen underneath does not: rebuilding Settings a hundred times while a
    // model comes down costs five IPC round trips each time and changes
    // nothing, because none of what it shows depends on how far along the
    // download is.
    const changed = !speech
      || speech.ready !== next.ready
      || speech.device !== next.device
      || speech.model !== next.model
      || speech.fellBackToCPU !== next.fellBackToCPU
      || speech.lastError !== next.lastError
      || (speech.downloading === null) !== (next.downloading === null);
    speech = next;
    drawSidebar();
    if (changed && (current === 'settings' || current === 'help')) void go(current);
  });
  api.on('activity', (payload) => {
    activity = payload as typeof activity;
    drawSidebar();
  });

  // Number keys jump between screens, the way every app with a sidebar does.
  document.addEventListener('keydown', (event) => {
    if (event.metaKey || event.ctrlKey) {
      const index = Number.parseInt(event.key, 10);
      if (Number.isInteger(index) && index >= 1 && index <= SECTIONS.length) {
        event.preventDefault();
        void go(SECTIONS[index - 1]!.id);
      }
    }
  });

  const fromHash = window.location.hash.replace('#', '');
  await go(SECTIONS.some((section) => section.id === fromHash) ? fromHash : 'insights');
}

void boot();
