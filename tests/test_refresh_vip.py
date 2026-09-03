import unittest
from unittest.mock import MagicMock, patch

from scripts import refresh_vip


class FetchRowsTests(unittest.TestCase):
    @patch("scripts.refresh_vip.time.sleep")
    @patch("scripts.refresh_vip.urllib.request.urlopen")
    def test_retries_a_timed_out_download(self, mock_urlopen, mock_sleep):
        response = MagicMock()
        response.__enter__.return_value.read.return_value = b"id,name\n123,Test shift\n"
        mock_urlopen.side_effect = [TimeoutError("read timed out"), response]

        rows = refresh_vip.fetch_rows("sheet-id", "sheet-gid")

        self.assertEqual([["id", "name"], ["123", "Test shift"]], rows)
        self.assertEqual(2, mock_urlopen.call_count)
        mock_sleep.assert_called_once_with(refresh_vip.FETCH_RETRY_DELAY_SECONDS)

    @patch("scripts.refresh_vip.time.sleep")
    @patch("scripts.refresh_vip.urllib.request.urlopen")
    def test_raises_after_all_download_attempts_fail(self, mock_urlopen, mock_sleep):
        mock_urlopen.side_effect = TimeoutError("read timed out")

        with self.assertRaises(TimeoutError):
            refresh_vip.fetch_rows("sheet-id", "sheet-gid")

        self.assertEqual(refresh_vip.FETCH_ATTEMPTS, mock_urlopen.call_count)
        self.assertEqual(refresh_vip.FETCH_ATTEMPTS - 1, mock_sleep.call_count)


if __name__ == "__main__":
    unittest.main()
