#!/usr/bin/env python3
"""Pull the ops Google Sheets and regenerate the data arrays (and snapshot
date) inside index.html:

- SEC1/SEC2/SEC3: the 'Daily Shift Metrics' tab of the shift staffing sheet.
- REVIEW_ROWS: the 'BF5 Pros to Review' tab (ops-curated) — full pipeline,
  drives the Pro Outreach Queue.
- OUTREACH_ROWS: the 'BF5 7-Day Review' tab — comprehensive near-term
  per-pro roster (flagged and clean), drives Shift Health and the
  Business Fill & Bonus Needs rollup.
"""

import csv
import io
import json
import re
import urllib.request
from datetime import datetime, timezone

SHIFT_SHEET_ID = "1Ry1cozuvFYRYPv8dg449WaC2mDykAtScb1R1JLmGbjM"
SHIFT_GID = "2006814828"
REVIEW_GID = "1635271142"
SEVENDAY_GID = "1327008017"

HEADERS = {
    "SEC1": ("Business Name", "Date", "Skill", "Requested", "Confirmed", "Unfilled",
              "Status", "Auto Select", "Gig Type", "Account Manager", "Ops Manager"),
    "SEC2": ("Business Name", "Date", "Skill", "Requested Pros", "Confirmed Pros",
              "Unfilled Pros", "Account Manager", "Ops Manager"),
    "SEC3": ("Date", "Business Name", "Unfilled", "Filled", "Unapproved",
              "Auto Select", "Private Offer"),
}

# Maps our internal embedding order to the CURRENT per-pro sheet column names.
# (housekeeping_* names were renamed to skill-generic ones since BF5 spans
# many skills; percentage fields carry a literal "%" suffix.)
SOURCE_COLUMN_MAP = {
    "business_name": "business_name",
    "location_id": "location_id",
    "shift_id": "shift_id",
    "shift_date": "shift_date",
    "market": "market",
    "skill": "skill",
    "requested_pros": "requested_pros",
    "confirmed_pros": "confirmed_pros",
    "auto_select_status": "auto_select_status",
    "shift_type": "shift_type",
    "pro_id": "pro_id",
    "pro_name": "pro_name",
    "housekeeping_certified": "confirmed_skill_profile_badge_status",
    "prior_paid_housekeeping_shifts": "prior_paid_same_skill_shifts",
    "has_worked_housekeeping_before": "has_worked_same_skill_before",
    "prior_paid_housekeeping_shifts_same_business": "prior_paid_same_skill_shifts_same_business",
    "repeat_housekeeping_at_same_business": "repeat_same_skill_at_same_business",
    "has_relevant_housekeeping_experience": "has_relevant_same_skill_experience",
    "avg_rating": "avg_rating",
    "ratings_count": "ratings_count",
    "completion_rate_lifetime_pct": "completion_rate_lifetime_pct",
    "completion_rate_last_30_days_pct": "completion_rate_last_30_days_pct",
    "completed_shifts_lifetime": "completed_shifts_lifetime",
    "pro_cancellations_last_30_days": "pro_cancellations_last_30_days",
    "pro_cancel_rate_last_30_days_pct": "pro_cancel_rate_last_30_days_pct",
    "no_shows_last_30_days": "no_shows_last_30_days",
    "distance_from_pro_last_seen_to_business_miles": "distance_from_pro_last_seen_to_business_miles",
    "pro_last_seen_at": "pro_last_seen_at",
    "confirmation_timestamp": "confirmation_timestamp",
    "selection_source": "selection_source",
    "pro_phone_number": "pro_phone_number",
}
# Output order — must match OCOLS in index.html.
PRO_COLUMNS = [
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
    "pro_phone_number",
]
INT_COLS = {
    "location_id", "shift_id", "requested_pros", "confirmed_pros", "pro_id",
    "prior_paid_housekeeping_shifts", "prior_paid_housekeeping_shifts_same_business",
    "ratings_count", "completed_shifts_lifetime", "pro_cancellations_last_30_days",
    "no_shows_last_30_days",
}
PCT_COLS = {
    "completion_rate_lifetime_pct", "completion_rate_last_30_days_pct",
    "pro_cancel_rate_last_30_days_pct",
}
FLOAT_COLS = {"avg_rating", "distance_from_pro_last_seen_to_business_miles"} | PCT_COLS
DATE_COLS = {"shift_date", "pro_last_seen_at", "confirmation_timestamp"}

# Sheet mixes "2026-07-22 7:00:00" (ISO, unpadded hour) and
# "7/22/2026 5:30 PM" (US, 12-hour) across tabs — normalize both to one
# consistent "YYYY-MM-DD HH:MM:SS" format before embedding.
US_AMPM_RE = re.compile(r"^(\d{1,2})/(\d{1,2})/(\d{4})\s+(\d{1,2}):(\d{2})\s*(AM|PM)$", re.I)
ISO_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?$")


