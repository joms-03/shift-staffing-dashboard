#!/usr/bin/env python3
"""Pull the VIP shift and qualification-risk outreach sheets and regenerate
the SHIFT_ROWS and OUTREACH_ROWS arrays (and snapshot date) inside
vip-outreach.html.

Sources:
- 'VIP' sheet (Redshift import) — one row per upcoming shift at a VIP
  business, with fill status and auto-select flag.
- 'VIP Outreach' sheet ('Coefficient_Raw' tab) — candidate rows for confirmed
  pros with a qualification signal missing. The dashboard applies the final
  outreach rule: both the profile match and prior paid position history must
  be missing.
- 'VIP Outreach' sheet ('Notes' tab) — outreach notes and assigned agent,
  joined back to the raw qualification-risk rows by row_key.
"""

import csv
import io
import json
import re
import urllib.request
from datetime import datetime, timedelta, timezone

SHIFT_SHEET_ID = "1b4Le5-0Uev8ji9ziCcvSh1MOERKWqeAwZyiPj8RtBkc"
SHIFT_GID = "849611260"
OUTREACH_SHEET_ID = "1k5oRyKF4RfMs9pvB7WVGLICKM6R-4MI10ZbTvk76PPw"
OUTREACH_GID = "1630000904"
OUTREACH_NOTES_GID = "930242576"

SHIFT_COLUMNS = [
    "shift_id", "start_datetime", "market", "location_name", "shift_type",
    "auto_select_enabled", "allowed_confirmed_pros", "current_confirmed_pros_count",
    "number_of_selected_pros", "shift_url",
]
OUTREACH_COLUMNS = [
    "row_key", "pro_name", "pro_phone_number", "outreach_status", "verified_status",
    "hours_to_start", "start_time", "location_name", "market", "skillset_type",
    "pro_id", "gig_id", "has_matching_profile_skill", "prior_paid_same_skill_shifts",
    "qualification_gap", "notes", "agent_name",
]

# Sheet mixes "MM/DD/YYYY H:MM AM/PM" (shift sheet), "M/D/YYYY H:MM:SS" 24-hour
# (outreach sheet), and bare Sheets serial-date numbers (seen when a cell's
# date format didn't survive the CSV export) — normalize all three to one
# "YYYY-MM-DD HH:MM:SS" format before embedding.
US_AMPM_RE = re.compile(r"^(\d{1,2})/(\d{1,2})/(\d{4})\s+(\d{1,2}):(\d{2})\s*(AM|PM)$", re.I)
US_24H_RE = re.compile(r"^(\d{1,2})/(\d{1,2})/(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})$")
SERIAL_RE = re.compile(r"^\d+(\.\d+)?$")
SHEETS_EPOCH = datetime(1899, 12, 30)


def csv_url(sheet_id, gid):
    return f"https://docs.google.com/spreadsheets/d/{sheet_id}/export?format=csv&gid={gid}"


