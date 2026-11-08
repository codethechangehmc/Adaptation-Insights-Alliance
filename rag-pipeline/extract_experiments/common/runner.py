"""Plan, execute and resume the same extraction tasks across three methods."""

import json
import time
from datetime import datetime, timezone
from pathlib import Path

import jsonschema

from common.api import BudgetError, Client
from common.files import ROOT, file_hash, fingerprint, read_json, tokens, write_json
from common.inputs import full_text, prepare_document
from common.rules import fact_flags, headline
from common.tasks import FIELDS, SYSTEM, VERSION, response_schema, task_text
from hybrid.retrieval import retrieve


def jobs(documents: list[dict], methods: list[str], groups: list[str], repeats: int) -> list[dict]:
    """Create reproducible independent task IDs, rotating method order between documents."""
    out = []
    for trial in range(1, repeats + 1):
        for index, doc in enumerate(documents):
            order = methods[index % len(methods) :] + methods[: index % len(methods)]
            for group in groups:
                for method in order:
                    job_id = f"t{trial:02d}/{method}/{doc['id']}/{group}"
                    out.append(
                        {
                            "id": job_id,
                            "document": doc["id"],
                            "method": method,
                            "group": group,
                            "trial": trial,
                            "path": job_id,
                        }
                    )
    return out


def prepare(documents: list[dict]) -> tuple[dict, list[str]]:
    """Collect every input problem before any client or paid request is created."""
    prepared, errors = {}, []
    for doc in documents:
        try:
            prepared[doc["id"]] = prepare_document(doc)
        except (ValueError, OSError, KeyError, TypeError) as error:
            errors.append(f"{doc['id']}: {error}")
    return prepared, errors


def input_estimate(document: dict, method: str, config: dict) -> int:
    """Estimate text/image input conservatively; PDF image tokens remain approximate."""
    amount = tokens(full_text(document))
    if method == "hybrid":
        return min(amount, config["packet_tokens"])
    return amount + document["page_count"] * 2500 if method == "full_pdf" else amount


def estimate(job: dict, document: dict, config: dict) -> dict:
    """Include schema, task and maximum output allowance in the scheduling estimate."""
    output = (
        config["results_output_tokens"] if job["group"] == "results" else config["output_tokens"]
    )
    overhead = (
        tokens(
            SYSTEM + task_text(job["group"], document) + json.dumps(response_schema(job["group"]))
        )
        + 500
    )
    inputs = input_estimate(document, job["method"], config) + overhead
    prices = config["prices_per_million"]
    return {
        "input_tokens_estimated": inputs,
        "output_tokens_limit": output,
        "reserved_usd": (inputs * prices["input"] + output * prices["output"]) / 1_000_000,
    }


def dry_plan(
    documents: list[dict], planned: list[dict], prepared: dict, errors: list[str], config: dict
) -> dict:
    """Describe the complete job matrix even when prepared inputs are missing."""
    estimates = [
        {"job": j["id"], **estimate(j, prepared[j["document"]], config)}
        for j in planned
        if j["document"] in prepared
    ]
    problems = errors + [
        f"{e['job']}: request exceeds the configured context allowance; no clipping is allowed."
        for e in estimates
        if e["input_tokens_estimated"] + e["output_tokens_limit"] > config["context_limit"]
    ]
    return {
        "jobs": len(planned),
        "documents": [d["id"] for d in documents],
        "methods": list(dict.fromkeys(j["method"] for j in planned)),
        "groups": list(dict.fromkeys(j["group"] for j in planned)),
        "trials": sorted({j["trial"] for j in planned}),
        "inputs": {
            name: {
                "pdf": doc["pdf"],
                "sections": doc["sections"],
                "page_count": doc["page_count"],
                "blocks": len(doc["blocks"]),
                "chunks": len(doc["chunks"]),
                "diagnostics": doc["diagnostics"],
                "warnings": doc["warnings"],
            }
            for name, doc in prepared.items()
        },
        "model": config["model"],
        "pdf_detail": config["pdf_detail"],
        "errors": problems,
        "network_calls": 0,
        "budget_usd": config["budget_usd"],
        "maximum_output_estimate_usd": sum(e["reserved_usd"] for e in estimates),
        "estimate_complete": not errors,
        "estimates": estimates,
        "note": "No paid calls. PDF image tokens are estimated, not a billing cap. Embeddings add a small separate cost.",
    }


def start_run(
    output: Path, planned: list[dict], prepared: dict, config: dict, resume: bool
) -> dict:
    """Freeze input/config/code hashes so a resume cannot silently mix different experiments."""
    code = {
        str(p.relative_to(ROOT)): file_hash(p)
        for p in ROOT.rglob("*.py")
        if not {"tests", "results", "cache"}.intersection(p.relative_to(ROOT).parts)
    }
    template_hashes = {
        name: file_hash(ROOT / "inputs" / name)
        for name in ("results_schema.json", "results_template.xlsx")
    }
    signature = fingerprint(
        {
            "config": {key: value for key, value in config.items() if key != "budget_usd"},
            "inputs": {k: v["input_hash"] for k, v in prepared.items()},
            "jobs": planned,
            "code": code,
            "template": template_hashes,
        }
    )
    path = output / "run.json"
    if path.exists():
        previous = read_json(path)
        if not resume or previous["signature"] != signature:
            raise ValueError(
                "Run exists or its inputs/settings/code changed. Choose a new run ID."
            )
        previous["config"]["budget_usd"] = config["budget_usd"]
        write_json(path, previous)
        return previous
    if resume:
        raise ValueError("Cannot resume a run that does not exist.")
    run = {
        "id": output.name,
        "signature": signature,
        "created": datetime.now(timezone.utc).isoformat(),
        "version": VERSION,
        "config": config,
        "jobs": planned,
        "code_hashes": code,
        "template_hashes": template_hashes,
    }
    write_json(path, run)
    for key, value in prepared.items():
        write_json(output / "prepared" / f"{key}.json", value)
    return run


