"""A minimal REST client; instantiated only by an explicitly executed live run."""

import os
import time
from pathlib import Path

import requests

from common.files import file_hash, read_json, tokens, write_json


class BudgetError(RuntimeError):
    """The next request cannot fit the remaining scheduling allowance."""


def load_key(path: Path) -> str:
    """Read an environment variable, a conventional .env, or an existing bare key."""
    if os.environ.get("OPENAI_API_KEY"):
        return os.environ["OPENAI_API_KEY"]
    text = path.read_text(encoding="utf-8-sig").strip() if path.exists() else ""
    if text.startswith("sk-") and "\n" not in text:
        return text
    for line in text.splitlines():
        name, separator, value = line.removeprefix("export ").partition("=")
        if separator and name.strip() == "OPENAI_API_KEY":
            return value.strip().strip("\"'")
    raise ValueError("Set OPENAI_API_KEY or provide an .env file for a live run.")


class Client:
    """Send explicit paid requests with durable usage and conservative reservations."""

    def __init__(self, config: dict, run_dir: Path, cache: Path, key: str) -> None:
        """Load the selected run's ledger without contacting the API."""
        self.config, self.run_dir, self.cache = config, run_dir, cache
        self.ledger_path = run_dir / "ledger.json"
        self.ledger = read_json(self.ledger_path) if self.ledger_path.exists() else []
        self.session = requests.Session()
        self.session.headers["Authorization"] = f"Bearer {key}"

    def spent(self) -> float:
        """Include unresolved reservations so interrupted calls are not treated as free."""
        return sum(row.get("cost_usd", row["reserved_usd"]) for row in self.ledger)

    def request(self, endpoint: str, reserve: float, tag: str, **kwargs: object) -> dict:
        """Persist requests and usage, retrying only explicit temporary HTTP failures."""
        for attempt in range(3):
            if self.spent() + reserve > self.config["budget_usd"]:
                raise BudgetError("Next request exceeds the remaining budget allowance.")
            row = {
                "tag": tag,
                "endpoint": endpoint,
                "reserved_usd": reserve,
                "status": "pending",
                "attempt": attempt + 1,
            }
            self.ledger.append(row)
            write_json(self.ledger_path, self.ledger)
            started = time.monotonic()
            try:
                response = self.session.post(
                    "https://api.openai.com/v1/" + endpoint, timeout=(15, 240), **kwargs
                )
            except requests.RequestException:
                row["status"] = "unknown_cost_network_error"
                write_json(self.ledger_path, self.ledger)
                raise RuntimeError(
                    "API connection failed; cost reserved, no automatic resend."
                ) from None
            row["seconds"] = round(time.monotonic() - started, 3)
            if not response.ok:
                row["status"] = f"http_{response.status_code}"
                if response.status_code < 500:
                    row["cost_usd"] = 0
                write_json(self.ledger_path, self.ledger)
                if (
                    endpoint != "files"
                    and response.status_code in (429, 500, 502, 503, 504)
                    and attempt < 2
                ):
                    time.sleep(min(2**attempt, 8))
                    continue
                raise RuntimeError(
                    f"OpenAI HTTP {response.status_code}; inspect configuration or quota."
                )
            try:
                data = response.json()
            except ValueError:
                row["status"] = "unknown_cost_invalid_json"
                write_json(self.ledger_path, self.ledger)
                raise RuntimeError("API returned non-JSON data; cost remains reserved.") from None
            write_json(self.run_dir / "api" / f"{len(self.ledger):04d}.json", data)
            row.update(status="completed", response_id=data.get("id"), usage=data.get("usage"))
            if endpoint == "files":
                row["cost_usd"] = 0
            elif data.get("usage"):
                row["cost_usd"] = usage_cost(data["usage"], self.config, endpoint == "embeddings")
            write_json(self.ledger_path, self.ledger)
            return data
        raise RuntimeError("Request retries exhausted.")

    def embed(self, texts: list[str]) -> list[list[float]]:
        """Create vectors for a token-bounded batch of prepared passages."""
        amount = sum(tokens(text) for text in texts)
        reserve = amount * self.config["prices_per_million"]["embedding"] / 1_000_000
        data = self.request(
            "embeddings",
            reserve,
            "embeddings",
            json={
                "model": self.config["embedding_model"],
                "input": texts,
                "dimensions": self.config["dimensions"],
                "encoding_format": "float",
            },
        )
        return [item["embedding"] for item in sorted(data["data"], key=lambda x: x["index"])]

    def upload(self, pdf: Path) -> str:
        """Reuse a PDF upload by content hash without changing the original file."""
        path = self.cache / "uploads" / f"{file_hash(pdf)}.json"
        if path.exists():
            return read_json(path)["id"]
        with pdf.open("rb") as stream:
            data = self.request(
                "files",
                0,
                "upload",
                data={"purpose": "user_data"},
                files={"file": (pdf.name, stream, "application/pdf")},
            )
        write_json(path, {"id": data["id"]})
        return data["id"]


def usage_cost(usage: dict, config: dict, embedding: bool = False) -> float:
    """Price actual usage without counting reasoning tokens twice."""
    prices = config["prices_per_million"]
    if embedding:
        return usage["total_tokens"] * prices["embedding"] / 1_000_000
    cached = usage.get("input_tokens_details", {}).get("cached_tokens", 0)
    return (
        (usage["input_tokens"] - cached) * prices["input"]
        + cached * prices["cached_input"]
        + usage["output_tokens"] * prices["output"]
    ) / 1_000_000
