"""Export every method at the same raw Session-1 stage, keeping all facts and evidence."""

from collections import defaultdict
from pathlib import Path

from common.files import read_json, write_csv, write_json
from common.rules import headline
from common.tasks import GROUPS, RESULT_CONTEXT_FIELDS

ARRAY_FIELDS = {"countries", "funder_names", "implementor_names"}
PAGE_NAMES = {
    "project_lead_name": "project_lead_page",
    "document_type_stated": "document_type_page",
    "scope_stated": "scope_page",
    "instrument_stated": "instrument_page",
}


def evidence_columns(facts: list[dict]) -> dict:
    """Keep all supporting pages and quotations instead of inventing a single citation."""
    evidence = [item for fact in facts for item in fact["evidence"]]
    pages = sorted({page for item in evidence for page in item["pages"] if page > 0})
    return {
        "page": pages[0] if len(pages) == 1 else 0,
        "pages": pages,
        "quotes": [item["quote"] for item in evidence if item["quote"]],
        "evidence": evidence,
    }


def flatten_fields(row: dict, facts: list[dict]) -> None:
    """Map named facts into R Session-1 columns without silently choosing conflicts."""
    grouped = defaultdict(list)
    for fact in facts:
        if fact["field"] != "result":
            grouped[fact["field"]].append(fact)
    for field, members in grouped.items():
        values = list(dict.fromkeys(fact["value"] for fact in members if fact["value"]))
        row[field] = (
            "; ".join(values) if field in ARRAY_FIELDS else values[0] if len(values) == 1 else ""
        )
        if field not in ARRAY_FIELDS and len(values) > 1:
            row[field + "_alternatives"] = values
        evidence = evidence_columns(members)
        page_name = PAGE_NAMES.get(field, field + "_page")
        row[page_name] = evidence["page"]
        row[field + "_pages"] = evidence["pages"]
        row[field + "_quote"] = " ... ".join(evidence["quotes"])
        row[field + "_evidence"] = evidence["evidence"]
        row[field + "_derivation"] = " | ".join(
            f["derivation"] for f in members if f["derivation"]
        )
        row[field + "_status"] = "; ".join(dict.fromkeys(f["status"] for f in members))
        if field in {"budget_total", "budget_lead_share", "disbursed"}:
            row[field + "_stated"] = row[field + "_quote"]


def result_row(fact: dict, metadata: dict, index: int) -> dict:
    """Use R's metric_stated/unit_stated names while preserving the full result record."""
    evidence = evidence_columns([fact])
    return {
        **metadata,
        "result_index": index,
        "value": fact["value"],
        **{name: fact.get(name, "") for name in RESULT_CONTEXT_FIELDS},
        "metric_stated": fact["metric"],
        "unit_stated": fact["unit"],
        "scope": fact["scope"],
        "value_type": fact["value_type"],
        "category": fact["category"],
        "project_total": fact["project_total"],
        "in_summary": fact["in_summary"],
        "indicator_level": fact["indicator_level"],
        "status": fact["achievement_status"],
        "extraction_status": fact["status"],
        "page": evidence["page"],
        "pages": evidence["pages"],
        "evidence": evidence["evidence"],
    }


def fill_slots(row: dict, facts: list[dict]) -> None:
    """Create the same optional headline view for every method, independent of raw scoring."""
    top = headline(facts)
    for slot in range(1, 4):
        prefix = f"result{slot}"
        fact = top[slot - 1] if slot <= len(top) else None
        row[prefix] = fact["value"] if fact else ""
        for field, source in [
            ("metric_stated", "metric"),
            ("unit_stated", "unit"),
            ("scope", "scope"),
        ]:
            row[prefix + "_" + field] = fact[source] if fact else ""
        evidence = evidence_columns([fact] if fact else [])
        row[prefix + "_page"] = evidence["page"]
        row[prefix + "_evidence"] = evidence["evidence"]


def export_run(run_dir: Path) -> dict:
    """Write flat Session-1 rows and lossless facts/results tables for review and adapters."""
    run = read_json(run_dir / "run.json")
    wide, long, results = {}, [], []
    for job in run["jobs"]:
        key = (job["method"], job["document"], job["trial"])
        metadata = {
            "method": job["method"],
            "project_code_hint": job["document"],
            "trial": job["trial"],
            "stage": "session1_raw",
        }
        if key not in wide:
            document = read_json(run_dir / "prepared" / f"{job['document']}.json")
            wide[key] = {
                **metadata,
                "document": Path(document["pdf"]).name,
                "model": run.get("baselines", {})
                .get(job["method"], {})
                .get("model", run["config"]["model"]),
                **{group + "_status": "not_scheduled" for group in GROUPS},
            }
        row = wide[key]
        path = run_dir / job["path"] / "result.json"
        result = read_json(path) if path.exists() else {"status": "not_run"}
        row[job["group"] + "_status"] = result["status"]
        if result["status"] != "completed":
            continue
        answer = result["answer"]
        facts = answer["facts"]
        flatten_fields(row, facts)
        row[job["group"] + "_notes"] = answer["notes"]
        row[job["group"] + "_pages"] = evidence_columns(facts)["pages"]
        long.extend(
            {**metadata, "group": job["group"], "fact_index": i, **fact}
            for i, fact in enumerate(facts, 1)
        )
        if job["group"] == "results":
            results.extend(result_row(fact, metadata, i) for i, fact in enumerate(facts, 1))
            fill_slots(row, facts)
            row["result_notes"] = answer["notes"]
            row["results_all_n"] = len(facts)
    output = run_dir / "exports"
    tables = {"session1": list(wide.values()), "facts": long, "results": results}
    for name, rows in tables.items():
        columns = list(dict.fromkeys(key for row in rows for key in row))
        write_csv(output / f"{name}.csv", rows, columns or ["stage"])
        write_json(output / f"{name}.json", rows)
    # Template exports are a separate presentation layer over the unchanged raw tables.
    from common.template import export_template

    export_template(run_dir, list(wide.values()))
    write_json(
        output / "format.json",
        {
            "stage": "session1_raw",
            "harmonized": False,
            "notes": [
                "All methods use the same field mapping and headline selector.",
                "Metric/unit _stated columns contain document wording, not controlled codes.",
                "Use the common reviewed scorer; do not compare different scorer percentages.",
                "Original model replies and all facts remain in per-job files.",
            ],
        },
    )
    return {name: len(rows) for name, rows in tables.items()}
