"""
parse.py - PDF -> Docling JSON + cleaned markdown + sectioned JSON, one folder per paper.

Run from rag-pipeline/:
    python parse.py                  # every PDF in data/raw -> data/parsed/<paper_id>/
    python parse.py --pages 1-10     # quick test slice, same folders (meta.json records the pages)
    python parse.py --only cif_01    # one paper (file stem)
    python parse.py --force          # redo papers that are already done
    python parse.py --reprocess      # re-run ONLY the cleanup from saved docling.json (seconds, no Docling needed)

Per-paper outputs (data/parsed/<paper_id>/):
    docling.json    native Docling document (pages, bboxes, cell spans) - the source of truth
    raw.md          Docling's markdown, untouched (for before/after comparison)
    clean.md        rendered from docling.json by postprocess.py (spans fixed, footnotes kept, furniture dropped)
    sections.json   clean.md split by headings, with heading path + page numbers (input for chunking)
    meta.json       run info + fix counts; written LAST, so it doubles as the "done" marker

All cleanup logic (text cleaning, tables, sections) lives in postprocess.py. This file only
runs Docling and saves files, so you can tweak the cleanup and rerun with --reprocess
without paying the 10+ minute parse again.
"""
import argparse
import json
import logging
import time
from pathlib import Path

ROOT = Path(__file__).parent.resolve()
PDF_DIR = ROOT / "data" / "raw"

import postprocess  # noqa: E402  (sits next to parse.py)


# --------------------------------------------------------------------------
# 4. Docling + per-paper driver
# --------------------------------------------------------------------------
_converter = None


# Recorded in meta.json. A paper parsed with different options is re-parsed on the next normal run.
DOCLING_OPTIONS = {"heading_hierarchy": True}


def get_converter():
    """Build the converter once (model loading is slow); import lazily."""
    global _converter
    if _converter is None:
        from docling.datamodel.base_models import InputFormat
        from docling.datamodel.pipeline_options import HeadingHierarchyOptions, PdfPipelineOptions
        from docling.document_converter import DocumentConverter, PdfFormatOption
        opts = PdfPipelineOptions(
            generate_parsed_pages=True,        # style-based levels need the parsed cells (font size/weight)
            heading_hierarchy_options=HeadingHierarchyOptions(enabled=True),   # bookmarks -> numbering -> font style
        )
        _converter = DocumentConverter(format_options={InputFormat.PDF: PdfFormatOption(pipeline_options=opts)})
    return _converter


def render_outputs(out: Path, pdf_path: Path | None = None) -> tuple[list, dict]:
    """docling.json -> clean.md + sections.json. Pure function of the saved JSON, so it is cheap to rerun."""
    doc = json.loads((out / "docling.json").read_text(encoding="utf-8"))
    clean_md, sections, stats = postprocess.process(doc, pdf_path)
    (out / "clean.md").write_text(clean_md, encoding="utf-8")
    (out / "sections.json").write_text(
        json.dumps({"sections": sections}, indent=4, ensure_ascii=False), encoding="utf-8")
    return sections, dict(stats)


def reprocess(out_root: Path, only: str | None) -> None:
    for d in sorted(p for p in out_root.iterdir() if (p / "docling.json").exists()):
        if only and d.name != only:
            continue
        meta_path = d / "meta.json"
        meta = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.exists() else {}
        pdf = PDF_DIR / meta.get("source_file", d.name + ".pdf")
        sections, stats = render_outputs(d, pdf if pdf.exists() else None)
        meta.update({"n_sections": len(sections), "fixes": stats})
        meta_path.write_text(json.dumps(meta, indent=2), encoding="utf-8")
        print(f"reprocessed: {d.name}")


def process_pdf(pdf: Path, out_root: Path, pages: tuple[int, int] | None, force: bool) -> str:
    pid = pdf.stem                                   # full stem as paper ID: no collisions
    out = out_root / pid
    meta_path = out / "meta.json"
    wanted_pages = list(pages) if pages else None
    if meta_path.exists() and not force:
        done = json.loads(meta_path.read_text(encoding="utf-8"))
        if done.get("page_range") == wanted_pages and done.get("docling_options") == DOCLING_OPTIONS:
            return "skipped"
        # earlier run covered different pages (a test slice, now a full parse) or used other Docling options -> redo

    out.mkdir(parents=True, exist_ok=True)
    start = time.time()

    kwargs = {"page_range": pages} if pages else {}
    doc = get_converter().convert(str(pdf), **kwargs).document

    doc.save_as_json(str(out / "docling.json"))
    raw_md = doc.export_to_markdown()
    (out / "raw.md").write_text(raw_md, encoding="utf-8")

    sections, stats = render_outputs(out, pdf)

    meta_path.write_text(json.dumps({
        "paper_id": pid,
        "source_file": pdf.name,
        "parser": "docling",
        "docling_options": DOCLING_OPTIONS,
        "page_range": wanted_pages,
        "seconds": round(time.time() - start, 1),
        "n_sections": len(sections),
        "fixes": stats,
    }, indent=2), encoding="utf-8")
    return "done"


def parse_pages(s: str) -> tuple[int, int]:
    a, b = s.split("-")
    return int(a), int(b)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pages", type=parse_pages, help="page range like 1-10 for quick tests (same output folders; a later full run re-parses)")
    ap.add_argument("--only", help="only parse the PDF with this file stem")
    ap.add_argument("--reprocess", action="store_true", help="skip Docling; re-render clean.md/sections.json from saved docling.json")
    ap.add_argument("--force", action="store_true", help="re-parse even if already done")
    args = ap.parse_args()

    (ROOT / "data").mkdir(exist_ok=True)
    logging.basicConfig(filename=ROOT / "data" / "parse_errors.log", level=logging.ERROR)

    out_root = ROOT / "data" / "parsed"
    if args.reprocess:
        reprocess(out_root, args.only)
        return
    pdfs = sorted(p for p in PDF_DIR.iterdir() if p.suffix.lower() == ".pdf")
    if args.only:
        pdfs = [p for p in pdfs if p.stem == args.only]

    counts = {"done": 0, "skipped": 0, "failed": 0}
    for pdf in pdfs:
        try:
            result = process_pdf(pdf, out_root, args.pages, args.force)
            counts[result] += 1
            print(f"{result}: {pdf.name}")
        except Exception:
            counts["failed"] += 1
            logging.exception(pdf.name)
            print(f"FAILED: {pdf.name} (see data/parse_errors.log)")
    print(f"=== {len(pdfs)} PDFs: {counts} ===")


if __name__ == "__main__":
    main()