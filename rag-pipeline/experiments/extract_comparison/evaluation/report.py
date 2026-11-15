"""Static, escaped comparison pages with local PDF links and no hosted services."""

import html
import os
from pathlib import Path
from urllib.parse import quote

from common.exports import export_run
from common.files import fingerprint, read_json, write_json
from evaluation.evidence import prediction_id

STYLE = """body{font:15px system-ui;margin:2rem;color:#182337;background:#f7f8fa}
table{border-collapse:collapse;width:100%;table-layout:fixed;background:white;margin-bottom:2rem}
th,td{border:1px solid #d5dce5;padding:1rem;vertical-align:top;overflow-wrap:anywhere}
th{background:#e9eef5;text-align:left}small{color:#526278}blockquote{border-left:3px solid #bccada;
margin:.6rem 0;padding:.3rem .7rem}h3{margin:.5rem 0}details{margin:.5rem 0}a{color:#1258a0}
.missing{color:#a23724}pre{white-space:pre-wrap}nav{margin:1rem 0}section{scroll-margin-top:1rem}"""


def escape(value: object) -> str:
    """Escape every document/model supplied value before embedding it in HTML."""
    return html.escape(str(value))


def fact_html(fact: dict, prediction: str, pdf: Path, output: Path) -> str:
    """Render a fact and its evidence without exposing a method name in blind review."""
    token = fingerprint(prediction)[:12]
    parts = [
        f"<h3>{escape(fact['field'])}</h3><strong>{escape(fact['value'] or '(empty)')}</strong>",
        f"<div>{escape(fact.get('metric', ''))} {escape(fact.get('unit', ''))}</div>",
        f"<small>{escape(fact['scope'])} | {escape(fact['status'])} | review {token}</small>",
    ]
    relative = quote(os.path.relpath(pdf, output.parent).replace("\\", "/"), safe="/:")
    for evidence in fact["evidence"]:
        links = " ".join(f'<a href="{relative}#page={p}">PDF p{p}</a>' for p in evidence["pages"])
        parts.append(f"<blockquote>{escape(evidence['quote'])}<br>{links}</blockquote>")
    if fact["derivation"]:
        parts.append(f"<div>Derivation: {escape(fact['derivation'])}</div>")
    return "\n".join(parts)


def cell(job: dict | None, run_dir: Path, output: Path, review_map: dict) -> str:
    """Show a completed answer or an explicit missing/failed job."""
    if job is None:
        return '<span class="missing">Not scheduled</span>'
    path = run_dir / job["path"] / "result.json"
    if not path.exists():
        return '<span class="missing">Not run</span>'
    result = read_json(path)
    if result["status"] != "completed":
        return f'<span class="missing">{escape(result["status"])}: {escape(result.get("error", ""))}</span>'
    doc = read_json(run_dir / "prepared" / f"{job['document']}.json")
    parts = []
    for index, fact in enumerate(result["answer"]["facts"]):
        prediction = prediction_id(job, fact, index)
        review_map[fingerprint(prediction)[:12]] = prediction
        parts.append(fact_html(fact, prediction, Path(doc["pdf"]), output))
    parts.append(f"<p>{escape(result['answer']['notes'])}</p>")
    if result.get("checks"):
        parts.append(
            f"<details><summary>Rule checks</summary><pre>{escape(result['checks'])}</pre></details>"
        )
    return "\n<hr>\n".join(parts)


def report(run_dir: Path) -> list[Path]:
    """Write analysis and blinded review pages for all scheduled jobs."""
    run = read_json(run_dir / "run.json")
    export_run(run_dir)
    directory = run_dir / "reports"
    directory.mkdir(parents=True, exist_ok=True)
    methods = sorted(
        {job["method"] for job in run["jobs"]}, key=lambda method: fingerprint([run["id"], method])
    )
    mapping = {method: f"Method {chr(65 + i)}" for i, method in enumerate(methods)}
    review_map, paths = {}, []
    keys = list(dict.fromkeys((j["document"], j["group"], j["trial"]) for j in run["jobs"]))
    for blind in (False, True):
        output = directory / ("review.html" if blind else "comparison.html")
        title = "Blinded extraction review" if blind else "Extraction comparison"
        parts = [
            f"<!doctype html><html><head><meta charset='utf-8'><title>{title}</title><style>{STYLE}</style></head><body>",
            f"<h1>{title}</h1><p>Development pilot. Quote occurrence is not proof of correctness.</p>",
        ]
        if not blind:
            inputs = {
                document: read_json(run_dir / "prepared" / f"{document}.json")
                for document in dict.fromkeys(j["document"] for j in run["jobs"])
            }
            diagnostics = {
                name: {"diagnostics": doc.get("diagnostics", {}), "warnings": doc["warnings"]}
                for name, doc in inputs.items()
            }
            parts.append(
                f"<details><summary>Input preparation and parse gaps</summary><pre>{escape(diagnostics)}</pre></details>"
            )
            if run.get("baselines"):
                parts.append(
                    f"<details open><summary>Baseline conditions</summary><pre>{escape(run['baselines'])}</pre></details>"
                )
            ledger = (
                read_json(run_dir / "ledger.json") if (run_dir / "ledger.json").exists() else []
            )
            cost = sum(r.get("cost_usd", r["reserved_usd"]) for r in ledger)
            parts.append(
                f"<p>Recorded charges plus unresolved reservations: US${cost:.4f}. "
                "<a href='review.html'>Open blinded review</a></p>"
            )
            summary_path = run_dir / "evaluation" / "summary.json"
            if summary_path.exists():
                parts.append(
                    f"<details><summary>Evaluation summary</summary><pre>{escape(summary_path.read_text(encoding='utf-8'))}</pre></details>"
                )
        for document, group, trial in keys:
            parts.append(
                f"<section><h2>{escape(document)} / {escape(group)} / trial {trial}</h2><table><tr>"
            )
            parts.extend(f"<th>{escape(mapping[m] if blind else m)}</th>" for m in methods)
            parts.append("</tr><tr>")
            for method in methods:
                job = next(
                    (
                        j
                        for j in run["jobs"]
                        if (j["document"], j["group"], j["trial"], j["method"])
                        == (document, group, trial, method)
                    ),
                    None,
                )
                parts.append("<td>" + cell(job, run_dir, output, review_map) + "</td>")
            parts.append("</tr></table></section>")
        output.write_text("\n".join(parts) + "</body></html>", encoding="utf-8")
        paths.append(output)
    write_json(directory / "review_key.json", {"methods": mapping, "predictions": review_map})
    return paths
