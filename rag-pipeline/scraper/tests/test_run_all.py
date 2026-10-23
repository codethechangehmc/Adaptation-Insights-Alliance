"""Batch runs: lanes run side by side, folders stay separate, one failure does not stop others."""

from __future__ import annotations

import tempfile
import threading
import unittest
from pathlib import Path
from unittest.mock import patch

import run_all


class BatchTests(unittest.TestCase):
    """run_all with the per-source process replaced by a stub."""

    def test_lanes_overlap_and_a_failure_does_not_stop_the_rest(self) -> None:
        """AF and CIF meet at a barrier, so they ran at the same time; AF's failure is reported."""
        barrier = threading.Barrier(2, timeout=10)
        commands = {}

        def run(source: str, command: list[str]) -> int:
            commands[source] = command
            barrier.wait()
            return 1 if source == "af" else 0

        with tempfile.TemporaryDirectory() as temporary, patch.object(run_all, "run_command", run):
            root = Path(temporary)
            result = run_all.main(
                ["--sources", "af", "cif", "--output-dir", str(root), "--metadata-only"]
            )
        self.assertEqual(result, 1)
        for source in ("af", "cif"):
            self.assertEqual(commands[source][2], source)
            self.assertIn(str(root / source), commands[source])
            self.assertIn("--metadata-only", commands[source])


if __name__ == "__main__":
    unittest.main()
