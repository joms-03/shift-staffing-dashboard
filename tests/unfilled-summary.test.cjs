const assert = require('node:assert/strict');
const { countDistinctUnfilled, parseLocalShiftDate } = require('../assets/unfilled-summary.js');

const now = new Date(2026, 7, 27, 12, 0, 0);
const shifts = [
  [101, '2026-08-27 12:00:00', 3, 2], // inclusive start
  [101, '2026-08-28 12:00:00', 3, 1], // duplicate shift ID
  [102, '2026-08-30 11:59:59', 1, 0], // immediately before cutoff
  [103, '2026-08-30 12:00:00', 2, 0], // exclusive cutoff
  [104, '2026-08-27 11:59:59', 2, 0], // past
  [105, '2026-08-29 09:00:00', 2, 2], // filled
  [106, 'not-a-date', 2, 0],
  [107, '2026-08-29 09:00:00', 2, null], // missing staffing data
];

assert.equal(parseLocalShiftDate('2026-08-27 7:05:00').getHours(), 7);
assert.equal(countDistinctUnfilled(shifts, now), 2);
assert.equal(countDistinctUnfilled([], now), 0);
assert.equal(countDistinctUnfilled(null, now), 0);

console.log('unfilled-summary tests passed');
