// Formatting for the Insights screen.
//
// Split out from `insightsMetrics.ts` so the renderer can import it. That file
// reaches the vocabulary store, which reaches the filesystem, and a browser
// bundle that pulls in `node:fs` does not build — the split is load-bearing
// rather than tidiness.

// MARK: - Formatting

export const InsightsFormat = {
  count(value: number): string {
    return value.toLocaleString(undefined, { useGrouping: true });
  },

  /// "1h 52m" / "48m" / "2m". The unit is part of the number here rather than a
  /// caption, because "1h 52m" has no honest single unit.
  duration(seconds: number): { text: string; isUnit: boolean }[] {
    const total = Math.round(seconds);
    const hours = Math.floor(total / 3600);
    const minutes = Math.floor((total % 3600) / 60);
    if (hours > 0) {
      return [
        { text: String(hours), isUnit: false },
        { text: 'h ', isUnit: true },
        { text: String(minutes), isUnit: false },
        { text: 'm', isUnit: true },
      ];
    }
    if (minutes > 0) {
      return [{ text: String(minutes), isUnit: false }, { text: 'm', isUnit: true }];
    }
    return [{ text: String(total), isUnit: false }, { text: 's', isUnit: true }];
  },

  /// Milliseconds shown in seconds to two places. A latency screen that prints
  /// "382 ms" beside "0.71 s" is asking the reader to do the conversion.
  seconds(ms: number): string {
    return (ms / 1000).toFixed(2);
  },

  percent(fraction: number): string {
    return `${Math.round(Math.abs(fraction) * 100)}%`;
  },

  shortDate(date: number): string {
    return new Date(date).toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
  },

  monthLabel(date: number): string {
    return new Date(date).toLocaleDateString(undefined, { month: 'short' });
  },
};
