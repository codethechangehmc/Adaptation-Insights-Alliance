"""Minimal offline checks for checkpoint recovery and safe publication."""

from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock
from zipfile import ZipFile

from core import storage
from helpers import zotero_checkpoint as checkpoint


class CheckpointTests(unittest.TestCase):
    """Protect the saved corpus and its last verified checkpoint."""

    def seed(self, root: Path) -> None:
        """Create one saved record and its downloaded file."""
        output = root / "outputs/af"
        output.mkdir(parents=True)
        (root / "downloads/af").mkdir(parents=True)
        connection = storage.open_state(output / "state.sqlite3")
        storage.save_records(connection, [{"source": "af", "id": "1"}], "first-seen", {"1"})
        connection.close()
        (root / "downloads/af/report.pdf").write_bytes(b"report bytes")

    def test_roundtrip_preserves_data_and_rejects_damage(self) -> None:
        """Restore state and files; refuse damaged archives and existing working folders."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.seed(root / "seed")
            archive = root / "checkpoint.zip"
            checkpoint.pack(root / "seed", archive)
            checkpoint.unpack(archive, root / "restored")
            self.assertEqual(
                (root / "restored/downloads/af/report.pdf").read_bytes(), b"report bytes"
            )
            connection = storage.open_state(root / "restored/outputs/af/state.sqlite3")
            self.assertEqual(storage.load_state(connection)["1"]["first_seen"], "first-seen")
            connection.close()
            with self.assertRaises(ValueError):
                checkpoint.unpack(archive, root / "restored")

            # Damage one member and confirm no partial restore is installed.
            damaged = root / "damaged.zip"
            with ZipFile(archive) as source, ZipFile(damaged, "w") as destination:
                for name in source.namelist():
                    content = b"wrong" if name.endswith("report.pdf") else source.read(name)
                    destination.writestr(name, content)
            with self.assertRaises(ValueError):
                checkpoint.unpack(damaged, root / "rejected")
            self.assertFalse((root / "rejected/outputs").exists())

    def test_only_verified_upload_becomes_next_checkpoint(self) -> None:
        """A resumed run keeps its old pointer until its next archive passes read-back."""
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            self.seed(root / "seed")
            seed_archive = root / "seed.zip"
            checkpoint.pack(root / "seed", seed_archive)
            extra = checkpoint.POINTER_PREFIX + json.dumps(
                {
                    "attachment": "SEED0001",
                    "sha256": checkpoint.file_hash(seed_archive),
                    "bytes": seed_archive.stat().st_size,
                }
            )
            client = Mock(spec=checkpoint.Zotero)
            client.identity = "groups/123/items/PARENT01"
            client.parent_key = "PARENT01"
            client.parent.return_value = {"version": 1, "data": {"extra": extra}}
            client.download.side_effect = lambda _key, target: shutil.copyfile(
                seed_archive, target
            )
            checkpoint.restore(client, root / "restored", root / "restored.zip")
            client.upload.return_value = "NEXT0001"
            archive = root / "next.zip"

            # Failed verification must leave the last recoverable archive selected.
            client.download.side_effect = OSError("read-back unavailable")
            with self.assertRaises(OSError):
                checkpoint.save(client, root / "restored", archive, False)
            client.request.assert_not_called()

            # A verified archive can advance the checkpoint.
            client.download.side_effect = lambda _key, target: shutil.copyfile(archive, target)
            checkpoint.save(client, root / "restored", archive, False)
            client.request.assert_called_once()
            pointer = client.request.call_args.kwargs["json"]["extra"]
            self.assertEqual(
                json.loads(pointer.removeprefix(checkpoint.POINTER_PREFIX))["attachment"],
                "NEXT0001",
            )


if __name__ == "__main__":
    unittest.main()
