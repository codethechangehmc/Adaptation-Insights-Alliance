"""
dashboard.py - step 05 (optional): one self-contained HTML page comparing a step 04 run with the
Alliance's R pipeline and the hand-made answer key. Open it in any browser; no internet needed.

It needs:
    data/04_extracted/<run-id>/exports/results.csv      our results (step 04)
    data/05_eval/<run-id>/compare/summary.json           costs and checks (run compare.py first)
    ../test_set/                                         the answer key and R's saved output
    step05_evaluate/labels/gold_check_<run-id>.json      the hand check: for every answer-key result,
                                                         did each source really find it, and which row
                                                         shows it (see "how" inside the file)

Writes data/05_eval/<run-id>/dashboard.html.

The page's sentences and examples (dashboard_template.html) were written for run meetingsample01.
The tables, charts and counts come from the data, but after a new run, read the page and update any
example the new numbers no longer match.

Run from rag-pipeline/:
    python -m step05_evaluate.compare --run-id meetingsample01
    python -m step05_evaluate.dashboard --run-id meetingsample01
"""

import argparse
import json
import re
from datetime import date
from pathlib import Path

from paths import EVAL, EXTRACTED, REFERENCE
from step05_evaluate.compare import note_results, numbers, read_csv

HERE = Path(__file__).parent
TEMPLATE = HERE / "dashboard_template.html"
METHODS = ("hybrid", "full_parsed", "full_pdf")
METHOD_NAMES = {
    "hybrid": "Hybrid search",
    "full_parsed": "Full parsed text",
    "full_pdf": "Full PDF",
}


def r_rows(code: str, general: dict, locations: list[dict]) -> list[dict]:
    """Everything the R pipeline wrote for one report, from all three places it puts results."""
    row = general.get(code, {})
    out = []
    for i in (1, 2, 3):
        if row.get(f"result{i}", "").strip():
            out.append(
                {
                    "where": f"result{i}",
                    "value": row[f"result{i}"],
                    "text": row.get(f"result{i}_metric", ""),
                    "unit": row.get(f"result{i}_unit", ""),
                    "page": "",
                }
            )
    for value, entry in note_results(row.get("result_notes", "")):
        page = re.search(r"p(\d+)\)\s*$", entry)
        out.append(
            {
                "where": "further results (notes)",
                "value": value,
                "text": entry,
                "unit": "",
                "page": page.group(1) if page else "",
            }
        )
    for loc in locations:
        if loc["project_code"] == code and loc.get("result_value", "").strip():
            text = loc.get("result_stated", "")
            if loc.get("result_unit"):
                text = f"{text}  [unit: {loc['result_unit']}]"
            out.append(
                {
                    "where": "location sheet",
                    "value": loc["result_value"],
                    "text": text,
                    "unit": "",
                    "page": "",
                }
            )
    return out


def same_value(gold_value: str, value: str) -> bool:
    """The same number (or, for Y/N answers, the same letter)."""
    wanted = numbers(gold_value)
    return bool(wanted & numbers(value)) if wanted else value.strip() == gold_value.strip()


