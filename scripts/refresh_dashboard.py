#!/usr/bin/env python3
"""Pull the ops Google Sheets and regenerate the data arrays (and snapshot
date) inside index.html:

- SEC1/SEC2/SEC3: the 'Daily Shift Metrics' tab of the shift staffing sheet.
- OUTREACH_QUEUE: the 'Notes' tab of the BF5 Outreach sheet (near-term
  pro-level outreach queue, enriched with agent notes).
- OUTREACH_AGENTS: aggregated all-time notes-logged-per-agent, from the
  'Coefficient_Raw' tab of the same sheet.
"""

import csv
import io
import json
import re
import urllib.request
from collections import Counter
from datetime import datetime, timezone

SHIFT_SHEET_ID = "1Ry1cozuvFYRYPv8dg449WaC2mDykAtScb1R1JLmGbjM"
SHIFT_GID = "2006814828"

OUTREACH_SHEET_ID = "1pgA0imF5zQHd7iQ6K8GOUZK2eU4Q6KEhSQJkFpIz9C0"
NOTES_GID = "11145450"
COEFFICIENT_GID = "738247926"

HEADERS = {
    "SEC1": ("Business Name", "Date", "Skill", "Requested", "Confirmed", "Unfilled",
              "Status", "Auto Select", "Gig Type", "Account Manager", "Ops Manager"),
    "SEC2": ("Business Name", "Date", "Skill", "Requested Pros", "Confirmed Pros",
              "Unfilled Pros", "Account Manager", "Ops Manager"),
    "SEC3": ("Date", "Business Name", "Unfilled", "Filled", "Unapproved",
              "Auto Select", "Private Offer"),
}


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


def parse_outreach_queue(rows):
    # Deliberately excludes pro_phone_number: this data feeds a public dashboard,
    # and phone numbers shouldn't be published even though the sheet has them.
    header = rows[0]
    idx = {name: i for i, name in enumerate(header)}
    queue = []
    for r in rows[1:]:
        if not r or not r[0]:
            continue
        queue.append([
            r[idx["pro_name"]],
            r[idx["location_name"]],
            r[idx["market"]],
            r[idx["skillset"]],
            r[idx["hours_to_start_time"]],
            r[idx["actual_start_time"]],
            r[idx["verified_status"]],
            r[idx["notes"]].strip(),
            r[idx["agent_name"]].strip(),
            r[idx["shift_url"]],
        ])
    return queue


def parse_outreach_agents(rows):
    data = [r for r in rows[1:] if r and r[0]]
    counts = Counter(r[2].strip() for r in data if len(r) > 2 and r[2].strip())
    return sorted(counts.items(), key=lambda kv: -kv[1])


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

    notes_rows = fetch_rows(OUTREACH_SHEET_ID, NOTES_GID)
    outreach_queue = parse_outreach_queue(notes_rows)
    validate("OUTREACH_QUEUE", outreach_queue)

    coefficient_rows = fetch_rows(OUTREACH_SHEET_ID, COEFFICIENT_GID)
    outreach_agents = parse_outreach_agents(coefficient_rows)
    validate("OUTREACH_AGENTS", outreach_agents)

    index_path = "index.html"
    with open(index_path, "r", encoding="utf-8") as f:
        html = f.read()

    arrays = {
        "SEC1": sections["SEC1"],
        "SEC2": sections["SEC2"],
        "SEC3": sections["SEC3"],
        "OUTREACH_QUEUE": outreach_queue,
        "OUTREACH_AGENTS": outreach_agents,
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
          f"OUTREACH_QUEUE={len(outreach_queue)} rows, "
          f"OUTREACH_AGENTS={len(outreach_agents)} agents, "
          f"snapshot={snapshot}")


if __name__ == "__main__":
    main()
