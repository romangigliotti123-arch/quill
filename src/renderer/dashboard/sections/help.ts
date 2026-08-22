import { api, type DiagnosticsReport } from '../bridge';
import { card, clear, h, keycap, message, pageHead } from '../dom';
import { toast } from '../toast';

/// The screen you open when it is not working.
///
/// Every failure this app has is silent by nature: a keyboard hook that will
/// not start, a compositor that will not say which window is focused, a
/// microphone that was refused. None of those raise an error anywhere the user
/// can see, so the whole point of this screen is to say which of them is
/// currently true — and, where the answer is bad, exactly what to type.

export async function renderHelp(root: HTMLElement): Promise<void> {
  clear(root);
  root.appendChild(pageHead('Help', 'What Quill can see from in here, and what to do when it cannot see something.'));

  const body = h('div', {});
  root.appendChild(body);

  const report = await api.app.diagnostics();
  body.appendChild(howItWorks());
  body.appendChild(checks(report));
  body.appendChild(privacy());
  body.appendChild(about(report));
}

function howItWorks(): HTMLElement {
  return h('section', {},
    h('h2', { class: 'section-title' }, 'How it works'),
    card(
      h('ul', { style: 'margin:0;padding-left:18px;line-height:1.7' },
        h('li', {}, 'Hold the dictation key and speak. Let go, and the words land where your cursor already is.'),
        h('li', {}, 'Double-tap it for hands-free. Tap once to stop.'),
        h('li', {}, 'Press ', keycap('Esc'), ' while holding to throw the dictation away.'),
        h('li', {}, 'Speech recognition runs entirely on this machine. It works on a plane.'))));
}

function checks(report: DiagnosticsReport): HTMLElement {
  const section = h('section', {}, h('h2', { class: 'section-title' }, 'Checks'));

  section.appendChild(checkRow(
    'Push-to-talk',
    report.keyboardHook,
    report.keyboardHook
      ? 'Quill can see the dictation key.'
      : 'Quill cannot watch the keyboard on this machine, so holding a key does nothing. '
        + 'Dictation still works from the tray menu.',
    report.keyboardHook ? null : hookFix(report),
  ));

  section.appendChild(checkRow(
    'Knowing which window you are in',
    report.focusTracking.working,
    report.focusTracking.working
      ? `Currently: ${report.focusTracking.active ?? 'unknown'}. This is what lets Quill leave the `
        + 'full stop off a shell command and keep the capital in a chat message.'
      : (report.focusTracking.reason
        ?? 'Quill cannot tell which window is focused, so everything is formatted as prose.'),
    null,
  ));

  section.appendChild(checkRow(
    'Speech model',
    report.speech.ready,
    report.speech.ready
      ? `${report.speech.model} on the ${report.speech.device === 'webgpu' ? 'GPU' : 'CPU'}.`
        + (report.speech.fellBackToCPU ? ' You asked for the GPU and this machine could not provide it.' : '')
      : (report.speech.lastError
        ?? 'Not loaded yet. It downloads once, the first time you dictate, and then runs offline.'),
    null,
  ));

  section.appendChild(checkRow(
    'Word list',
    report.dictionary.loaded,
    report.dictionary.loaded
      ? `${report.dictionary.words.toLocaleString()} words. This is what stops Quill "correcting" `
        + 'a word you meant.'
      : 'The bundled word list is missing, so Quill is more willing to rewrite words than it should '
        + 'be. Reinstall to fix it.',
    null,
  ));

  section.appendChild(checkRow(
    'AI cleanup',
    report.aiKey.configured,
    report.aiKey.configured
      ? `A key is configured (${report.aiKey.fingerprint}). This only affects the cleanup pass — `
        + 'transcription is on-device either way.'
      : 'No key. Everything except spoken self-correction works without one.',
    null,
  ));

  return section;
}

function hookFix(report: DiagnosticsReport): HTMLElement | null {
  if (report.platform.startsWith('linux') && report.sessionType === 'wayland') {
    return h('div', {},
      h('p', { class: 'metric-note' },
        'On Wayland, Quill reads the keyboard through /dev/input, which is restricted by default. '
        + 'Add yourself to the input group and log back in:'),
      h('pre', { class: 'mono tiny', style: 'margin:6px 0;white-space:pre-wrap' },
        'sudo usermod -aG input $USER'));
  }
  if (report.platform.startsWith('darwin')) {
    return h('p', { class: 'metric-note' },
      'macOS needs Quill in System Settings ▸ Privacy & Security ▸ Accessibility. If it is already '
      + 'listed, remove it and add it again — the permission is tied to the exact binary, and a '
      + 'rebuild invalidates it while the toggle keeps showing as on.');
  }
  return h('p', { class: 'metric-note' },
    'This usually means the input library did not install. Reinstalling Quill is the fix.');
}

function checkRow(
  title: string,
  good: boolean,
  detail: string,
  extra: HTMLElement | null,
): HTMLElement {
  return card(
    h('div', { style: 'display:flex;align-items:center;gap:8px' },
      h('span', { class: good ? 'dot live' : 'dot bad' }),
      h('span', { style: 'font-weight:600' }, title),
      h('span', { class: good ? 'chip good' : 'chip warn', style: 'margin-left:auto' },
        good ? 'working' : 'needs attention')),
    h('div', { class: 'metric-note', style: 'margin-top:8px' }, detail),
    extra);
}

function privacy(): HTMLElement {
  return h('section', {},
    h('h2', { class: 'section-title' }, 'What leaves this machine'),
    message({
      title: 'Your voice never does.',
      body: 'Speech recognition runs locally, on a model downloaded once and then cached. There is '
        + 'no account and no upload.',
      steps: [
        'The speech model is fetched from huggingface.co the first time you dictate, and never again.',
        'If you add an API key, the cleaned-up TEXT of a dictation is sent for the optional cleanup pass — never the audio, and only when a retraction or a confusable word is detected.',
        'Everything Quill knows about you is plain JSON in one folder that you can read, edit and delete.',
      ],
      action: { label: 'Open that folder', onClick: () => { void api.app.openDataDirectory(); } },
    }));
}

function about(report: DiagnosticsReport): HTMLElement {
  const lines: [string, string][] = [
    ['Version', report.version],
    ['Electron', report.electron],
    ['Platform', `${report.platform} · ${report.arch}`],
    ['Session', report.sessionType ?? '—'],
    ['Data', report.dataDirectory],
  ];
  return h('section', {},
    h('h2', { class: 'section-title' }, 'About'),
    card(
      ...lines.map(([label, value]) => h('div', {
        style: 'display:flex;justify-content:space-between;gap:16px;padding:3px 0',
      },
        h('span', { class: 'muted tiny' }, label),
        h('span', { class: 'mono tiny truncate' }, value))),
      h('div', { style: 'display:flex;gap:8px;margin-top:14px' },
        h('button', {
          class: 'button secondary small',
          onClick: async () => {
            await navigator.clipboard.writeText(JSON.stringify(report, null, 2));
            toast('Diagnostics copied — paste them into a bug report.');
          },
        }, 'Copy diagnostics'),
        h('button', { class: 'button ghost small', onClick: () => { void api.app.relaunch(); } },
          'Restart Quill'))));
}
