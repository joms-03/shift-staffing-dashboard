import unittest

from scripts import refresh_dashboard, refresh_vip


class UnfilledSummaryFeedTests(unittest.TestCase):
    def test_bf5_feed_uses_shift_id_start_and_staffing_fields(self):
        rows = [
            ["Business", 22, 101, "2026-08-27 12:00:00", "Server", 3, 2],
            ["Missing ID", 23, None, "2026-08-27 13:00:00", "Cook", 2, 1],
        ]

        self.assertEqual(
            refresh_dashboard.summary_shift_rows(rows),
            [[101, "2026-08-27 12:00:00", 3, 2]],
        )

    def test_vip_feed_uses_shift_id_start_and_staffing_fields(self):
        rows = [
            [201, "2026-08-28 08:00:00", "Boston", "Hotel", "Dishwasher", "On", 4, 1, 8, "url"],
            [None, "2026-08-28 09:00:00", "Boston", "Hotel", "Cook", "On", 2, 0, 4, "url"],
        ]

        self.assertEqual(
            refresh_vip.summary_shift_rows(rows),
            [[201, "2026-08-28 08:00:00", 4, 1]],
        )


if __name__ == "__main__":
    unittest.main()
