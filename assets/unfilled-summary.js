(function () {
  'use strict';

  const THREE_DAYS_MS = 72 * 60 * 60 * 1000;

  function parseLocalShiftDate(value) {
    const match = String(value || '').trim().match(
      /^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$/
    );
    if (!match) return new Date(NaN);
    return new Date(
      Number(match[1]),
      Number(match[2]) - 1,
      Number(match[3]),
      Number(match[4] || 0),
      Number(match[5] || 0),
      Number(match[6] || 0)
    );
  }

  function countDistinctUnfilled(shifts, now) {
    const windowStart = now instanceof Date ? now : new Date();
    const windowEnd = new Date(windowStart.getTime() + THREE_DAYS_MS);
    const unfilledIds = new Set();

    (Array.isArray(shifts) ? shifts : []).forEach(row => {
      if (
        !Array.isArray(row) ||
        row.length < 4 ||
        row[0] == null ||
        row[2] == null ||
        row[3] == null
      ) return;
      const shiftStart = parseLocalShiftDate(row[1]);
      const requested = Number(row[2]);
      const confirmed = Number(row[3]);
      if (
        !Number.isNaN(shiftStart.getTime()) &&
        Number.isFinite(requested) &&
        Number.isFinite(confirmed) &&
        shiftStart >= windowStart &&
        shiftStart < windowEnd &&
        confirmed < requested
      ) {
        unfilledIds.add(String(row[0]));
      }
    });

    return unfilledIds.size;
  }

  function renderCounter(counter, count) {
    const value = counter.querySelector('.unfilled-counter-value');
    value.textContent = String(count);
    counter.classList.toggle('attention', count > 0);
    counter.classList.remove('load-error');
  }

  async function updateCounter(counter) {
    try {
      const separator = counter.dataset.summarySrc.includes('?') ? '&' : '?';
      const response = await fetch(`${counter.dataset.summarySrc}${separator}v=${Date.now()}`, { cache: 'no-store' });
      if (!response.ok) throw new Error('summary unavailable');
      const payload = await response.json();
      renderCounter(counter, countDistinctUnfilled(payload.shifts));
    } catch (error) {
      counter.querySelector('.unfilled-counter-value').textContent = '—';
      counter.classList.remove('attention');
      counter.classList.add('load-error');
    }
  }

  function updateAllCounters() {
    if (typeof document === 'undefined') return Promise.resolve();
    return Promise.all(
      Array.from(document.querySelectorAll('.unfilled-counter[data-summary-src]'), updateCounter)
    );
  }

  const api = { countDistinctUnfilled, parseLocalShiftDate, updateAllCounters };
  if (typeof window !== 'undefined') window.QwickUnfilledSummary = api;
  if (typeof module !== 'undefined' && module.exports) module.exports = api;

  if (typeof document !== 'undefined') {
    updateAllCounters();
    window.setInterval(updateAllCounters, 5 * 60 * 1000);
    document.addEventListener('visibilitychange', () => {
      if (!document.hidden) updateAllCounters();
    });
  }
})();
