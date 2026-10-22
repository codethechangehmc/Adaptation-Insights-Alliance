"""GEF date regressions for month-name text and original OOXML metadata."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from zipfile import ZipFile

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

    def test_docx_raw_xml_bound_excludes_later_project_dates(self) -> None:
        """Formatting-heavy Office reports use the same raw XML bound as the R baseline."""
        for cover, later, expected, method in [
            ("June 2020", "Estimated completion December 2026", "2020", "text"),
            ("", "Project started July 2016", "2022", "ooxml_created"),
        ]:
            with self.subTest(cover=cover), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "report.docx"
                with ZipFile(path, "w") as archive:
                    archive.writestr(
                        "docProps/core.xml",
                        '<core xmlns:dcterms="http://purl.org/dc/terms/">'
                        "<dcterms:created>2022-01-01T00:00:00Z</dcterms:created></core>",
                    )
                    archive.writestr(
                        "word/document.xml",
                        f"<document><text>{cover}</text>"
                        + "<format/>" * 12000
                        + f"<text>{later}</text></document>",
                    )
                row = dates.inspect_file(path)
                self.assertEqual(row["final_year"], expected)
                self.assertEqual(row["method"], method)


if __name__ == "__main__":
    unittest.main()
