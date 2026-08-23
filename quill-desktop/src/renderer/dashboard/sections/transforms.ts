import { api, type WireTransform } from '../bridge';
import { card, clear, empty, h, keycap, pageHead, switchControl } from '../dom';
import { toast } from '../toast';
import { openSheet } from '../sheet';

/// Reshaping text that already exists.
///
/// Three ways in, in order of how much each is trusted: a hotkey (the user
/// pressed a key, unambiguous), the wake word ("Quill, make that shorter"), and
/// a bare spoken instruction. Only the third goes through the router's guards,
/// and the screen says so — because the guards are the reason a sentence you
/// dictated does not get eaten by a transform you did not ask for.

const RECIPES = [
  { value: 'none', label: 'Needs the network' },
  { value: 'bulletList', label: 'Split into bullets' },
  { value: 'numberedList', label: 'Split into a numbered list' },
  { value: 'expandContractions', label: 'Expand contractions' },
  { value: 'fastClean', label: 'Deterministic cleanup' },
  { value: 'sentenceCase', label: 'Sentence case' },
  { value: 'titleCase', label: 'Title Case' },
  { value: 'upperCase', label: 'UPPERCASE' },
  { value: 'lowerCase', label: 'lowercase' },
];

const TARGETS = [
  { value: 'automatic', label: 'Selection, or the last dictation' },
  { value: 'selection', label: 'The current selection' },
  { value: 'lastDictation', label: 'The last dictation' },
];

