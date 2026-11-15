"""Import explicit R raw group JSON files; never run R or use harmonised outputs."""

from pathlib import Path

import jsonschema

from common.files import file_hash, fingerprint, read_json, write_json
from common.runner import check_answer
from common.tasks import FIELDS, GROUPS, RESULT_CONTEXT_FIELDS, response_schema

METHOD = "r_baseline"
ARRAY_FIELDS = {"funder_names", "implementor_names"}
QUOTE_FIELDS = {
    "start_year": "start_year_quote",
    "closure_year": "closure_year_quote",
    "scope_stated": "scope_stated",
    "rationale_project": "rationale_project",
    "target_beneficiary_stated": "target_beneficiary_stated",
    "GESI_project": "GESI_project_quote",
    "budget_total": "budget_total_stated",
    "budget_lead_share": "budget_lead_share_stated",
    "disbursed": "disbursed_stated",
}
PAGE_FIELDS = {
    "project_lead_name": "project_lead_page",
    "document_type_stated": "document_type_page",
    "scope_stated": "scope_page",
    "instrument_stated": "instrument_page",
}


def as_list(value: object) -> list:
    """Handle jsonlite's scalar representation of one-element arrays."""
    return value if isinstance(value, list) else [] if value is None else [value]


def evidence(raw: dict, field: str, page_count: int, group: str) -> list[dict]:
    """Preserve explicit R quotes/pages, marking absent quotes rather than fabricating them."""
    page_key = "page" if group == "results" else PAGE_FIELDS.get(field, field + "_page")
    pages = [int(p) for p in as_list(raw.get(page_key) or raw.get("source_pages")) if int(p) > 0]
    if any(p > page_count for p in pages):
        raise ValueError("R citation is outside the original PDF page range.")
    quote_key = QUOTE_FIELDS.get(field)
    quote = str(raw.get(quote_key) or "") if quote_key else ""
    return [{"quote": quote, "pages": pages}] if quote or pages else []


def scalar_fact(raw: dict, field: str, value: object, page_count: int, group: str) -> dict:
    """Map a raw R scalar into the shared evidence-backed representation."""
    text = str(value) if value is not None else ""
    return {
        "field": field,
        "value": text,
        "status": "present" if text else "not_found_in_input",
        "scope": "",
        "derivation": "",
        "evidence": evidence(raw, field, page_count, group),
    }


def result_fact(raw: dict, page_count: int) -> dict:
    """Map R's result fields exactly, requiring actual-versus-target metadata."""
    required = (
        "value",
        "metric_stated",
        "unit_stated",
        "scope",
        "value_type",
        "category",
        "project_total",
        "indicator_level",
    )
    if any(key not in raw for key in required):
        raise ValueError(
            "R results need the current raw Session-1 schema, including value_type and scope."
        )
    fact = scalar_fact(raw, "result", raw["value"], page_count, "results")
    fact.update(
        **{name: str(raw.get(name) or "") for name in RESULT_CONTEXT_FIELDS},
        metric=raw["metric_stated"],
        unit=raw["unit_stated"],
        scope=raw["scope"],
        value_type=raw["value_type"],
        category=raw["category"],
        project_total=raw["project_total"],
        indicator_level=raw["indicator_level"],
        in_summary=raw.get("in_summary", "unknown"),
        achievement_status=raw.get("status", ""),
    )
    return fact


