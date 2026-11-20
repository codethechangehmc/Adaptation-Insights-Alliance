"""Offline tests for steps 03-05: shared inputs, page checks, review flags, exports, cache and budget.

Run from rag-pipeline/ (no network, no API key, no cost):
    python -m unittest discover -s tests
"""

import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import numpy as np
import pymupdf
import requests

from step03_chunk.chunk import PaperChunker
from step04_extract import extract
from step04_extract.api import BudgetError, Client
from step04_extract.evidence import check_quote, pdf_pages, quote_pages
from step04_extract.exports import export_run
from step04_extract.files import CONFIG, fingerprint, read_json, write_json
from step04_extract.inputs import full_text, load_manifest, prepare_document
from step04_extract.retrieval import embeddings, pack
from step04_extract.runner import dry_plan, execute, jobs, prepare, start_run
from step04_extract.tasks import FIELDS, GROUPS, METHODS, RESULT_CONTEXT_FIELDS
from step04_extract.workbook import export_xlsx
from step05_evaluate.compare import is_match, note_results, numbers
from step05_evaluate.report import report
from step05_evaluate.scoring import evaluate


def result_fact(**changes) -> dict:
    """One achieved result with checkable PDF evidence (page 2 says '12.5 hectares restored')."""
    fact = {
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
    return {**fact, **changes}


def chunk_line(
    paper: str, index: int, text: str, pages: list, kind: str = "text", **extra
) -> dict:
    """One line of chunks.jsonl in step 03's format."""
    return {
        "chunk_id": f"{paper}_c{index:04d}",
        "paper_id": paper,
        "type": kind,
        "section_kind": extra.get("section_kind", "body"),
        "heading_path": extra.get("heading_path", ["Results"]),
        "pages": pages,
        "text": text,
        "embed_text": f"Document: {paper} | Section: Results\n\n{text}",
        "suspect_reasons": extra.get("suspect_reasons", []),
    }


class FakeClient:
    """Deterministic embeddings and valid answers, without HTTP or credentials."""

    def __init__(self) -> None:
        self.calls: list[dict] = []
        self.ledger: list[dict] = []

    def embed(self, texts: list[str]) -> list[list[float]]:
        return [[1 + int(fingerprint(text)[i : i + 2], 16) for i in range(8)] for text in texts]

    def upload(self, path: Path) -> str:
        return "file-offline-test"

    def request(self, endpoint: str, reserve: float, tag: str, **kwargs: object) -> dict:
        body = kwargs["json"]
        self.calls.append(body)
        group = body["text"]["format"]["name"]
        facts = (
            [result_fact()]
            if group == "results"
            else [
                {
                    "field": f,
                    "value": "",
                    "status": "not_found_in_input",
                    "scope": "",
                    "derivation": "",
                    "evidence": [],
                }
                for f in FIELDS[group]
            ]
        )
        text = json.dumps({"facts": facts, "notes": ""})
        return {
            "status": "completed",
            "output": [{"type": "message", "content": [{"type": "output_text", "text": text}]}],
            "usage": {"input_tokens": 100, "output_tokens": 20},
        }


class Workflows(unittest.TestCase):
    """Small local fixtures in the data layout: raw/<paper>.pdf, parsed/<paper>/, chunks/<paper>/."""

    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        for name, folder in (("RAW", "raw"), ("PARSED", "parsed"), ("CHUNKS", "chunks")):
            moved = patch(f"step04_extract.inputs.{name}", self.directory / folder)
            moved.start()
            self.addCleanup(moved.stop)
        network = patch(
            "requests.sessions.Session.request", side_effect=AssertionError("Network forbidden")
        )
        network.start()
        self.addCleanup(network.stop)
        quiet = redirect_stdout(StringIO())
        quiet.__enter__()
        self.addCleanup(quiet.__exit__, None, None, None)
        self.config = {**read_json(CONFIG / "config.json"), "dimensions": 8}
        self.manifest = self.directory / "manifest.json"
        self.docs = [self.make_report(f"D{i}", f"paper{i}") for i in (1, 2, 3)]
        self.doc = self.docs[0]

    def make_report(self, report_id: str, paper: str, extra_page: str = "") -> dict:
        """A 3-page PDF (plus extra_page), its sections.json and chunks.jsonl; returns the manifest entry."""
        pdf = self.directory / "raw" / f"{paper}.pdf"
        pdf.parent.mkdir(parents=True, exist_ok=True)
        pages = ["Report 2019. Project P123.", "12.5 hectares restored", "Target: 90 hectares."]
        with pymupdf.open() as document:
            for text in pages + ([extra_page] if extra_page else []):
                document.new_page().insert_text((72, 72), text)
            document.save(pdf)
        write_json(
            self.directory / "parsed" / paper / "sections.json",
            {
                "sections": [
                    {"heading": "Results", "pages": [2, 2], "content": ["12.5 hectares restored"]}
                ]
            },
        )
        self.write_chunks(
            paper,
            [
                chunk_line(paper, 0, "Report 2019. Project P123.", [1, 1]),
                chunk_line(paper, 1, "12.5 hectares restored", [2, 2], section_kind="annex"),
                chunk_line(paper, 2, "Target: 90 hectares.", [3, 3]),
            ],
        )
        entries = read_json(self.manifest)["documents"] if self.manifest.exists() else []
        entries.append({"id": report_id, "paper": paper, "family": "wb_icr", "focus": ""})
        write_json(self.manifest, {"documents": entries})
        return load_manifest(self.manifest, [report_id])[0]

    def write_chunks(self, paper: str, lines: list[dict]) -> None:
        path = self.directory / "chunks" / paper / "chunks.jsonl"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("".join(json.dumps(line) + "\n" for line in lines), encoding="utf-8")

    def benchmark(self) -> Path:
        """A reviewed result label for D1 and a result set declared complete."""
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

    def run_fake(self, documents: list[dict], methods=METHODS, groups=GROUPS, name="run") -> Path:
        prepared, errors = prepare(documents)
        self.assertEqual(errors, [])
        planned = jobs(documents, list(methods), list(groups), 1)
        output = self.directory / name
        start_run(output, planned, prepared, self.config, False)
        self.assertTrue(
            execute(planned, prepared, self.config, FakeClient(), output, self.directory / "cache")
        )
        return output

    # ------------------------------------------------------------------------------------------

    def test_all_methods_share_tasks_outputs_and_review(self) -> None:
        """45 jobs differ only in evidence; resume is free; scores, exports and pages for all."""
        prepared, errors = prepare(self.docs)
        self.assertEqual(errors, [])
        planned = jobs(self.docs, list(METHODS), list(GROUPS), 1)
        output, cache = self.directory / "run", self.directory / "cache"
        start_run(output, planned, prepared, self.config, False)
        client = FakeClient()
        self.assertTrue(execute(planned, prepared, self.config, client, output, cache))
        self.assertEqual(len(client.calls), 45)
        for group in GROUPS:
            bodies = [b for b in client.calls if b["text"]["format"]["name"] == group]
            common = [{**b, "input": b["input"][0]["content"][-1]} for b in bodies]
            self.assertTrue(all(b == common[0] for b in common))
        start_run(output, planned, prepared, self.config, True)
        self.assertTrue(execute(planned, prepared, self.config, client, output, cache))
        self.assertEqual(len(client.calls), 45)  # resume: nothing sent again
        with self.assertRaisesRegex(ValueError, "changed"):
            start_run(output, planned, prepared, {**self.config, "pdf_detail": "high"}, True)

        out_dir = self.directory / "eval"
        scores = evaluate(output, self.benchmark(), out_dir)
        for row in scores["groups"]:
            if row["group"] == "results":
                self.assertEqual(row["reviewed_prediction_accuracy"], 1)
                self.assertEqual(row["reviewed_fact_recall"], 1)
        self.assertTrue((out_dir / "scores" / "summary.json").is_file())
        pages = report(output, out_dir)
        self.assertTrue(all(p.exists() for p in pages))
        self.assertNotIn("full_pdf", pages[1].read_text(encoding="utf-8"))  # blind review
        self.assertIn("Evaluation summary", pages[0].read_text(encoding="utf-8"))

        tables = export_run(output)
        self.assertEqual(len(tables["results"]), 9)  # 3 reports x 3 methods x 1 result
        self.assertEqual(len(tables["projects"]), 9)
        exports = output / "exports"
        self.assertEqual(
            sorted(p.relative_to(exports).as_posix() for p in exports.rglob("*.csv")),
            sorted(
                ["results.csv", "projects.csv"]
                + [
                    f"paper{i}/{f}.csv"
                    for i in (1, 2, 3)
                    for f in ("facts", "results", "projects")
                ]
            ),
        )
        self.assertFalse(list(exports.rglob("*.json")))  # no JSON copies, no R-style tables
        facts = (exports / "paper1" / "facts.csv").read_text(encoding="utf-8-sig")
        self.assertIn("project_title", facts)  # every task's facts, not just results
        hybrid = next(
            r for r in tables["results"] if r["method"] == "hybrid" and r["project_code"] == "D1"
        )
        self.assertEqual((hybrid["chunk_id"], hybrid["section"]), ("paper1_c0001", "annex"))

    def test_inputs_come_from_parsed_sections_and_step03_chunks(self) -> None:
        """full_parsed reads sections.json, hybrid reads chunks.jsonl; bad inputs are refused."""
        document = prepare_document(self.doc)
        self.assertEqual(len(document["blocks"]), 1)
        self.assertEqual(
            [c["id"] for c in document["chunks"]], ["paper1_c0000", "paper1_c0001", "paper1_c0002"]
        )
        self.assertEqual(document["chunks"][1]["section_kind"], "annex")
        self.assertTrue(document["chunks"][1]["search_text"].startswith("Document: paper1"))
        self.assertEqual(set(document["source_hashes"]), {"pdf", "sections", "chunks"})
        packet = pack(document["chunks"], [1, 0, 2], 500)
        self.assertIn("12.5 hectares restored", packet["text"])
        self.assertEqual(pack(document["chunks"], [0], 1)["selected"], [])
        self.assertIn("12.5 hectares restored", full_text(document))

        # Selection by project code or paper id; unknown names and missing/partial inputs fail.
        self.assertEqual(
            [d["id"] for d in load_manifest(self.manifest, ["paper2", "D3"])], ["D2", "D3"]
        )
        with self.assertRaisesRegex(ValueError, "Not in the manifest"):
            load_manifest(self.manifest, ["H001"])
        (self.directory / "chunks" / "paper2" / "chunks.jsonl").unlink()
        prepared, errors = prepare([self.docs[1]])
        self.assertFalse(prepared)
        self.assertIn("missing chunks", errors[0])
        write_json(self.directory / "parsed" / "paper1" / "meta.json", {"page_range": [1, 2]})
        with self.assertRaisesRegex(ValueError, "partial"):
            prepare_document(self.doc)

    def test_typed_parser_evidence_gaps_and_frozen_inputs(self) -> None:
        """Typed blocks and gap diagnostics; a run refuses changed inputs; preflight blocks big requests."""
        sections = self.directory / "parsed" / "paper1" / "sections.json"
        write_json(
            sections,
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
        meta = sections.parent / "meta.json"
        write_json(
            meta,
            {
                "source_file": "paper1.pdf",
                "page_range": None,
                "fixes": {"pages_without_text": [3]},
            },
        )
        document = prepare_document(self.doc)
        self.assertEqual(
            [b["type"] for b in document["blocks"]],
            ["text", "table", "footnote", "figure", "figure", "table"],
        )
        self.assertEqual(document["diagnostics"]["figures_without_text"], 1)
        self.assertEqual(document["diagnostics"]["tables_without_text"], 1)
        self.assertEqual(document["diagnostics"]["parser_pages_without_text"], [3])
        self.assertEqual(document["diagnostics"]["suspect_blocks"], ["b0001"])
        for text in ("Table: Actuals", "12.5 ha", "1 Area measured after completion."):
            self.assertIn(text, full_text(document))
        self.assertIn("figure without parsed text", full_text(document))

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
        self.write_chunks(
            "paper1", [chunk_line("paper1", 0, "12.5 hectares restored, rechunked", [2, 2])]
        )
        with self.assertRaisesRegex(ValueError, "changed"):  # new chunks = new run
            start_run(output, planned, {"D1": prepare_document(self.doc)}, self.config, True)

        preview = dry_plan([self.doc], planned, {"D1": document}, [], self.config)
        self.assertEqual(preview["errors"], [])
        config_dir = self.directory / "config"
        write_json(config_dir / "config.json", {**self.config, "context_limit": 1})
        with (
            patch("step04_extract.extract.CONFIG", config_dir),
            patch("step04_extract.extract.MANIFEST", self.manifest),
            patch("step04_extract.extract.Client") as client,
            patch("step04_extract.extract.load_key") as key,
        ):
            with self.assertRaisesRegex(ValueError, "input errors"):
                extract.run(documents=["D1"], execute=True, run_id="blocked")
            client.assert_not_called()
            key.assert_not_called()

    def test_exports_keep_all_reports_and_literal_values(self) -> None:
        """All methods, qualified and zero values, stable IDs, zero/failed reports, workbook."""
        prepared, errors = prepare(self.docs)
        self.assertEqual(errors, [])
        planned = jobs(self.docs, list(METHODS), ["results"], 1)
        output = self.directory / "template"
        start_run(output, planned, prepared, self.config, False)
        actual = result_fact(
            baseline_stated="0",
            target_stated="90",
            reporting_year="2019",
            location_stated="project-wide",
        )
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
        tables = export_run(output)
        rows = tables["results"]
        self.assertEqual(len(rows), 9)  # 3 unique claims x 3 methods
        self.assertEqual(len(tables["facts"]), 12)  # 4 raw facts x 3 methods
        plain = next(r for r in rows if r["value_stated"] == "12.5" and r["method"] == "hybrid")
        self.assertEqual(
            (plain["value"], plain["baseline"], plain["target"], plain["year"]),
            (12.5, 0, 90, 2019),
        )
        self.assertEqual(
            (plain["unit"], plain["duplicates_merged"], plain["verified"]), ("hectares", 1, True)
        )
        self.assertEqual(
            (plain["chunk_id"], plain["page_cited"], plain["page_repaired"]),
            ("paper1_c0001", "2", False),
        )
        self.assertTrue(plain["needs_review"])  # conflicts with the >12.5 claim
        self.assertTrue(all(r["value"] is None for r in rows if r["value_stated"] == ">12.5"))
        self.assertTrue(all(r["value"] == 0 for r in rows if r["value_stated"] == "0"))
        self.assertTrue(all(not r["chunk_id"] for r in rows if r["method"] != "hybrid"))
        for project in tables["projects"]:
            expected = {"D1": (3, "completed"), "D2": (0, "completed"), "D3": (0, "failed")}[
                project["project_code"]
            ]
            self.assertEqual((project["results_exported"], project["results_status"]), expected)
        for paper in ("paper1", "paper2", "paper3"):
            self.assertTrue((output / "exports" / paper / "results.csv").is_file())
        identifiers = {r["result_id"] for r in rows}
        path = output / "t01/hybrid/D1/results/result.json"
        result = read_json(path)
        result["answer"]["facts"].reverse()
        write_json(path, result)
        tables = export_run(output)
        self.assertEqual(identifiers, {r["result_id"] for r in tables["results"]})
        self.assertEqual(
            export_xlsx(output, tables["results"], tables["projects"]).name, "results.xlsx"
        )

    def test_page_repair_is_recorded(self) -> None:
        """A wrong page moves only to the one page holding quote + value, and the move is visible."""
        planned = jobs([self.doc], ["full_pdf", "hybrid"], ["results"], 1)
        prepared, _ = prepare([self.doc])
        output = self.directory / "pages"
        start_run(output, planned, prepared, self.config, False)
        wrong_page = result_fact(evidence=[{"quote": "12.5 hectares restored", "pages": [3]}])
        unsupported = result_fact(
            value="7",
            value_stated="7",
            metric="other land",
            evidence=[{"quote": "seven hectares restored", "pages": [3]}],
        )
        for job in planned:
            write_json(
                output / job["path"] / "result.json",
                {
                    "status": "completed",
                    "answer": {"facts": [wrong_page, unsupported], "notes": ""},
                },
            )
            write_json(
                output / job["path"] / "packet.json", {"text": "", "selected": ["paper1_c0001"]}
            )
        rows = export_run(output)["results"]
        moved = next(r for r in rows if r["value_stated"] == "12.5" and r["method"] == "hybrid")
        self.assertEqual(
            (moved["page_cited"], moved["page"], moved["page_repaired"], moved["verified"]),
            ("3", 2, True, True),
        )
        self.assertEqual(moved["chunk_id"], "paper1_c0001")  # the chunk link survives the repair
        self.assertFalse(moved["needs_review"])  # a repaired page is a note, not a problem
        self.assertIn("note: cited page [3]", moved["review_details"])
        missing = next(r for r in rows if r["value_stated"] == "7")
        self.assertEqual(
            (missing["page"], missing["verified"], missing["page_repaired"]), (3, False, False)
        )
        self.assertTrue(missing["needs_review"])

        hyphenated = self.directory / "hyphen.pdf"
        with pymupdf.open() as pdf:
            pdf.new_page().insert_text((72, 72), "the training im-\nproves results")
            pdf.save(hyphenated)
        self.assertEqual(quote_pages("training improves results", pdf_pages(hyphenated)), [1])

    def test_labelled_values_and_review_flags(self) -> None:
        """Context and milestone rows are kept with their value_type; only real problems need review."""
        doc = self.make_report("D4", "paper4", extra_page="Plan adopted: Yes")  # page 4
        planned = jobs([doc], ["full_parsed"], ["results"], 1)
        prepared, _ = prepare([doc])
        output = self.directory / "labels"
        start_run(output, planned, prepared, self.config, False)
        facts = [
            result_fact(metric="a brand new metric"),  # vocabulary note only
            result_fact(
                value="90",
                value_stated="90",
                metric="target area",
                value_type="context",
                evidence=[{"quote": "Target: 90 hectares.", "pages": [3]}],
            ),
            result_fact(
                value="",
                value_stated="Yes",
                metric="plan adopted",
                value_type="milestone",
                evidence=[{"quote": "Plan adopted: Yes", "pages": [4]}],
            ),
            # "Yes" is printed on page 4, but this quote isn't: a wordy value alone doesn't verify.
            result_fact(
                value="",
                value_stated="Yes",
                metric="unsupported milestone",
                value_type="milestone",
                evidence=[{"quote": "this sentence is not in the report", "pages": [4]}],
            ),
            result_fact(value="12.5", value_stated="12.5", metric="a target", value_type="target"),
        ]
        write_json(
            output / planned[0]["path"] / "result.json",
            {"status": "completed", "answer": {"facts": facts, "notes": ""}},
        )
        write_json(output / planned[0]["path"] / "packet.json", {"text": ""})
        rows = {r["metric_stated"]: r for r in export_run(output)["results"]}
        self.assertFalse(rows["a brand new metric"]["needs_review"])
        self.assertIn("note: new metric", rows["a brand new metric"]["review_details"])
        self.assertEqual(
            (rows["target area"]["value_type"], rows["target area"]["needs_review"]),
            ("context", False),
        )
        self.assertEqual(
            (rows["plan adopted"]["verified"], rows["plan adopted"]["needs_review"]), (True, False)
        )
        self.assertEqual(
            (
                rows["unsupported milestone"]["verified"],
                rows["unsupported milestone"]["needs_review"],
            ),
            (False, True),
        )
        self.assertTrue(
            rows["a target"]["needs_review"]
        )  # a target exported as a result is a problem
        self.assertIn("not_actual_result", rows["a target"]["review_details"])

    def test_embedding_cache_is_one_file_and_survives_a_crash(self) -> None:
        """One .npz per report; vectors are saved per batch, so a rerun only pays for the rest."""
        path = self.directory / "cache" / "embeddings" / "D1.npz"
        texts = [f"text number {i}" for i in range(100)]
        config = {"embedding_model": "m", "dimensions": 8}

        class Flaky(FakeClient):
            def __init__(self, fail_on: int) -> None:
                super().__init__()
                self.batches, self.sent, self.fail_on = 0, 0, fail_on

            def embed(self, batch: list[str]) -> list[list[float]]:
                self.batches += 1
                if self.batches == self.fail_on:
                    raise RuntimeError("network died")
                self.sent += len(batch)
                return super().embed(batch)

        first = Flaky(fail_on=3)
        with self.assertRaisesRegex(RuntimeError, "network died"):
            embeddings(texts, first, path, config)
        with np.load(path) as saved:
            self.assertEqual(len(saved["keys"]), first.sent)
        second = Flaky(fail_on=0)
        matrix = embeddings(texts, second, path, config)
        self.assertEqual(
            (matrix.shape, second.sent, first.sent + second.sent), ((100, 8), 36, 100)
        )
        third = Flaky(fail_on=0)
        embeddings(texts, third, path, config)
        self.assertEqual(third.sent, 0)
        self.assertEqual([p.name for p in path.parent.iterdir()], ["D1.npz"])

        # A damaged cache must fail before an unnecessary paid request can be made.
        with path.open("wb") as stream:
            np.savez(stream, keys=np.array(["orphan-key"]), vectors=np.ones((2, 8)))
        with self.assertRaises(ValueError):
            embeddings(texts, third, path, config)
        self.assertEqual(third.sent, 0)

    def test_chunker_marks_pages_inside_split_tables(self) -> None:
        """A table crossing a page break gets a (PDF page N) row and exact pages per piece."""
        rows = [[f"Indicator {i}", str(i)] for i in range(6)]
        item = {
            "type": "table",
            "title": "Results",
            "header": [["Indicator", "Actual"]],
            "rows": rows,
            "row_pages": [55, 55, 55, 56, 56, 56],
            "pages": [55, 56],
        }
        settings = {
            "target_tokens": 450,
            "max_tokens": 600,
            "min_tokens": 100,
            "max_table_tokens": 1500,
            "footnote_cap": 150,
            "header_min_pages": 3,
        }
        chunker = PaperChunker("P", "P", lambda text: len(text.split()), settings)
        chunker.add_table(item, None)
        text = chunker.chunks[0]["text"]
        self.assertIn("| (PDF page 56) |", text)
        self.assertLess(text.index("Indicator 2"), text.index("(PDF page 56)"))
        self.assertLess(text.index("(PDF page 56)"), text.index("Indicator 3"))
        self.assertEqual(chunker.chunks[0]["pages"], [55, 56])

        small = PaperChunker(
            "P", "P", lambda text: len(text.split()), {**settings, "max_table_tokens": 12}
        )
        small.add_table(item, None)  # forced to split into pieces
        self.assertEqual(small.chunks[0]["pages"], [55, 55])
        self.assertEqual(small.chunks[-1]["pages"], [56, 56])
        old = PaperChunker("P", "P", lambda text: len(text.split()), settings)
        old.add_table({k: v for k, v in item.items() if k != "row_pages"}, None)
        self.assertNotIn("(PDF page", old.chunks[0]["text"])  # older sections.json still works
        self.assertEqual(old.chunks[0]["pages"], [55, 56])

        # Incomplete page metadata must not silently discard the final table row.
        with self.assertRaises(ValueError):
            old.add_table({**item, "row_pages": item["row_pages"][:-1]}, None)

    def test_table_row_quotes_and_compare_rules(self) -> None:
        """A table row quote passes when its label and cells are on the page, even read column by
        column; compare reads '10 000' as one number and matches Yes/No only with the metric."""
        table_pdf = self.directory / "table.pdf"
        with (
            pymupdf.open() as pdf
        ):  # the text layer lists values, then dates, like World Bank ICRs
            pdf.new_page().insert_text(
                (72, 72),
                "Technologies generated\nNumber\n0.00\n115.00\n175.00\n"
                "14-Mar-2013\n14-Mar-2013\n31-Jan-2020",
            )
            pdf.save(table_pdf)
        pages = pdf_pages(table_pdf)
        row = "| Technologies generated | Number | 0.00 14-Mar-2013 | 115.00 14-Mar-2013 |  | 175.00 31-Jan-2020 |"
        self.assertEqual(check_quote({"quote": row, "pages": [1]}, pages), "table_cells")
        wrong_label = row.replace("Technologies generated", "Farmers trained daily")
        self.assertEqual(
            check_quote({"quote": wrong_label, "pages": [1]}, pages), "not_found_needs_review"
        )
        self.assertEqual(
            check_quote({"quote": row.replace("175.00", "999.00"), "pages": [1]}, pages),
            "not_found_needs_review",
        )

        self.assertEqual(numbers("nearly ten thousand (10 000)"), {10000.0})
        self.assertEqual(numbers("in 10 2019 surveys"), {10.0, 2019.0})
        self.assertEqual(numbers("379,162.00 and >1000"), {379162.0, 1000.0})
        self.assertTrue(
            is_match(
                "N",
                "SLM Knowledge Platform up and running",
                "N",
                "SLM Knowledge Platform operational",
            )
        )
        self.assertFalse(
            is_match(
                "N", "SLM Knowledge Platform up and running", "N", "Communication strategy updated"
            )
        )
        self.assertTrue(is_match("10000", "farmers who benefited", "10 000", "farm managers"))

        notes = (
            "Document notes: target revised. | further results: 175 Technologies generated "
            "(Regional (all crops), p39); 35; 26; 44 contracts by type (breakdown; goods, p12); "
            "nearly 3,000 km of roads (rural, p8) | funding_mechanism_portion recoded"
        )
        self.assertEqual([v for v, _ in note_results(notes)], ["175", "35", "3,000"])
        self.assertEqual(note_results("no further results here"), [])

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