def gold_check(gold: list[dict], labels: dict, r_out: dict, ours: list[dict]) -> list[dict]:
    """One row per answer-key result: the hand verdict per source and the row that shows it."""
    by_key = {(item["report"], item["value"]): item for item in labels["results"]}
    rows, problems = [], []
    for g in gold:
        code, value = g["project_code"], g["value"]
        label = by_key.get((code, value))
        if label is None:
            problems.append(f"{code} {value}: no hand check in the labels file")
            continue
        row = {
            "report": code,
            "gold_value": value,
            "gold_indicator": g["metric_stated"],
            "gold_unit": g["unit_stated"],
            "gold_page": g["page"],
            "gold_note": g["note"],
            "why": label.get("why", ""),
        }
        verdict, pick = label["r"]["verdict"], label["r"]["row"]
        hit = None
        if pick:
            hit = next(
                (
                    r
                    for r in r_out[code]
                    if pick.lower() in r["text"].lower() and same_value(value, r["value"])
                ),
                None,
            )
            if hit is None:
                problems.append(f"{code} {value}: no R row with {pick!r}")
        row.update(
            {
                "r_verdict": verdict,
                "r_value": hit["value"] if hit else "",
                "r_text": hit["text"] if hit else "",
                "r_where": hit["where"] if hit else "",
                "r_page": hit["page"] if hit else "",
            }
        )
        for method in METHODS:
            verdict, pick = label[method]["verdict"], label[method]["row"]
            hit = None
            if pick:
                hit = next(
                    (
                        o
                        for o in ours
                        if o["project_code"] == code
                        and o["method"] == method
                        and pick.lower() in f"{o['metric_stated']} {o['value_stated']}".lower()
                        and same_value(value, o["value_stated"])
                    ),
                    None,
                )
                if hit is None:
                    problems.append(f"{code} {value}: no {method} row with {pick!r}")
            row.update(
                {
                    f"{method}_verdict": verdict,
                    f"{method}_value": hit["value_stated"] if hit else "",
                    f"{method}_indicator": hit["metric_stated"] if hit else "",
                    f"{method}_page": hit["page"] if hit else "",
                    f"{method}_verified": hit["verified"] if hit else "",
                }
            )
        rows.append(row)
    if problems:
        raise ValueError(
            "The hand check does not fit this run; update the labels file:\n  "
            + "\n  ".join(problems)
        )
    return rows


def verdict_tally(checked: list[dict]) -> list[dict]:
    """Count checked yes, partial and no verdicts for each comparison source."""
    tally = []
    for source in ("r",) + METHODS:
        tally.append(
            {
                "source": source,
                "total": len(checked),
                "yes": sum(c[f"{source}_verdict"] == "yes" for c in checked),
                "partial": sum(c[f"{source}_verdict"] == "partial" for c in checked),
                "no": sum(c[f"{source}_verdict"] == "no" for c in checked),
                # R finds that are not in its 3 headline slots (they are in its notes or location sheet)
                "not_headline": sum(
                    c["r_verdict"] == "yes" and not c["r_where"].startswith("result")
                    for c in checked
                )
                if source == "r"
                else None,
            }
        )

    return tally


def page_review_stats(ours: list[dict]) -> tuple[list[dict], list[dict]]:
    """Summarize page repairs and flagged values by extraction method."""
    page_repairs, review = [], []
    for method in METHODS:
        mine = [o for o in ours if o["method"] == method and o["page"]]
        repaired = [o for o in mine if o["page_repaired"] == "True"]
        shifts = {}
        for o in repaired:
            shift = int(o["page"]) - int(o["page_cited"].split(",")[0])
            shifts[shift] = shifts.get(shift, 0) + 1
        top = max(shifts.items(), key=lambda kv: kv[1]) if shifts else (None, 0)
        page_repairs.append(
            {
                "method": method,
                "rows_with_page": len(mine),
                "repaired": len(repaired),
                "right_first_time": len(mine) - len(repaired),
                "top_offset": top[0],
                "top_offset_count": top[1],
            }
        )
        flagged = [o for o in ours if o["method"] == method and o["needs_review"] == "True"]
        review.append(
            {
                "method": method,
                "flagged": len(flagged),
                "flagged_value_ok": sum(o["verified"] == "True" for o in flagged),
            }
        )

    return page_repairs, review


