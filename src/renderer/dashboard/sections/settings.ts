import { api, type BindingOption, type SettingsValues, type SpeechStatus } from '../bridge';
import {
  card, clear, formatBytes, h, keycap, pageHead, segmented, toggleRow,
} from '../dom';
import { toast } from '../toast';
import { confirmSheet } from '../sheet';

/// Everything a user is allowed to change.
///
/// Ordered by how often it is touched rather than by how the code is
/// structured: the key you hold is first because it is the one thing somebody
/// will change on day one, and "erase everything" is last because it is the one
/// thing they should not reach by accident.

const MODELS = [
  { value: 'onnx-community/whisper-tiny.en', label: 'Tiny — fastest, least accurate (~40 MB)' },
  { value: 'onnx-community/whisper-base.en', label: 'Base — the default (~80 MB)' },
  { value: 'onnx-community/whisper-small.en', label: 'Small — more accurate, slower (~250 MB)' },
  { value: 'onnx-community/whisper-large-v3-turbo', label: 'Large turbo — best, needs a GPU (~800 MB)' },
];

export async function renderSettings(root: HTMLElement): Promise<void> {
  // Built off-screen and swapped in, rather than cleared and then filled.
  //
  // This screen is re-rendered on every speech status change, and the model
  // download emits one of those per progress tick. Clearing first meant
  // Settings blanked itself to a bare heading and stayed that way for up to
  // four seconds — the timeout on the microphone list — over and over while the
  // model came down. Measured: content at 308 ms, nothing at 4.7 s, content
  // again at 8.0 s.
  const body = h('div', {});
  let attached = false;

  const draw = async (): Promise<void> => {
    const [settings, bindings, speech, key, devices] = await Promise.all([
      api.settings.get(),
      api.settings.bindings(),
      api.speech.status(),
      api.ai.key(),
      api.speech.devices().catch(() => []),
    ]);
    clear(body);
    body.appendChild(hotkeys(settings, bindings, draw));
    body.appendChild(dictating(settings, draw));
    body.appendChild(microphone(settings, devices, draw));
    body.appendChild(speechModel(settings, speech, draw));
    body.appendChild(writing(settings, draw));
    body.appendChild(aiSection(key, draw));
    body.appendChild(filesSection(settings, draw));

    if (!attached) {
      attached = true;
      clear(root);
      root.appendChild(pageHead('Settings'));
      root.appendChild(body);
    }
  };

  await draw();
}

function hotkeys(
  settings: SettingsValues,
  bindings: BindingOption[],
  redraw: () => Promise<void>,
): HTMLElement {
  const section = h('section', {}, h('h2', { class: 'section-title' }, 'The key you hold'));
  const current = bindings.find((binding) => binding.name === settings.holdKey);

  const grid = h('div', { class: 'grid cols-4' });
  for (const binding of bindings) {
    const chosen = binding.name === settings.holdKey;
    grid.appendChild(h('button', {
      class: 'card',
      style: `text-align:left;border-color:${chosen ? 'var(--accent)' : 'var(--hairline)'}`,
      onClick: async () => {
        // Both are set together. When they are the same key, hands-free is
        // reached by double-tapping — which is the shipped arrangement and the
        // one the gesture machine is written around.
        await api.settings.set({ holdKey: binding.name, toggleKey: binding.name });
        toast(`Dictation key set to ${binding.display}.`);
        await redraw();
      },
    },
      h('div', { style: 'display:flex;align-items:center;gap:8px' },
        h('span', { class: chosen ? 'dot live' : 'dot' }),
        h('span', { style: 'font-weight:600' }, binding.display)),
      binding.mayBeAltGr
        ? h('div', { class: 'metric-note', style: 'margin-top:6px' },
          'On a European layout this key is AltGr and types characters. Pick Right Control instead.')
        : null));
  }
  section.appendChild(grid);
  section.appendChild(card(
    h('div', {},
      'Hold ', keycap(current?.display ?? settings.holdKey), ' and speak. Let go and the words land '
      + 'where your cursor already is. Double-tap it to keep recording with your hands free; tap it '
      + 'once to stop.'),
    h('div', { class: 'metric-note', style: 'margin-top:8px' },
      'Only a bare modifier can be the dictation key. A modifier is the one trigger that never '
      + 'collides with ordinary typing, and it is the one thing a normal global shortcut cannot '
      + 'express — which is why Quill watches the keyboard directly.')));
  return section;
}

