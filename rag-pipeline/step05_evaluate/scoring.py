"""Reviewed-label scoring; incomplete references never imply false positives."""

from collections import defaultdict
from pathlib import Path

from common.api import usage_cost
from common.files import contains, file_hash, fingerprint, norm, read_json, write_csv, write_json
from common.rules import content_flags, fact_flags, number, scoring_fact
from evaluation.evidence import check_quote, evidence_covered, pdf_pages, prediction_id


def equivalent(got: str, accepted: list[str]) -> bool:
    """Match explicit alternatives or exact decimals, never arbitrary numeric substrings."""
    for expected in accepted:
        if norm(got) == norm(expected):
            # Punctuation normalization must not erase meaningful numeric signs/qualifiers.
            if any(c.isdigit() for c in got + expected):
                if number(got) is not None and number(expected) is not None:
                    return number(got) == number(expected)
                return got.strip().casefold() == expected.strip().casefold()
            return True
        if (
            number(got) is not None
            and number(expected) is not None
            and number(got) == number(expected)
        ):
            return True
    return False


def matches(fact: dict, label: dict) -> bool:
    """Match the field and full result tuple, requiring reviewed scope aliases."""
    if fact["field"] != label["field"] or not equivalent(fact["value"], label["values"]):
        return False
    if label["field"] != "result":
        return True
    if fact.get("value_type") != "achieved":
        return False
    if content_flags(fact):
        return False
    return all(
        label.get(key + "_aliases") and equivalent(fact.get(key, ""), label[key + "_aliases"])
        for key in ("metric", "unit", "scope")
    )


def assign(facts: list[dict], labels: list[dict], decisions: dict | None = None) -> dict[int, int]:
    """Find maximum one-to-one matches so alternatives and duplicate facts cannot inflate recall."""
    edges = [
        matching_labels(fact, labels, (decisions or {}).get(i, {})) for i, fact in enumerate(facts)
    ]
    owners: dict[int, int] = {}

    def visit(index: int, seen: set[int]) -> bool:
        """Reassign an earlier match when an alternative permits a larger matching."""
        for candidate in edges[index]:
            if candidate in seen:
                continue
            seen.add(candidate)
            if candidate not in owners or visit(owners[candidate], seen):
                owners[candidate] = index
                return True
        return False

    for index in range(len(facts)):
        visit(index, set())
    return {fact: label for label, fact in owners.items()}


def matching_labels(fact: dict, labels: list[dict], decision: dict) -> list[int]:
    """Use explicit human adjudication or conservative tuple matching."""
    if decision.get("verdict") == "incorrect":
        return []
    if decision.get("verdict") == "correct" and decision.get("label"):
        return [i for i, label in enumerate(labels) if label["id"] == decision["label"]]
    return [i for i, label in enumerate(labels) if matches(fact, label)]


def decisions_for(job: dict, facts: list[dict], benchmark: dict) -> dict:
    """Resolve blind review tokens or full prediction IDs for this exact answer."""
    decisions = benchmark.get("judgements", {})
    out = {}
    for index, fact in enumerate(facts):
        key = prediction_id(job, fact, index)
        out[index] = decisions.get(key, decisions.get(fingerprint(key)[:12], {}))
    return out


def retrieval_rows(job: dict, document: dict, packet: dict, labels: list[dict]) -> list[dict]:
    """Measure evidence coverage at rank cutoffs, final packing and parsing ceiling."""
    rows = []
    chunks = {c["id"]: c for c in document["chunks"]}
    for label in labels:
        if label.get("absence"):
            continue
        for channel, ids in packet.get("rankings", {}).items():
            for cutoff in (5, 10, 20):
                rows.append(
                    {
                        "job": job["id"],
                        "label": label["id"],
                        "channel": channel,
                        "cutoff": cutoff,
                        "covered": evidence_covered(label, [chunks[i] for i in ids[:cutoff]]),
                    }
                )
        for channel, units in [
            ("packet", [chunks[i] for i in packet.get("selected", [])]),
            ("parsed", document["blocks"]),
        ]:
            rows.append(
                {
                    "job": job["id"],
                    "label": label["id"],
                    "channel": channel,
                    "cutoff": "all",
                    "covered": evidence_covered(label, units),
                }
            )
    return rows