def request_body(job: dict, document: dict, packet: dict, config: dict, file_id: str = "") -> dict:
    """Vary evidence delivery while keeping task, schema and reasoning settings identical."""
    inputs = (
        [{"type": "input_file", "file_id": file_id, "detail": config["pdf_detail"]}]
        if job["method"] == "full_pdf"
        else [{"type": "input_text", "text": "DOCUMENT EVIDENCE:\n" + packet["text"]}]
    )
    inputs.append({"type": "input_text", "text": task_text(job["group"], document)})
    output = (
        config["results_output_tokens"] if job["group"] == "results" else config["output_tokens"]
    )
    return {
        "model": config["model"],
        "store": False,
        "instructions": SYSTEM,
        "input": [{"role": "user", "content": inputs}],
        "reasoning": {"effort": config["reasoning_effort"]},
        "max_output_tokens": output,
        "text": {
            "format": {
                "type": "json_schema",
                "name": job["group"],
                "strict": True,
                "schema": response_schema(job["group"]),
            }
        },
    }


def parse_response(raw: dict, group: str) -> dict:
    """Reject incomplete, refused or structurally invalid responses rather than filling blanks."""
    if raw.get("status") != "completed":
        raise ValueError(f"Response did not complete: {raw.get('status')}")
    items = [item for message in raw.get("output", []) for item in message.get("content", [])]
    if any(item.get("type") == "refusal" for item in items):
        raise ValueError("Model refused the extraction task.")
    text = "".join(item["text"] for item in items if item.get("type") == "output_text")
    answer = json.loads(text)
    jsonschema.validate(answer, response_schema(group))
    return answer


def check_answer(answer: dict, group: str) -> dict:
    """Expose missing scalar fields and per-fact flags while retaining the raw answer."""
    multiple = {"countries", "funder_names", "implementor_names", "result"}
    expected = set(FIELDS[group]) - multiple
    supplied = [f["field"] for f in answer["facts"]]
    return {
        "missing_fields": sorted(expected - set(supplied)),
        "duplicate_scalars": sorted(f for f in expected if supplied.count(f) > 1),
        "facts": [fact_flags(f) for f in answer["facts"]],
    }


def execute_job(
    job: dict, document: dict, config: dict, client: Client, output: Path, cache: Path
) -> None:
    """Persist evidence and requests before extracting one independent category."""
    directory = output / job["path"]
    result_path = directory / "result.json"
    if result_path.exists() and read_json(result_path).get("status") == "completed":
        jsonschema.validate(read_json(result_path)["answer"], response_schema(job["group"]))
        return
    job_started = time.monotonic()
    if job["method"] == "hybrid":
        packet = retrieve(document, job["group"], client, cache, config)
    elif job["method"] == "full_parsed":
        packet = {"text": full_text(document)}
    else:
        packet = {"text": "", "pdf": document["pdf"], "detail": config["pdf_detail"]}
    write_json(directory / "packet.json", packet)
    reservation = estimate(job, document, config)
    if (
        reservation["input_tokens_estimated"] + reservation["output_tokens_limit"]
        > config["context_limit"]
    ):
        raise ValueError(
            "Request exceeds the configured context allowance; no clipping is allowed."
        )
    file_id = client.upload(Path(document["pdf"])) if job["method"] == "full_pdf" else ""
    body = request_body(job, document, packet, config, file_id)
    write_json(directory / "request.json", body)
    started = time.monotonic()
    raw = client.request("responses", reservation["reserved_usd"], job["id"], json=body)
    write_json(directory / "response.json", raw)
    answer = parse_response(raw, job["group"])
    write_json(
        result_path,
        {
            "status": "completed",
            "answer": answer,
            "checks": check_answer(answer, job["group"]),
            "top_three": headline(answer["facts"]) if job["group"] == "results" else [],
            "seconds": round(time.monotonic() - job_started, 3),
            "extraction_seconds": round(time.monotonic() - started, 3),
            "usage": raw.get("usage"),
        },
    )


def execute(
    planned: list[dict], prepared: dict, config: dict, client: Client, output: Path, cache: Path
) -> bool:
    """Continue independent tasks after ordinary failures but stop on budget or uncertain charges."""
    success = True
    for job in planned:
        try:
            execute_job(job, prepared[job["document"]], config, client, output, cache)
            print(f"ok {job['id']}")
        except BudgetError:
            write_json(output / "stop.json", {"reason": "budget", "next_job": job["id"]})
            return False
        except (RuntimeError, ValueError, KeyError, jsonschema.ValidationError) as error:
            success = False
            write_json(
                output / job["path"] / "result.json", {"status": "failed", "error": str(error)}
            )
            print(f"failed {job['id']}: {error}")
            if client.ledger and client.ledger[-1]["status"].startswith("unknown_cost"):
                return False
    return success