function dictating(settings: SettingsValues, redraw: () => Promise<void>): HTMLElement {
  return h('section', {},
    h('h2', { class: 'section-title' }, 'While you dictate'),
    card(
      toggleRow(
        'Show the text as you speak',
        api.platform === 'darwin'
          ? 'Types the words into the focused app as they are recognised, instead of pasting the '
            + 'finished sentence when you let go.'
          : 'Types the words in as they are recognised. On this platform each update is a '
            + 'clipboard paste, so your clipboard is borrowed for the length of the dictation and '
            + 'put back afterwards — turn this off if you would rather it were not touched.',
        settings.liveText,
        (next) => { void api.settings.set({ liveText: next }); },
      ),
      toggleRow(
        'Let the undo chord take back the last thing Quill typed',
        `Press ${settings.undoChordAccelerator.replace(/\+/g, ' + ')} and Quill deletes exactly what `
        + 'it inserted — after checking it is still there.',
        settings.undoChord,
        async (next) => { await api.settings.set({ undoChord: next }); await redraw(); },
      )));
}

function microphone(
  settings: SettingsValues,
  devices: { id: string; label: string }[],
  redraw: () => Promise<void>,
): HTMLElement {
  const section = h('section', {}, h('h2', { class: 'section-title' }, 'Microphone'));
  const select = document.createElement('select');
  select.className = 'field';
  const options = [{ id: '', label: 'Follow the system default' }, ...devices];
  for (const device of options) {
    const item = document.createElement('option');
    item.value = device.id;
    item.textContent = device.label;
    if ((settings.inputDeviceId ?? '') === device.id) item.selected = true;
    select.appendChild(item);
  }
  select.addEventListener('change', async () => {
    const chosen = options.find((device) => device.id === select.value);
    await api.settings.set({
      inputDeviceId: select.value.length > 0 ? select.value : null,
      inputDeviceLabel: select.value.length > 0 ? (chosen?.label ?? null) : null,
    });
    toast('Microphone set.');
    await redraw();
  });

  section.appendChild(card(
    select,
    h('div', { class: 'metric-note', style: 'margin-top:8px' },
      devices.length === 0
        ? 'Device names appear once Quill has been allowed to use the microphone. Try a dictation first.'
        : 'If the chosen device is unplugged, Quill falls back to the system default and says so '
          + 'in the history rather than recording silence.')));
  return section;
}

function speechModel(
  settings: SettingsValues,
  speech: SpeechStatus,
  redraw: () => Promise<void>,
): HTMLElement {
  const select = document.createElement('select');
  select.className = 'field';
  for (const model of MODELS) {
    const item = document.createElement('option');
    item.value = model.value;
    item.textContent = model.label;
    if (settings.speechModel === model.value) item.selected = true;
    select.appendChild(item);
  }
  select.addEventListener('change', async () => {
    await api.settings.set({ speechModel: select.value });
    toast('Model changed. It downloads the first time you dictate.');
    await redraw();
  });

  const status = speech.ready
    ? h('span', { class: 'chip good' },
      speech.device === 'webgpu' ? 'ready · GPU' : 'ready · CPU')
    : speech.downloading
      ? h('span', { class: 'chip accent' },
        `downloading ${Math.round(speech.downloading.progress)}%`)
      : h('span', { class: 'chip' }, 'not loaded yet');

  return h('section', {},
    h('h2', { class: 'section-title' }, 'Speech model'),
    card(
      h('div', { style: 'display:flex;gap:10px;align-items:center;margin-bottom:10px' },
        status,
        speech.fellBackToCPU
          ? h('span', { class: 'muted tiny' },
            'You asked for the GPU and this machine could not provide it, so it is running on the CPU.')
          : null),
      select,
      h('div', { style: 'margin-top:12px' },
        toggleRow(
          'Use the GPU when there is one',
          'WebGPU is several times faster. It is missing on a lot of Linux setups and older Windows '
          + 'drivers, and Quill falls back to the CPU on its own when it is.',
          settings.speechUseGPU,
          async (next) => { await api.settings.set({ speechUseGPU: next }); await redraw(); },
        )),
      h('div', { class: 'metric-note', style: 'margin-top:8px' },
        'The model is downloaded once and then runs entirely on this machine. Nothing you say is '
        + 'sent anywhere, with or without a network.'),
      speech.lastError
        ? h('div', { class: 'metric-note', style: 'margin-top:8px;color:var(--danger)' }, speech.lastError)
        : null,
      h('div', { style: 'margin-top:12px' },
        h('button', {
          class: 'button secondary small',
          onClick: async () => { await api.speech.prepare(); toast('Loading the model…'); await redraw(); },
        }, 'Load it now'))));
}