def csv_url(sheet_id, gid):
    return f"https://docs.google.com/spreadsheets/d/{sheet_id}/export?format=csv&gid={gid}"


def fetch_rows(sheet_id, gid):
    req = urllib.request.Request(csv_url(sheet_id, gid), headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        text = resp.read().decode("utf-8")
    return list(csv.reader(io.StringIO(text)))


def trim(row):
    while row and row[-1] == "":
        row.pop()
    return row


def parse_sections(rows):
    rows = [r[1:] for r in rows]  # drop leading blank column A
    sections = {"SEC1": [], "SEC2": [], "SEC3": []}
    current = None
    for r in rows:
        tr = trim(list(r))
        if not tr:
            current = None
            continue
        matched = next((k for k, h in HEADERS.items() if tuple(tr) == h), None)
        if matched:
            current = matched
            continue
        if current:
            sections[current].append(tr)
    return sections


def normalize_datetime(value):
    value = (value or "").strip()
    if not value:
        return None
    m = US_AMPM_RE.match(value)
    if m:
        mm, dd, yy, hh, mi, ampm = m.groups()
        hh = int(hh) % 12
        if ampm.upper() == "PM":
            hh += 12
        return f"{yy}-{int(mm):02d}-{int(dd):02d} {hh:02d}:{mi}:00"
    m = ISO_RE.match(value)
    if m:
        yy, mm, dd, hh, mi, ss = m.groups()
        hh = hh or "00"
        mi = mi or "00"
        ss = ss or "00"
        return f"{yy}-{mm}-{dd} {int(hh):02d}:{mi}:{ss}"
    return value  # unrecognized format — pass through rather than fail the refresh


def coerce(name, value):
    value = (value or "").strip()
    if name in PCT_COLS:
        value = value.rstrip("%").strip()
    if not value:
        return None
    if name in DATE_COLS:
        return normalize_datetime(value)
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


def parse_pro_rows(rows):
    header_idx = next(i for i, r in enumerate(rows) if r and r[0] == "business_name")
    header = rows[header_idx]
    idx = {name: i for i, name in enumerate(header)}
    records = [r for r in rows[header_idx + 1:] if r and r[0]]
    out = []
    for r in records:
        out.append([
            coerce(col, r[idx[SOURCE_COLUMN_MAP[col]]] if idx.get(SOURCE_COLUMN_MAP[col], -1) < len(r) else "")
            for col in PRO_COLUMNS
        ])
    return out


def validate(name, value):
    if not value:
        raise SystemExit(f"Refusing to update: {name} came back empty")


def to_js_array(rows):
    return json.dumps(rows, ensure_ascii=False)


def main():
    shift_rows = fetch_rows(SHIFT_SHEET_ID, SHIFT_GID)
    sections = parse_sections(shift_rows)
    for key in ("SEC1", "SEC2", "SEC3"):
        validate(key, sections[key])

    review_rows = parse_pro_rows(fetch_rows(SHIFT_SHEET_ID, REVIEW_GID))
    validate("REVIEW_ROWS", review_rows)

    sevenday_rows = parse_pro_rows(fetch_rows(SHIFT_SHEET_ID, SEVENDAY_GID))
    validate("OUTREACH_ROWS", sevenday_rows)

    index_path = "index.html"
    with open(index_path, "r", encoding="utf-8") as f:
        html = f.read()

    arrays = {
        "SEC1": sections["SEC1"],
        "SEC2": sections["SEC2"],
        "SEC3": sections["SEC3"],
        "REVIEW_ROWS": review_rows,
        "OUTREACH_ROWS": sevenday_rows,
    }
    for key, value in arrays.items():
        pattern = re.compile(rf"const {key} = \[.*?\];", re.DOTALL)
        replacement = f"const {key} = {to_js_array(value)};"
        new_html, count = pattern.subn(replacement, html, count=1)
        if count != 1:
            raise SystemExit(f"Could not find {key} array literal in {index_path}")
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

    with open(index_path, "w", encoding="utf-8") as f:
        f.write(html)

    print(f"Updated {index_path}: SEC1={len(sections['SEC1'])} rows, "
          f"SEC2={len(sections['SEC2'])} rows, SEC3={len(sections['SEC3'])} rows, "
          f"REVIEW_ROWS={len(review_rows)} rows, OUTREACH_ROWS={len(sevenday_rows)} rows, "
          f"snapshot={snapshot}")


if __name__ == "__main__":
    main()
