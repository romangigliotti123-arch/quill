import { clear, h } from './dom';

/// One modal, reused by every editor.
///
/// Deliberately not a per-screen dialog. There are five things in this app that
/// need "edit this in a box and save it", and five hand-rolled overlays is how
/// two of them end up with a different Escape behaviour.

export interface SheetOptions {
  title: string;
  body: Node;
  confirm: string;
  cancel?: string;
  /// Returns false to keep the sheet open — used when validation fails, so the
  /// user does not lose what they typed.
  run: () => Promise<boolean> | boolean;
  destructive?: { label: string; run: () => Promise<void> | void };
}

let closeCurrent: (() => void) | null = null;

export function openSheet(options: SheetOptions): void {
  const modal = document.getElementById('modal');
  const sheet = document.getElementById('sheet');
  if (!modal || !sheet) return;

  closeCurrent?.();
  clear(sheet);

  const close = (): void => {
    modal.classList.remove('open');
    document.removeEventListener('keydown', onKey);
    modal.removeEventListener('mousedown', onBackdrop);
    closeCurrent = null;
  };
  const onKey = (event: KeyboardEvent): void => {
    if (event.key === 'Escape') close();
  };
  const onBackdrop = (event: MouseEvent): void => {
    if (event.target === modal) close();
  };
  closeCurrent = close;

  sheet.appendChild(h('h3', {}, options.title));
  sheet.appendChild(options.body as HTMLElement);
  sheet.appendChild(h('div', { class: 'sheet-actions' },
    options.destructive
      ? h('button', {
        class: 'button danger',
        style: 'margin-right:auto',
        onClick: () => { void Promise.resolve(options.destructive!.run()).then(close); },
      }, options.destructive.label)
      : null,
    h('button', { class: 'button ghost', onClick: close }, options.cancel ?? 'Cancel'),
    h('button', {
      class: 'button primary',
      onClick: () => {
        void Promise.resolve(options.run()).then((done) => { if (done !== false) close(); });
      },
    }, options.confirm)));

  modal.classList.add('open');
  document.addEventListener('keydown', onKey);
  modal.addEventListener('mousedown', onBackdrop);
  const focusable = sheet.querySelector('input, textarea, button') as HTMLElement | null;
  focusable?.focus();
}

/// A confirmation that names what it is about to do, rather than asking the
/// user to trust the word "everything".
export function confirmSheet(options: {
  title: string;
  body: Node;
  confirm: string;
  run: () => Promise<void> | void;
}): void {
  openSheet({
    title: options.title,
    body: options.body,
    confirm: options.confirm,
    run: async () => { await options.run(); return true; },
  });
}
