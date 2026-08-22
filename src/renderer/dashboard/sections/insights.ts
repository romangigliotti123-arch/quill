import { api, type InsightsMetrics, type InsightsRange } from '../bridge';
import { card, clear, empty, h, metric, pageHead, segmented } from '../dom';
import { InsightsFormat } from '../../../core/insights/insightsFormat';

/// Everything on this screen is computable from this machine's own history.
///
/// The rule the section exists to enforce: no number here may be an estimate, a
/// constant, or a percentile against a population we cannot see. Other
/// dictation apps lead with "Top 6%" — a ranking against users you are not
/// allowed to inspect, next to a words-per-minute figure it does not explain.
/// Anything here that needs an assumption (typing speed) states the assumption
/// on screen.

let range: InsightsRange = 'month';

export async function renderInsights(root: HTMLElement): Promise<void> {
  clear(root);
  root.appendChild(pageHead('Insights', 'Everything here is measured on this machine. Nothing is compared against anybody else.'));

  const body = h('div', {});
  root.appendChild(body);

  const draw = async (): Promise<void> => {
    const metrics = await api.history.insights(range);
    clear(body);
    body.appendChild(controls(draw));
    if (metrics.sessions === 0) {
      body.appendChild(empty(
        `Nothing dictated ${rangePhrase(range)}.`,
        'Hold your dictation key, say something, and let go. The numbers start here.',
      ));
      return;
    }
    body.appendChild(volume(metrics));
    body.appendChild(pace(metrics));
    body.appendChild(latency(metrics));
    body.appendChild(corrections(metrics));
    body.appendChild(consistency(metrics));
  };

  await draw();
}

function rangePhrase(value: InsightsRange): string {
  switch (value) {
    case 'week': return 'in the last 7 days';
    case 'month': return 'in the last 30 days';
    case 'all': return 'yet';
  }
}

function controls(redraw: () => Promise<void>): HTMLElement {
  return h('div', { style: 'margin-bottom:20px' },
    segmented<InsightsRange>([
      { value: 'week', label: '7 days' },
      { value: 'month', label: '30 days' },
      { value: 'all', label: 'All time' },
    ], range, (value) => { range = value; void redraw(); }));
}

function volume(m: InsightsMetrics): HTMLElement {
  const delta = m.wordsDelta === null
    ? 'no earlier period to compare with'
    : `${m.wordsDelta >= 0 ? '+' : '−'}${InsightsFormat.percent(m.wordsDelta)} ${comparison(m.range)}`;

  const section = h('section', {},
    h('h2', { class: 'section-title' }, 'Volume'),
    h('div', { class: 'grid cols-4' },
      metric(InsightsFormat.count(m.totalWords), null, `words ${rangeWord(m.range)}`, delta),
      metric(InsightsFormat.count(m.sessions), null, 'dictations'),
      metric(...durationMetric(m.savedSeconds), 'saved against typing',
        `assuming ${40} words a minute typed`),
      metric(...durationMetric(m.speakingSeconds), 'spent speaking')));

  const days = m.dailyWords;
  if (days.length > 1) {
    const peak = Math.max(1, ...days.map((day) => day.words));
    const spark = h('div', { class: 'spark' });
    for (const day of days) {
      spark.appendChild(h('i', {
        class: day.date === days[days.length - 1]!.date ? 'today' : '',
        style: `height:${Math.max(2, Math.round((day.words / peak) * 56))}px`,
        title: `${InsightsFormat.shortDate(day.date)} — ${day.words} words`,
      }));
    }
    section.appendChild(card(
      h('div', { class: 'eyebrow' }, 'Words per day'),
      spark,
      h('div', { class: 'metric-note' },
        `${InsightsFormat.shortDate(days[0]!.date)} — ${InsightsFormat.shortDate(days[days.length - 1]!.date)}`)));
  }
  return section;
}

/// "1h 52m" has no honest single unit, so the whole thing goes in the value and
/// the unit slot is only used when there genuinely is one.
function durationMetric(seconds: number): [string, string | null] {
  const parts = InsightsFormat.duration(seconds);
  if (parts.length > 2) return [parts.map((part) => part.text).join(''), null];
  return [
    parts.filter((part) => !part.isUnit).map((part) => part.text).join(' '),
    parts.filter((part) => part.isUnit).map((part) => part.text).join(''),
  ];
}

function rangeWord(value: InsightsRange): string {
  switch (value) {
    case 'week': return 'in 7 days';
    case 'month': return 'in 30 days';
    case 'all': return 'all time';
  }
}

function comparison(value: InsightsRange): string {
  switch (value) {
    case 'week': return 'vs the 7 days before';
    case 'month': return 'vs the 30 days before';
    case 'all': return 'vs the first half';
  }
}

