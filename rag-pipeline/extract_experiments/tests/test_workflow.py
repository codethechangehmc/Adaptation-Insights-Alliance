"""Offline workflows covering fairness, typed parser inputs, R import and paid-call safety."""

import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pymupdf
import requests

from common.api import BudgetError, Client
from common.exports import export_run
from common.files import ROOT, fingerprint, read_json, write_json
from common.inputs import full_text, load_manifest, prepare_document
from common.runner import dry_plan, execute, jobs, prepare, start_run
from common.tasks import FIELDS, GROUPS, METHODS, RESULT_CONTEXT_FIELDS
from common.workbook import export_xlsx
from evaluation.evidence import pdf_pages, quote_pages
from evaluation.r_baseline import convert, import_baseline
from evaluation.report import report
from evaluation.scoring import evaluate
from hybrid.retrieval import pack
from run import main


def result_fact() -> dict:
    """Build one achieved result with independently checkable PDF evidence."""
    return {
        **{name: "" for name in RESULT_CONTEXT_FIELDS},
        "field": "result",
        "value": "12.5",
        "value_stated": "12.5",
        "status": "present",
        "scope": "whole project",
        "derivation": "",
        "evidence": [{"quote": "12.5 hectares restored", "pages": [2]}],
        "metric": "land restored",
        "unit": "hectares",
        "value_type": "achieved",
        "category": "physical_quantity",
        "project_total": "yes",
        "in_summary": "unknown",
        "indicator_level": "outcome",
        "achievement_status": "achieved",
    }


class FakeClient:
    """Return deterministic embeddings and valid answers without HTTP or credentials."""

    def __init__(self) -> None:
        """Record extraction requests and expose an empty cost ledger."""
        self.calls: list[dict] = []
        self.ledger: list[dict] = []

    def embed(self, texts: list[str]) -> list[list[float]]:
        """Generate nonzero vectors for the complete retrieval workflow."""
        return [[1 + int(fingerprint(text)[i : i + 2], 16) for i in range(8)] for text in texts]

    def upload(self, path: Path) -> str:
        """Supply a test file ID without a real upload."""
        return "file-offline-test"

    def request(self, endpoint: str, reserve: float, tag: str, **kwargs: object) -> dict:
        """Record the request and return its group's required fields."""
        body = kwargs["json"]
        self.calls.append(body)
        group = body["text"]["format"]["name"]
        facts = (
            [result_fact()]
            if group == "results"
            else [
                {
                    "field": field,
                    "value": "",
                    "status": "not_found_in_input",
                    "scope": "",
                    "derivation": "",
                    "evidence": [],
                }
                for field in FIELDS[group]
            ]
        )
        return {
            "status": "completed",
            "output": [
                {
                    "type": "message",
                    "content": [
                        {"type": "output_text", "text": json.dumps({"facts": facts, "notes": ""})}
                    ],
                }
            ],
            "usage": {"input_tokens": 100, "output_tokens": 20},
        }


