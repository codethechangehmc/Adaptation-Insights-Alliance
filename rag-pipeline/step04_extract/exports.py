"""Write a run's tables: checked results, project fields and the raw facts, per report and combined."""

from collections import defaultdict
from pathlib import Path

from step04_extract.files import read_json, write_csv
from step04_extract.tasks import GROUPS
from step04_extract.template import export_template

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


def fact_row(fact: dict, job: dict, index: int) -> dict:
    """One raw fact exactly as the model returned it, with its evidence in two readable columns."""
    evidence = fact.get("evidence", [])
    row = {
        "project_code": job["document"],
        "method": job["method"],
        "trial": job["trial"],
        "task": job["group"],
        "fact": index,
    }
    row.update({key: value for key, value in fact.items() if key != "evidence"})
    row["pages"] = "; ".join(dict.fromkeys(str(p) for e in evidence for p in e["pages"]))
    row["quotes"] = " | ".join(e["quote"] for e in evidence if e["quote"])
    return row


def export_run(run_dir: Path) -> dict:
    """Write exports/: results.csv and projects.csv for every report, plus one folder per
    report with its results, projects and facts (every raw fact the model returned).

    Returns the rows: {"results": [...], "projects": [...], "facts": [...]}.
    """
    run = read_json(run_dir / "run.json")
    projects, facts, papers = {}, defaultdict(list), {}
    for job in run["jobs"]:
        if job["document"] not in papers:
            document = read_json(run_dir / "prepared" / f"{job['document']}.json")
            papers[job["document"]] = Path(document["pdf"])
        key = (job["method"], job["document"], job["trial"])
        if key not in projects:
            projects[key] = {
                "method": job["method"],
                "project_code_hint": job["document"],
                "trial": job["trial"],
                "document": papers[job["document"]].name,
                "model": run["config"]["model"],
                **{group + "_status": "not_scheduled" for group in GROUPS},
            }
        row = projects[key]
        path = run_dir / job["path"] / "result.json"
        result = read_json(path) if path.exists() else {"status": "not_run"}
        row[job["group"] + "_status"] = result["status"]
        if result["status"] != "completed":
            continue
        answer = result["answer"]
        flatten_fields(row, answer["facts"])
        row[job["group"] + "_notes"] = answer["notes"]
        facts[job["document"]].extend(
            fact_row(fact, job, index) for index, fact in enumerate(answer["facts"], 1)
        )

    # Checked results and project fields, in our template's columns (template.py).
    results, project_rows = export_template(run_dir, list(projects.values()))

    # Raw facts, one file per report.
    for doc_id, rows in facts.items():
        columns = list(dict.fromkeys(key for row in rows for key in row))
        write_csv(run_dir / "exports" / papers[doc_id].stem / "facts.csv", rows, columns)
    return {
        "results": results,
        "projects": project_rows,
        "facts": [row for rows in facts.values() for row in rows],
    }
