import { api, type WireStyleProfile } from '../bridge';
import { card, clear, empty, h, pageHead, relativeTime, toggleRow } from '../dom';
import { toast } from '../toast';
import { confirmSheet } from '../sheet';

/// How Quill writes when it writes for you.
///
/// Two halves, and the split is the honest one. The PRESET is a choice you make
/// in one click and it works immediately. The LEARNED half needs corrections,
/// corrections are rare, and a feature that depends on them alone is a feature
/// that ships broken and gets good later — which is the same as shipping
/// broken.
///
/// The screen reports what it has actually observed and says plainly when that
/// is nothing. It used to arrive pre-loaded with two traits at full vote weight
/// — the two things known about the author — so it told every other user that
/// Quill had "learned" two facts about them on the day they installed it.

const PRESETS = [
  { value: 'neutral', title: 'Neutral', summary: 'Clean it up and change nothing else.' },
  { value: 'casual', title: 'Casual', summary: 'How you’d write to someone you know. Contractions, no sales voice.' },
  { value: 'professional', title: 'Professional', summary: 'Client-ready. Complete sentences, still human.' },
  { value: 'technical', title: 'Technical', summary: 'Precise. Keeps identifiers, paths and version numbers exactly as spoken.' },
] as const;

export async function renderStyle(root: HTMLElement): Promise<void> {
  clear(root);
  root.appendChild(pageHead('Style', 'The voice Quill writes in, and what it has worked out from your corrections.'));

  const body = h('div', {});
  root.appendChild(body);

  const draw = async (): Promise<void> => {
    const { profile, summary } = await api.style.get();
    clear(body);

    body.appendChild(card(
      h('div', { class: 'eyebrow' }, 'Right now'),
      h('div', { class: 'metric-small' }, summary)));

    body.appendChild(h('h2', { class: 'section-title' }, 'Voice'));
    const grid = h('div', { class: 'grid cols-2' });
    for (const preset of PRESETS) {
      const chosen = profile.preset === preset.value;
      grid.appendChild(h('button', {
        class: 'card',
        style: `text-align:left;border-color:${chosen ? 'var(--accent)' : 'var(--hairline)'}`,
        onClick: async () => {
          await api.style.setPreset(preset.value);
          toast(`Voice set to ${preset.title}.`);
          await draw();
        },
      },
        h('div', { style: 'display:flex;align-items:center;gap:8px' },
          h('span', { class: chosen ? 'dot live' : 'dot' }),
          h('span', { style: 'font-weight:600' }, preset.title)),
        h('div', { class: 'metric-note', style: 'margin-top:6px' }, preset.summary)));
    }
    body.appendChild(grid);
    body.appendChild(h('p', { class: 'metric-note', style: 'margin-top:10px' },
      'Every one of these describes word choice, never a kind of document. Measured against the '
      + 'real model, a line that described a document — “write it as a clear message to a client” '
      + '— did not adjust the sentence, it replaced it, and the guard then refused the answer on '
      + 'every single dictation.'));

    body.appendChild(h('h2', { class: 'section-title' }, 'Learned'));
    body.appendChild(card(toggleRow(
      'Learn from my corrections',
      'When you edit a dictation and save it, Quill compares the two and adjusts one trait at most.',
      profile.isLearningEnabled,
      (next) => { void api.style.setLearning(next).then(() => toast(next ? 'Learning on.' : 'Learning off.')); },
    )));

    const traits = traitRows(profile);
    if (traits.length === 0) {
      body.appendChild(empty(
        'Nothing learned yet.',
        'A trait needs two consistent corrections before Quill will act on it.',
      ));
    } else {
      const rows = h('div', { class: 'rows' });
      for (const trait of traits) {
        rows.appendChild(h('div', { class: 'row' },
          h('div', { class: 'grow' },
            h('div', { class: 'primary' }, trait.label),
            h('div', { class: 'secondary' }, trait.detail)),
          h('span', { class: trait.settled ? 'chip good' : 'chip' },
            trait.settled ? 'in use' : 'not sure yet')));
      }
      body.appendChild(rows);
    }

    if (profile.phrasings.length > 0) {
      body.appendChild(h('h2', { class: 'section-title' }, 'Rewrites you keep making'));
      const rows = h('div', { class: 'rows' });
      for (const phrasing of profile.phrasings) {
        const applicable = phrasing.count >= 3
          && (phrasing.from.split(' ').length > 1 || phrasing.from.length >= 6);
        rows.appendChild(h('div', { class: 'row' },
          h('div', { class: 'grow truncate' },
            h('span', { class: 'muted' }, phrasing.from), ' → ', h('span', { class: 'primary' }, phrasing.to)),
          h('span', { class: applicable ? 'chip good' : 'chip' },
            applicable ? `applied · seen ${phrasing.count}×` : `seen ${phrasing.count}×, needs 3`),
          h('button', {
            class: 'button ghost small',
            onClick: async () => {
              await api.style.removePhrasing(`${phrasing.from}→${phrasing.to}`);
              toast('Rewrite forgotten.');
              await draw();
            },
          }, 'Forget')));
      }
      body.appendChild(rows);
    }

    body.appendChild(h('div', { style: 'margin-top:20px;display:flex;gap:8px;align-items:center' },
      h('button', {
        class: 'button danger',
        onClick: () => confirmSheet({
          title: 'Forget everything learned?',
          body: h('p', {},
            `Quill has learned from ${profile.correctionCount} `
            + `${profile.correctionCount === 1 ? 'correction' : 'corrections'}`
            + `${profile.lastLearned ? `, most recently ${relativeTime(profile.lastLearned)}` : ''}. `
            + 'The voice you picked above is kept; only the observations go.'),
          confirm: 'Forget it',
          run: async () => { await api.style.forget(); toast('Learned traits cleared.'); await draw(); },
        }),
      }, 'Forget what it has learned'),
      h('span', { class: 'muted tiny' },
        profile.correctionCount === 0
          ? 'Nothing learned yet.'
          : `From ${profile.correctionCount} ${profile.correctionCount === 1 ? 'correction' : 'corrections'}.`)));
  };

  await draw();
}

