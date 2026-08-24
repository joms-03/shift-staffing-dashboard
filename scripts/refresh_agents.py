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
are shown. The DTR clock-in value is also compared with the scheduled
start so the dashboard can mark an online agent as late.
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
MANILA = ZoneInfo("Asia/Manila")

DAY_ALIASES = {
    "MON": 0,
    "MONDAY": 0,
    "TUE": 1,
    "TUES": 1,
    "TUESDAY": 1,
    "WED": 2,
    "WEDNESDAY": 2,
    "THU": 3,
    "THUR": 3,
    "THURS": 3,
    "THURSDAY": 3,
    "FRI": 4,
    "FRIDAY": 4,
    "SAT": 5,
    "SATURDAY": 5,
    "SUN": 6,
    "SUNDAY": 6,
}
DAY_TOKEN_PATTERN = re.compile(
    r"\b(" + "|".join(sorted(DAY_ALIASES, key=len, reverse=True)) + r")\b",
    flags=re.IGNORECASE,
)


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


def parse_clock_time(value):
    """Parse a DTR clock-in value into a time-of-day, or return None.

    DTR clock-ins are normally formatted as 24-hour times with optional
    seconds and fractional seconds, but accepting AM/PM keeps the refresh
    resilient to a display-format change in the source sheet.
    """
    text = str(value or "").strip()
    match = re.fullmatch(
        r"(\d{1,2}):(\d{2})(?::(\d{2})(?:\.(\d{1,6}))?)?\s*(AM|PM)?",
        text,
        flags=re.IGNORECASE,
    )
    if not match:
        return None

    hour, minute = int(match.group(1)), int(match.group(2))
    second = int(match.group(3) or 0)
    microsecond = int((match.group(4) or "").ljust(6, "0"))
    meridiem = (match.group(5) or "").upper()

    if minute > 59 or second > 59:
        return None
    if meridiem:
        if not 1 <= hour <= 12:
            return None
        hour = hour % 12 + (12 if meridiem == "PM" else 0)
    elif hour > 23:
        return None

    return datetime.min.replace(
        hour=hour,
        minute=minute,
        second=second,
        microsecond=microsecond,
    ).time()


def parse_scheduled_time(value):
    """Parse a DTR schedule time such as '12 PM' or '09:30 AM'."""
    match = re.fullmatch(r"\s*(\d{1,2})(?::(\d{2}))?\s*(AM|PM)\s*", str(value), flags=re.IGNORECASE)
    if not match:
        return None
    hour, minute = int(match.group(1)), int(match.group(2) or 0)
    if not 1 <= hour <= 12 or minute > 59:
        return None
    hour = hour % 12 + (12 if match.group(3).upper() == "PM" else 0)
    return datetime.min.replace(hour=hour, minute=minute).time()


def parse_schedule_days(value):
    """Return weekday indexes covered by one DTR schedule segment."""
    matches = list(DAY_TOKEN_PATTERN.finditer(str(value)))
    if not matches:
        return set()

    # A single hyphenated pair represents an inclusive day range. Ranges can
    # wrap the week, as in "Thursday - Monday".
    if len(matches) == 2 and re.fullmatch(
        r"\s*-\s*",
        str(value)[matches[0].end():matches[1].start()],
    ):
        start = DAY_ALIASES[matches[0].group(1).upper()]
        end = DAY_ALIASES[matches[1].group(1).upper()]
        days = {start}
        while start != end:
            start = (start + 1) % 7
            days.add(start)
        return days

    return {DAY_ALIASES[match.group(1).upper()] for match in matches}


def scheduled_start_from_dtr(schedule_value, weekday_name, work_date_est, dtr_timezone):
    """Return today's scheduled start using only the DTR Schedule cell."""
    schedule_text = str(schedule_value or "").strip()
    target_day = DAY_COLUMNS.index(weekday_name)
    default_zone_match = re.search(r"\b(EST|EDT|ET|MNL|PHT)\b", schedule_text, flags=re.IGNORECASE)

    for segment in schedule_text.split("|"):
        time_range = re.search(
            r"(?P<start>\d{1,2}(?::\d{2})?\s*(?:AM|PM))\s*-\s*"
            r"(?P<end>\d{1,2}(?::\d{2})?\s*(?:AM|PM))",
            segment,
            flags=re.IGNORECASE,
        )
        if not time_range:
            continue

        covered_days = parse_schedule_days(segment[:time_range.start()].strip(" ,:"))
        if target_day not in covered_days:
            continue

        start_time = parse_scheduled_time(time_range.group("start"))
        if start_time is None:
            return None

        zone_match = re.search(r"\b(EST|EDT|ET|MNL|PHT)\b", segment, flags=re.IGNORECASE)
        zone_label = (zone_match or default_zone_match)
        if zone_label and zone_label.group(1).upper() in {"EST", "EDT", "ET"}:
            source_timezone = EST
        elif zone_label and zone_label.group(1).upper() in {"MNL", "PHT"}:
            source_timezone = MANILA
        else:
            source_timezone = dtr_timezone

        scheduled_source = datetime.combine(work_date_est, start_time, tzinfo=source_timezone)
        return scheduled_source.astimezone(dtr_timezone)

    return None


