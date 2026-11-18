"""
compare.py - step 05 (optional): how a step 04 run compares with the Alliance's R pipeline and
with Lolita's hand-made gold answers, for the reports in the run. No API calls, no cost.

The questions it answers, per report and per method:
    How much output?   result rows delivered (R: its result1-3 slots plus location-sheet values)
    How many of the gold results were found?   "gold recall": a gold value counts as found if the
                       same number appears among that source's results for that report. The same
                       lenient rule is used for R and for us, so the comparison is fair, but it
                       checks numbers only, not that the indicator is the right one.
    How trustworthy?   verified (the value is printed on the cited page), page right first time
                       (not repaired), rows needing review
    What did it cost?  from ledger.json; embeddings count towards hybrid

Writes data/05_eval/<run-id>/compare/:
    summary.json     everything below, for the meeting dashboard
    by_report.csv    one row per report x source (R pipeline, each method)
    gold_matches.csv one row per gold value: which sources found it, and where we found it

Run from rag-pipeline/:
    python -m step05_evaluate.compare --run-id pilot03
"""
import argparse
import csv
import json
import re
from collections import defaultdict
from pathlib import Path

from paths import EVAL, EXTRACTED, REFERENCE

# "10 000" (groups of three digits split by spaces) is one number; otherwise digits with commas.
NUMBER_RE = re.compile(r"(?<!\d)\d{1,3}(?:[ \u00a0\u202f]\d{3}(?!\d))+(?:\.\d+)?|\d[\d,]*(?:\.\d+)?")
STOPWORDS = {"the", "and", "for", "with", "from", "that", "which", "who", "are", "was", "were",
             "number", "share", "total", "project", "projects", "level", "per", "into", "under"}


def numbers(text: str) -> set:
    """Every number written in text, as floats: '379,162.00' -> 379162.0, '>1000' -> 1000.0."""
    out = set()
    for match in NUMBER_RE.findall(text or ""):
        try:
            out.add(float(re.sub(r"[,\s\u00a0\u202f]", "", match)))
        except ValueError:
            pass
    return out


def words(text: str) -> set:
    return {w for w in re.findall(r"[a-z]{3,}", (text or "").casefold()) if w not in STOPWORDS}


def is_match(gold_value: str, gold_metric: str, value: str, metric: str) -> bool:
    """Does a (value, metric) pair count as finding this gold result?

    A gold value with digits: the same number appears in value. A gold value without digits
    (Yes, No, N): the same value AND at least two words of the gold metric, otherwise every
    "N" in a report would count. The same rule is applied to the R pipeline and to us.
    """
    wanted = numbers(gold_value)
    if wanted:
        return bool(wanted & numbers(value))
    same = (value or "").strip().casefold() == (gold_value or "").strip().casefold()
    return same and len(words(gold_metric) & words(metric)) >= 2


def read_csv(path: Path) -> list[dict]:
    with open(path, encoding="utf-8-sig", newline="") as stream:
        return list(csv.DictReader(stream))


