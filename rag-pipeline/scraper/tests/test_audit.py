"""The R comparison audit refuses to claim coverage it cannot prove."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from core import storage

# The audit helper is deliberately separate from the runtime modules.
PATH = Path(__file__).resolve().parents[1] / "audit" / "compare_with_r.py"
SPEC = importlib.util.spec_from_file_location("compare_with_r", PATH)
AUDIT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(AUDIT)


class AuditTests(unittest.TestCase):
    """End-to-end run of the audit command."""

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
            report = root / "rag-pipeline/scraper/data/fake_review/r_comparison.csv"
            self.assertTrue(report.exists())
            self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
