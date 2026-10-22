"""Project API fields, atomic publication and document enrichment regressions."""

from __future__ import annotations

import argparse
import tempfile
import unittest
from datetime import date
from pathlib import Path
from unittest.mock import patch

from core import classification, storage
from helpers import worldbank_projects as projects
from sources import worldbank


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

    def test_project_snapshot_refreshes_stored_records_without_searching(self) -> None:
        """Download-only runs must apply the newly selected project snapshot to stored records."""
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            snapshot = output / "worldbank_projects.csv"
            storage.write_csv(
                snapshot,
                [{"project_id": "P119662", "sectors": "Agriculture"}],
                ["project_id", "sectors"],
            )
            args = argparse.Namespace(projects_file=snapshot, output_dir=output)
            with patch.dict(worldbank.PROJECT_DETAILS, clear=True):
                worldbank.prepare_run(args)
                record = {
                    "id": "1",
                    "title": "Completion review",
                    "country": "Kenya",
                    "project_id": "P119662",
                    "doc_date": "2020-01-01",
                }
                self.assertEqual(
                    classification.decide(worldbank, record, date(2015, 1, 1), date(2026, 10, 22))[
                        1
                    ],
                    "agriculture_project_sector",
                )

    def test_instrument_excludes_policy_lending_without_title_hint(self) -> None:
        """Instrument evidence applies even when the title does not mention policy."""
        record = {
            "country": "Kenya",
            "title": "Agriculture review",
            "project_instruments": "Development Policy Lending",
        }
        self.assertEqual(worldbank.classify(record)[:2], ("drop", "policy_or_budget_support"))


if __name__ == "__main__":
    unittest.main()
