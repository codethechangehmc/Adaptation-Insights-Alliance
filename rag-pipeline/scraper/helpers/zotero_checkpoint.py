"""Save and restore complete retrieval checkpoints using a dedicated Zotero item."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sqlite3
import tempfile
import time
import uuid
from pathlib import Path, PurePosixPath
from typing import BinaryIO
from zipfile import ZIP_DEFLATED, ZipFile

import requests

from core import storage

# R's zotero_pull.R treats a parent with a doc: tag as pipeline-owned. This
# separate prefix is not one of zotero_upload.R's six funder document prefixes.
OWNER_TAG = "scraperdoc:checkpoint"
POINTER_PREFIX = "AIA scraper checkpoint: "
FOLDERS = ("outputs", "downloads")
MAX_ARCHIVE_BYTES = 4_000_000_000


def file_hash(path: Path, algorithm: str = "sha256") -> str:
    """Hash a file without loading the complete corpus archive into memory."""
    digest = hashlib.new(algorithm)
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_states(root: Path) -> None:
    """Require readable scraper state and check the integrity of every SQLite database."""
    databases = sorted((root / "outputs").rglob("*.sqlite3"))
    if not databases:
        raise ValueError("No SQLite state found; seed from an explicitly chosen retrieval run")
    for path in databases:
        connection = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
        try:
            if connection.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
                raise ValueError(f"Corrupt SQLite state: {path.name}")
        finally:
            connection.close()


def pack(root: Path, archive: Path) -> None:
    """Archive state, documents, logs and old file versions with a checksum manifest."""
    check_states(root)
    if not (root / "downloads").is_dir():
        raise ValueError("The checkpoint needs a downloads directory, even if it is empty")
    if any(archive.resolve().is_relative_to((root / name).resolve()) for name in FOLDERS):
        raise ValueError("Keep the checkpoint archive outside outputs and downloads")

    # Snapshot SQLite through its backup API, including any committed WAL data.
    manifest = {
        "format": 1,
        "checkpoint_id": uuid.uuid4().hex,
        "created_at": storage.utc_now(),
        "code_revision": os.environ.get("GITHUB_SHA", ""),
        "files": {},
    }
    archive.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as temporary, ZipFile(archive, "w", ZIP_DEFLATED) as bundle:
        for folder in FOLDERS:
            for path in sorted((root / folder).rglob("*")):
                if path.is_symlink():
                    raise ValueError("Checkpoint folders must not contain symbolic links")
                if not path.is_file() or path.name.endswith((".lock", "-wal", "-shm", "-journal")):
                    continue
                name = path.relative_to(root).as_posix()
                saved = path
                if path.suffix == ".sqlite3":
                    saved = Path(temporary) / uuid.uuid4().hex
                    source = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
                    destination = sqlite3.connect(saved)
                    try:
                        source.backup(destination)
                    finally:
                        destination.close()
                        source.close()
                manifest["files"][name] = {
                    "sha256": file_hash(saved),
                    "bytes": saved.stat().st_size,
                }
                bundle.write(saved, name)
        bundle.writestr("manifest.json", json.dumps(manifest, ensure_ascii=False))


def member_path(name: str) -> PurePosixPath:
    """Accept portable regular-file paths only inside the two retrieval folders."""
    path = PurePosixPath(name)
    if (
        path.is_absolute()
        or ".." in path.parts
        or "\\" in name
        or ":" in name
        or not path.parts
        or path.parts[0] not in FOLDERS
        or path.as_posix() != name
    ):
        raise ValueError(f"Unsafe checkpoint member: {name}")
    return path


def unpack(archive: Path, root: Path) -> None:
    """Restore into empty folders only after all archive members pass verification."""
    if any((root / folder).exists() for folder in FOLDERS):
        raise ValueError(
            "Restore requires a fresh data directory; existing data is never replaced"
        )
    root.mkdir(parents=True, exist_ok=True)

    # Stage and verify everything before making it the next run's working data.
    with tempfile.TemporaryDirectory(dir=root) as temporary, ZipFile(archive) as bundle:
        manifest = json.loads(bundle.read("manifest.json"))
        if manifest.get("format") != 1:
            raise ValueError("Unsupported checkpoint format")
        names = bundle.namelist()
        expected = set(manifest["files"]) | {"manifest.json"}
        if set(names) != expected or len(names) != len(expected):
            raise ValueError("Checkpoint members do not match the manifest")
        if len({name.casefold() for name in names}) != len(names):
            raise ValueError("Checkpoint has filenames that collide on Windows")
        stage = Path(temporary)
        for name, info in manifest["files"].items():
            path = stage.joinpath(*member_path(name).parts)
            path.parent.mkdir(parents=True, exist_ok=True)
            with bundle.open(name) as source, path.open("wb") as destination:
                shutil.copyfileobj(source, destination)
            if path.stat().st_size != info["bytes"] or file_hash(path) != info["sha256"]:
                raise ValueError(f"Checkpoint checksum mismatch: {name}")
        check_states(stage)
        for folder in FOLDERS:
            (stage / folder).mkdir(exist_ok=True)
            shutil.move(str(stage / folder), root / folder)


class Zotero:
    """Access only the configured automation parent and its checkpoint attachments."""

    def __init__(self) -> None:
        """Read the same library credentials as R plus a dedicated checkpoint item key."""
        key = os.environ["ZOTERO_API_KEY"]
        library_type = os.environ.get("ZOTERO_LIBRARY_TYPE", "groups")
        library_id = os.environ["ZOTERO_LIBRARY_ID"]
        self.parent_key = os.environ["ZOTERO_CHECKPOINT_ITEM_KEY"]
        if library_type not in {"groups", "users"} or not library_id.isdigit():
            raise ValueError("Invalid Zotero library type or numeric ID")
        if not re.fullmatch(r"[A-Z0-9]{8}", self.parent_key):
            raise ValueError("Invalid Zotero checkpoint item key")
        self.identity = f"{library_type}/{library_id}/items/{self.parent_key}"
        self.base = f"https://api.zotero.org/{library_type}/{library_id}"
        self.session = requests.Session()
        self.session.headers.update({"Zotero-API-Key": key, "Zotero-API-Version": "3"})
        self.wait_until = 0.0

    def request(self, method: str, path: str, **kwargs: object) -> requests.Response:
        """Make an API request, respecting server backoff and stopping on failed writes."""
        time.sleep(max(0, self.wait_until - time.monotonic()))
        response = self.session.request(method, self.base + path, timeout=(30, 300), **kwargs)
        self.wait_until = time.monotonic() + float(response.headers.get("Backoff", "0"))
        if not response.ok:
            response.close()
            raise RuntimeError(f"Zotero {method} {path}: HTTP {response.status_code}")
        return response

    def parent(self) -> dict:
        """Require an explicitly tagged automation item outside the R report namespace."""
        item = self.request("GET", f"/items/{self.parent_key}").json()
        data = item["data"]
        tags = {tag["tag"] for tag in data.get("tags", [])}
        if data.get("itemType") != "computerProgram" or OWNER_TAG not in tags:
            raise ValueError(f"Checkpoint parent must be a Computer Program tagged {OWNER_TAG}")
        if data.get("extra") and not data["extra"].startswith(POINTER_PREFIX):
            raise ValueError("Checkpoint parent Extra field contains unrelated text")
        return item

    def download(self, attachment: str, destination: Path) -> None:
        """Download a checkpoint without forwarding the API key to file-storage hosts."""
        if not re.fullmatch(r"[A-Z0-9]{8}", attachment):
            raise ValueError("Invalid checkpoint attachment key")
        item = self.request("GET", f"/items/{attachment}").json()["data"]
        if item.get("parentItem") != self.parent_key or item.get("linkMode") != "imported_file":
            raise ValueError("Checkpoint attachment does not belong to the configured parent")
        response = self.request(
            "GET", f"/items/{attachment}/file", stream=True, allow_redirects=False
        )
        if response.is_redirect:
            url = response.headers["Location"]
            response.close()
            if not url.startswith("https://"):
                raise ValueError("Checkpoint download requires HTTPS")
            response = requests.get(url, stream=True, timeout=(30, 300))
        with response, destination.open("wb") as handle:
            response.raise_for_status()
            for chunk in response.iter_content(1024 * 1024):
                handle.write(chunk)

    def upload(self, archive: Path) -> str:
        """Create a dated attachment and complete Zotero's three-stage file upload."""
        # Checked 2026-10-29: Zotero staff report a 4 GB per-file limit at
        # https://forums.zotero.org/discussion/comment/516120/ . Use decimal GB.
        if archive.stat().st_size >= MAX_ARCHIVE_BYTES:
            raise ValueError(
                "Checkpoint reaches Zotero's 4 GB file limit; use smaller storage units"
            )
        payload = [
            {
                "itemType": "attachment",
                "linkMode": "imported_file",
                "parentItem": self.parent_key,
                "title": archive.name,
                "filename": archive.name,
                "contentType": "application/zip",
            }
        ]
        result = self.request(
            "POST", "/items", json=payload, headers={"Zotero-Write-Token": uuid.uuid4().hex}
        ).json()
        if result.get("failed") or "0" not in result.get("successful", {}):
            raise RuntimeError("Zotero rejected the checkpoint attachment")
        attachment = result["successful"]["0"]["key"]
        path = f"/items/{attachment}/file"
        headers = {"If-None-Match": "*"}
        authorization = self.request(
            "POST",
            path,
            headers=headers,
            data={
                "md5": file_hash(archive, "md5"),
                "filename": archive.name,
                "filesize": archive.stat().st_size,
                "mtime": int(archive.stat().st_mtime * 1000),
            },
        ).json()
        if not authorization.get("exists"):
            self.upload_bytes(archive, authorization)
            self.request(
                "POST", path, headers=headers, data={"upload": authorization["uploadKey"]}
            )
        return attachment

    def upload_bytes(self, archive: Path, authorization: dict) -> None:
        """Stream a multipart upload from a temporary file using no Zotero credentials."""
        if not authorization["url"].startswith("https://"):
            raise ValueError("Checkpoint upload requires HTTPS")
        with tempfile.TemporaryFile() as body:
            body.write(authorization["prefix"].encode("utf-8"))
            with archive.open("rb") as source:
                shutil.copyfileobj(source, body)
            body.write(authorization["suffix"].encode("utf-8"))
            body.seek(0)
            send_upload(body, authorization)


