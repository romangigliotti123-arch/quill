import { api, type WireSnippet } from '../bridge';
import { card, clear, empty, h, pageHead, relativeTime, switchControl } from '../dom';
import { toast } from '../toast';
import { openSheet } from '../sheet';

/// A spoken phrase that stands in for a block of text.
///
/// The editor makes one thing plain that the storage layer already assumes:
/// matching is EXACT. A snippet is an edit that drops hundreds of characters
/// into a document someone is already typing in, so "close enough" is not a
/// mode it has. What the match does forgive is everything the recogniser adds
/// on its own — a capital at a sentence start, a comma nobody said.

export async function renderSnippets(root: HTMLElement): Promise<void> {
  clear(root);
  root.appendChild(pageHead(
    'Snippets',
    'Say a phrase, get a block of text. Matched word for word after case and punctuation are '
    + 'discarded — never fuzzily, because the worst case here is four hundred characters landing '
    + 'in the middle of a message to someone else.',
  ));

  const body = h('div', {});
  root.appendChild(body);

  const draw = async (): Promise<void> => {
    const snippets = await api.snippets.list();
    clear(body);

    body.appendChild(h('div', { style: 'display:flex;gap:8px;margin-bottom:16px' },
      h('button', {
        class: 'button primary',
        onClick: () => edit(blankSnippet()),
      }, 'New snippet'),
      h('div', { class: 'muted tiny', style: 'align-self:center' },
        snippets.length === 0
          ? ''
          : `${totalSaved(snippets).toLocaleString()} characters saved so far`)));

    if (snippets.length === 0) {
      body.appendChild(empty('No snippets yet.', 'A snippet is worth having the third time you retype the same thing.'));
      return;
    }

    const rows = h('div', { class: 'rows' });
    for (const snippet of snippets) {
      rows.appendChild(h('div', { class: 'row' },
        switchControl(snippet.isEnabled, (next) => {
          void api.snippets.upsert({ ...snippet, isEnabled: next });
          toast(next ? 'Snippet on.' : 'Snippet off.');
        }, `Enable ${snippet.phrase}`),
        h('div', { class: 'grow' },
          h('div', { class: 'primary' }, `“${snippet.phrase}”`),
          h('div', { class: 'secondary truncate' }, previewLine(snippet.replacement))),
        snippet.mode === 'alone' ? h('span', { class: 'chip' }, 'on its own') : null,
        h('span', { class: 'mono muted tiny' },
          snippet.useCount === 0 ? 'never used' : `×${snippet.useCount} · ${relativeTime(snippet.lastUsed ?? snippet.created)}`),
        h('button', { class: 'button ghost small', onClick: () => edit(snippet) }, 'Edit')));
    }
    body.appendChild(rows);
  };

  const edit = (snippet: WireSnippet): void => {
    const phrase = h('input', { class: 'field', value: snippet.phrase, spellcheck: false });
    const replacement = h('textarea', { class: 'field', rows: 6, spellcheck: false });
    replacement.value = snippet.replacement;
    let mode = snippet.mode;

    const modePicker = h('div', { class: 'segmented' });
    const rebuildMode = (): void => {
      clear(modePicker);
      for (const option of [
        { value: 'anywhere' as const, label: 'Anywhere in a sentence' },
        { value: 'alone' as const, label: 'Only on its own' },
      ]) {
        modePicker.appendChild(h('button', {
          'aria-pressed': mode === option.value ? 'true' : 'false',
          onClick: () => { mode = option.value; rebuildMode(); },
        }, option.label));
      }
    };
    rebuildMode();

    openSheet({
      title: snippet.phrase.length === 0 ? 'New snippet' : 'Edit snippet',
      body: h('div', {},
        h('label', { class: 'stack' }, h('span', {}, 'What you say'), phrase),
        h('label', { class: 'stack' }, h('span', {}, 'What gets typed'), replacement),
        h('label', { class: 'stack' }, h('span', {}, 'Where it may fire'), modePicker),
        h('p', { class: 'metric-note' },
          'Pick “only on its own” for a trigger made of ordinary words. “Standup” matched '
          + 'anywhere would fire inside “the standup is at nine” and eat the sentence.')),
      confirm: 'Save',
      destructive: snippet.phrase.length > 0
        ? { label: 'Delete', run: async () => { await api.snippets.remove(snippet.id); toast('Snippet deleted.'); await draw(); } }
        : undefined,
      run: async () => {
        const value = phrase.value.trim();
        if (value.length === 0 || replacement.value.length === 0) {
          toast('A snippet needs both a phrase and a replacement.');
          return false;
        }
        await api.snippets.upsert({ ...snippet, phrase: value, replacement: replacement.value, mode });
        toast('Snippet saved.');
        await draw();
        return true;
      },
    });
  };

  await draw();
}

function blankSnippet(): WireSnippet {
  return {
    id: crypto.randomUUID(),
    phrase: '',
    replacement: '',
    mode: 'anywhere',
    isEnabled: true,
    useCount: 0,
    lastUsed: null,
    created: Date.now(),
  };
}

function previewLine(replacement: string): string {
  return replacement.replace(/\s+/g, ' ').trim();
}

function totalSaved(snippets: WireSnippet[]): number {
  return snippets.reduce(
    (total, snippet) => total + snippet.useCount * Math.max(0, snippet.replacement.length - snippet.phrase.length),
    0,
  );
}

export { card };
