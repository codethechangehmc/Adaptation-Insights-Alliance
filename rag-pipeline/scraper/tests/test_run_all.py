"""Batch execution keeps source state separate and reports only current runs."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import run_all


class BatchTests(unittest.TestCase):
    """Batch failures do not contaminate or stop another source."""

    def test_source_directories_are_separate_and_failure_does_not_stop_next(self) -> None:
        """Custom base folders get source subfolders, and every source still executes."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(
                run_all.subprocess,
                "run",
                side_effect=[
                    SimpleNamespace(returncode=1),
                    SimpleNamespace(returncode=0),
                ],
            ) as command:
                result = run_all.main(
                    [
                        "--sources",
                        "worldbank",
                        "worldbank_projects",
                        "--output-dir",
                        str(root / "outputs"),
                        "--download-dir",
                        str(root / "downloads"),
                        "--metadata-only",
                    ]
                )
            self.assertEqual(result, 1)
            self.assertEqual(command.call_count, 2)
            for source, call in zip(
                ["worldbank", "worldbank_projects"], command.call_args_list, strict=True
            ):
                self.assertEqual(call.args[0][1:3], [str(run_all.SCRAPER_DIR / "run.py"), source])
                self.assertIn(str(root / "outputs" / "worldbank"), call.args[0])
                self.assertIn("--metadata-only", call.args[0])


if __name__ == "__main__":
    unittest.main()
