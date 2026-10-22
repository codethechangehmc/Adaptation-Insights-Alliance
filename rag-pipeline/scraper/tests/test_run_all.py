"""Batch execution keeps source state separate and reports only current runs."""

from __future__ import annotations

import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

import run_all


class BatchTests(unittest.TestCase):
    """Batch failures do not contaminate or stop another source."""

    def test_source_directories_are_separate_and_failure_does_not_stop_next(self) -> None:
        """Custom base folders get source subfolders, and every source still executes."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with patch.object(run_all, "run_command", side_effect=[1, 0]) as command:
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
                arguments = call.args[1]
                self.assertEqual(arguments[1:3], [str(run_all.SCRAPER_DIR / "run.py"), source])
                self.assertIn(str(root / "outputs" / "worldbank"), arguments)
                self.assertIn("--metadata-only", arguments)

    def test_separate_lanes_run_at_the_same_time(self) -> None:
        """Sources in different lanes overlap; the barrier fails if they ran in turn."""
        barrier = threading.Barrier(2, timeout=10)

        def meet(source: str, command: list[str]) -> int:
            barrier.wait()
            return 0

        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(run_all, "run_command", side_effect=meet),
        ):
            result = run_all.main(
                ["--sources", "af", "cif", "--output-dir", temporary, "--metadata-only"]
            )
        self.assertEqual(result, 0)


if __name__ == "__main__":
    unittest.main()