function writing(settings: SettingsValues, redraw: () => Promise<void>): HTMLElement {
  return h('section', {},
    h('h2', { class: 'section-title' }, 'How it writes'),
    card(
      h('div', { class: 'eyebrow' }, 'Spoken numbers'),
      segmented([
        { value: 'asHeard' as const, label: 'Leave as heard' },
        { value: 'spellOutSmall' as const, label: 'Spell out small' },
        { value: 'alwaysDigits' as const, label: 'Always digits' },
        { value: 'alwaysWords' as const, label: 'Always words' },
      ], settings.numberStyle, async (value) => {
        await api.settings.set({ numberStyle: value });
        await redraw();
      }),
      h('div', { class: 'metric-note', style: 'margin-top:8px' },
        numberDetail(settings.numberStyle)),
      h('div', { class: 'metric-note' },
        'Never applied in a terminal, a search box or a code editor. “git log -3” becoming '
        + '“git log -three” is a broken command, not a style.')),
    card(toggleRow(
      'Let the model fix a word that sounds right but means the wrong thing',
      'Quill sends the finished sentence and accepts the answer only where the replacement is '
      + 'pronounced identically to what was heard — “flour” for “flower”, “moved” for “move”. '
      + 'Anything else is thrown away. Needs an API key; costs nothing when there is none.',
      settings.contextRecovery,
      (next) => { void api.settings.set({ contextRecovery: next }); },
    )));
}

function numberDetail(style: SettingsValues['numberStyle']): string {
  switch (style) {
    case 'asHeard': return 'Whatever the recogniser wrote.';
    case 'spellOutSmall': return '“four men”, but “15 years old”. Dates, versions, times, money and ages keep their digits.';
    case 'alwaysDigits': return '“4 men”, “25 people”.';
    case 'alwaysWords': return '“four men”, “fifteen years old”.';
  }
}

function aiSection(
  key: { configured: boolean; fingerprint: string },
  redraw: () => Promise<void>,
): HTMLElement {
  const field = h('input', {
    class: 'field',
    type: 'password',
    placeholder: key.configured ? `Key set — ${key.fingerprint}` : 'nvapi-…',
    spellcheck: false,
  });

  return h('section', {},
    h('h2', { class: 'section-title' }, 'The optional AI pass'),
    card(
      h('p', { class: 'metric-note', style: 'margin-top:0' },
        'Everything above works with no key, no account and no network. A key adds one thing: a '
        + 'model pass that applies corrections you made out loud — say “send it to Noah, no wait, '
        + 'send it to Carlo” and only Carlo is typed. If the network is slow or gone, the '
        + 'deterministic result ships instead and you lose nothing.'),
      h('div', { style: 'display:flex;gap:8px;align-items:center;margin-top:12px' },
        h('div', { style: 'flex:1 1 auto' }, field),
        h('button', {
          class: 'button primary',
          onClick: async () => {
            await api.ai.setKey(field.value.trim());
            toast(field.value.trim().length === 0 ? 'Key removed.' : 'Key saved.');
            await redraw();
          },
        }, key.configured ? 'Replace' : 'Save')),
      h('div', { style: 'display:flex;gap:8px;margin-top:12px;align-items:center' },
        h('button', {
          class: 'button secondary small',
          onClick: async () => {
            toast('Checking…');
            const status = await api.ai.status();
            toast(statusLine(status));
          },
        }, 'Check it works'),
        key.configured
          ? h('button', {
            class: 'button ghost small',
            onClick: async () => { await api.ai.setKey(''); toast('Key removed.'); await redraw(); },
          }, 'Remove')
          : null,
        h('button', {
          class: 'button ghost small',
          onClick: () => { void api.app.openExternal('https://build.nvidia.com/'); },
        }, 'Get a free key'))));
}

