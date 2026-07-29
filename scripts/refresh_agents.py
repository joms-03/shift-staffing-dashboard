#!/usr/bin/env python3
"""Pull the Pro Success/MOPS weekly schedule (public sheet) and cross-check
today's DTR clock-in status (private sheet, via service account) to show
who's currently on shift on the Qwick Magic Team Dashboard hub.

Sources:
- 'Magic Schedule' sheet — weekly EST shift hours per agent, PRO SUCCESS
  AGENTS and MOPS AGENTS sections. All times are EST; coverage is
  7am-10pm EST, Monday-Sunday.
- 'Qwick <> Magic DTR' sheet — actual daily clock-in/out per agent, one
  tab per week (named "MM/DD - MM/DD", Sunday-Saturday). Restricted
  (not link-shareable) — read via a service account, credentials at
  DTR_SERVICE_ACCOUNT_KEY_PATH.

Only agents who are (a) scheduled to work today per the roster and
(b) currently clocked in (In filled, Out blank) in today's DTR column
are shown — who's working and until when, nothing about who's off.
"""

import csv
import io
import json
import os
import re
import urllib.request
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from google.oauth2 import service_account
from googleapiclient.discovery import build

SCHEDULE_SHEET_ID = "1GXYJVVH_VVbrCox73yuxD1AKOCIbrEWg1MHObOjuJRA"
SCHEDULE_GID = "0"
DTR_SHEET_ID = "1JsTk5JDwPaKlFDqMZKaVfG9kDQuG27Soi_7bX1WNils"

# Nickname (schedule sheet) -> full name (DTR sheet). Small, stable roster —
# update by hand if someone joins/leaves or a name changes in either sheet.
NAME_MAP = {
    "Joms": "Jomarc Lamorena",
    "Audrey": "Jhan Audrey De Leon",
    "Mark": "Mark Joseph Camillo",
    "Angelo": "Angelo Bartolome",
    "Rhys": "Rhys Johansen Cruz",
    "Chand": "Chand Dionisio",
    "Cyrus": "Cyrus Jedwin Lescano",
    "Bryan": "Mark Bryan Caras",
    "Mavis": "Mavis De Jesus",
}

DAY_COLUMNS = ["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"]
EST = ZoneInfo("America/New_York")


def csv_url(sheet_id, gid):
    return f"https://docs.google.com/spreadsheets/d/{sheet_id}/export?format=csv&gid={gid}"


