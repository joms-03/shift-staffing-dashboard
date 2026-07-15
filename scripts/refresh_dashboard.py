#!/usr/bin/env python3
"""Pull the 'Daily Shift Metrics' tab from the ops Google Sheet and regenerate
the SEC1/SEC2/SEC3 data arrays (and snapshot date) inside index.html."""

import csv
import io
import json
import re
import sys
import urllib.request
from datetime import datetime, timezone

SHEET_ID = "1Ry1cozuvFYRYPv8dg449WaC2mDykAtScb1R1JLmGbjM"
GID = "2006814828"
CSV_URL = f"https://docs.google.com/spreadsheets/d/{SHEET_ID}/export?format=csv&gid={GID}"

HEADERS = {
    "SEC1": ("Business Name", "Date", "Skill", "Requested", "Confirmed", "Unfilled",
              "Status", "Auto Select", "Gig Type", "Account Manager", "Ops Manager"),
    "SEC2": ("Business Name", "Date", "Skill", "Requested Pros", "Confirmed Pros",
              "Unfilled Pros", "Account Manager", "Ops Manager"),
    "SEC3": ("Date", "Business Name", "Unfilled", "Filled", "Unapproved",
              "Auto Select", "Private Offer"),
}

def fetch_rows():
    req = urllib.request.Request(CSV_URL, headers={"User-Agent": "Mozilla/5.0"})
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


def validate(sections):
    empty = [k for k, v in sections.items() if not v]
    if empty:
        raise SystemExit(f"Refusing to update: sections came back empty: {empty}")


def to_js_array(rows):
    return json.dumps(rows, ensure_ascii=False)


def main():
    rows = fetch_rows()
    sections = parse_sections(rows)
    validate(sections)

    index_path = "index.html"
    with open(index_path, "r", encoding="utf-8") as f:
        html = f.read()

    for key in ("SEC1", "SEC2", "SEC3"):
        pattern = re.compile(rf"const {key} = \[.*?\];", re.DOTALL)
        replacement = f"const {key} = {to_js_array(sections[key])};"
        new_html, count = pattern.subn(replacement, html, count=1)
        if count != 1:
            raise SystemExit(f"Could not find {key} array literal in {index_path}")
        html = new_html

    snapshot = datetime.now(timezone.utc).strftime("%B %-d, %Y %H:%M UTC")
    html = re.sub(
        r'(<div class="snapshot-tag" id="snapshotTag">Snapshot &middot; )[^<]*(</div>)',
        rf"\1{snapshot}\2",
        html,
        count=1,
    )

    with open(index_path, "w", encoding="utf-8") as f:
        f.write(html)

    print(f"Updated {index_path}: SEC1={len(sections['SEC1'])} rows, "
          f"SEC2={len(sections['SEC2'])} rows, SEC3={len(sections['SEC3'])} rows, "
          f"snapshot={snapshot}")


if __name__ == "__main__":
    main()
