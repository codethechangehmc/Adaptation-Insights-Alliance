"""Map raw extraction to the supplied result columns without replacing source wording."""

import re
from collections import Counter
from pathlib import Path

from step04_extract.files import CONFIG, contains, fingerprint, norm, read_json, write_csv
from step04_extract.rules import content_flags, number
from step04_extract.tasks import GROUPS
from step04_extract.evidence import check_quote, pdf_pages, quote_pages

SCHEMA = read_json(CONFIG / "results_schema.json")
RESULT_COLUMNS = SCHEMA["columns"] + [
    "method",
    "trial",
    "value_type",
    "page_cited",
    "page_repaired",
    "scope",
    "source_block_id",
    "review_details",
    "duplicates_merged",
]
PROJECT_COLUMNS = [
    "project_code",
    "paper_id",
    "method",
    "trial",
    "model",
    "project_title",
    "project_id",
    "project_lead_name",
    "publication_year",
    "start_year",
    "closure_year",
    "countries",
    "scope_stated",
    "location_count",
    "rationale_project",
    "target_beneficiary_stated",
    "GESI_project",
    "budget_total",
    "budget_lead_share",
    "disbursed",
    "currency",
    "instrument_stated",
    "funder_names",
    "implementor_names",
    "results_exported",
    *[group + "_status" for group in GROUPS],
    "notes",
    "parse_warnings",
]
ALIASES = {
    "result_metric": {
        "direct project beneficiaries": "direct beneficiaries",
        "female beneficiaries": "women beneficiaries",
    },
    "result_unit": {
        "number": "quantity",
        "numbers": "quantity",
        "%": "percentage",
        "percent": "percentage",
        "ha": "hectares",
        "hectare": "hectares",
        "people": "individuals",
        "persons": "individuals",
        "participants": "individuals",
        "household": "households",
        "tonnes": "tons",
        "tonne": "tons",
        "kilograms": "kg",
    },
    "target_beneficiary": {
        "smallholder farmers": "smallholder farmer",
        "farmers": "producer",
        "households": "household",
        "artisanal fishers": "artisanal fisher",
    },
}


def canonical(value: str, listing: str) -> str:
    """Accept exact normalized options or the explicit aliases, never fuzzy matches."""
    options = {norm(option): option for option in SCHEMA["lists"][listing]}
    aliases = {norm(key): val for key, val in ALIASES.get(listing, {}).items() if norm(key)}
    key = "%" if value.strip() == "%" else norm(value)
    if not key:
        return ""
    if key == "%" and listing == "result_unit":
        return "percentage"
    return options.get(key, aliases.get(key, ""))


def numeric(value: str) -> int | float | None:
    """Parse an exact stated number, retaining percent points and rejecting bounds/ranges."""
    parsed = number(value.strip().removesuffix("%"))
    if parsed is None:
        return None
    return int(parsed) if parsed == parsed.to_integral() else float(parsed)


def unique_claims(facts: list[dict]) -> list[tuple[dict, str, int]]:
    """Merge exact repeated claims only, retaining conflicting values and all their evidence."""
    grouped = {}
    for fact in facts:
        if fact["field"] != "result" or not (fact["value"] or fact.get("value_stated")):
            continue
        identity = {
            key: value for key, value in fact.items() if key not in ("evidence", "derivation")
        }
        key = fingerprint(identity)
        if key not in grouped:
            grouped[key] = ({**fact, "evidence": list(fact["evidence"])}, key, 0)
            continue
        previous, _, count = grouped[key]
        previous["evidence"] = list(
            {fingerprint(e): e for e in previous["evidence"] + fact["evidence"]}.values()
        )
        grouped[key] = (previous, key, count + 1)
    return list(grouped.values())


def section_of(document: dict, page: int, stated: str) -> str:
    """body / annex / references, from step 03's chunk tags, for every method alike.

    Uses the chunk on that page that contains the value, or else any chunk on that page.
    """
    on_page = [c for c in document["chunks"] if c["pages"][0] <= page <= c["pages"][1]]
    with_value = [c for c in on_page if contains(stated, c["text"])]
    chosen = (with_value or on_page)[:1]
    return chosen[0].get("section_kind", "") if chosen else ""


