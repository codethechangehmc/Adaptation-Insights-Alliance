"""Create editable reference labels; never mark imported answers as reviewed."""

import csv
from pathlib import Path

from common.files import ROOT, write_json
from common.tasks import FIELDS

REFERENCE_FIELDS = {
    "project_title": "project_title",
    "project_id": "project_id",
    "project_lead": "project_lead_name",
    "publication_year": "publication_year",
    "start_year": "start_year",
    "closure_year": "closure_year",
    "location_count": "location_count",
    "target_beneficiary_project": "target_beneficiary_stated",
    "GESI_project": "GESI_project",
    "budget_total": "budget_total",
    "disbursed": "disbursed",
    "currency": "currency",
    "funding_mechanism": "instrument_stated",
    "funder": "funder_names",
    "implementors": "implementor_names",
    "document_type": "document_type_stated",
    "resource_id": "resource_id",
}


def csv_rows(path: Path) -> list[dict]:
    """Read existing reference tables without making them runtime extraction inputs."""
    with path.open(encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream))


def new_label(document: str, group: str, field: str, value: str = "") -> dict:
    """Build an unreviewed label with explicit evidence and matching requirements."""
    return {
        "document": document,
        "group": group,
        "field": field,
        "values": [value] if value else [],
        "metric_aliases": [],
        "unit_aliases": [],
        "scope_aliases": [],
        "reviewed": False,
        "absence": False,
        "evidence_groups": [],
        "comment": "Confirm from PDF. Replace coded categories with document wording; add evidence.",
    }


def seed(path: Path, documents: list[dict], references: Path | None = None) -> None:
    """Seed a review file once, refusing to overwrite human work."""
    if path.exists():
        raise ValueError(f"Review file already exists; edit it in place: {path}")
    references = references or ROOT.parents[1] / "test_set"
    general = csv_rows(references / "reference_general.csv")
    results = csv_rows(references / "reference_gold_results.csv")
    labels = []
    for doc in documents:
        source = next((r for r in general if r["project_code"] == doc["id"]), {})
        for group, fields in FIELDS.items():
            if group == "results":
                continue
            for field in fields:
                column = next((k for k, v in REFERENCE_FIELDS.items() if v == field), "")
                value = source.get(column, "")
                label = new_label(doc["id"], group, field)
                label["values"] = [v.strip() for v in value.split("||") if v.strip()]
                labels.append(label)
        for row in results:
            if row["project_code"] != doc["id"]:
                continue
            label = new_label(doc["id"], "results", "result", row["value"])
            label.update(
                metric_aliases=[row["metric_stated"]],
                unit_aliases=[row["unit_stated"]],
                comment=f"Reference page {row['page']} may be printed pagination; verify original PDF page. {row.get('note', '')}",
            )
            labels.append(label)
    for index, label in enumerate(labels):
        label["id"] = f"L{index + 1:04d}"
    write_json(path, {"version": 1, "labels": labels, "exhaustive": [], "judgements": {}})
