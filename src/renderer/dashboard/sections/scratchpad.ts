import { api, type WireNote } from '../bridge';
import { clear, empty, h, pageHead, relativeTime } from '../dom';
import { toast } from '../toast';

/// Somewhere for a thought to go that is not another app's text field.
///
/// The useful part is that a dictation has a destination even when nothing is
/// focused. The list gives a note its title from its first line rather than
/// asking for one — nobody should have to name a thought before they are
/// allowed to have it.

export async function renderScratchpad(root: HTMLElement): Promise<void> {
  clear(root);
  root.appendChild(pageHead('Scratchpad', 'Quick notes. Nothing here is sent anywhere.'));

  const list = h('div', { class: 'list-pane' });
  const detail = h('div', { class: 'detail-pane' });
  const layout = h('div', { class: 'split' }, h('div', {}, list), detail);

  root.appendChild(h('div', { style: 'display:flex;gap:8px;margin-bottom:16px' },
    h('button', {
      class: 'button primary',
      onClick: async () => {
        const created = await api.notes.upsert(blank());
        selected = created.id;
        await draw();
      },
    }, 'New note')));
  root.appendChild(layout);

  let selected: string | null = null;
  let saveTimer: number | null = null;

  const draw = async (): Promise<void> => {
    const notes = await api.notes.list();
    clear(list);
    clear(detail);

    if (notes.length === 0) {
      list.replaceWith(empty('No notes yet.'));
      return;
    }
    if (selected === null || !notes.some((note) => note.id === selected)) {
      selected = notes[0]!.id;
    }

    for (const note of notes) {
      list.appendChild(h('button', {
        class: 'row',
        'aria-selected': note.id === selected ? 'true' : 'false',
        onClick: () => { selected = note.id; void draw(); },
      },
        h('div', { class: 'grow' },
          h('div', { class: 'primary truncate' }, displayTitle(note)),
          h('div', { class: 'secondary' },
            `${wordCount(note.body)} ${wordCount(note.body) === 1 ? 'word' : 'words'} · ${relativeTime(note.modified)}`)),
        note.isPinned ? h('span', { class: 'chip accent' }, 'pinned') : null));
    }

    const note = notes.find((candidate) => candidate.id === selected);
    if (!note) return;

    const title = h('input', {
      class: 'field',
      value: note.title,
      placeholder: 'Title — optional, the first line is used when this is empty',
    });
    const bodyField = h('textarea', { class: 'field', rows: 18, spellcheck: true });
    bodyField.value = note.body;

    const queueSave = (): void => {
      if (saveTimer !== null) window.clearTimeout(saveTimer);
      // Debounced rather than saved per keystroke: the store writes the whole
      // file atomically, and doing that on every character would rewrite the
      // notes file a hundred times a sentence.
      saveTimer = window.setTimeout(() => {
        saveTimer = null;
        void api.notes.upsert({ ...note, title: title.value, body: bodyField.value });
      }, 500);
    };
    title.addEventListener('input', queueSave);
    bodyField.addEventListener('input', queueSave);

    detail.appendChild(h('div', { style: 'display:grid;gap:10px' },
      title,
      bodyField,
      h('div', { style: 'display:flex;gap:8px;align-items:center' },
        h('button', {
          class: 'button secondary small',
          onClick: async () => {
            await api.notes.upsert({ ...note, title: title.value, body: bodyField.value, isPinned: !note.isPinned });
            await draw();
          },
        }, note.isPinned ? 'Unpin' : 'Pin'),
        h('button', {
          class: 'button danger small',
          onClick: async () => {
            await api.notes.delete(note.id);
            selected = null;
            toast('Note deleted.');
            await draw();
          },
        }, 'Delete'),
        h('span', { class: 'muted tiny', style: 'margin-left:auto' },
          `Saved automatically · ${relativeTime(note.modified)}`))));
  };

  await draw();
}

function blank(): WireNote {
  const now = Date.now();
  return { id: crypto.randomUUID(), title: '', body: '', created: now, modified: now, isPinned: false };
}

function displayTitle(note: WireNote): string {
  if (note.title.length > 0) return note.title;
  const firstLine = (note.body.split('\n')[0] ?? '').trim();
  if (firstLine.length === 0) return 'Untitled';
  return firstLine.length > 60 ? `${firstLine.slice(0, 60)}…` : firstLine;
}

function wordCount(text: string): number {
  return text.split(/\s+/).filter((word) => word.length > 0).length;
}