def fetch_rows(sheet_id, gid):
    req = urllib.request.Request(csv_url(sheet_id, gid), headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        text = resp.read().decode("utf-8")
    return list(csv.reader(io.StringIO(text)))


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
    m = US_24H_RE.match(value)
    if m:
        mm, dd, yy, hh, mi, ss = m.groups()
        return f"{yy}-{int(mm):02d}-{int(dd):02d} {int(hh):02d}:{mi}:{ss}"
    if SERIAL_RE.match(value):
        serial = float(value)
        dt = SHEETS_EPOCH + timedelta(days=int(serial), seconds=round((serial % 1) * 86400))
        return dt.strftime("%Y-%m-%d %H:%M:%S")
    return value  # unrecognized format — pass through rather than fail the refresh


def to_int(value):
    value = (value or "").strip()
    if not value:
        return None
    try:
        return int(float(value))
    except ValueError:
        return None


def to_float(value):
    value = (value or "").strip()
    if not value:
        return None
    try:
        return float(value)
    except ValueError:
        return None


def to_onoff(value):
    value = (value or "").strip().upper()
    if value == "TRUE":
        return "On"
    if value == "FALSE":
        return "Off"
    return value or None


def clean(value):
    value = (value or "").strip()
    return value or None


def parse_shift_rows(raw_rows):
    header_idx = next(i for i, r in enumerate(raw_rows) if r and r[0].strip() == "id")
    records = [r for r in raw_rows[header_idx + 1:] if r and r[0].strip()]
    out = []
    for r in records:
        r = r + [""] * (len(SHIFT_COLUMNS) - len(r))
        out.append([
            to_int(r[0]),
            normalize_datetime(r[1]),
            clean(r[2]),
            clean(r[3]),
            clean(r[4]),
            to_onoff(r[5]),
            to_int(r[6]),
            to_int(r[7]),
            to_int(r[8]),
            clean(r[9]),
        ])
    return out


def parse_notes(raw_rows):
    header_idx = next(i for i, r in enumerate(raw_rows) if r and r[0].strip().lower() == "row_key")
    header = [h.strip().lower().replace(" ", "_") for h in raw_rows[header_idx]]
    idx = {name: i for i, name in enumerate(header) if name}

    def get(r, name):
        i = idx.get(name)
        return r[i] if i is not None and i < len(r) else ""

    notes = {}
    for r in raw_rows[header_idx + 1:]:
        row_key = clean(get(r, "row_key"))
        if row_key:
            notes[row_key] = {
                "notes": clean(get(r, "notes")),
                "agent_name": clean(get(r, "agent_name")),
            }
    return notes


def parse_outreach_rows(raw_rows, notes_by_key):
    header_idx = next(i for i, r in enumerate(raw_rows) if r and r[0].strip() == "row_key")
    header = [h.strip() for h in raw_rows[header_idx]]
    idx = {name: i for i, name in enumerate(header) if name}
    records = [r for r in raw_rows[header_idx + 1:] if r and r[0].strip()]

    def get(r, name):
        i = idx.get(name)
        return r[i] if i is not None and i < len(r) else ""

    out = []
    for r in records:
        row_key = clean(get(r, "row_key"))
        note = notes_by_key.get(row_key, {})
        out.append([
            row_key,
            clean(get(r, "pro_name")),
            clean(get(r, "pro_phone_number")),
            clean(get(r, "outreach_status")),
            clean(get(r, "verified_status")),
            to_float(get(r, "hours_to_start")),
            normalize_datetime(get(r, "start_time")),
            clean(get(r, "location_name")),
            clean(get(r, "market")),
            clean(get(r, "skillset_type")),
            to_int(get(r, "pro_id")),
            to_int(get(r, "gig_id")),
            clean(get(r, "has_matching_profile_skill")),
            to_int(get(r, "prior_paid_same_skill_shifts")),
            clean(get(r, "qualification_gap")),
            note.get("notes"),
            note.get("agent_name"),
        ])
    return out


def main():
    shift_rows = parse_shift_rows(fetch_rows(SHIFT_SHEET_ID, SHIFT_GID))
    if not shift_rows:
        raise SystemExit("Refusing to update: VIP shift sheet came back empty")

    notes_by_key = parse_notes(fetch_rows(OUTREACH_SHEET_ID, OUTREACH_NOTES_GID))
    outreach_rows = parse_outreach_rows(
        fetch_rows(OUTREACH_SHEET_ID, OUTREACH_GID),
        notes_by_key,
    )
    # An empty outreach result is valid: it means no confirmed VIP pros have
    # a qualification gap right now, and the dashboard should show zero
    # rather than preserving a stale queue from the prior refresh.

    html_path = "vip-outreach.html"
    with open(html_path, "r", encoding="utf-8") as f:
        html = f.read()

    for key, rows in (("SHIFT_ROWS", shift_rows), ("OUTREACH_ROWS", outreach_rows)):
        replacement = f"const {key} = {json.dumps(rows, ensure_ascii=False)};"
        html, count = re.subn(rf"const {key} = \[.*?\];", replacement, html, count=1, flags=re.DOTALL)
        if count != 1:
            raise SystemExit(f"Could not find {key} array literal in {html_path}")

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

    print(f"Updated {html_path}: SHIFT_ROWS={len(shift_rows)} rows, "
          f"OUTREACH_ROWS={len(outreach_rows)} rows, snapshot={snapshot}")


if __name__ == "__main__":
    main()