def provenance(
    fact: dict, document: dict, job: dict, packet: dict, pages: tuple[str, ...]
) -> dict:
    """Check cited PDF text and associate evidence with passages actually supplied to retrieval."""
    cited = sorted(
        {
            p
            for e in fact["evidence"]
            for p in e["pages"]
            if type(p) is int and 1 <= p <= len(pages)
        }
    )
    stated = fact.get("value_stated") or fact["value"]
    # A value without digits (Yes, No, N) appears on almost any page, so for those the
    # fact's own quote must be on the page too.
    wordy = not any(ch.isdigit() for ch in stated)
    found = [
        p
        for p in cited
        if contains(stated, pages[p - 1])
        and (
            not wordy
            or any(len(norm(e["quote"])) >= 8 and contains(e["quote"], pages[p - 1]) for e in fact["evidence"])
        )
    ]

    # Full PDF answers often cite the printed page label, not the PDF page (P001 and P009
    # are off by their front matter, pilot 2026-11-05). Use the page where the fact's own
    # quote and value are string-matched, but only when exactly one page fits.
    relocated_from = []
    if not found:
        located = {
            p
            for e in fact["evidence"]
            for p in quote_pages(e["quote"], pages)
            if contains(stated, pages[p - 1])
        }
        if len(located) == 1:
            relocated_from, found = cited, sorted(located)
    primary = next(
        (
            p
            for p in found
            if any(p in e["pages"] and contains(stated, e["quote"]) for e in fact["evidence"])
        ),
        None,
    )
    primary = primary or next(iter(found or cited), None)
    candidates = document["blocks"]
    if job["method"] == "hybrid":
        candidates = [c for c in document["chunks"] if c["id"] in packet.get("selected", [])]
    matched = [
        b
        for b in candidates
        if primary
        and b["pages"][0] <= primary <= b["pages"][1]
        and contains(stated, b["text"])
        and any(
            len(norm(e["quote"])) >= 8
            and (primary in e["pages"] or primary in quote_pages(e["quote"], pages))
            and contains(e["quote"], b["text"])
            for e in fact["evidence"]
        )
    ]
    matched.sort(key=lambda b: b["type"] != "table")
    block = next(iter(matched), {})
    repeats = [
        p
        for p in found
        if p != primary
        and any(p in e["pages"] and contains(stated, e["quote"]) for e in fact["evidence"])
    ]
    return {
        "page": primary,
        "page_cited": ",".join(map(str, cited)),
        "page_repaired": bool(relocated_from),   # value not on any cited page; moved to where it is
        "also_pages": ",".join(map(str, repeats)),
        "quote": " ... ".join(dict.fromkeys(e["quote"] for e in fact["evidence"] if e["quote"])),
        "chunk_id": block["id"]
        if block and job["method"] == "hybrid"
        else "",
        "source_block_id": block.get("block_id", block.get("id", "")),
        "source_kind": "text" if block.get("type") == "footnote" else block.get("type", ""),
        "section": section_of(document, primary, stated) if primary else "",
        "verified": bool(found),
        "relocated_from": relocated_from,
        "quote_checks": [check_quote(e, pages) for e in fact["evidence"]],
        "suspect": bool(block.get("suspect")),
    }


# Values the model labels on purpose as something other than an achieved result. They are kept
# in results.csv with their value_type, so being "not an actual result" is not a problem for them.
LABELLED_VALUE_TYPES = {"context", "milestone"}


def review_flags(fact: dict, row: dict, source: dict) -> tuple[list[tuple[str, str]], list[str]]:
    """Split the automatic checks in two.

    problems: the row might be wrong, so a person should check it (sets needs_review).
    notes:    to-dos that don't make the row wrong: a new metric or unit for the vocabulary,
              a qualified value like ">1000", a repaired page. Written to review_details only.
    """
    content = [
        flag
        for flag in content_flags(fact)
        if flag != "not_plain_numeric"
        and not (flag == "not_actual_result" and fact.get("value_type") in LABELLED_VALUE_TYPES)
    ]
    # Quote checks (evidence.check_quote): a quote that exists nowhere in the PDF, or a page that
    # doesn't exist, is a problem. A real quote on another page, or one too short to check, is a note.
    checks = source["quote_checks"]
    bad_quotes = [c for c in checks if c in ("not_found_needs_review", "invalid_page")]
    odd_quotes = [c for c in checks if c not in ("exact", "normalized", "joined_passages") and c not in bad_quotes]
    problem_checks = [
        (not row["verified"], "not_on_page", "Stated value not found on a cited PDF page"),
        (source["suspect"], "suspect_table", "Matched parser block has suspect-table flags"),
        (not checks, "other", "No evidence quoted"),
        (bool(bad_quotes), "other", "Quote not found in the PDF: " + ", ".join(bad_quotes)),
        (bool(content), "other", "Content flags: " + ", ".join(content)),
    ]
    note_checks = [
        (
            bool(source["relocated_from"]),
            f"note: cited page {source['relocated_from']}; value found on page {row['page']}",
        ),
        (bool(odd_quotes), "note: quote check " + ", ".join(dict.fromkeys(odd_quotes))),
        (row["metric"].startswith("CANDIDATE:"), "note: new metric (not in the vocabulary yet)"),
        (row["value"] is None, "note: value is qualified or not a plain number"),
        (not row["unit"], "note: unit not in the vocabulary"),
        (
            bool(fact.get("beneficiary_stated")) and not row["target_beneficiary"],
            "note: beneficiary not in the vocabulary",
        ),
        (not row["source_kind"], "note: no parsed block matched this evidence"),
    ]
    problems = [(reason, detail) for failed, reason, detail in problem_checks if failed]
    notes = [detail for failed, detail in note_checks if failed]
    return problems, notes


