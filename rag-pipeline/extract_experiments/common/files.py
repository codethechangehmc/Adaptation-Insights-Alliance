"""Small file and token helpers; none of these functions use the network."""

import csv
import hashlib
import json
import re
from functools import lru_cache
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]


def read_json(path: Path) -> Any:
    """Read a UTF-8 JSON file."""
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write_json(path: Path, value: Any) -> None:
    """Replace a JSON file atomically after creating its parent folder."""
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False), encoding="utf-8")
    temporary.replace(path)


def fingerprint(value: Any) -> str:
    """Hash serializable data with stable object ordering."""
    raw = json.dumps(value, sort_keys=True, ensure_ascii=False).encode()
    return hashlib.sha256(raw).hexdigest()


def file_hash(path: Path) -> str:
    """Calculate a file's SHA-256 without loading it all into memory."""
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


@lru_cache(maxsize=1)
def tokenizer() -> Any:
    """Load the embedding tokenizer, whose first setup may fetch a free public vocabulary."""
    import tiktoken

    # Loading an encoding can fetch a public tokenizer file on its first use.
    return tiktoken.get_encoding("cl100k_base")


def tokens(text: str) -> int:
    """Count tokens with the embedding model's tokenizer."""
    return len(tokenizer().encode(text, disallowed_special=()))


def norm(text: str) -> str:
    """Normalize prose punctuation without erasing numeric signs or decimal separators."""
    return " ".join(
        re.findall(
            r"(?<!\w)(?:[<>≤≥]=?|[+-])?\d+(?:[.,]\d+)*%?|\w+", text.casefold(), flags=re.UNICODE
        )
    )


def contains(phrase: str, text: str) -> bool:
    """Match complete normalized tokens, preserving numeric signs and word boundaries."""
    return bool(norm(phrase)) and f" {norm(phrase)} " in f" {norm(text)} "


def write_csv(path: Path, rows: list[dict], columns: list[str]) -> None:
    """Write a consistently ordered CSV, including a header when there are no rows."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        for row in rows:
            writer.writerow(
                {k: json.dumps(v) if isinstance(v, (dict, list)) else v for k, v in row.items()}
            )