def fetch_csv_rows(sheet_id, gid):
    req = urllib.request.Request(csv_url(sheet_id, gid), headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        text = resp.read().decode("utf-8")
    return list(csv.reader(io.StringIO(text)))


def parse_shift_code(code):
    """'12-9' -> (12, 21) in 24h EST hours. 'OFF' / blank -> None.

    Coverage is always 7am-10pm EST, which makes every "N-M" code
    unambiguous: an end value is always PM (add 12, except 12 itself),
    and a start value of 1-6 is PM while 7-11 is AM (12 is noon).
    """
    code = (code or "").strip().upper()
    if not code or code == "OFF":
        return None
    m = re.match(r"^(\d{1,2})-(\d{1,2})$", code)
    if not m:
        return None
    start, end = int(m.group(1)), int(m.group(2))
    end_24 = 12 if end == 12 else end + 12
    if start == 12:
        start_24 = 12
    elif start <= 6:
        start_24 = start + 12
    else:
        start_24 = start
    return (start_24, end_24)


def parse_schedule_sheet(rows):
    """Returns {nickname: {weekday: (startHour, endHour) or None}}."""
    agents = {}
    header_idx = None
    for r in rows:
        if r and r[0].strip() == "Name":
            header_idx = True
            continue
        if header_idx is None or not r or not r[0].strip():
            continue
        raw_days = [r[1 + j] if 1 + j < len(r) else "" for j in range(7)]
        if not any(v.strip() for v in raw_days):
            continue  # section title row (e.g. "MOPS AGENTS"), not an agent
        name = r[0].strip()
        days = {DAY_COLUMNS[j]: parse_shift_code(v) for j, v in enumerate(raw_days)}
        agents[name] = days
    return agents


def fmt_hour_12(hour24):
    period = "AM" if hour24 < 12 else "PM"
    h12 = hour24 % 12
    if h12 == 0:
        h12 = 12
    return f"{h12}:00 {period}"


def get_dtr_service():
    key_path = os.environ["DTR_SERVICE_ACCOUNT_KEY_PATH"]
    creds = service_account.Credentials.from_service_account_file(
        key_path, scopes=["https://www.googleapis.com/auth/spreadsheets.readonly"]
    )
    return build("sheets", "v4", credentials=creds)


def week_tab_title(today_est):
    # Weeks run Sunday-Saturday, named "MM/DD - MM/DD" (zero-padded, matching
    # the current sheet's convention as of 2026-07).
    sunday = today_est - timedelta(days=(today_est.weekday() + 1) % 7)
    saturday = sunday + timedelta(days=6)
    return f"{sunday.month:02d}/{sunday.day:02d} - {saturday.month:02d}/{saturday.day:02d}"


def find_week_tab(service, today_est):
    meta = service.spreadsheets().get(spreadsheetId=DTR_SHEET_ID).execute()
    titles = [s["properties"]["title"] for s in meta["sheets"]]
    wanted = week_tab_title(today_est)
    if wanted in titles:
        return wanted
    # Fallback: parse "M/D - M/D" titles (padding varies across older tabs)
    # and find the one whose range actually contains today.
    for title in titles:
        m = re.match(r"^(\d{1,2})/(\d{1,2})\s*-\s*(\d{1,2})/(\d{1,2})$", title.strip())
        if not m:
            continue
        sm, sd, em, ed = map(int, m.groups())
        try:
            start = datetime(today_est.year, sm, sd).date()
            end = datetime(today_est.year, em, ed).date()
        except ValueError:
            continue
        if start <= today_est <= end:
            return title
    raise SystemExit(f"Could not find a DTR tab for the week of {today_est}")


def fetch_dtr_clockins(service, tab_title, today_est):
    result = service.spreadsheets().values().get(
        spreadsheetId=DTR_SHEET_ID,
        range=f"'{tab_title}'!A1:AZ40",
    ).execute()
    rows = result.get("values", [])

    date_row = next(
        (r for r in rows if any(re.match(r"^\d{1,2}/\d{1,2}/\d{2}$", c.strip()) for c in r if c)), None
    )
    if not date_row:
        raise SystemExit(f"Could not find date header row in DTR tab '{tab_title}'")

    today_str = f"{today_est.month}/{today_est.day}/{today_est.year % 100}"
    in_col = None
    for i, cell in enumerate(date_row):
        if cell.strip() == today_str:
            in_col = i  # 'In' column; 'Out' is the next column over.
            break
    if in_col is None:
        raise SystemExit(f"Could not find today's ({today_str}) column in DTR tab '{tab_title}'")

    name_col = 1
    clocked_in = set()
    for r in rows:
        if len(r) <= name_col or not r[name_col].strip():
            continue
        name = r[name_col].strip()
        in_val = r[in_col].strip() if in_col < len(r) else ""
        out_val = r[in_col + 1].strip() if in_col + 1 < len(r) else ""
        if in_val and not out_val:
            clocked_in.add(name)
    return clocked_in


def main():
    now_utc = datetime.now(timezone.utc)
    now_est = now_utc.astimezone(EST)
    today_est = now_est.date()
    weekday_name = DAY_COLUMNS[today_est.weekday()]

    schedule_rows = fetch_csv_rows(SCHEDULE_SHEET_ID, SCHEDULE_GID)
    agents = parse_schedule_sheet(schedule_rows)
    if not agents:
        raise SystemExit("Refusing to update: schedule sheet came back empty")

    service = get_dtr_service()
    tab_title = find_week_tab(service, today_est)
    clocked_in_names = fetch_dtr_clockins(service, tab_title, today_est)

    online = []
    for nickname, days in agents.items():
        today_shift = days.get(weekday_name)
        if not today_shift:
            continue
        full_name = NAME_MAP.get(nickname)
        if not full_name or full_name not in clocked_in_names:
            continue
        online.append({"name": nickname, "until": fmt_hour_12(today_shift[1])})

    online.sort(key=lambda a: a["name"])

    html_path = "qwick-dashboard.html"
    with open(html_path, "r", encoding="utf-8") as f:
        html = f.read()

    replacement = f"const AGENT_STATUS = {json.dumps(online, ensure_ascii=False)};"
    html, count = re.subn(r"const AGENT_STATUS = \[.*?\];", replacement, html, count=1, flags=re.DOTALL)
    if count != 1:
        raise SystemExit("Could not find AGENT_STATUS array literal in qwick-dashboard.html")

    snapshot_iso = now_utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    html = re.sub(
        r'<span class="agent-status-snapshot" id="agentSnapshot"[^>]*></span>',
        f'<span class="agent-status-snapshot" id="agentSnapshot" data-snapshot-utc="{snapshot_iso}"></span>',
        html,
        count=1,
    )

    with open(html_path, "w", encoding="utf-8") as f:
        f.write(html)

    print(f"Updated {html_path}: {len(online)} agent(s) online, tab='{tab_title}', weekday={weekday_name}")


if __name__ == "__main__":
    main()
