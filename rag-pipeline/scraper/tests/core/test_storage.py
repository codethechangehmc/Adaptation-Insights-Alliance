"""Offline regressions for core.storage."""

from __future__ import annotations

import sqlite3
import tempfile
import unittest
from pathlib import Path

from core import storage
from helpers import processing
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
        self.assertEqual(connection.execute("PRAGMA user_version").fetchone()[0], 2)
        self.assertEqual(storage.load_state(connection)["1"]["first_seen"], "a")
        connection.close()
        self.assertTrue((self.root / "state.sqlite3.schema0.bak").exists())

    def test_metadata_edits_and_processing_follow_content(self) -> None:
        """Edits survive refresh; changed PDFs, parsed text and recipes request the right work."""
        with (
            storage.directory_lock(self.root / ".run.lock"),
            self.assertRaises(RuntimeError),
            storage.directory_lock(self.root / ".run.lock"),
        ):
            self.fail("Concurrent writer acquired the folder")
        connection = storage.open_state(self.root / "state.sqlite3")
        record = {"id": "1", "source": "afdb", "title": "Report", "project_code": "P-1"}
        storage.save_records(connection, [record], "a", {"1"})
        storage.save_download(connection, "1", {"status": "downloaded", "sha256": "pdf"})
        connection.execute("UPDATE documents SET title = 'Corrected title'")
        storage.save_records(connection, [{**record, "country": "Kenya"}], "b", {"1"})
        row = storage.catalogue_rows(connection)[0]
        self.assertEqual(
            (row["title"], row["country"], row["project_id"]), ("Corrected title", "Kenya", "P-1")
        )
        self.assertNotIn("project_code", storage.load_state(connection)["1"]["record"])
        artifact = self.root / "sections.json"
        artifact.write_text("parsed text")
        processing.complete(connection, "1", "parse", "pdf", "parser-v1", artifact)
        parsed = processing.status(connection)[0]["extract_input_sha256"]
        processing.complete(connection, "1", "extract", parsed, "prompt-v1", artifact)
        self.assertFalse(processing.status(connection)[0]["needs_extract"])
        connection.execute("UPDATE documents SET report_no = 'R1'")
        self.assertTrue(processing.status(connection)[0]["needs_extract"])
        self.assertFalse(processing.status(connection)[0]["needs_parse"])
        self.assertTrue(
            processing.status(connection, extract_recipe="prompt-v2")[0]["needs_extract"]
        )
        self.assertTrue(processing.status(connection, parse_recipe="parser-v2")[0]["needs_parse"])
        artifact.write_text("corrected parsed text")
        processing.complete(connection, "1", "parse", "pdf", "parser-v1", artifact)
        self.assertTrue(processing.status(connection)[0]["needs_extract"])
        storage.save_download(connection, "1", {"status": "downloaded", "sha256": "changed"})
        self.assertTrue(processing.status(connection)[0]["needs_parse"])
        with self.assertRaises(ValueError):
            processing.complete(connection, "1", "parse", "pdf", "parser-v1", artifact)
        connection.close()


if __name__ == "__main__":
    unittest.main()