function pace(m: InsightsMetrics): HTMLElement {
  if (m.medianWPM === 0) {
    return h('section', {},
      h('h2', { class: 'section-title' }, 'Pace'),
      card(h('div', { class: 'muted' },
        'Not enough dictations with recorded audio length yet. Pace needs the length of what you spoke, not just the words.')));
  }
  return h('section', {},
    h('h2', { class: 'section-title' }, 'Pace'),
    h('div', { class: 'grid cols-3' },
      metric(String(m.medianWPM), ' wpm', 'median speaking pace',
        `${m.wpmP10}–${m.wpmP90} across the middle of your dictations`),
      metric(String(Math.round(m.totalWords / Math.max(1, m.sessions))), null, 'words per dictation'),
      metric(InsightsFormat.percent(m.thoroughShare), null, 'used the AI cleanup pass',
        m.thoroughShare === 0 ? 'no key configured, or nothing needed it' : null)));
}

function latency(m: InsightsMetrics): HTMLElement {
  const section = h('section', {}, h('h2', { class: 'section-title' }, 'Latency'));
  if (!m.hasReleaseLatency) {
    section.appendChild(card(h('div', { class: 'muted' },
      'Key release to text on screen has not been measured yet. It is stamped on every dictation from now on.')));
    return section;
  }
  section.appendChild(h('div', { class: 'grid cols-3' },
    metric(InsightsFormat.seconds(m.releaseP50), ' s', 'key release to text on screen',
      'the wait you actually feel'),
    metric(InsightsFormat.seconds(m.releaseP90), ' s', 'nine times in ten, under'),
    metric(InsightsFormat.seconds(m.firstWordP50), ' s', 'key down to first word')));
  section.appendChild(card(
    h('div', { class: 'eyebrow' }, 'Where the time goes'),
    breakdown('Microphone opening', m.firstWordMs.length > 0 ? median(m.endToEndMs) : 0, m),
    h('div', { class: 'metric-note' },
      `${m.releaseMs.length} dictations measured. The slowest one in a hundred took `
      + `${InsightsFormat.seconds(m.releaseP99)} s.`)));
  return section;
}

function median(values: number[]): number {
  if (values.length === 0) return 0;
  return values[Math.floor(values.length / 2)] ?? 0;
}

function breakdown(_label: string, _value: number, m: InsightsMetrics): HTMLElement {
  const rows: [string, number][] = [
    ['Release → text', m.releaseP50],
    ['Key down → first word', m.firstWordP50],
    ['Whole interaction', m.endToEndP50],
  ];
  const peak = Math.max(1, ...rows.map(([, value]) => value));
  const wrap = h('div', { style: 'display:grid;gap:10px;margin-top:10px' });
  for (const [label, value] of rows) {
    wrap.appendChild(h('div', {},
      h('div', { style: 'display:flex;justify-content:space-between;font-size:11.5px;margin-bottom:4px' },
        h('span', { class: 'muted' }, label),
        h('span', { class: 'mono' }, `${InsightsFormat.seconds(value)} s`)),
      h('div', { class: 'bar-track' },
        h('div', { class: 'bar-fill', style: `width:${Math.round((value / peak) * 100)}%` }))));
  }
  return wrap;
}

function corrections(m: InsightsMetrics): HTMLElement {
  const section = h('section', {}, h('h2', { class: 'section-title' }, 'Corrections'));
  section.appendChild(h('div', { class: 'grid cols-3' },
    metric(InsightsFormat.count(m.totalFixes), null, 'words Quill repaired'),
    metric(InsightsFormat.count(m.dictionaryFixes), null, 'of those, from your Dictionary'),
    metric(InsightsFormat.count(m.wordsCorrected), null, 'punctuation, filler and case')));

  if (m.topFixes.length > 0) {
    const rows = h('div', { class: 'rows', style: 'margin-top:12px' });
    for (const fix of m.topFixes) {
      rows.appendChild(h('div', { class: 'row' },
        h('div', { class: 'grow truncate' },
          h('span', { class: 'muted' }, fix.heard),
          ' → ',
          h('span', { class: 'primary' }, fix.written)),
        fix.isDictionary ? h('span', { class: 'chip accent' }, 'dictionary') : null,
        h('span', { class: 'mono muted' }, `×${fix.count}`)));
    }
    section.appendChild(rows);
  }
  return section;
}

function consistency(m: InsightsMetrics): HTMLElement {
  const section = h('section', {}, h('h2', { class: 'section-title' }, 'Consistency'));
  section.appendChild(h('div', { class: 'grid cols-3' },
    metric(String(m.currentStreak), m.currentStreak === 1 ? ' day' : ' days', 'current streak'),
    metric(String(m.longestStreak), m.longestStreak === 1 ? ' day' : ' days', 'longest streak'),
    metric(`${m.activeDays}`, ` / ${m.observedDays}`, 'days you dictated on',
      m.firstRecord ? `since ${InsightsFormat.shortDate(m.firstRecord)}` : null)));

  const peak = Math.max(1, ...m.heat.map((day) => day.words));
  const grid = h('div', { class: 'heat' });
  for (const day of m.heat) {
    const level = day.words === 0 ? 0 : Math.min(4, Math.ceil((day.words / peak) * 4));
    grid.appendChild(h('i', {
      'data-level': String(level),
      title: `${InsightsFormat.shortDate(day.date)} — ${day.words} words`,
    }));
  }
  section.appendChild(card(
    h('div', { class: 'eyebrow' }, 'Every day since you installed Quill'),
    h('div', { class: 'heat-wrap' }, grid)));
  return section;
}
