import unittest
from datetime import date
from zoneinfo import ZoneInfo

from scripts.refresh_agents import (
    clock_in_is_late,
    parse_clock_time,
    scheduled_start_from_dtr,
)


class ParseClockTimeTests(unittest.TestCase):
    def test_parses_dtr_fractional_seconds(self):
        parsed = parse_clock_time("21:55:01.231000")
        self.assertEqual((21, 55, 1, 231000), (
            parsed.hour,
            parsed.minute,
            parsed.second,
            parsed.microsecond,
        ))

    def test_accepts_am_pm_format(self):
        self.assertEqual(21, parse_clock_time("9:05 PM").hour)

    def test_rejects_non_clock_statuses(self):
        self.assertIsNone(parse_clock_time("Leave"))


class ClockInLatenessTests(unittest.TestCase):
    work_date = date(2026, 8, 17)
    manila = ZoneInfo("Asia/Manila")
    eastern_schedule = "Monday - Friday 10:00 AM - 07:00 PM EST"

    def test_exactly_on_time_is_not_late(self):
        self.assertFalse(clock_in_is_late(
            "22:00:00", self.eastern_schedule, "MONDAY", self.work_date, self.manila
        ))

    def test_fraction_after_start_is_late(self):
        self.assertTrue(clock_in_is_late(
            "22:00:00.000001", self.eastern_schedule, "MONDAY", self.work_date, self.manila
        ))

    def test_before_start_is_not_late(self):
        self.assertFalse(clock_in_is_late(
            "21:59:59.999999", self.eastern_schedule, "MONDAY", self.work_date, self.manila
        ))

    def test_early_clock_in_before_midnight_is_not_late(self):
        schedule = "Monday-Tuesday 12 PM - 09 PM | Wednesday - Friday 10:00 AM - 7:00 PM EST"
        self.assertFalse(clock_in_is_late(
            "23:58:01.186000", schedule, "MONDAY", self.work_date, self.manila
        ))

    def test_after_midnight_start_is_late(self):
        schedule = "Monday-Tuesday 12 PM - 09 PM | Wednesday - Friday 10:00 AM - 7:00 PM EST"
        self.assertTrue(clock_in_is_late(
            "00:02:00", schedule, "MONDAY", self.work_date, self.manila
        ))

    def test_unparseable_clock_in_is_not_late(self):
        self.assertFalse(clock_in_is_late(
            "UTO", self.eastern_schedule, "MONDAY", self.work_date, self.manila
        ))

    def test_unparseable_dtr_schedule_is_not_late(self):
        self.assertFalse(clock_in_is_late(
            "22:05:00", "Schedule pending", "MONDAY", self.work_date, self.manila
        ))


class DtrScheduleTests(unittest.TestCase):
    work_date = date(2026, 8, 17)
    manila = ZoneInfo("Asia/Manila")

    def test_uses_the_matching_day_specific_segment(self):
        schedule = "Mon,Thur, Fri: 08:00 AM - 05:00 PM EST | Tue - Wed: 07:00 AM - 04:00 PM EST"
        monday = scheduled_start_from_dtr(schedule, "MONDAY", self.work_date, self.manila)
        tuesday = scheduled_start_from_dtr(
            schedule,
            "TUESDAY",
            date(2026, 8, 18),
            self.manila,
        )
        self.assertEqual((20, 0), (monday.hour, monday.minute))
        self.assertEqual((19, 0), (tuesday.hour, tuesday.minute))

    def test_supports_wrapping_day_ranges(self):
        schedule = "Thursday - Monday 07:00 AM - 04:00 PM EST"
        monday = scheduled_start_from_dtr(schedule, "MONDAY", self.work_date, self.manila)
        self.assertEqual((19, 0), (monday.hour, monday.minute))

    def test_supports_manila_schedule_times(self):
        schedule = "Monday - Friday 10:00 PM - 7:00 AM MNL"
        monday = scheduled_start_from_dtr(schedule, "MONDAY", self.work_date, self.manila)
        self.assertEqual((22, 0), (monday.hour, monday.minute))


if __name__ == "__main__":
    unittest.main()