def template_row(
    fact: dict,
    identity: str,
    duplicates: int,
    document: dict,
    job: dict,
    packet: dict,
    pages: tuple[str, ...],
) -> dict:
    """Fill the template columns from literal fields and deterministic checks."""
    source = provenance(fact, document, job, packet, pages)
    row = dict.fromkeys(RESULT_COLUMNS, "")
    row.update(
        result_id=f"{Path(document['pdf']).stem}_{job['method']}_t{job['trial']:02d}_{identity[:16]}",
        paper_id=Path(document["pdf"]).stem,
        project_code=job["document"],
        method=job["method"],
        trial=job["trial"],
        duplicates_merged=duplicates,
        scope=fact["scope"],
        metric_stated=fact["metric"],
        metric=canonical(fact["metric"], "result_metric") or f"CANDIDATE: {fact['metric']}",
        result_level=canonical(fact["indicator_level"], "result_level"),
        value_stated=fact.get("value_stated", ""),
        value=numeric(fact.get("value_stated") or fact["value"]),
        unit_stated=fact["unit"],
        unit=canonical(fact["unit"], "result_unit"),
        baseline=numeric(fact.get("baseline_stated", "")),
        target=numeric(fact.get("target_stated", "")),
        year=int(fact["reporting_year"])
        if re.fullmatch(r"\d{4}", fact.get("reporting_year", ""))
        else None,
        location=fact.get("location_stated", ""),
        target_beneficiary=canonical(fact.get("beneficiary_stated", ""), "target_beneficiary"),
        intervention=fact.get("intervention_stated", ""),
        value_type=fact.get("value_type", ""),
        **{key: value for key, value in source.items() if key in RESULT_COLUMNS},
    )
    problems, notes = review_flags(fact, row, source)
    row.update(
        needs_review=bool(problems),
        review_reason=problems[0][0] if problems else "",
        review_details="; ".join([detail for _, detail in problems] + notes),
    )
    return row


def mark_conflicts(rows: list[dict]) -> None:
    """Flag differing claims on the same indicator/scope instead of choosing the latest value."""
    claims = {}
    for row in rows:
        key = tuple(
            row[k]
            for k in (
                "project_code",
                "method",
                "trial",
                "metric_stated",
                "unit_stated",
                "scope",
                "location",
                "year",
            )
        )
        claims.setdefault(key, []).append(row)
    for members in claims.values():
        if len({row["value_stated"] for row in members}) > 1:
            for row in members:
                row["needs_review"] = True
                row["review_reason"] = row["review_reason"] or "duplicate_check"
                row["review_details"] += (
                    "; Different values share this indicator/location/year; check population and scope"
                )


def export_template(run_dir: Path, projects: list[dict]) -> tuple[list[dict], list[dict]]:
    """Write results.csv and projects.csv, combined and per report (including reports with
    zero or failed results). Returns (result rows, project rows)."""
    run = read_json(run_dir / "run.json")
    rows, documents, texts = [], {}, {}
    for doc_id in dict.fromkeys(j["document"] for j in run["jobs"]):
        document = read_json(run_dir / "prepared" / f"{doc_id}.json")
        documents[doc_id] = document
        texts[doc_id] = pdf_pages(Path(document["pdf"]))
    for job in run["jobs"]:
        path = run_dir / job["path"] / "result.json"
        if job["group"] != "results" or not path.exists():
            continue
        result = read_json(path)
        if result["status"] != "completed":
            continue
        packet = read_json(run_dir / job["path"] / "packet.json")
        for fact, identity, duplicates in unique_claims(result["answer"]["facts"]):
            rows.append(
                template_row(
                    fact,
                    identity,
                    duplicates,
                    documents[job["document"]],
                    job,
                    packet,
                    texts[job["document"]],
                )
            )
    mark_conflicts(rows)
    counts = Counter((r["project_code"], r["method"], r["trial"]) for r in rows)
    project_rows = [
        {
            **{key: project.get(key, "") for key in PROJECT_COLUMNS},
            "project_code": project["project_code_hint"],
            "paper_id": Path(project["document"]).stem,
            "results_exported": counts[
                (project["project_code_hint"], project["method"], project["trial"])
            ],
            "notes": " | ".join(
                project.get(g + "_notes", "") for g in GROUPS if project.get(g + "_notes")
            ),
            "parse_warnings": " | ".join(documents[project["project_code_hint"]]["warnings"]),
        }
        for project in projects
    ]
    # Excel receives typed numeric project fields while raw exports keep model strings.
    for project in project_rows:
        for field in (
            "publication_year",
            "start_year",
            "closure_year",
            "location_count",
            "budget_total",
            "budget_lead_share",
            "disbursed",
        ):
            value = str(project[field])
            project[field] = numeric(value) if number(value) is not None else project[field]
    output = run_dir / "exports"
    write_csv(output / "results.csv", rows, RESULT_COLUMNS)
    write_csv(output / "projects.csv", project_rows, PROJECT_COLUMNS)
    for doc_id, document in documents.items():
        folder = output / Path(document["pdf"]).stem       # per report, named by paper id
        write_csv(folder / "results.csv", [r for r in rows if r["project_code"] == doc_id], RESULT_COLUMNS)
        write_csv(
            folder / "projects.csv",
            [r for r in project_rows if r["project_code"] == doc_id],
            PROJECT_COLUMNS,
        )
    return rows, project_rows
