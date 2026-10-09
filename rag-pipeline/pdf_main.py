import json
import logging
import time
from pathlib import Path

import pdf_to_markdown
import mdtojson
import json_editor

ROOT = Path(__file__).parent.resolve()
PDF_DIR = ROOT / "data" / "raw"
OUT_DIR = ROOT / "data" / "parsed"

(ROOT / "data").mkdir(exist_ok=True)
logging.basicConfig(filename=ROOT / "data" / "parse_errors.log", level=logging.ERROR)


def process_pdf(pdf_path: Path) -> str:
    pid = pdf_path.stem                      # full stem: no collisions
    cleaned = OUT_DIR / f"cleaned_{pid}.json"
    if cleaned.exists():
        return "skipped"

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    start = time.time()

    # 1) PDF -> Markdown (the existing code writes output.md; keep it per paper)
    pdf_to_markdown.run(source=pdf_path, output_dir=OUT_DIR)
    md = OUT_DIR / f"{pid}.md"
    (OUT_DIR / "output.md").replace(md)

    # 2) Markdown -> sectioned JSON
    raw = OUT_DIR / f"{pid}.json"
    mdtojson.convert_md_to_json(md, raw)

    # 3) Clean (written last, so a crash leaves no cleaned file and it retries)
    data = json.loads(raw.read_text(encoding="utf-8"))
    cleaned.write_text(
        json.dumps(json_editor.clean_json(data), indent=4, ensure_ascii=False),
        encoding="utf-8",
    )

    (OUT_DIR / f"{pid}.meta.json").write_text(json.dumps({
        "paper_id": pid, "source_file": pdf_path.name,
        "parser": "docling", "seconds": round(time.time() - start, 1),
    }, indent=2))
    return "done"


def main() -> None:
    pdfs = sorted(p for p in PDF_DIR.iterdir() if p.suffix.lower() == ".pdf")
    counts = {"done": 0, "skipped": 0, "failed": 0}
    for pdf in pdfs:
        try:
            counts[process_pdf(pdf)] += 1
        except Exception:
            counts["failed"] += 1
            logging.exception(pdf.name)
            print(f"FAILED: {pdf.name} (see data/parse_errors.log)")
    print(f"=== {len(pdfs)} PDFs: {counts} ===")


if __name__ == "__main__":
    main()