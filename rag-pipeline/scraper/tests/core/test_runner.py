"""Offline regressions for core.runner."""

from __future__ import annotations

import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from core import runner, storage
from core.fetch import Client
from tests.core.support import (
    OTHER_PDF,
    PDF,
    fake_source,
    record,
    write_pdf,
)


class RunnerTests(unittest.TestCase):
    """Whole runs with a fake source."""

    def setUp(self) -> None:
        """Make a temporary repository with output and download folders."""
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.output = self.root / "outputs"
        self.pdfs = self.root / "downloads"

    def tearDown(self) -> None:
        """Remove the temporary folder."""
        self.temp.cleanup()

    def run_source(self, source: object, *options: str) -> int:
        """Run a source against the temporary folders, with no request delay."""
        argv = [
            "--output-dir",
            str(self.output),
            "--download-dir",
            str(self.pdfs),
            "--request-interval",
            "0",
            *options,
        ]
        with self.assertLogs("scraper", level="INFO"), patch("sys.stderr", io.StringIO()):
            return runner.main(source, argv)

    def summaries(self) -> list[dict]:
        """Return every run summary, oldest first."""
        paths = sorted((self.output / "runs").glob("*/summary.json"))
        return [json.loads(path.read_text(encoding="utf-8")) for path in paths]

    def test_incomplete_search_changes_nothing(self) -> None:
        """An incomplete search exits 1 and leaves catalogue, state and PDFs as they were."""
        searches = {"a": [record("1")]}
        with patch.object(Client, "download", write_pdf):
            self.assertEqual(self.run_source(fake_source(self.root, searches)), 0)
        catalogue = (self.output / "fake_metadata.csv").read_bytes()
        failing = fake_source(self.root, {"a": [record("1"), record("2")]}, {"a": "site down"})
        self.assertEqual(self.run_source(failing), 1)
        self.assertEqual((self.output / "fake_metadata.csv").read_bytes(), catalogue)
        self.assertEqual(self.summaries()[-1]["status"], "incomplete_search")
        connection = storage.open_state(self.output / "state.sqlite3")
        self.assertEqual(list(storage.load_state(connection)), ["1"])
        connection.close()

    def test_outputs_and_shared_rules(self) -> None:
        """A complete run writes every output and applies date and language rules."""
        searches = {
            "a": [record("1"), record("2", doc_date="2010-01-01")],
            "b": [record("1"), record("3", language="French"), record("4", doc_date="")],
        }
        self.assertEqual(self.run_source(fake_source(self.root, searches), "--metadata-only"), 0)
        run_dir = next((self.output / "runs").iterdir())
        for name in ("summary.json", "searches.csv", "decisions.csv", "downloads.csv", "run.log"):
            self.assertTrue((run_dir / name).exists(), name)
        decisions = {row["id"]: row for row in storage.read_csv(run_dir / "decisions.csv")}
        self.assertEqual(decisions["1"]["search_ids"], "s001;s002")
        self.assertEqual(decisions["2"]["filter_reason"], "outside_date_range")
        self.assertEqual(decisions["3"]["filter_reason"], "not_english")
        self.assertEqual(decisions["4"]["screen_status"], "to_screen")
        self.assertEqual(decisions["4"]["filter_reason"], "unknown_document_date")

    def test_project_siblings_share_the_strongest_decision(self) -> None:
        """A weak-evidence drop is lifted by a kept sibling; a rule-based drop is not."""
        searches = {
            "a": [
                record("1", project_id="P1"),
                record("2", title="Review", project_id="P1"),
                record("3", title="Review", project_id="P1", language="French"),
                record("4", title="Review", project_id="P1", doc_date=""),
            ]
        }
        self.run_source(fake_source(self.root, searches), "--metadata-only")
        rows = storage.read_csv(next((self.output / "runs").iterdir()) / "decisions.csv")
        decisions = {row["id"]: row for row in rows}
        self.assertEqual(decisions["2"]["screen_status"], "in_scope")
        self.assertEqual(decisions["2"]["filter_reason"], "project_sibling_evidence")
        self.assertEqual(decisions["3"]["screen_status"], "drop")
        # A sibling cannot supply a missing date, so the undated document needs screening.
        self.assertEqual(decisions["4"]["filter_reason"], "unknown_document_date")

    def test_downloads_skip_adopt_and_refresh(self) -> None:
        """Good local files are skipped or adopted; --refresh keeps the old version."""
        source = fake_source(self.root, {"a": [record("1"), record("2")]})
        self.pdfs.mkdir()
        (self.pdfs / "fake_2_noproj_2020.pdf").write_bytes(PDF)
        with patch.object(Client, "download", write_pdf):
            self.run_source(source)
            self.assertEqual(
                self.summaries()[-1]["download_counts"], {"adopted_local": 1, "downloaded": 1}
            )
            self.run_source(source)
            self.assertEqual(self.summaries()[-1]["download_counts"], {"skipped_valid": 2})
        (self.pdfs / "fake_1_noproj_2020.pdf").write_bytes(OTHER_PDF)
        with patch.object(Client, "download", write_pdf):
            self.run_source(source, "--refresh", "--max-downloads", "1")
        self.assertEqual(len(list((self.output / "versions").iterdir())), 1)

    def test_inclusions_survive_rule_drops_and_later_searches(self) -> None:
        """Reference recall preserves the rule decision and does not lift siblings."""
        path = self.root / "include.csv"
        storage.write_csv(
            path,
            [record("1", title="Review", project_id="P1", language="French")],
            storage.RECORD_FIELDS,
        )
        source = fake_source(self.root, {"a": [record("2", title="Review", project_id="P1")]})
        with patch.object(Client, "download", write_pdf):
            self.run_source(source, "--include-listing", str(path))
            self.run_source(source)
        rows = {row["id"]: row for row in storage.read_csv(self.output / "fake_metadata.csv")}
        self.assertEqual(set(rows), {"1"})
        self.assertEqual(rows["1"]["filter_reason"], "reference_recall")
        self.assertEqual(rows["1"]["rule_reason"], "not_english")
        self.assertEqual(self.summaries()[-1]["download_counts"], {"skipped_valid": 1})


if __name__ == "__main__":
    unittest.main()