def send_upload(body: BinaryIO, authorization: dict) -> None:
    """Send the prepared upload body without API-key headers or write redirects."""
    response = requests.post(
        authorization["url"],
        data=body,
        headers={"Content-Type": authorization["contentType"]},
        timeout=(30, 300),
        allow_redirects=False,
    )
    with response:
        if response.status_code != 201:
            raise RuntimeError(f"Checkpoint file upload: HTTP {response.status_code}")


def restore(client: Zotero, root: Path, archive: Path) -> None:
    """Restore the last committed checkpoint or stop without starting a fresh corpus."""
    parent = client.parent()
    extra = parent["data"].get("extra", "")
    if not extra:
        raise ValueError("No committed checkpoint; explicitly initialize from chosen local data")
    pointer = json.loads(extra.removeprefix(POINTER_PREFIX))
    archive.parent.mkdir(parents=True, exist_ok=True)
    client.download(pointer["attachment"], archive)
    if file_hash(archive) != pointer["sha256"] or archive.stat().st_size != pointer["bytes"]:
        raise ValueError("Downloaded checkpoint does not match the committed pointer")
    unpack(archive, root)
    storage.write_json(root / "restored.json", {"identity": client.identity, "extra": extra})


def save(client: Zotero, root: Path, archive: Path, initialize: bool) -> None:
    """Publish a verified archive before conditionally advancing the latest checkpoint."""
    parent = client.parent()
    expected = ""
    if not initialize:
        restored = json.loads((root / "restored.json").read_text(encoding="utf-8"))
        if restored["identity"] != client.identity:
            raise ValueError("Restored data belongs to a different Zotero checkpoint parent")
        expected = restored["extra"]
    if parent["data"].get("extra", "") != expected:
        raise ValueError("Checkpoint changed remotely; restore again before saving")

    # Verify the actual uploaded bytes before making this the next restore target.
    pack(root, archive)
    attachment = client.upload(archive)
    with tempfile.TemporaryDirectory() as temporary:
        downloaded = Path(temporary) / "verify.zip"
        client.download(attachment, downloaded)
        if file_hash(downloaded) != file_hash(archive):
            raise ValueError("Uploaded checkpoint failed read-back verification")
    parent = client.parent()
    if parent["data"].get("extra", "") != expected:
        raise ValueError("Another writer advanced the checkpoint; uploaded archive is preserved")
    pointer = {
        "attachment": attachment,
        "sha256": file_hash(archive),
        "bytes": archive.stat().st_size,
    }
    client.request(
        "PATCH",
        f"/items/{client.parent_key}",
        headers={"If-Unmodified-Since-Version": str(parent["version"])},
        json={"extra": POINTER_PREFIX + json.dumps(pointer)},
    )
    print(f"Committed Zotero checkpoint {attachment}; {pointer['bytes']} bytes")


def main(argv: list[str] | None = None) -> int:
    """Pack locally, restore a committed checkpoint, or save after a completed batch process."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["pack", "restore", "save"])
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument(
        "--initialize", action="store_true", help="seed an empty automation parent"
    )
    args = parser.parse_args(argv)
    if args.initialize and args.action != "save":
        parser.error("--initialize is only valid with save")
    if args.action == "pack":
        pack(args.data_dir, args.archive)
    elif args.action == "restore":
        restore(Zotero(), args.data_dir, args.archive)
    else:
        save(Zotero(), args.data_dir, args.archive, args.initialize)
    return 0