def run(run_id: str, labels_path: Path | None = None) -> Path:
    """Build data/05_eval/<run_id>/dashboard.html and return its path."""
    results_path = EXTRACTED / run_id / "exports" / "results.csv"
    summary_path = EVAL / run_id / "compare" / "summary.json"
    labels_path = labels_path or HERE / "labels" / f"gold_check_{run_id}.json"
    for path, fix in (
        (results_path, "run step 04"),
        (summary_path, "run compare.py"),
        (labels_path, "write the hand check"),
    ):
        if not path.exists():
            raise ValueError(f"No {path} ({fix} first).")
    summary = json.loads(summary_path.read_text(encoding="utf-8"))
    labels = json.loads(labels_path.read_text(encoding="utf-8"))
    codes = summary["reports"]
    ours = [r for r in read_csv(results_path) if r["project_code"] in codes]
    gold = [
        g for g in read_csv(REFERENCE / "reference_gold_results.csv") if g["project_code"] in codes
    ]
    general = {
        r["project_code"]: r
        for r in read_csv(REFERENCE / "pipeline_general.csv")
        if r.get("set") == "gold"
    }
    locations = read_csv(REFERENCE / "pipeline_gold_locations.csv")
    r_out = {code: r_rows(code, general, locations) for code in codes}

    checked = gold_check(gold, labels, r_out, ours)
    tally = verdict_tally(checked)

    all_results = []
    for o in ours:
        all_results.append(
            {
                "source": o["method"],
                "report": o["project_code"],
                "where": "",
                "indicator": o["metric_stated"],
                "value": o["value_stated"],
                "unit": o["unit_stated"],
                "page": o["page"],
                "page_cited": o["page_cited"],
                "page_repaired": o["page_repaired"],
                "verified": o["verified"],
                "needs_review": o["needs_review"],
                "quote": o["quote"],
            }
        )
    for code in codes:
        for r in r_out[code]:
            all_results.append(
                {
                    "source": "R pipeline",
                    "report": code,
                    "where": r["where"],
                    "indicator": r["text"],
                    "value": r["value"],
                    "unit": r["unit"] if r["where"].startswith("result") else "",
                    "page": r["page"],
                    "page_cited": "",
                    "page_repaired": "",
                    "verified": "",
                    "needs_review": "",
                    "quote": "",
                }
            )

    counts = []
    for report in list(codes) + ["All"]:
        for source in ("R pipeline",) + METHODS:
            here = [
                a
                for a in all_results
                if a["source"] == source and (report == "All" or a["report"] == report)
            ]
            counts.append(
                {
                    "report": report,
                    "source": source,
                    "rows": len(here),
                    "ones": sum(str(a["value"]).strip() == "1" for a in here),
                }
            )

    page_repairs, review = page_review_stats(ours)

    methods = []
    for key in METHODS:
        m = summary["methods"].get(key)
        if m:
            methods.append(
                {
                    "source": key,
                    "name": METHOD_NAMES[key],
                    "rows": m["rows"],
                    "cost_usd": m["cost_usd"],
                    "cost_per_report": m["cost_usd"] / len(codes),
                    "seconds": m["seconds"],
                    "verified_pct": m["verified_pct"],
                    "page_right_first_time_pct": m["page_right_first_time_pct"],
                    "needs_review_pct": m["needs_review_pct"],
                }
            )

    data = {
        "tally": tally,
        "counts": counts,
        "page_repairs": page_repairs,
        "review": review,
        "methods": methods,
        "gold_check": checked,
        "all_results": all_results,
    }
    page = TEMPLATE.read_text(encoding="utf-8")
    # "</" inside the JSON would end the <script> tag early
    page = page.replace(
        "__DATA_JSON__", json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
    )
    page = page.replace(
        "__GENERATED__",
        f"Made by rag-pipeline/step05_evaluate/dashboard.py from run {run_id} "
        f"on {date.today().isoformat()}. Hand check: {labels_path.name} "
        f"(checked {labels.get('checked_on', '?')}).",
    )
    out = EVAL / run_id / "dashboard.html"
    out.write_text(page, encoding="utf-8")
    return out


def main():
    ap = argparse.ArgumentParser(description="Write a self-contained HTML dashboard for one run.")
    ap.add_argument("--run-id", required=True, help="run folder under data/04_extracted/")
    ap.add_argument(
        "--labels",
        type=Path,
        default=None,
        help="hand-check file (default: step05_evaluate/labels/gold_check_<run-id>.json)",
    )
    args = ap.parse_args()
    try:
        out = run(args.run_id, args.labels)
    except (ValueError, OSError, KeyError) as error:
        raise SystemExit(f"Error: {error}") from error
    print(f"Wrote {out}")


if __name__ == "__main__":
    main()