def score_job(
    job: dict, result: dict, document: dict, packet: dict, benchmark: dict
) -> tuple[list[dict], list[dict]]:
    """Score reviewed claims and expose evidence failures for human adjudication."""
    labels = [
        label_item
        for label_item in benchmark["labels"]
        if label_item.get("reviewed")
        and label_item["document"] == job["document"]
        and label_item["group"] == job["group"]
    ]
    pages = pdf_pages(Path(document["pdf"]))
    facts = result["answer"]["facts"]
    positive = [label_item for label_item in labels if not label_item.get("absence")]
    decisions = decisions_for(job, facts, benchmark)
    mapping = assign([scoring_fact(fact) for fact in facts], positive, decisions)
    rows = []
    metadata = {key: job[key] for key in ("document", "method", "trial", "group")}
    metadata["job"] = job["id"]
    for index, fact in enumerate(facts):
        prediction = prediction_id(job, fact, index)
        decision = decisions[index]
        label = positive[mapping[index]] if index in mapping else None
        view = scoring_fact(fact)
        verdict = prediction_verdict(view, label, decision, labels, benchmark, job)
        checks = [check_quote(e, pages) for e in fact["evidence"]]
        input_support = (
            None
            if job["method"] == "full_pdf" or packet.get("input_available") is False
            else all(contains(e["quote"], packet["text"]) for e in fact["evidence"])
        )
        rows.append(
            {
                **metadata,
                "prediction": prediction,
                "field": fact["field"],
                "value": fact["value"],
                "compared_value": view["value"],
                "verdict": verdict,
                "label": label["id"] if label else "",
                "citation_checks": checks,
                "in_supplied_text": input_support if fact["evidence"] else None,
                "flags": fact_flags(fact),
                "quote_recorded": any(e["quote"].strip() for e in fact["evidence"]),
                "populated": bool(view["value"]),
                "set_complete": complete_set(job, fact["field"], benchmark),
            }
        )
    for index, label in enumerate(positive):
        found = index in mapping.values()
        rows.append(
            {
                **metadata,
                "prediction": "",
                "field": label["field"],
                "value": "",
                "verdict": "label_found" if found else "label_missing",
                "diagnosis": missing_diagnosis(label, document, packet, job, found),
                "label": label["id"],
                "citation_checks": [],
                "in_supplied_text": None,
                "flags": [],
                "set_complete": complete_set(job, label["field"], benchmark),
            }
        )
    retrieval = retrieval_rows(job, document, packet, labels) if job["method"] == "hybrid" else []
    return rows, retrieval


def missing_diagnosis(label: dict, document: dict, packet: dict, job: dict, found: bool) -> str:
    """Separate evidence preparation, retrieval, and answer errors when labels permit it."""
    if found:
        return "found"
    parsed = evidence_covered(label, document["blocks"])
    if parsed is False:
        return "parse_gap" if job["method"] != "full_pdf" else "review_pdf_evidence"
    if job["method"] == "hybrid":
        selected = set(packet.get("selected", []))
        units = [c for c in document["chunks"] if c["id"] in selected]
        if evidence_covered(label, units) is False:
            return "retrieval_miss"
    return "extraction_or_attribution_error" if parsed else "needs_evidence_annotation"


def validate_benchmark(benchmark: dict) -> None:
    """Reject reviewed labels that cannot support their claimed scoring semantics."""
    labels = benchmark["labels"]
    if len({label["id"] for label in labels}) != len(labels):
        raise ValueError("Benchmark label IDs must be unique.")
    for label in labels:
        if not label.get("reviewed"):
            continue
        if label.get("absence"):
            if label.get("values"):
                raise ValueError(f"{label['id']}: an absence label cannot contain values.")
        elif not label.get("values"):
            raise ValueError(f"{label['id']}: reviewed positive labels need accepted values.")
        elif label["field"] == "result":
            if not all(label.get(key + "_aliases") for key in ("metric", "unit", "scope")):
                raise ValueError(
                    f"{label['id']}: result labels need metric, unit and scope aliases."
                )


def prediction_verdict(
    fact: dict, label: dict | None, decision: dict, labels: list[dict], benchmark: dict, job: dict
) -> str:
    """Distinguish correctness, abstention, and unknown precision under partial annotation."""
    if decision.get("verdict") in ("correct", "incorrect"):
        return decision["verdict"]
    if fact["field"] == "result" and content_flags(fact):
        return "rule_violation"
    if not fact["value"]:
        return (
            "correct_abstention"
            if any(
                label_item.get("absence") and label_item["field"] == fact["field"]
                for label_item in labels
            )
            else "abstained"
        )
    if label:
        return "correct"
    if any(
        label_item.get("absence") and label_item["field"] == fact["field"] for label_item in labels
    ):
        return "incorrect"
    return "incorrect" if complete_set(job, fact["field"], benchmark) else "needs_review"


def complete_set(job: dict, field: str, benchmark: dict) -> bool:
    """Check whether a human explicitly declared this field's reference set exhaustive."""
    return any(
        e.get("reviewed")
        and e["document"] == job["document"]
        and e["group"] == job["group"]
        and e["field"] == field
        for e in benchmark.get("exhaustive", [])
    )


