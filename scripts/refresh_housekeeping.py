#!/usr/bin/env python3
"""Pull the Housekeeping pro-history sheet and regenerate the ROWS array
(and snapshot date) inside housekeeping-outreach.html.

Source: 'Housekeeping shift + pro history' sheet, one row per pro assigned
to (or in the pipeline for) a Housekeeping shift in the next 7 days.
Risk scoring, business rollups, and rendering all happen client-side in
the HTML so thresholds can be tuned without re-running this script.
"""

import csv
import io
import json
import re
import urllib.request
from datetime import datetime, timezone

SHEET_ID = "1rSf0TXQOv7uz4sjkgruL7ObDCJ1qaj1EFdSXCAgeBjo"
GID = "123456789"

# Positional column order embedded into ROWS. Keep in sync with the
# `COLS` index map documented at the top of the ROWS <script> in the HTML.
# pro_phone_number is deliberately excluded: this feeds a public dashboard.
COLUMNS = [
    "business_name", "location_id", "shift_id", "shift_date", "market", "skill",
    "requested_pros", "confirmed_pros", "auto_select_status", "shift_type",
    "pro_id", "pro_name",
    "housekeeping_certified", "prior_paid_housekeeping_shifts",
    "has_worked_housekeeping_before", "prior_paid_housekeeping_shifts_same_business",
    "repeat_housekeeping_at_same_business", "has_relevant_housekeeping_experience",
    "avg_rating", "ratings_count", "completion_rate_lifetime_pct",
    "completion_rate_last_30_days_pct", "completed_shifts_lifetime",
    "pro_cancellations_last_30_days", "pro_cancel_rate_last_30_days_pct",
    "no_shows_last_30_days", "distance_from_pro_last_seen_to_business_miles",
    "pro_last_seen_at", "confirmation_timestamp", "selection_source",
]

INT_COLS = {
    "location_id", "shift_id", "requested_pros", "confirmed_pros", "pro_id",
    "prior_paid_housekeeping_shifts", "prior_paid_housekeeping_shifts_same_business",
    "ratings_count", "completed_shifts_lifetime", "pro_cancellations_last_30_days",
    "no_shows_last_30_days",
}
FLOAT_COLS = {
    "avg_rating", "completion_rate_lifetime_pct", "completion_rate_last_30_days_pct",
    "pro_cancel_rate_last_30_days_pct", "distance_from_pro_last_seen_to_business_miles",
}


def csv_url(sheet_id, gid):
    return f"https://docs.google.com/spreadsheets/d/{sheet_id}/export?format=csv&gid={gid}"


def fetch_rows(sheet_id, gid):
    req = urllib.request.Request(csv_url(sheet_id, gid), headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        text = resp.read().decode("utf-8")
    return list(csv.DictReader(io.StringIO(text)))


def coerce(name, value):
    value = (value or "").strip()
    if not value:
        return None
    if name in INT_COLS:
        try:
            return int(float(value))
        except ValueError:
            return None
    if name in FLOAT_COLS:
        try:
            return float(value)
        except ValueError:
            return None
    return value


def main():
    records = fetch_rows(SHEET_ID, GID)
    if not records:
        raise SystemExit("Refusing to update: sheet came back empty")

    rows = [[coerce(col, r.get(col, "")) for col in COLUMNS] for r in records]

    html_path = "housekeeping-outreach.html"
    with open(html_path, "r", encoding="utf-8") as f:
        html = f.read()

    replacement = f"const ROWS = {json.dumps(rows, ensure_ascii=False)};"
    new_html, count = re.subn(r"const ROWS = \[.*?\];", replacement, html, count=1, flags=re.DOTALL)
    if count != 1:
        raise SystemExit(f"Could not find ROWS array literal in {html_path}")
    html = new_html

    snapshot_dt = datetime.now(timezone.utc)
    snapshot_iso = snapshot_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
    snapshot = snapshot_dt.strftime("%B %-d, %Y %H:%M UTC")
    html = re.sub(
        r'<div class="snapshot-tag" id="snapshotTag"[^>]*>[^<]*</div>',
        f'<div class="snapshot-tag" id="snapshotTag" data-snapshot-utc="{snapshot_iso}">Snapshot &middot; {snapshot}</div>',
        html,
        count=1,
    )

    with open(html_path, "w", encoding="utf-8") as f:
        f.write(html)

    shifts = len({r[COLUMNS.index("shift_id")] for r in rows})
    print(f"Updated {html_path}: {len(rows)} pro-shift rows across {shifts} shifts, snapshot={snapshot}")


if __name__ == "__main__":
    main()