function statusLine(status: { kind: string; model?: string; latencyMs?: number; why?: string; detail?: string }): string {
  switch (status.kind) {
    case 'ready': return `AI ready — ${status.model}, ${status.latencyMs}ms`;
    case 'notConfigured': return 'No key is configured.';
    case 'offline': return `No network — ${status.why}`;
    case 'badKey': return 'The key is present but not valid.';
    case 'modelUnavailable': return `That model is not served to this account. ${status.detail ?? ''}`;
    default: return status.detail ?? 'The service is busy or rate-limiting.';
  }
}

function filesSection(settings: SettingsValues, redraw: () => Promise<void>): HTMLElement {
  const section = h('section', {}, h('h2', { class: 'section-title' }, 'Your data'));

  section.appendChild(card(
    h('div', { class: 'eyebrow' }, 'Keep dictations for'),
    segmented([
      { value: 'day' as const, label: 'A day' },
      { value: 'week' as const, label: 'A week' },
      { value: 'month' as const, label: 'A month' },
      { value: 'forever' as const, label: 'Forever' },
    ], settings.historyRetention, async (value) => {
      await api.settings.set({ historyRetention: value });
      toast('Retention changed. Anything already past it goes within the hour.');
      await redraw();
    }),
    h('div', { class: 'metric-note', style: 'margin-top:8px' },
      retentionDetail(settings.historyRetention)),
    h('div', { class: 'metric-note' },
      'A dictation history is a transcript of everything you have said at your desk. One that '
      + 'grows forever by default is a liability nobody chose, which is why the default is a month.')));

  section.appendChild(card(
    h('div', { class: 'eyebrow' }, 'Startup'),
    toggleRow('Start Quill when this machine starts', 'It sits in the tray until you hold the key.',
      settings.launchAtLogin, (next) => { void api.settings.set({ launchAtLogin: next }); }),
    toggleRow('Open this window on launch', 'Off, Quill starts in the tray with no window.',
      settings.showDashboardOnLaunch, (next) => { void api.settings.set({ showDashboardOnLaunch: next }); })));

  const actions = h('div', { style: 'display:flex;gap:8px;margin-top:16px' },
    h('button', { class: 'button secondary', onClick: () => { void api.app.openDataDirectory(); } },
      'Open the folder'),
    h('button', {
      class: 'button danger',
      onClick: async () => {
        const files = await api.app.dataSummary();
        confirmSheet({
          title: 'Erase everything?',
          body: h('div', {},
            h('p', {},
              'This deletes every file Quill has written and puts the app back to how it was the '
              + 'day you installed it. It cannot be undone, and Quill restarts afterwards.'),
            files.length === 0
              ? h('p', { class: 'muted' }, 'There is nothing to delete.')
              : h('div', { class: 'rows' }, ...files.map((file) => h('div', { class: 'row' },
                h('span', { class: 'grow mono tiny' }, file.name),
                h('span', { class: 'muted tiny' }, formatBytes(file.bytes)))))),
          confirm: 'Erase everything',
          run: async () => { await api.app.eraseEverything(); },
        });
      },
    }, 'Erase everything'));
  section.appendChild(actions);
  return section;
}

function retentionDetail(value: SettingsValues['historyRetention']): string {
  switch (value) {
    case 'day': return 'Anything dictated more than a day ago is deleted.';
    case 'week': return 'Anything dictated more than a week ago is deleted.';
    case 'month': return 'Anything dictated more than a month ago is deleted.';
    case 'forever': return 'Nothing is ever deleted. Insights keeps every number.';
  }
}
