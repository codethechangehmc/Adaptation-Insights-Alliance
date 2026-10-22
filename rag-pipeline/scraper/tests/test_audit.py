"""Audit comparisons keep documents whose download URLs are not yet resolved."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from core import storage

# The audit helper is deliberately outside the runtime scraper package.
PATH = Path(__file__).resolve().parents[2] / "audit" / "compare_with_r.py"
SPEC = importlib.util.spec_from_file_location("compare_with_r", PATH)
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)
REFERENCES = __import__("reference_catalogues")


class AuditTests(unittest.TestCase):
    """Document-page identity works when native source IDs have changed."""

    def test_url_match_preserves_references_and_download_evidence(self) -> None:
        """Duplicate URL rows remain visible and a dropped copy cannot hide a kept copy."""
        rows = AUDIT.compare(
            [
                {
                    "id": "1",
                    "pdf_url": "https://example.org/a.pdf",
                    "screen_status": "in_scope",
                    "filename": "a.pdf",
                    "sha256": "digest",
                },
                {"id": "2", "pdf_url": "https://example.org/a.pdf", "screen_status": "drop"},
            ],
            [
                {"id": "old1", "pdf_url": "https://example.org/a.pdf"},
                {"id": "old2", "pdf_url": "https://example.org/a.pdf"},
            ],
        )
        self.assertEqual(len(rows), 2)
        self.assertEqual({row["r_id"] for row in rows}, {"old1", "old2"})
        self.assertTrue(all(row["membership"] == "both" for row in rows))
        self.assertTrue(all(row["filename"] == "a.pdf" for row in rows))
        self.assertTrue(all(row["sha256"] == "digest" for row in rows))

    def test_corpus_family_mapping_preserves_file_provenance_without_matching(self) -> None:
        """A project-code mapping retains its uncertainty and distinct corpus filenames."""
        reference = REFERENCES.normalize_reference(
            "gcf",
            {
                "filename": "gcf_FP023_Evaluation_report.pdf",
                "url": "https://climateprojectexplorer.org/document/shared-family",
                "match_method": "gcf:fpcode",
                "year": "2016",
            },
            Path("doc_index.csv"),
        )
        rows = AUDIT.compare(
            [{"id": "different", "web_url": reference["web_url"], "screen_status": "in_scope"}],
            [reference],
        )
        self.assertEqual(rows[0]["membership"], "r_only")
        self.assertEqual(rows[0]["reference_mapping"], "gcf:fpcode")
        self.assertEqual(rows[0]["reference_filename"], "gcf_FP023_Evaluation_report.pdf")
        self.assertEqual(reference["doc_date"], "")
        self.assertEqual(reference["reference_date"], "2016")

    def test_local_adoption_rejects_skips_and_heuristic_corpus_urls(self) -> None:
        """Only successful download logs may associate an existing legacy file by URL."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            folder = root / "downloads/gcf"
            folder.mkdir(parents=True)
            (folder / "legacy.pdf").write_bytes(
                b"%PDF-1.4\n" + b"x" * storage.MIN_FILE_BYTES + b"\n%%EOF"
            )
            (root / "outputs").mkdir()
            storage.write_csv(
                root / "outputs/download_log.csv",
                [
                    {
                        "source": "gcf",
                        "url": "https://example.org/a.pdf",
                        "filepath": "legacy.pdf",
                        "status": "skipped",
                    }
                ],
                ["source", "url", "filepath", "status"],
            )
            (root / "catalogues").mkdir()
            storage.write_csv(
                root / "catalogues/doc_index.csv",
                [{"source": "gcf", "url": "https://example.org/a.pdf", "filename": "legacy.pdf"}],
                ["source", "url", "filename"],
            )
            with patch.object(AUDIT, "REPO", root):
                copied = AUDIT.adopt_local(
                    "gcf", [{"id": "new", "pdf_url": "https://example.org/a.pdf"}], root / "review"
                )
        self.assertEqual(copied, 0)

    def test_all_saved_snapshots_and_successful_downloads_form_the_baseline(self) -> None:
        """Older metadata and successful log-only documents cannot disappear from the audit."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            metadata, log = root / "metadata.csv", root / "download_log.csv"
            storage.write_csv(
                metadata,
                [{"id": "1", "title": "Report", "pdf_url": "https://example.org/1.pdf"}],
                ["id", "title", "pdf_url"],
            )
            storage.write_csv(
                log,
                [
                    {
                        "source": "worldbank",
                        "title": "Copy",
                        "url": "https://example.org/1.pdf",
                        "status": "success",
                    },
                    {
                        "source": "worldbank",
                        "title": "Old",
                        "url": "https://example.org/2.pdf",
                        "status": "success",
                    },
                    {
                        "source": "af",
                        "title": "Other",
                        "url": "https://example.org/3.pdf",
                        "status": "success",
                    },
                    {
                        "source": "worldbank",
                        "title": "Skipped collision",
                        "url": "https://example.org/skipped.pdf",
                        "status": "skipped",
                    },
                ],
                ["source", "title", "url", "status"],
            )
            rows = AUDIT.load_baseline("worldbank", [metadata, log])
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[0]["id"], "1")

    def test_cli_superset_check_fails_for_missing_file(self) -> None:
        """The CLI writes its audit and refuses metadata-only proof of download coverage."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline, run = root / "baseline.csv", root / "run"
            run.mkdir()
            storage.write_csv(baseline, [{"id": "1", "title": "Report"}], ["id", "title"])
            storage.write_csv(
                run / "decisions.csv",
                [{"id": "1", "screen_status": "to_screen", "sha256": "a"}],
                ["id", "screen_status", "sha256"],
            )
            with patch.object(AUDIT, "REPO", root):
                code = AUDIT.main(
                    [
                        "fake",
                        "--run",
                        str(run),
                        "--r-file",
                        str(baseline),
                        "--download-dir",
                        str(root),
                        "--require-superset",
                    ]
                )
            report = root / "rag-pipeline/data/fake_review/r_comparison.csv"
            self.assertTrue(report.exists())
            self.assertEqual(code, 1)

    def test_cli_keeps_only_this_source_from_a_mixed_corpus(self) -> None:
        """Mixed-source corpus references are filtered to the audited source."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline, run = root / "doc_index.csv", root / "run"
            run.mkdir()
            storage.write_csv(
                baseline,
                [
                    {"source": "fake", "filename": "fake.pdf", "url": "https://example.org/a.pdf"},
                    {
                        "source": "other",
                        "filename": "other.pdf",
                        "url": "https://example.org/b.pdf",
                    },
                ],
                ["source", "filename", "url"],
            )
            storage.write_csv(
                run / "decisions.csv",
                [{"id": "corpus_fake.pdf", "screen_status": "to_screen"}],
                ["id", "screen_status"],
            )
            with patch.object(AUDIT, "REPO", root):
                code = AUDIT.main(["fake", "--run", str(run), "--r-file", str(baseline)])
            rows = storage.read_csv(root / "rag-pipeline/data/fake_review/r_comparison.csv")
            self.assertEqual(code, 0)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0]["r_id"], "corpus_fake.pdf")
            self.assertEqual(rows[0]["membership"], "both")


if __name__ == "__main__":
    unittest.main()
