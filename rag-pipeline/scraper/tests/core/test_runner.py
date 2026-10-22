"""Offline regressions for core.runner."""

from __future__ import annotations

import hashlib
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from zipfile import ZipFile

from core import runner, storage
from core.fetch import Client, RequestFailed
from tests.core.support import (
    OTHER_PDF,
    PDF,
    fail_download,
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
            ]
        }
        self.run_source(fake_source(self.root, searches), "--metadata-only")
        rows = storage.read_csv(next((self.output / "runs").iterdir()) / "decisions.csv")
        decisions = {row["id"]: row for row in rows}
        self.assertEqual(decisions["2"]["screen_status"], "in_scope")
        self.assertEqual(decisions["2"]["filter_reason"], "project_sibling_evidence")
        self.assertEqual(decisions["3"]["screen_status"], "drop")

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

    def test_failed_download_is_retried_after_disappearing_from_search(self) -> None:
        """A periodic search cannot strand an earlier kept document in the download backlog."""
        source = fake_source(self.root, {"a": [record("1")]})
        with patch.object(Client, "download", fail_download):
            self.run_source(source)
        with patch.object(Client, "download", write_pdf):
            self.run_source(fake_source(self.root, {"a": []}))
        self.assertEqual(self.summaries()[-1]["download_counts"], {"downloaded": 1})

    def test_download_only_does_not_search_or_change_last_seen(self) -> None:
        """Retrying a saved corpus is labelled explicitly and does not invent a live sighting."""
        source = fake_source(self.root, {"a": [record("1")]})
        self.run_source(source, "--metadata-only")
        before = storage.read_csv(self.output / "fake_metadata.csv")[0]["last_seen"]
        source.plan_searches = lambda args: self.fail("download-only called the live planner")
        with patch.object(Client, "download", write_pdf):
            self.run_source(source, "--download-only")
        after = storage.read_csv(self.output / "fake_metadata.csv")[0]["last_seen"]
        self.assertEqual(before, after)
        self.assertEqual(self.summaries()[-1]["mode"], "download_only")

    def test_sibling_evidence_cannot_supply_a_missing_document_date(self) -> None:
        """A lifted undated document still needs screening even with an in-scope sibling."""
        source = fake_source(
            self.root,
            {
                "a": [
                    record("1", project_id="P1"),
                    record("2", title="Review", project_id="P1", doc_date=""),
                ]
            },
        )
        self.run_source(source, "--metadata-only")
        rows = storage.read_csv(next((self.output / "runs").iterdir()) / "decisions.csv")
        lifted = next(row for row in rows if row["id"] == "2")
        self.assertEqual(lifted["screen_status"], "to_screen")
        self.assertEqual(lifted["filter_reason"], "unknown_document_date")

    def test_date_enrichment_reuses_saved_filename(self) -> None:
        """Recovering a document date must not fetch its already checked PDF again."""
        source = fake_source(self.root, {"a": [record("1", doc_date="")]})
        with patch.object(Client, "download", write_pdf):
            self.run_source(source)
        source = fake_source(self.root, {"a": [record("1", doc_date="2021-03-01")]})
        with patch.object(Client, "download") as download:
            self.run_source(source)
            download.assert_not_called()
        self.assertEqual(self.summaries()[-1]["download_counts"], {"skipped_valid": 1})

    def test_shared_legacy_filename_is_replaced_by_distinct_record_paths(self) -> None:
        """An old truncation collision is repaired without reusing one file for two records."""
        first, second = "a" * 110 + "one", "a" * 110 + "two"
        source = fake_source(self.root, {"a": [record(first), record(second)]})
        self.run_source(source, "--metadata-only")
        shared_name = f"fake_{'a' * 100}_noproj_2020.pdf"
        shared = self.pdfs / shared_name
        shared.write_bytes(PDF)
        connection = storage.open_state(self.output / "state.sqlite3")
        for identifier, body in ((first, PDF), (second, OTHER_PDF)):
            storage.save_download(
                connection,
                identifier,
                {"filename": shared_name, "sha256": hashlib.sha256(body).hexdigest()},
            )
        connection.close()

        def download(client: Client, url: str, part_path: Path) -> dict:
            """Return different report bytes for the two colliding native IDs."""
            part_path.write_bytes(PDF if url.endswith(first + ".pdf") else OTHER_PDF)
            return {"resolved_url": url}

        with patch.object(Client, "download", download):
            self.run_source(source)
        rows = storage.read_csv(self.output / "fake_metadata.csv")
        self.assertEqual(len({row["filename"] for row in rows}), 2)
        self.assertEqual(self.summaries()[-1]["download_counts"], {"downloaded": 2})
        for row in rows:
            self.assertNotEqual(row["filename"], shared_name)
            self.assertEqual(
                storage.check_document(self.pdfs / row["filename"])["sha256"], row["sha256"]
            )
        self.assertEqual(shared.read_bytes(), PDF)

    def test_office_reference_fallback_keeps_its_extension_and_versions(self) -> None:
        """A Word fallback to a dead PDF link is downloaded, reused and archived as Word."""
        source = fake_source(self.root, {"a": [record("1")]})
        path = self.root / "include.csv"
        storage.write_csv(
            path,
            [record("1", pdf_url="https://example.org/report.docx")],
            storage.RECORD_FIELDS,
        )
        document_body = "first version " * 1000

        def download(client: Client, url: str, part_path: Path) -> dict:
            """Return a Word report only from the included fallback URL."""
            if url.endswith(".pdf"):
                raise RequestFailed(url, "HTTP 404", 404)
            with ZipFile(part_path, "w") as archive:
                archive.writestr("[Content_Types].xml", "types")
                archive.writestr("word/document.xml", document_body)
            return {"resolved_url": url}

        with patch.object(Client, "download", download):
            self.run_source(source, "--include-listing", str(path))
        row = storage.read_csv(self.output / "fake_metadata.csv")[0]
        destination = self.pdfs / row["filename"]
        self.assertEqual(destination.suffix, ".docx")
        first_bytes = destination.read_bytes()
        with patch.object(Client, "download") as requested:
            self.run_source(source)
            requested.assert_not_called()
        document_body = "second version " * 1000
        with patch.object(Client, "download", download):
            self.run_source(source, "--refresh")
        version = next((self.output / "versions").iterdir())
        self.assertEqual(version.suffix, ".docx")
        self.assertEqual(version.read_bytes(), first_bytes)
        self.assertNotEqual(destination.read_bytes(), first_bytes)

    def test_pdf_redirect_to_html_cannot_be_adopted_as_a_report(self) -> None:
        """A PDF link redirecting to an HTML error page still fails PDF validation."""
        source = fake_source(self.root, {"a": [record("1")]})

        def download(client: Client, url: str, part_path: Path) -> dict:
            """Return an error page with a supported HTML extension."""
            part_path.write_bytes(b"<html>File not found" + b"x" * 12000)
            return {"resolved_url": "https://example.org/error.html"}

        with patch.object(Client, "download", download):
            self.run_source(source)
        self.assertEqual(self.summaries()[-1]["failed_ids"], ["1"])
        self.assertEqual(list(self.pdfs.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