def evaluate(run_dir: Path, benchmark_path: Path) -> dict:
    """Write detailed and aggregate scores without making API calls."""
    benchmark = read_json(benchmark_path)
    labels = benchmark["labels"]
    validate_benchmark(benchmark)
    validate_exhaustive(benchmark)
    run = read_json(run_dir / "run.json")
    rows, retrieval, failures, performance = [], [], [], []
    for job in run["jobs"]:
        path = run_dir / job["path"] / "result.json"
        if not path.exists() or read_json(path).get("status") != "completed":
            failures.append(job["id"])
            continue
        document = read_json(run_dir / "prepared" / f"{job['document']}.json")
        if file_hash(Path(document["pdf"])) != document["source_hashes"]["pdf"]:
            raise ValueError(
                f"{job['document']}: PDF changed since the run; do not score against a different source."
            )
        packet = read_json(run_dir / job["path"] / "packet.json")
        result = read_json(path)
        values, coverage = score_job(job, result, document, packet, benchmark)
        rows.extend(values)
        retrieval.extend(coverage)
        usage = result.get("usage")
        performance.append(
            {
                "job": job["id"],
                "method": job["method"],
                "group": job["group"],
                "trial": job["trial"],
                "seconds": result.get("seconds"),
                "usage": usage,
                "extraction_cost_usd": usage_cost(usage, run["config"]) if usage else None,
            }
        )
    summary = summarize(rows)
    output = run_dir / "evaluation"
    columns = [
        "job",
        "document",
        "method",
        "trial",
        "group",
        "prediction",
        "field",
        "value",
        "compared_value",
        "verdict",
        "label",
        "citation_checks",
        "in_supplied_text",
        "flags",
        "quote_recorded",
        "populated",
        "diagnosis",
        "set_complete",
    ]
    write_csv(output / "claims.csv", rows, columns)
    write_csv(
        output / "retrieval.csv", retrieval, ["job", "label", "channel", "cutoff", "covered"]
    )
    report = {
        "benchmark": str(benchmark_path),
        "reviewed_labels": sum(bool(label_item.get("reviewed")) for label_item in labels),
        "failed_or_missing_jobs": failures,
        "groups": summary,
        "retrieval_summary": summarize_retrieval(retrieval),
        "performance": performance,
        "note": "Development pilot. Unknown labels and empty-empty agreement do not enter accuracy. Quote occurrence is not semantic correctness.",
    }
    write_json(output / "summary.json", report)
    write_json(output / "benchmark_used.json", benchmark)
    return report


def validate_exhaustive(benchmark: dict) -> None:
    """Require reviewed membership before treating unmatched predictions as false positives."""
    for entry in benchmark.get("exhaustive", []):
        if not entry.get("reviewed"):
            continue
        members = [
            label
            for label in benchmark["labels"]
            if all(label[key] == entry[key] for key in ("document", "group", "field"))
        ]
        if not members or any(not label.get("reviewed") for label in members):
            raise ValueError("An exhaustive set needs reviewed members or a reviewed absence.")


def summarize_retrieval(rows: list[dict]) -> list[dict]:
    """Average only evidence-labelled retrieval cases, retaining their small denominators."""
    grouped = defaultdict(list)
    for row in rows:
        if row["covered"] is not None:
            grouped[(row["channel"], row["cutoff"])].append(row["covered"])
    return [
        {
            "channel": channel,
            "cutoff": cutoff,
            "labelled_cases": len(values),
            "evidence_recall": sum(values) / len(values),
        }
        for (channel, cutoff), values in grouped.items()
    ]


def summarize(rows: list[dict]) -> list[dict]:
    """Aggregate counts by method, task and trial, keeping unreviewed claims visible."""
    grouped = defaultdict(list)
    for row in rows:
        grouped[(row["method"], row["group"], row["trial"])].append(row)
    out = []
    for (method, group, trial), items in grouped.items():
        counts = {
            key: sum(r["verdict"] == key for r in items)
            for key in (
                "correct",
                "incorrect",
                "rule_violation",
                "needs_review",
                "abstained",
                "correct_abstention",
                "label_found",
                "label_missing",
            )
        }
        scored = counts["correct"] + counts["incorrect"] + counts["rule_violation"]
        total_labels = counts["label_found"] + counts["label_missing"]
        complete = bool(items) and all(r.get("set_complete") for r in items)
        precision = counts["correct"] / scored if scored else 0.0
        recall = counts["label_found"] / total_labels if total_labels else 0.0
        populated = [r for r in items if r.get("prediction") and r.get("populated")]
        recorded = [
            check for r in populated for check in r["citation_checks"] if check != "not_recorded"
        ]
        out.append(
            {
                "method": method,
                "group": group,
                "trial": trial,
                "populated_facts": len(populated),
                "quote_recording_rate": sum(bool(r.get("quote_recorded")) for r in populated)
                / len(populated)
                if populated
                else None,
                "recorded_citation_verification_rate": sum(
                    c in ("exact", "normalized", "joined_passages") for c in recorded
                )
                / len(recorded)
                if recorded
                else None,
                **counts,
                "reviewed_prediction_accuracy": counts["correct"] / scored if scored else None,
                "reviewed_fact_recall": counts["label_found"] / total_labels
                if total_labels
                else None,
                "result_set_precision": precision if group == "results" and complete else None,
                "result_set_recall": recall if group == "results" and complete else None,
                "result_set_f1": (
                    2 * precision * recall / (precision + recall) if precision + recall else 0.0
                )
                if group == "results" and complete
                else None,
            }
        )
    return out
