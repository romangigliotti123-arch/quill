/// The sidebar's icons, drawn.
///
/// The first version used Unicode glyphs — ▤, ✂, ⚙ — and it was wrong for a
/// reason worth writing down rather than just fixing. A Unicode glyph is
/// whatever the machine's font stack decides it is: on macOS several of them
/// render as full-colour emoji, on Windows they come from Segoe UI Symbol at a
/// different optical weight, and on a Linux box without a symbol font half of
/// them are a box. Ten icons that each look like a different app is the exact
/// failure a shared design system exists to prevent, and it is worse on a
/// cross-platform build than it ever was on one.
///
/// So they are inline SVG: one stroke weight, one size, one visual language,
/// identical on all three platforms. `currentColor` throughout, so they inherit
/// the row's ink and change with selection and with the theme without a second
/// palette to keep in sync.

const STROKE = 'fill="none" stroke="currentColor" stroke-width="1.5" '
  + 'stroke-linecap="round" stroke-linejoin="round"';

const PATHS: Record<string, string> = {
  // A waveform. The same shape as the app icon and the tray icon, because those
  // three are one identity.
  insights: `<path ${STROKE} d="M2.5 9.5v3M6 6v10M9.5 3.5v15M13 6.5v9M16.5 9v4"/>`,
  // A microphone.
  dictation: `<path ${STROKE} d="M11 2.5a2.5 2.5 0 0 0-2.5 2.5v5a2.5 2.5 0 0 0 5 0V5A2.5 2.5 0 0 0 11 2.5Z"/>`
    + `<path ${STROKE} d="M5 9.5V10a6 6 0 0 0 12 0v-.5M11 16v3.5M8 19.5h6"/>`,
  // A book.
  dictionary: `<path ${STROKE} d="M3.5 4.5A1.5 1.5 0 0 1 5 3h5v15H5a1.5 1.5 0 0 0-1.5 1.5Z"/>`
    + `<path ${STROKE} d="M18.5 4.5A1.5 1.5 0 0 0 17 3h-5v15h5a1.5 1.5 0 0 1 1.5 1.5Z"/>`,
  // Scissors.
  snippets: `<circle ${STROKE} cx="5" cy="17" r="2.2"/><circle ${STROKE} cx="17" cy="17" r="2.2"/>`
    + `<path ${STROKE} d="M6.6 15.4 16 3M15.4 15.4 6 3"/>`,
  // A pen nib.
  style: `<path ${STROKE} d="M3.5 18.5 6 12l7-7a2.1 2.1 0 0 1 3 3l-7 7Z"/>`
    + `<path ${STROKE} d="M11.5 6.5 14.5 9.5"/>`,
  // A wand with a spark.
  transforms: `<path ${STROKE} d="M4 18 14.5 7.5"/><path ${STROKE} d="M13 6 16 9"/>`
    + `<path ${STROKE} d="M17 3v3M15.5 4.5h3M19 12v2M18 13h2"/>`,
  // A record button.
  notetaker: `<circle ${STROKE} cx="11" cy="11" r="8"/><circle cx="11" cy="11" r="3.4" fill="currentColor"/>`,
  // A page with a pencil.
  scratchpad: `<path ${STROKE} d="M16 11.5V18a1.5 1.5 0 0 1-1.5 1.5h-9A1.5 1.5 0 0 1 4 18V6a1.5 1.5 0 0 1 1.5-1.5H11"/>`
    + `<path ${STROKE} d="m13.5 3.5 3 3-6 6H7.5V9.5Z"/>`,
  // A gear, six teeth, drawn rather than a circle with bumps.
  settings: `<circle ${STROKE} cx="11" cy="11" r="3"/>`
    + `<path ${STROKE} d="M11 2.6v2.1M11 17.3v2.1M17.9 6.9l-1.8 1M5.9 13.1l-1.8 1M17.9 15.1l-1.8-1M5.9 8.9l-1.8-1"/>`,
  // A question mark in a circle.
  help: `<circle ${STROKE} cx="11" cy="11" r="8"/>`
    + `<path ${STROKE} d="M8.7 8.5a2.4 2.4 0 0 1 4.6.8c0 1.6-2.3 2-2.3 3.4"/>`
    + `<circle cx="11" cy="15.6" r="0.9" fill="currentColor"/>`,
};

export function icon(name: string): SVGElement {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 22 22');
  svg.setAttribute('width', '17');
  svg.setAttribute('height', '17');
  svg.setAttribute('aria-hidden', 'true');
  // Built from a table this file owns; nothing here is ever user text, and the
  // page's policy forbids inline script regardless.
  svg.innerHTML = PATHS[name] ?? '';
  return svg;
}

/// The mark: the same five-bar waveform as the app icon and the tray icon.
///
/// Drawn rather than shipped as an asset so it inherits the palette and stays
/// sharp at any scale — and so the three cannot drift apart, which is what
/// happens the first time somebody edits one PNG and not the others.
export function brandMark(): SVGElement {
  const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  svg.setAttribute('viewBox', '0 0 26 26');
  svg.setAttribute('width', '26');
  svg.setAttribute('height', '26');
  svg.setAttribute('aria-hidden', 'true');
  const heights = [0.30, 0.66, 0.94, 0.66, 0.30];
  const barWidth = 2.2;
  const pitch = 3.9;
  const startX = (26 - pitch * (heights.length - 1) - barWidth) / 2;
  svg.innerHTML = heights.map((factor, index) => {
    const height = Math.max(barWidth, 13 * factor * 1.15);
    const x = startX + index * pitch;
    const y = (26 - height) / 2;
    return `<rect x="${x.toFixed(2)}" y="${y.toFixed(2)}" width="${barWidth}" `
      + `height="${height.toFixed(2)}" rx="${barWidth / 2}" fill="currentColor"/>`;
  }).join('');
  return svg;
}
