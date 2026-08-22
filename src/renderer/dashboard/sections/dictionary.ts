import { api } from '../bridge';
import { card, clear, empty, h, pageHead } from '../dom';
import { toast } from '../toast';

/// The words the recogniser has no reason to know.
///
/// The single highest-leverage screen in the app and the one nobody maintains,
/// which is why the suggestions half exists: it reads project and repository
/// names off this machine and offers them, because asking someone to sit down
/// and type out their own vocabulary is a task that never gets done.
///
/// Suggestions are proposed, never applied. A dictionary that adds words by
/// itself is one that starts rewriting your speech into terms you did not
/// choose.

export async function renderDictionary(root: HTMLElement): Promise<void> {
  clear(root);
  root.appendChild(pageHead(
    'Dictionary',
    'Names, tools and jargon a general speech model has never heard. Quill biases the recogniser '
    + 'toward these and repairs them afterwards when it still gets them wrong.',
  ));

  const body = h('div', {});
  root.appendChild(body);

  const draw = async (): Promise<void> => {
    const [terms, suggestions] = await Promise.all([
      api.vocabulary.list(),
      api.vocabulary.suggestions().catch(() => []),
    ]);
    clear(body);

    const input = h('input', {
      class: 'field',
      placeholder: 'Add a word or a name — “Craigieburn”, “nxt”, “Wispr Flow”',
      spellcheck: false,
      onKeyDown: (event) => {
        if (event.key !== 'Enter') return;
        void add(input.value);
      },
    });

    body.appendChild(card(
      h('div', { style: 'display:flex;gap:8px;align-items:center' },
        h('div', { class: 'grow', style: 'flex:1 1 auto' }, input),
        h('button', { class: 'button primary', onClick: () => void add(input.value) }, 'Add')),
      h('div', { class: 'metric-note', style: 'margin-top:8px' },
        'A word here is a bias, not a rule — it is what the recogniser is nudged toward, '
        + 'and what the repair pass is allowed to correct a mishearing into.')));

    body.appendChild(h('h2', { class: 'section-title' },
      `Your words`, h('span', { class: 'muted', style: 'font-weight:400' }, ` — ${terms.length}`)));

    if (terms.length === 0) {
      body.appendChild(empty('Nothing here yet.'));
    } else {
      const rows = h('div', { class: 'rows' });
      for (const term of terms) {
        rows.appendChild(h('div', { class: 'row' },
          h('div', { class: 'grow truncate primary' }, term),
          h('button', {
            class: 'button ghost small',
            onClick: () => void remove(term),
          }, 'Remove')));
      }
      body.appendChild(rows);
    }

    if (suggestions.length > 0) {
      body.appendChild(h('h2', { class: 'section-title' }, 'Found on this machine'));
      body.appendChild(h('p', { class: 'page-subtitle', style: 'margin-bottom:12px' },
        'Folder, package and repository names Quill noticed. It reads names only — never the '
        + 'contents of a file — and nothing here is added until you say so.'));
      const rows = h('div', { class: 'rows' });
      for (const suggestion of suggestions.slice(0, 40)) {
        rows.appendChild(h('div', { class: 'row' },
          h('div', { class: 'grow' },
            h('div', { class: 'primary' }, suggestion.term),
            h('div', { class: 'secondary' }, suggestion.source)),
          h('button', {
            class: 'button secondary small',
            onClick: () => void add(suggestion.term),
          }, 'Add')));
      }
      body.appendChild(rows);
    }

    async function add(term: string): Promise<void> {
      const trimmed = term.trim();
      if (trimmed.length === 0) return;
      const added = await api.vocabulary.add(trimmed);
      toast(added ? `Added “${trimmed}”.` : `“${trimmed}” is already in the Dictionary.`);
      if (added) await draw();
    }

    async function remove(term: string): Promise<void> {
      await api.vocabulary.remove(term);
      toast(`Removed “${term}”.`);
      await draw();
    }
  };

  await draw();
}