export async function renderTransforms(root: HTMLElement): Promise<void> {
  clear(root);
  root.appendChild(pageHead(
    'Transforms',
    'Reshape what you just said, or whatever is selected. Say the phrase, press the chord, '
    + 'or run it from here.',
  ));

  const body = h('div', {});
  root.appendChild(body);

  const draw = async (): Promise<void> => {
    const transforms = await api.transforms.list();
    clear(body);

    body.appendChild(h('div', { style: 'display:flex;gap:8px;margin-bottom:16px' },
      h('button', { class: 'button primary', onClick: () => edit(blank()) }, 'New transform')));

    if (transforms.length === 0) {
      body.appendChild(empty('No transforms.'));
      return;
    }

    const rows = h('div', { class: 'rows' });
    for (const transform of transforms) {
      rows.appendChild(h('div', { class: 'row' },
        switchControl(transform.isEnabled, (next) => {
          void api.transforms.upsert({ ...transform, isEnabled: next });
          toast(next ? `${transform.name} on.` : `${transform.name} off.`);
        }, `Enable ${transform.name}`),
        h('div', { class: 'grow' },
          h('div', { class: 'primary' }, transform.name),
          h('div', { class: 'secondary truncate' },
            transform.triggers.length > 0 ? `“${transform.triggers[0]}”` : 'no spoken trigger')),
        transform.offline === 'none'
          ? h('span', { class: 'chip warn' }, 'needs network')
          : h('span', { class: 'chip good' }, 'works offline'),
        transform.accelerator ? keycap(transform.accelerator.replace(/\+/g, ' + ')) : null,
        h('button', {
          class: 'button secondary small',
          onClick: async () => {
            const outcome = await api.transforms.run(transform.id);
            toast(outcome.kind === 'done' ? `${transform.name} ran.` : (outcome.reason ?? 'It did not run.'));
          },
        }, 'Run'),
        h('button', { class: 'button ghost small', onClick: () => edit(transform) }, 'Edit')));
    }
    body.appendChild(rows);

    body.appendChild(card(
      h('div', { class: 'eyebrow' }, 'How a spoken transform fires'),
      h('p', { class: 'metric-note' },
        'A whole utterance that matches a trigger word for word runs immediately. Anything else '
        + 'has to start with a command verb, refer to existing text, and carry no other content '
        + '— so “make that shorter” runs, and “make it the last one on the list” is typed.'),
      h('p', { class: 'metric-note' },
        'Say “Quill,” first to skip every guard: the wake word is you saying this is an '
        + 'instruction, and after it Quill will even run a request it has no transform for.')));
  };

  const edit = (transform: WireTransform): void => {
    const name = h('input', { class: 'field', value: transform.name, spellcheck: false });
    const instruction = h('textarea', { class: 'field', rows: 4, spellcheck: false });
    instruction.value = transform.instruction;
    const triggers = h('textarea', { class: 'field', rows: 3, spellcheck: false });
    triggers.value = transform.triggers.join('\n');
    const keywords = h('input', { class: 'field', value: transform.keywords.join(', '), spellcheck: false });
    const accelerator = h('input', {
      class: 'field',
      value: transform.accelerator ?? '',
      placeholder: api.platform === 'darwin' ? 'Command+Alt+B' : 'Control+Alt+B',
      spellcheck: false,
    });
    const recipe = select(RECIPES, transform.offline);
    const target = select(TARGETS, transform.target);

    openSheet({
      title: transform.name.length === 0 ? 'New transform' : `Edit “${transform.name}”`,
      body: h('div', {},
        h('label', { class: 'stack' }, h('span', {}, 'Name'), name),
        h('label', { class: 'stack' }, h('span', {}, 'Instruction to the model'), instruction),
        h('label', { class: 'stack' }, h('span', {}, 'Spoken triggers, one per line'), triggers),
        h('label', { class: 'stack' }, h('span', {}, 'Keywords, comma separated'), keywords),
        h('label', { class: 'stack' }, h('span', {}, 'What it acts on'), target),
        h('label', { class: 'stack' }, h('span', {}, 'What it does with no network'), recipe),
        h('label', { class: 'stack' }, h('span', {}, 'Keyboard chord'), accelerator),
        h('p', { class: 'metric-note' },
          'A chord must include a modifier. A transform bound to a bare letter swallows that '
          + 'letter everywhere on the machine, and there would be no way to work out why.'),
        h('p', { class: 'metric-note' },
          'Every trigger should contain a command verb AND a word pointing at existing text — '
          + '“make that shorter”, not “bullet points”. A trigger made of ordinary words is a '
          + 'sentence somebody will dictate, and firing on it costs them their words.')),
      confirm: 'Save',
      destructive: transform.name.length > 0
        ? {
          label: 'Delete',
          run: async () => { await api.transforms.remove(transform.id); toast('Transform deleted.'); await draw(); },
        }
        : undefined,
      run: async () => {
        if (name.value.trim().length === 0 || instruction.value.trim().length === 0) {
          toast('A transform needs a name and an instruction.');
          return false;
        }
        const chord = accelerator.value.trim();
        if (chord.length > 0 && !/\+/.test(chord)) {
          toast('A chord must include a modifier, like Control+Alt+B.');
          return false;
        }
        await api.transforms.upsert({
          ...transform,
          name: name.value.trim(),
          instruction: instruction.value.trim(),
          triggers: triggers.value.split('\n').map((line) => line.trim()).filter((line) => line.length > 0),
          keywords: keywords.value.split(',').map((word) => word.trim()).filter((word) => word.length > 0),
          accelerator: chord.length > 0 ? chord : null,
          target: target.value as WireTransform['target'],
          offline: recipe.value,
        });
        toast('Transform saved.');
        await draw();
        return true;
      },
    });
  };

  await draw();
}

function select(options: { value: string; label: string }[], current: string): HTMLSelectElement {
  const element = document.createElement('select');
  element.className = 'field';
  for (const option of options) {
    const item = document.createElement('option');
    item.value = option.value;
    item.textContent = option.label;
    if (option.value === current) item.selected = true;
    element.appendChild(item);
  }
  return element;
}

function blank(): WireTransform {
  return {
    id: crypto.randomUUID(),
    name: '',
    instruction: '',
    triggers: [],
    keywords: [],
    accelerator: null,
    target: 'automatic',
    offline: 'none',
    bounds: { minRatio: 0.6, maxRatio: 1.6, slack: 24 },
    preservesVocabulary: true,
    isEnabled: true,
    isBuiltIn: false,
    useCount: 0,
    lastUsed: null,
    created: Date.now(),
  };
}

export { card };
