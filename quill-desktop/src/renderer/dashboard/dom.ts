/// The smallest thing that stops ten section files reinventing
/// `document.createElement`.
///
/// Deliberately not a framework. Every screen here is a list, a form or a set
/// of numbers, all of which are one render each — a virtual DOM would be a
/// dependency, a build step and a class of bug, bought to avoid writing
/// `element.textContent =`.

type Child = Node | string | number | null | undefined | false;

export interface Attributes {
  class?: string;
  id?: string;
  type?: string;
  value?: string;
  placeholder?: string;
  title?: string;
  href?: string;
  role?: string;
  disabled?: boolean;
  rows?: number;
  min?: string;
  max?: string;
  step?: string;
  spellcheck?: boolean;
  style?: string;
  html?: string;
  [key: `data-${string}`]: string | undefined;
  [key: `aria-${string}`]: string | undefined;
  onClick?: (event: MouseEvent) => void;
  onInput?: (event: Event) => void;
  onChange?: (event: Event) => void;
  onKeyDown?: (event: KeyboardEvent) => void;
  onBlur?: (event: FocusEvent) => void;
}

export function h<K extends keyof HTMLElementTagNameMap>(
  tag: K,
  attributes: Attributes = {},
  ...children: Child[]
): HTMLElementTagNameMap[K] {
  const element = document.createElement(tag);
  for (const [key, value] of Object.entries(attributes)) {
    if (value === undefined || value === null || value === false) continue;
    switch (key) {
      case 'class': element.className = String(value); break;
      case 'html':
        // Only ever called with markup this file built — never with anything
        // that came off disk or out of a model. The CSP forbids inline script
        // regardless, so the worst a slip could do is bad layout.
        element.innerHTML = String(value);
        break;
      case 'onClick': element.addEventListener('click', value as EventListener); break;
      case 'onInput': element.addEventListener('input', value as EventListener); break;
      case 'onChange': element.addEventListener('change', value as EventListener); break;
      case 'onKeyDown': element.addEventListener('keydown', value as EventListener); break;
      case 'onBlur': element.addEventListener('blur', value as EventListener); break;
      case 'style':
        // Through the CSSOM, not `setAttribute`.
        //
        // The page's policy is `style-src 'self'` with no `'unsafe-inline'`,
        // which blocks the parsing of a `style` ATTRIBUTE — silently, with the
        // element simply rendering as though the declaration were not there.
        // That is how every `display:flex` in this file was being dropped while
        // the markup showed it present in the DOM.
        //
        // A CSSOM write is not an inline style for CSP's purposes, so this
        // works with the strict policy intact. Weakening the policy to
        // `'unsafe-inline'` would have been the one-character fix and the wrong
        // one: nothing here needs it.
        element.style.cssText = String(value);
        break;
      case 'disabled': (element as HTMLButtonElement).disabled = value === true; break;
      case 'value': (element as HTMLInputElement).value = String(value); break;
      case 'spellcheck': element.spellcheck = value === true; break;
      default: element.setAttribute(key, String(value));
    }
  }
  append(element, children);
  return element;
}

export function append(parent: Node, children: Child[]): void {
  for (const child of children) {
    if (child === null || child === undefined || child === false) continue;
    parent.appendChild(typeof child === 'object' ? child : document.createTextNode(String(child)));
  }
}

export function clear(element: Element): void {
  while (element.firstChild) element.removeChild(element.firstChild);
}

export function fragment(...children: Child[]): DocumentFragment {
  const out = document.createDocumentFragment();
  append(out, children);
  return out;
}

// MARK: - Common pieces

export function pageHead(title: string, subtitle?: string): HTMLElement {
  return h('header', { class: 'page-head' },
    h('h1', { class: 'page-title' }, title),
    subtitle ? h('p', { class: 'page-subtitle' }, subtitle) : null);
}

export function card(...children: Child[]): HTMLElement {
  return h('div', { class: 'card' }, ...children);
}

export function metric(
  value: string,
  unit: string | null,
  label: string,
  note?: string | null,
): HTMLElement {
  return card(
    h('div', { class: 'metric' }, value, unit ? h('span', { class: 'unit' }, unit) : null),
    h('div', { class: 'metric-label' }, label),
    note ? h('div', { class: 'metric-note' }, note) : null);
}

export function switchControl(
  checked: boolean,
  onToggle: (next: boolean) => void,
  label: string,
): HTMLButtonElement {
  const button = h('button', {
    class: 'switch',
    role: 'switch',
    'aria-checked': checked ? 'true' : 'false',
    'aria-label': label,
    onClick: () => {
      const next = button.getAttribute('aria-checked') !== 'true';
      button.setAttribute('aria-checked', next ? 'true' : 'false');
      onToggle(next);
    },
  });
  return button;
}

export function toggleRow(
  title: string,
  detail: string,
  checked: boolean,
  onToggle: (next: boolean) => void,
): HTMLElement {
  return h('div', { class: 'toggle-row' },
    h('div', { class: 'grow' },
      h('div', { class: 'title' }, title),
      h('div', { class: 'detail' }, detail)),
    switchControl(checked, onToggle, title));
}

export function segmented<T extends string>(
  options: { value: T; label: string }[],
  current: T,
  onPick: (value: T) => void,
): HTMLElement {
  const wrap = h('div', { class: 'segmented', role: 'group' });
  for (const option of options) {
    wrap.appendChild(h('button', {
      'aria-pressed': option.value === current ? 'true' : 'false',
      onClick: () => onPick(option.value),
    }, option.label));
  }
  return wrap;
}

export function empty(message: string, detail?: string): HTMLElement {
  return h('div', { class: 'empty' },
    h('div', {}, message),
    detail ? h('div', { class: 'tiny', style: 'margin-top:6px' }, detail) : null);
}

export function message(options: {
  title: string;
  body: string;
  steps?: string[];
  action?: { label: string; onClick: () => void };
}): HTMLElement {
  return h('div', { class: 'message' },
    h('h3', {}, options.title),
    h('p', {}, options.body),
    options.steps && options.steps.length > 0
      ? h('ul', {}, ...options.steps.map((step) => h('li', {}, step)))
      : null,
    options.action
      ? h('button', { class: 'button secondary', onClick: options.action.onClick }, options.action.label)
      : null);
}

export function keycap(text: string): HTMLElement {
  return h('kbd', { class: 'keycap' }, text);
}

/// A relative time that stays readable at every distance. "3 min ago" is more
/// useful than a timestamp for something that happened during this sitting, and
/// a date is more useful than "37 days ago" for something that did not.
export function relativeTime(timestamp: number, now = Date.now()): string {
  const seconds = Math.round((now - timestamp) / 1000);
  if (seconds < 45) return 'just now';
  if (seconds < 90) return 'a minute ago';
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) return `${minutes} min ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 24) return `${hours} h ago`;
  const days = Math.round(hours / 24);
  if (days < 7) return `${days} d ago`;
  return new Date(timestamp).toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
}
