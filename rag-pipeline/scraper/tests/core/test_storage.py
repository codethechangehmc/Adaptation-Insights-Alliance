"""Offline regressions for core.storage."""

from __future__ import annotations

import sqlite3
import tempfile
import unittest
from pathlib import Path

from core import storage
from tests.core.support import PDF


class StorageTests(unittest.TestCase):
    """State database, PDF checks and file names."""

    def setUp(self) -> None:
        """Make a temporary folder."""
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self) -> None:
        """Remove the temporary folder."""
        self.temp.cleanup()

    def test_pdf_check(self) -> None:
        """A real-looking PDF passes; an HTML page or a cut file fails."""
        good, html, cut = self.root / "good.pdf", self.root / "page.pdf", self.root / "cut.pdf"
        good.write_bytes(PDF)
        html.write_bytes(b"<html>" + b" " * 20000)
        cut.write_bytes(PDF[:15000])
        self.assertEqual(storage.check_document(good)["bytes"], len(PDF))
        for path in (html, cut):
            with self.assertRaises(ValueError):
                storage.check_document(path)

    def test_old_state_schema_is_upgraded(self) -> None:
        """The first World Bank state file keeps its rows under the new column names."""
        path = self.root / "state.sqlite3"
        old = sqlite3.connect(path)
        old.execute(
            "CREATE TABLE documents (id TEXT PRIMARY KEY, metadata TEXT NOT NULL, "
            "first_seen TEXT NOT NULL, last_seen TEXT NOT NULL, download TEXT NOT NULL)"
        )
        old.execute("INSERT INTO documents VALUES ('1', '{\"id\": \"1\"}', 'a', 'b', '{}')")
        old.commit()
        old.close()
        connection = storage.open_state(path)
        self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 1)
        self.assertEqual(storage.load_state(connection)["1"]["first_seen"], "a")
        connection.close()
        self.assertTrue((self.root / "state.sqlite3.schema0.bak").exists())


if __name__ == "__main__":
    unittest.main()