def clock_in_is_late(clock_in_value, schedule_value, weekday_name, work_date_est, dtr_timezone):
    """Return True only when the DTR clock-in is after the DTR schedule.

    Both values come from the same DTR row. Comparing full datetimes handles
    starts that cross midnight after timezone conversion (for example, noon ET
    is midnight in Manila). If either DTR value cannot be read, do not label the
    person late.
    """
    clock_time = parse_clock_time(clock_in_value)
    scheduled_dtr = scheduled_start_from_dtr(
        schedule_value,
        weekday_name,
        work_date_est,
        dtr_timezone,
    )
    if clock_time is None or scheduled_dtr is None:
        return False

    # DTR gives us a time-of-day. Pick the occurrence nearest the scheduled
    # start so an early 11:58 PM clock-in for midnight is not marked late.
    actual_candidates = [
        datetime.combine(
            scheduled_dtr.date() + timedelta(days=offset),
            clock_time,
            tzinfo=dtr_timezone,
        )
        for offset in (-1, 0, 1)
    ]
    actual_dtr = min(
        actual_candidates,
        key=lambda candidate: abs((candidate - scheduled_dtr).total_seconds()),
    )
    return actual_dtr > scheduled_dtr


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
    timezone_name = meta.get("properties", {}).get("timeZone", "Asia/Manila")
    try:
        dtr_timezone = ZoneInfo(timezone_name)
    except (KeyError, ValueError):
        raise SystemExit(f"DTR sheet has an invalid timezone: {timezone_name!r}")
    wanted = week_tab_title(today_est)
    if wanted in titles:
        return wanted, dtr_timezone
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
            return title, dtr_timezone
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
        print(
            f"Agent status unchanged: today's ({today_str}) column is not yet "
            f"available in DTR tab '{tab_title}'"
        )
        return None

    name_col = 1
    schedule_col = 2
    clocked_in = {}
    for r in rows:
        if len(r) <= name_col or not r[name_col].strip():
            continue
        name = r[name_col].strip()
        schedule_val = r[schedule_col].strip() if schedule_col < len(r) else ""
        in_val = r[in_col].strip() if in_col < len(r) else ""
        out_val = r[in_col + 1].strip() if in_col + 1 < len(r) else ""
        if in_val and not out_val:
            clocked_in[name] = {"clock_in": in_val, "schedule": schedule_val}
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
    tab_title, dtr_timezone = find_week_tab(service, today_est)
    clockins_by_name = fetch_dtr_clockins(service, tab_title, today_est)
    if clockins_by_name is None:
        return

    online = []
    for nickname, days in agents.items():
        today_shift = days.get(weekday_name)
        if not today_shift:
            continue
        full_name = NAME_MAP.get(nickname)
        if not full_name or full_name not in clockins_by_name:
            continue
        dtr_entry = clockins_by_name[full_name]
        online.append({
            "name": nickname,
            "until": fmt_hour_12(today_shift[1]),
            "late": clock_in_is_late(
                dtr_entry["clock_in"],
                dtr_entry["schedule"],
                weekday_name,
                today_est,
                dtr_timezone,
            ),
        })

    online.sort(key=lambda a: a["name"])

    html_path = "ops-portal-a7c93e4b16f28d05c4e9713b/index.html"
    with open(html_path, "r", encoding="utf-8") as f:
        html = f.read()

    replacement = f"const AGENT_STATUS = {json.dumps(online, ensure_ascii=False)};"
    html, count = re.subn(r"const AGENT_STATUS = \[.*?\];", replacement, html, count=1, flags=re.DOTALL)
    if count != 1:
        raise SystemExit(f"Could not find AGENT_STATUS array literal in {html_path}")

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
