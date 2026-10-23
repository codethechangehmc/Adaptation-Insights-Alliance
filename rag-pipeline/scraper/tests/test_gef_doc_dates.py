"""GEF date regressions for month-name text and original OOXML metadata."""

from __future__ import annotations

import unittest
from pathlib import Path
from unittest.mock import patch

from helpers import gef_doc_dates as dates


class GEFDateTests(unittest.TestCase):
    """Reject regenerated PDF metadata and numeric planned closing dates."""

    def test_scanned_and_pdf_metadata_ignored(self) -> None:
        """Little first-page text is flagged without using PDF creation metadata."""
        with patch.object(dates, "pdf_text", return_value=""):
            row = dates.inspect_file(Path("report.pdf"))
        self.assertTrue(row["scanned"])
        self.assertEqual(row["final_year"], "")
        with patch.object(dates, "pdf_text", return_value=""):
            generated = dates.inspect_file(Path("gef_1_abc_123_2020.pdf"))
            original = dates.inspect_file(
                Path("gef_1_abc_123_2020.pdf"), original_name="report_2019.pdf"
            )
        self.assertEqual(generated["final_year"], "")
        self.assertEqual(original["final_year"], "2019")


if __name__ == "__main__":
    unittest.main()
