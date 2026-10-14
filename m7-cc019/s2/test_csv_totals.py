import os
import tempfile
import unittest

from csv_totals import summarize


class SummarizeTests(unittest.TestCase):
    def _write(self, directory, text):
        path = os.path.join(directory, "data.csv")
        with open(path, "w", encoding="utf-8", newline="") as handle:
            handle.write(text)
        return path

    def test_normal_sum(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self._write(directory, "name,amount\na,1\nb,2\nc,3\n")
            self.assertEqual(summarize(path), {"rows": 3, "total": "6"})

    def test_header_only(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self._write(directory, "name,amount\n")
            self.assertEqual(summarize(path), {"rows": 0, "total": "0"})

    def test_empty_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self._write(directory, "")
            self.assertEqual(summarize(path), {"rows": 0, "total": "0"})

    def test_invalid_amount_reports_file_line(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self._write(
                directory, "name,amount\nalice,1.00\nbob,oops\ncarol,2.00\n"
            )
            with self.assertRaises(ValueError) as raised:
                summarize(path)
            self.assertIn("line 3", str(raised.exception))

    def test_decimal_exact_sum(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self._write(
                directory, "name,amount\na,0.10\nb,0.20\nc,0.30\n"
            )
            self.assertEqual(summarize(path), {"rows": 3, "total": "0.60"})

    def test_exact_sum_beyond_default_precision(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self._write(
                directory, "name,amount\na,0.12345678901234567890123456789\n"
            )
            self.assertEqual(
                summarize(path),
                {"rows": 1, "total": "0.12345678901234567890123456789"},
            )

    def test_non_finite_amount_reports_file_line(self):
        with tempfile.TemporaryDirectory() as directory:
            for raw in ("NaN", "Infinity", "-Infinity"):
                path = self._write(
                    directory, "name,amount\nalice,1.00\nbob,%s\n" % raw
                )
                with self.assertRaises(ValueError) as raised:
                    summarize(path)
                self.assertIn("line 3", str(raised.exception))


if __name__ == "__main__":
    unittest.main()
