"""unittest coverage for :mod:`csv_totals.summarize`."""

import os
import tempfile
import unittest

from csv_totals import summarize

HEADER = "name,amount"


class SummarizeTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.path = os.path.join(self._tmp.name, "data.csv")

    def _write(self, text):
        with open(self.path, "w", encoding="utf-8") as handle:
            handle.write(text)

    def test_normal_sum(self):
        self._write(HEADER + "\nalice,10\nbob,20\ncarol,12\n")
        self.assertEqual(summarize(self.path), {"rows": 3, "total": "42"})

    def test_header_only(self):
        self._write(HEADER + "\n")
        self.assertEqual(summarize(self.path), {"rows": 0, "total": "0"})

    def test_empty_file(self):
        self._write("")
        self.assertEqual(summarize(self.path), {"rows": 0, "total": "0"})

    def test_decimal_precision(self):
        self._write(HEADER + "\nx,0.1\ny,0.2\nz,0.3\n")
        self.assertEqual(summarize(self.path), {"rows": 3, "total": "0.6"})

    def test_invalid_amount_reports_line_number(self):
        # Header occupies line 1, so the bad amount sits on line 3.
        self._write(HEADER + "\nalice,10\nbob,not-a-number\n")
        with self.assertRaises(ValueError) as ctx:
            summarize(self.path)
        self.assertIn("line 3", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