interface TraitRow { label: string; detail: string; settled: boolean }

function traitRows(profile: WireStyleProfile): TraitRow[] {
  const out: TraitRow[] = [];
  const add = (label: string, trait: WireStyleProfile['spelling'], describe: (key: string) => string): void => {
    const entries = Object.entries(trait.votes).filter(([, count]) => count > 0);
    if (entries.length === 0) return;
    entries.sort((a, b) => b[1] - a[1]);
    const [key, support] = entries[0]!;
    const total = entries.reduce((sum, [, count]) => sum + count, 0);
    const tie = entries.length > 1 && entries[1]![1] === support;
    const settled = !tie && support >= 2 && support / total >= 0.6;
    out.push({
      label,
      detail: `${describe(key)} · ${support} of ${total} observations`
        + (trait.lastObserved ? ` · last seen ${relativeTime(trait.lastObserved)}` : ''),
      settled,
    });
  };

  add('Spelling', profile.spelling, (key) => (key === 'british' ? 'British/Australian' : 'American'));
  add('Contractions', profile.contractions, (key) => (key === 'yes' ? 'uses them' : 'writes them out'));
  add('Register', profile.formality, (key) => key);
  add('Serial comma', profile.oxfordComma, (key) => (key === 'yes' ? 'uses one' : 'does not'));
  add('Exclamation marks', profile.exclamations, (key) => (key === 'yes' ? 'uses them' : 'avoids them'));

  if (profile.sentenceLength.count >= 3) {
    const average = profile.sentenceLength.total / profile.sentenceLength.count;
    out.push({
      label: 'Sentence length',
      detail: `about ${Math.round(average)} words · ${profile.sentenceLength.count} samples`,
      settled: true,
    });
  }
  return out;
}

export { card };