def write_csv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    columns = list(dict.fromkeys(key for row in rows for key in row)) or ["empty"]
    with open(path, "w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=columns)
        writer.writeheader()
        writer.writerows(rows)


def r_pipeline(codes: list[str]) -> dict:
    """The R pipeline's output for these reports: its 3 headline result slots plus location values,
    each as a (value, metric) pair."""
    general = [r for r in read_csv(REFERENCE / "pipeline_general.csv") if r.get("set") == "gold"]
    locations = read_csv(REFERENCE / "pipeline_gold_locations.csv")
    out = {}
    for code in codes:
        row = next((r for r in general if r["project_code"] == code), {})
        slots = [(row.get(f"result{i}", ""), row.get(f"result{i}_metric", "")) for i in (1, 2, 3)]
        located = [(r.get("result_value", ""), r.get("result_metric") or r.get("result_stated", ""))
                   for r in locations if r["project_code"] == code]
        out[code] = {
            "headline_slots": sum(1 for v, _ in slots if v.strip()),
            "location_values": sum(1 for v, _ in located if v.strip()),
            "pairs": [(v, m) for v, m in slots + located if v.strip()],
        }
        out[code]["rows"] = len(out[code]["pairs"])
    return out


def percent(part: int, whole: int):
    return round(100 * part / whole, 1) if whole else None


def run(run_id: str) -> dict:
    """Compare one step 04 run with the R pipeline and the gold answers; write and return the summary."""
    run_dir = EXTRACTED / run_id
    results_path = run_dir / "exports" / "results.csv"
    if not results_path.exists():
        raise ValueError(f"No {results_path}. Run step 04 (with --execute) first.")
    run_info = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
    codes = list(dict.fromkeys(job["document"] for job in run_info["jobs"]))
    methods = list(dict.fromkeys(job["method"] for job in run_info["jobs"]))
    results = read_csv(results_path)
    gold = [g for g in read_csv(REFERENCE / "reference_gold_results.csv") if g["project_code"] in codes]
    r_out = r_pipeline(codes)

    # ---- per report x source: output and gold recall ----
    ours = defaultdict(list)
    for row in results:
        ours[(row["project_code"], row["method"])].append(row)
    by_report, matches = [], []
    for code in codes:
        gold_here = [g for g in gold if g["project_code"] == code]
        sources = {"R pipeline": r_out[code]["pairs"]}
        for method in methods:
            sources[method] = [(r["value_stated"], r["metric_stated"]) for r in ours[(code, method)]]
        for name, pairs in sources.items():
            found = sum(
                1 for g in gold_here
                if any(is_match(g["value"], g["metric_stated"], v, m) for v, m in pairs)
            )
            by_report.append({
                "report": code,
                "source": name,
                "rows": r_out[code]["rows"] if name == "R pipeline" else len(ours[(code, name)]),
                "gold_results": len(gold_here),
                "gold_found": found,
            })
        for g in gold_here:
            line = {"report": code, "gold_value": g["value"], "gold_metric": g["metric_stated"],
                    "gold_page": g.get("page", ""),
                    "R pipeline": any(is_match(g["value"], g["metric_stated"], v, m) for v, m in sources["R pipeline"])}
            for method in methods:
                hit = next((r for r in ours[(code, method)]
                            if is_match(g["value"], g["metric_stated"], r["value_stated"], r["metric_stated"])), None)
                line[method] = bool(hit)
                line[f"{method}_page"] = hit["page"] if hit else ""
                line[f"{method}_metric"] = hit["metric_stated"] if hit else ""
            matches.append(line)

    # ---- per method: output kinds, trust, cost, time ----
    ledger = json.loads((run_dir / "ledger.json").read_text(encoding="utf-8")) if (run_dir / "ledger.json").exists() else []
    cost = defaultdict(float)
    for entry in ledger:
        amount = entry.get("cost_usd", entry["reserved_usd"])
        if entry["endpoint"] == "responses":
            cost[entry["tag"].split("/")[1]] += amount
        elif entry["endpoint"] == "embeddings":
            cost["hybrid"] += amount
    seconds = defaultdict(float)
    for job in run_info["jobs"]:
        path = run_dir / job["path"] / "result.json"
        if path.exists():
            seconds[job["method"]] += json.loads(path.read_text(encoding="utf-8")).get("seconds") or 0
    per_method = {}
    for method in methods:
        rows = [r for r in results if r["method"] == method]
        with_page = [r for r in rows if r["page"]]
        per_method[method] = {
            "rows": len(rows),
            "by_value_type": {k: sum(1 for r in rows if r.get("value_type") == k) for k in ("achieved", "context", "milestone")},
            "gold_found": sum(b["gold_found"] for b in by_report if b["source"] == method),
            "gold_results": len(gold),
            "verified_pct": percent(sum(r["verified"] == "True" for r in rows), len(rows)),
            "page_right_first_time_pct": percent(sum(r.get("page_repaired") != "True" for r in with_page), len(with_page)),
            "needs_review_pct": percent(sum(r["needs_review"] == "True" for r in rows), len(rows)),
            "cost_usd": round(cost[method], 4),
            "seconds": round(seconds[method], 1),
        }
    r_total = {
        "rows": sum(v["rows"] for v in r_out.values()),
        "headline_slots": sum(v["headline_slots"] for v in r_out.values()),
        "gold_found": sum(b["gold_found"] for b in by_report if b["source"] == "R pipeline"),
        "gold_results": len(gold),
    }
    summary = {
        "run_id": run_id,
        "reports": codes,
        "methods": per_method,
        "r_pipeline": r_total,
        "by_report": by_report,
        "notes": [
            "gold_found: a gold value counts as found if the same number appears among that source's "
            "results for the report (for Yes/No values: the same value and at least two words of the "
            "gold metric). Same rule for R and for us; it does not check the indicator itself.",
            "R rows = its 3 headline result slots plus values in its location sheet.",
            "verified: the value is printed on the page given. page right first time: the model's own "
            "page was correct (not repaired).",
        ],
    }
    out = EVAL / run_id / "compare"
    out.mkdir(parents=True, exist_ok=True)
    (out / "summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    write_csv(out / "by_report.csv", by_report)
    write_csv(out / "gold_matches.csv", matches)
    return summary


def main():
    ap = argparse.ArgumentParser(description="Compare a step 04 run with the R pipeline and the gold answers.")
    ap.add_argument("--run-id", required=True, help="run folder under data/04_extracted/")
    args = ap.parse_args()
    try:
        summary = run(args.run_id)
    except (ValueError, OSError, KeyError) as error:
        raise SystemExit(f"Error: {error}")
    print(f"{'source':12} {'rows':>5} {'gold found':>11}  per report")
    for source in ["R pipeline"] + list(summary["methods"]):
        rows = [b for b in summary["by_report"] if b["source"] == source]
        found = sum(b["gold_found"] for b in rows)
        total = sum(b["gold_results"] for b in rows)
        detail = "  ".join(f"{b['report']} {b['gold_found']}/{b['gold_results']} ({b['rows']} rows)" for b in rows)
        print(f"{source:12} {sum(b['rows'] for b in rows):5} {found:5}/{total:<5}  {detail}")
    for method, m in summary["methods"].items():
        print(f"{method:12} verified {m['verified_pct']}% | page right first time {m['page_right_first_time_pct']}% "
              f"| needs review {m['needs_review_pct']}% | ${m['cost_usd']} | {m['seconds']}s")
    print(f"Details: {EVAL / args.run_id / 'compare'}")


if __name__ == "__main__":
    main()