class Workflows(unittest.TestCase):
    """Protect complete experiments and consequential failures with small local fixtures."""

    def setUp(self) -> None:
        """Create disposable inputs and forbid all unmocked HTTP."""
        temporary = tempfile.TemporaryDirectory(dir=ROOT / "results")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        network = patch(
            "requests.sessions.Session.request", side_effect=AssertionError("Network forbidden")
        )
        network.start()
        self.addCleanup(network.stop)
        quiet = redirect_stdout(StringIO())
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)
        self.config = {**read_json(ROOT / "config.json"), "dimensions": 8}
        self.pdf, self.sections = self.directory / "example.pdf", self.directory / "sections.json"
        with pymupdf.open() as pdf:
            for text in (
                "Report 2019. Project P123.",
                "12.5 hectares restored",
                "Target: 90 hectares.",
            ):
                pdf.new_page().insert_text((72, 72), text)
            pdf.save(self.pdf)
        write_json(
            self.sections,
            {
                "sections": [
                    {"heading": "Results", "pages": [2, 2], "content": ["12.5 hectares restored"]}
                ]
            },
        )
        self.doc = {"id": "D1", "pdf": self.pdf, "sections": self.sections, "family": "wb_icr"}

    def benchmark(self) -> Path:
        """Write a reviewed result tuple and an explicitly complete result set."""
        path = self.directory / "review.json"
        write_json(
            path,
            {
                "labels": [
                    {
                        "id": "L1",
                        "document": "D1",
                        "group": "results",
                        "field": "result",
                        "values": ["12.5"],
                        "metric_aliases": ["land restored"],
                        "unit_aliases": ["hectares"],
                        "scope_aliases": ["whole project"],
                        "reviewed": True,
                        "evidence_groups": [[{"quote": "12.5 hectares restored", "pages": [2]}]],
                    }
                ],
                "exhaustive": [
                    {"document": "D1", "group": "results", "field": "result", "reviewed": True}
                ],
                "judgements": {},
            },
        )
        return path

    def test_all_methods_share_tasks_outputs_and_review(self) -> None:
        """Run the 45-job matrix, resume without calls and compare common exports and scores."""
        documents = [{**self.doc, "id": name} for name in ("D1", "D2", "D3")]
        prepared, errors = prepare(documents)
        self.assertEqual(errors, [])
        planned = jobs(documents, list(METHODS), list(GROUPS), 1)
        output, cache = self.directory / "run", self.directory / "cache"
        start_run(output, planned, prepared, self.config, False)
        client = FakeClient()
        self.assertTrue(execute(planned, prepared, self.config, client, output, cache))
        self.assertEqual(len(client.calls), 45)

        # Evidence delivery is the only request difference within each task.
        for group in GROUPS:
            bodies = [body for body in client.calls if body["text"]["format"]["name"] == group]
            common = [{**body, "input": body["input"][0]["content"][-1]} for body in bodies]
            self.assertTrue(all(body == common[0] for body in common))
        for body in client.calls:
            evidence = body["input"][0]["content"][0]
            if evidence["type"] == "input_file":
                self.assertEqual(evidence["detail"], "low")
        start_run(output, planned, prepared, self.config, True)
        self.assertTrue(execute(planned, prepared, self.config, client, output, cache))
        self.assertEqual(len(client.calls), 45)
        with self.assertRaisesRegex(ValueError, "changed"):
            start_run(output, planned, prepared, {**self.config, "pdf_detail": "high"}, True)

        # All methods use the same reviewed tuple, exports and method-blinded report.
        scores = evaluate(output, self.benchmark())
        for row in scores["groups"]:
            if row["group"] == "results":
                self.assertEqual(row["reviewed_prediction_accuracy"], 1)
                self.assertEqual(row["reviewed_fact_recall"], 1)
                self.assertIsNone(row["result_set_precision"])
            else:
                self.assertIsNone(row["reviewed_prediction_accuracy"])
        self.assertTrue(all(row["evidence_recall"] == 1 for row in scores["retrieval_summary"]))
        paths = report(output)
        self.assertTrue(all(path.exists() for path in paths))
        self.assertNotIn("full_pdf", paths[1].read_text(encoding="utf-8"))
        exported = read_json(output / "exports/session1.json")
        self.assertEqual(len(exported), 9)
        self.assertTrue(all(row["stage"] == "session1_raw" for row in exported))
        self.assertTrue(all(row["result1_metric_stated"] == "land restored" for row in exported))
        self.assertEqual(len(read_json(output / "exports/results.json")), 9)

    def test_parsed_methods_share_source_and_reject_partial_inputs(self) -> None:
        """Keep table evidence in both parsed methods and block divergent or missing inputs."""
        write_json(
            self.sections,
            {
                "sections": [
                    {
                        "heading": "Finance",
                        "pages": [1, 2],
                        "content": [
                            "| Source | Actual |",
                            "|---|---|",
                            "| Fund | 12.5 |",
                            "Closing statement",
                        ],
                    }
                ]
            },
        )
        document = prepare_document(self.doc)
        table = document["blocks"][0]["text"]
        self.assertEqual(len(document["blocks"]), 2)
        self.assertEqual(full_text(document).count(table), 1)
        self.assertEqual(set(document["source_hashes"]), {"pdf", "sections"})
        packet = pack(document["chunks"], list(range(len(document["chunks"]))), 500)
        self.assertIn(table, packet["text"])
        self.assertIn("Closing statement", packet["text"])
        self.assertEqual(pack(document["chunks"], [0], 1)["selected"], [])

        # Repeated heading text must not merge separate tables or expand across sections.
        write_json(
            self.sections,
            {
                "sections": [
                    {"heading": "Finance", "pages": [1, 1], "content": ["| First table |"]},
                    {"heading": "Finance", "pages": [2, 2], "content": ["| Separate table |"]},
                ]
            },
        )
        repeated = prepare_document(self.doc)
        self.assertEqual(len(repeated["blocks"]), 2)
        self.assertNotIn("Separate table", pack(repeated["chunks"], [0], 500)["text"])

        # A separate chunk source or explicitly partial parse invalidates the comparison.
        manifest = self.directory / "manifest.json"
        write_json(
            manifest,
            {
                "documents": [
                    {
                        "id": "D1",
                        "pdf": "example.pdf",
                        "sections": "sections.json",
                        "chunks": "old.jsonl",
                    }
                ]
            },
        )
        with self.assertRaisesRegex(ValueError, "derived from sections"):
            load_manifest(manifest)
        write_json(self.directory / "meta.json", {"page_range": [1, 2]})
        with self.assertRaisesRegex(ValueError, "partial"):
            prepare_document(self.doc)
        prepared, errors = prepare([{**self.doc, "sections": self.directory / "absent.json"}])
        self.assertFalse(prepared)
        self.assertIn("missing sections", errors[0])

    def test_r_and_all_python_methods_use_identical_scoring(self) -> None:
        """Import raw R, separate missing quotations and reject wrong units and duplicate facts."""
        prepared, _ = prepare([self.doc])
        planned = jobs([self.doc], list(METHODS), list(GROUPS), 1)
        output = self.directory / "paired"
        start_run(output, planned, prepared, self.config, False)
        execute(planned, prepared, self.config, FakeClient(), output, self.directory / "cache")
        raw_result = {
            "value": "12.5",
            "metric_stated": "land restored",
            "unit_stated": "hectares",
            "scope": "whole project",
            "value_type": "achieved",
            "category": "physical_quantity",
            "project_total": "yes",
            "indicator_level": "outcome",
            "page": 2,
            "status": "achieved",
        }
        paths = {}
        for group in GROUPS:
            path = self.directory / f"r_{group}.json"
            fields = {
                field: [] if field in ("funder_names", "implementor_names") else ""
                for field in FIELDS[group]
                if field != "countries"
            }
            write_json(path, {"results": [raw_result]} if group == "results" else fields)
            paths[group] = path.name
        source = self.directory / "r_manifest.json"
        write_json(
            source,
            {
                "stage": "session1_raw",
                "model": "gpt-5-mini",
                "prompt_version": "s1-v2.7",
                "documents": [{"id": "D1", "pdf": self.pdf.name, "groups": paths}],
            },
        )
        self.assertEqual(import_baseline(output, source), 5)
        benchmark = self.benchmark()
        for row in evaluate(output, benchmark)["groups"]:
            if row["group"] == "results":
                self.assertEqual(row["reviewed_prediction_accuracy"], 1)
                self.assertEqual(
                    row["quote_recording_rate"], 0 if row["method"] == "r_baseline" else 1
                )
        report(output)
        self.assertEqual(len(read_json(output / "exports/session1.json")), 4)

        # Wrong tuple components and repeated predictions cannot inflate common scores.
        for method in METHODS:
            path = output / f"t01/{method}/D1/results/result.json"
            result = read_json(path)
            result["answer"]["facts"].extend(
                [
                    result_fact(),
                    {**result_fact(), "unit": "people"},
                    {**result_fact(), "scope": "one district"},
                ]
            )
            write_json(path, result)
        for row in evaluate(output, benchmark)["groups"]:
            if row["group"] == "results" and row["method"] != "r_baseline":
                self.assertEqual(row["result_set_precision"], 0.25)
                self.assertEqual(row["result_set_recall"], 1)
        with self.assertRaisesRegex(ValueError, "already has"):
            import_baseline(output, source)
        with self.assertRaisesRegex(ValueError, "harmonised"):
            convert({"result1": "12.5"}, "results", 3)

    def test_typed_parser_evidence_gaps_and_resume(self) -> None:
        """Preserve typed evidence, expose image gaps and freeze all prompt-affecting inputs."""
        write_json(
            self.sections,
            {
                "sections": [
                    {
                        "heading": "Results",
                        "heading_path": ["Findings", "Results"],
                        "pages": [1, 3],
                        "content": [
                            {"type": "text", "text": "12.5 hectares restored", "pages": [2, 2]},
                            {
                                "type": "table",
                                "title": "Actuals",
                                "header": [["Area", "Actual"]],
                                "rows": [["Restored", "12.5"]],
                                "pages": [2, 2],
                                "suspect": ["check cells"],
                            },
                            {
                                "type": "footnote",
                                "text": "1 Area measured after completion.",
                                "page": 2,
                            },
                            {
                                "type": "figure",
                                "caption": "Land restored",
                                "labels": "12.5 ha",
                                "image": "figures/chart.png",
                                "text": "",
                                "pages": [2, 2],
                            },
                            {
                                "type": "figure",
                                "caption": None,
                                "labels": "",
                                "image": "figures/scan.png",
                                "text": "Figure: (no caption)",
                                "pages": [3, 3],
                            },
                            {
                                "type": "table",
                                "text": "",
                                "header": [],
                                "rows": [],
                                "title": None,
                                "pages": [3, 3],
                            },
                        ],
                    }
                ]
            },
        )
        meta = self.directory / "meta.json"
        write_json(
            meta,
            {
                "source_file": self.pdf.name,
                "page_range": None,
                "fixes": {"pages_without_text": [3]},
            },
        )
        document = prepare_document(self.doc)
        self.assertEqual(
            [b["type"] for b in document["blocks"]],
            ["text", "table", "footnote", "figure", "figure", "table"],
        )
        self.assertEqual(document["blocks"][2]["pages"], [2, 2])
        self.assertEqual(document["blocks"][-2]["image"], "figures/scan.png")
        self.assertEqual(document["diagnostics"]["figures_without_text"], 1)
        self.assertEqual(document["diagnostics"]["tables_without_text"], 1)
        self.assertEqual(document["diagnostics"]["parser_pages_without_text"], [3])
        self.assertEqual(document["diagnostics"]["suspect_blocks"], ["b0001"])
        packet = pack(document["chunks"], list(range(len(document["chunks"]))), 500)
        for text in ("Table: Actuals", "12.5 ha", "1 Area measured after completion."):
            self.assertIn(text, full_text(document))
            self.assertIn(text, packet["text"])
        self.assertIn("figure without parsed text", full_text(document))
        self.assertTrue(all(c["text"].strip() and c["block_id"] for c in document["chunks"]))

        # Metadata and task routing must not change underneath an existing run.
        planned = jobs([self.doc], list(METHODS), ["results"], 1)
        output = self.directory / "typed-run"
        start_run(output, planned, {"D1": document}, self.config, False)
        for changed in ({"family": "agency_evaluation"}, {"focus": "A subproject"}):
            with self.assertRaisesRegex(ValueError, "changed"):
                start_run(
                    output,
                    planned,
                    {"D1": prepare_document({**self.doc, **changed})},
                    self.config,
                    True,
                )
        write_json(meta, {"source_file": self.pdf.name, "page_range": None})
        with self.assertRaisesRegex(ValueError, "changed"):
            start_run(output, planned, {"D1": prepare_document(self.doc)}, self.config, True)

        # An oversized request fails in preflight, before credentials or paid retrieval.
        preview = dry_plan([self.doc], planned, {"D1": document}, [], self.config)
        self.assertEqual(preview["inputs"]["D1"]["diagnostics"], document["diagnostics"])
        self.assertEqual(preview["errors"], [])
        manifest, config = self.directory / "manifest.json", self.directory / "config.json"
        write_json(
            manifest,
            {"documents": [{"id": "D1", "pdf": self.pdf.name, "sections": self.sections.name}]},
        )
        write_json(config, {**self.config, "context_limit": 1})
        with (
            patch(
                "sys.argv",
                [
                    "run.py",
                    "run",
                    "--execute",
                    "--manifest",
                    str(manifest),
                    "--config",
                    str(config),
                ],
            ),
            patch("run.Client") as client,
            patch("run.load_key") as key,
        ):
            self.assertEqual(main(), 2)
            client.assert_not_called()
            key.assert_not_called()

    def test_template_exports_keep_all_reports_and_literal_values(self) -> None:
        """Export all methods, qualified/zero values, stable IDs and explicit zero/failed cases."""
        documents = [{**self.doc, "id": name} for name in ("D1", "D2", "D3")]
        prepared, errors = prepare(documents)
        self.assertEqual(errors, [])
        planned = jobs(documents, list(METHODS), ["results"], 1)
        output = self.directory / "template"
        start_run(output, planned, prepared, self.config, False)
        actual = {
            **result_fact(),
            "baseline_stated": "0",
            "target_stated": "90",
            "reporting_year": "2019",
            "location_stated": "project-wide",
        }
        bounded = {**actual, "value": "", "value_stated": ">12.5"}
        zero = {**actual, "value": "0", "value_stated": "0", "scope": "one district"}
        for job in planned:
            if job["document"] == "D3":
                write_json(
                    output / job["path"] / "result.json",
                    {"status": "failed", "error": "test failure"},
                )
                continue
            facts = [actual, actual, bounded, zero] if job["document"] == "D1" else []
            write_json(
                output / job["path"] / "result.json",
                {"status": "completed", "answer": {"facts": facts, "notes": ""}},
            )
            write_json(
                output / job["path"] / "packet.json",
                {"selected": [c["id"] for c in prepared[job["document"]]["chunks"]]},
            )
        export_run(output)
        rows = read_json(output / "exports/template_results.json")
        self.assertEqual(len(rows), 9)
        self.assertEqual(len(read_json(output / "exports/results.json")), 12)
        self.assertEqual({r["method"] for r in rows}, set(METHODS))
        plain = next(r for r in rows if r["value_stated"] == "12.5" and r["method"] == "hybrid")
        self.assertEqual(
            (plain["value"], plain["baseline"], plain["target"], plain["year"]),
            (12.5, 0, 90, 2019),
        )
        self.assertEqual(plain["unit"], "hectares")
        self.assertEqual(plain["duplicates_merged"], 1)
        self.assertTrue(plain["verified"])
        self.assertTrue(plain["chunk_id"].endswith(":c0000"))
        self.assertTrue(plain["needs_review"])  # Conflicting bounded claim still needs review.
        self.assertTrue(
            all(
                r["value"] is None and r["needs_review"]
                for r in rows
                if r["value_stated"] == ">12.5"
            )
        )
        self.assertTrue(all(r["value"] == 0 for r in rows if r["value_stated"] == "0"))
        self.assertTrue(all(not r["chunk_id"] for r in rows if r["method"] != "hybrid"))
        projects = read_json(output / "exports/projects.json")
        for project in projects:
            expected = {"D1": (3, "completed"), "D2": (0, "completed"), "D3": (0, "failed")}[
                project["project_code"]
            ]
            self.assertEqual((project["results_exported"], project["results_status"]), expected)
            self.assertTrue(
                (output / "exports" / project["project_code"] / "results.csv").is_file()
            )
        identifiers = {r["result_id"] for r in rows}
        path = output / "t01/hybrid/D1/results/result.json"
        result = read_json(path)
        result["answer"]["facts"].reverse()
        write_json(path, result)
        export_run(output)
        self.assertEqual(
            identifiers,
            {r["result_id"] for r in read_json(output / "exports/template_results.json")},
        )
        self.assertTrue(export_xlsx(output).is_file())

    def test_citations_are_matched_back_to_pdf_pages(self) -> None:
        """Move a wrong page only to the one page holding the quote; join line-end hyphens."""
        prepared, _ = prepare([self.doc])
        planned = jobs([self.doc], ["full_pdf"], ["results"], 1)
        output = self.directory / "pages"
        start_run(output, planned, prepared, self.config, False)
        printed_page = {
            **result_fact(),
            "evidence": [{"quote": "12.5 hectares restored", "pages": [3]}],
        }
        unsupported = {
            **result_fact(),
            "value": "7",
            "value_stated": "7",
            "evidence": [{"quote": "seven hectares restored", "pages": [3]}],
        }
        path = output / planned[0]["path"]
        answer = {"facts": [printed_page, unsupported], "notes": ""}
        write_json(path / "result.json", {"status": "completed", "answer": answer})
        write_json(path / "packet.json", {"text": ""})
        export_run(output)
        rows = {r["value_stated"]: r for r in read_json(output / "exports/template_results.json")}
        self.assertEqual((rows["12.5"]["page"], rows["12.5"]["verified"]), (2, True))
        self.assertIn("Cited page [3]", rows["12.5"]["review_details"])
        self.assertEqual((rows["7"]["page"], rows["7"]["verified"]), (3, False))

        hyphenated = self.directory / "hyphen.pdf"
        with pymupdf.open() as pdf:
            pdf.new_page().insert_text((72, 72), "the training im-\nproves results")
            pdf.save(hyphenated)
        self.assertEqual(quote_pages("training improves results", pdf_pages(hyphenated)), [1])

    def test_budget_and_uncertain_charges_stop_requests(self) -> None:
        """Block overspending and prevent automatic resends after ambiguous timeouts."""
        client = Client(
            self.config, self.directory / "api-run", self.directory / "cache", "fake-key"
        )
        client.session.post = Mock()
        with self.assertRaises(BudgetError):
            client.request("responses", 6, "test", json={})
        client.session.post.assert_not_called()
        client.session.post.side_effect = requests.Timeout()
        with self.assertRaisesRegex(RuntimeError, "no automatic resend"):
            client.request("responses", 1, "test", json={})
        self.assertEqual(client.spent(), 1)
        self.assertEqual(client.session.post.call_count, 1)


if __name__ == "__main__":
    unittest.main()
