"""Command entry points locate their modules and settings from any working folder."""

from __future__ import annotations

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import run


class CommandTests(unittest.TestCase):
    """Moving modules must preserve command options and persistent storage paths."""

    def test_every_command_help_from_another_folder(self) -> None:
        """All source and helper commands load outside the repository without network."""
        launcher = Path(run.__file__).resolve()

        # A different working folder exposes accidental relative imports and config paths.
        with tempfile.TemporaryDirectory() as temporary:
            for name in run.COMMANDS:
                with self.subTest(command=name):
                    result = subprocess.run(
                        [sys.executable, str(launcher), name, "--help"],
                        cwd=temporary,
                        capture_output=True,
                        text=True,
                        check=False,
                        timeout=30,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn("--output-dir", result.stdout)


if __name__ == "__main__":
    unittest.main()