def convert(raw: dict, group: str, page_count: int) -> dict:
    """Normalize original group replies without catalogue enrichment or harmonisation."""
    if not isinstance(raw, dict):
        raise ValueError("Each R group reply must be a JSON object.")
    if "facts" in raw or any(
        key in raw for key in ("project_code_hint", "project_lead", "result1")
    ):
        raise ValueError("Supply original per-group R JSON, not a folded or harmonised table.")
    if group == "results":
        if "results" not in raw:
            raise ValueError("R results reply is missing its results array.")
        facts = [result_fact(item, page_count) for item in as_list(raw.get("results"))]
        return {"facts": facts, "notes": str(raw.get("result_notes") or "")}
    if set(FIELDS[group]) - {"countries"} - set(raw):
        raise ValueError(f"R {group} reply is missing required Session-1 fields.")
    facts = []
    for field in FIELDS[group]:
        if field == "countries":
            continue  # R stores country evidence in scope/notes, not a separate array.
        values = as_list(raw.get(field)) if field in ARRAY_FIELDS else [raw.get(field, "")]
        facts.extend(scalar_fact(raw, field, value, page_count, group) for value in values)
    return {"facts": facts, "notes": str(raw.get("finance_notes") or "")}


def stage_entries(manifest: dict, source: Path, run_dir: Path) -> list[tuple[dict, dict, dict]]:
    """Validate every baseline input before modifying any saved experiment files."""
    staged = []
    allowed = {job["document"] for job in read_json(run_dir / "run.json")["jobs"]}
    for entry in manifest["documents"]:
        doc_id = entry["id"]
        if doc_id not in allowed:
            raise ValueError("R baseline IDs must match documents already in this experiment run.")
        document = read_json(run_dir / "prepared" / f"{doc_id}.json")
        pdf = (source.parent / entry["pdf"]).resolve()
        if file_hash(pdf) != document["source_hashes"]["pdf"]:
            raise ValueError(f"{doc_id}: R and Python must refer to the same PDF bytes.")
        if set(entry["groups"]) != set(GROUPS):
            raise ValueError("Declare paths for all five raw R group replies.")
        for group in GROUPS:
            path = (source.parent / entry["groups"][group]).resolve()
            raw = read_json(path)
            answer = convert(raw, group, document["page_count"])
            jsonschema.validate(answer, response_schema(group))
            job_id = f"t01/{METHOD}/{doc_id}/{group}"
            job = {
                "id": job_id,
                "path": job_id,
                "method": METHOD,
                "document": doc_id,
                "group": group,
                "trial": 1,
            }
            staged.append(
                (job, raw, {"answer": answer, "source": str(path), "sha256": file_hash(path)})
            )
    return staged


def import_baseline(run_dir: Path, source: Path) -> int:
    """Add a saved raw R baseline to the common scorer and exports, with no model calls."""
    manifest = read_json(source)
    if (
        manifest.get("stage") != "session1_raw"
        or not manifest.get("model")
        or not manifest.get("prompt_version")
    ):
        raise ValueError("R manifest must declare stage=session1_raw, model and prompt_version.")
    run = read_json(run_dir / "run.json")
    if any(job["method"] == METHOD for job in run["jobs"]):
        raise ValueError("This run already has an R baseline; keep it immutable or use a new run.")
    staged = stage_entries(manifest, source, run_dir)
    ids = [job["id"] for job, _, _ in staged]
    if not ids or len(ids) != len(set(ids)):
        raise ValueError("R baseline documents must be nonempty and unique.")
    for job, raw, imported in staged:
        directory = run_dir / job["path"]
        write_json(directory / "r_original.json", raw)
        write_json(
            directory / "packet.json",
            {
                "text": "",
                "input_available": False,
                "note": "Original R input packet is not reconstructed from its output.",
            },
        )
        write_json(
            directory / "result.json",
            {
                "status": "completed",
                **imported,
                "checks": check_answer(imported["answer"], job["group"]),
                "seconds": None,
                "usage": None,
            },
        )
        run["jobs"].append(job)
    run.setdefault("baselines", {})[METHOD] = {
        "stage": "session1_raw",
        "model": manifest["model"],
        "prompt_version": manifest["prompt_version"],
        "manifest_hash": fingerprint(manifest),
        "note": "Historical system comparison; model, prompts and input preparation may differ. Not a controlled language-only comparison.",
    }
    write_json(run_dir / "run.json", run)
    return len(staged)
