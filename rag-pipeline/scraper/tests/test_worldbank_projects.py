"""Project API fields, atomic publication and document enrichment regressions."""

from __future__ import annotations

import argparse
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from core import storage
from helpers import worldbank_projects as projects


class ProjectTests(unittest.TestCase):
    """Project lookups preserve identifiers, units and the last complete table."""

    def test_failed_refresh_keeps_previous_table(self) -> None:
        """One failed project lookup prevents replacing the complete CSV."""
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            catalogue = output / "worldbank_metadata.csv"
            storage.write_csv(catalogue, [{"project_id": "P119662,P000001"}], ["project_id"])
            target = output / "worldbank_projects.csv"
            target.write_text("previous complete table", encoding="utf-8")
            args = argparse.Namespace(
                catalogue=catalogue, output_dir=output, request_interval=0, workers=1
            )
            with patch.object(projects, "collect_projects", return_value=([], {"P000001": "404"})):
                self.assertEqual(projects.run(args, output), 1)
            self.assertEqual(target.read_text(encoding="utf-8"), "previous complete table")


if __name__ == "__main__":
    unittest.main()
