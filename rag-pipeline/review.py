"""
review.py - list every table the parser flagged as possibly mis-parsed, across all papers.

Run from rag-pipeline/:
    python review.py                      # print the flagged tables, grouped by paper
    python review.py --only af_01         # one paper
    python review.py --csv review.csv     # also write a sheet with blank verdict/notes columns to fill in

Where the flags come from: postprocess.py checks each table's cell geometry and writes the suspects to
data/parsed/<paper>/meta.json under fixes -> suspect_table_list. It also lists headings over 200 characters
that it turned into plain text (fixes -> demoted_heading_list): usually a list the layout model mistook for a heading. This script only READS those files, so
it is safe to run any time and needs no Docling.

Page numbers are the PDF's physical pages (page 1 = first page of the file), NOT the numbers printed on
the pages. A report whose front matter is numbered i, ii, iii is still counted from 1 here.

A flag means "look at this table against the PDF", not "this table is wrong". Fill the verdict column
with real / false alarm so we can see whether the thresholds in postprocess.py need tuning.
"""
import argparse
import csv
import json
import sys
from pathlib import Path

ROOT = Path(__file__).parent.resolve()
PARSED = ROOT / "data" / "parsed"
RAW = ROOT / "data" / "raw"


def pages_label(pages) -> str:
    a, b = pages
    return f"{a}" if a == b else f"{a}-{b}"


def load(only):
    """Return [(paper_id, source_pdf, n_tables, flags or None)]. flags is None if the paper predates flagging."""
    papers = []
    for meta_path in sorted(PARSED.glob("*/meta.json")):
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
        pid = meta.get("paper_id", meta_path.parent.name)
        if only and pid != only:
            continue
        fixes = meta.get("fixes", {})
        # postprocess.py always writes suspect_tables (0 if none). Missing key = older version of the cleanup.
        flags = fixes.get("suspect_table_list", []) if "suspect_tables" in fixes else None
        papers.append((pid, meta.get("source_file", pid + ".pdf"), fixes.get("tables"), flags,
                       fixes.get("demoted_heading_list", [])))
    return papers


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", help="only this paper (folder name under data/parsed)")
    ap.add_argument("--csv", help="also write a review sheet to this path (refuses to overwrite an existing one)")
    ap.add_argument("--force", action="store_true", help="overwrite the --csv file even if it exists")
    args = ap.parse_args()

    try:                                   # Windows consoles choke on some characters in table text
        sys.stdout.reconfigure(errors="replace")
    except Exception:
        pass

    papers = load(args.only)
    if not papers:
        print("No meta.json files found under data/parsed. Run parse.py first.")
        return

    sheet, total_flags, total_demoted, stale = [], 0, 0, []
    for pid, pdf, n_tables, flags, demoted in papers:
        for d in demoted:
            total_demoted += 1
            if d.get("rebuilt_rows"):
                what = f"rebuilt as {d['rebuilt_rows']} table rows from the PDF and joined to the table above"
            else:
                what = "demoted to plain text (" + d.get("not_rebuilt", "not under a table") + ")"
            print(f"{pid}: PDF page {d['page']}  |  {d['chars']}-char heading {what}: \"{d['preview']}...\"")
            sheet.append([pid, pdf, d["page"], d["page"], "(long heading)", f"{what}: {d['preview']}", "", ""])
        if flags is None:
            stale.append(pid)
            print(f"{pid}: no flag info (processed before flagging existed). Run: python parse.py --reprocess\n")
            continue
        n = f"{len(flags)} of {n_tables} tables flagged" if n_tables is not None else f"{len(flags)} flagged"
        print(f"{pid}: {n}   (pdf: data/raw/{pdf})")
        for f in flags:
            total_flags += 1
            title = f.get("title") or "(no title)"
            print(f"  PDF page {pages_label(f['pages'])}  |  {title}")
            for r in f["reasons"]:
                print(f"      - {r}")
                sheet.append([pid, pdf, f["pages"][0], f["pages"][1], f.get("title") or "", r, "", ""])
        print()

    print(f"=== {len(papers)} papers, {total_flags} flagged tables, {total_demoted} long headings handled"
          + (f", {len(stale)} need --reprocess" if stale else "") + " ===")

    if args.csv:
        out = Path(args.csv)
        if out.exists() and not args.force:
            print(f"\nNot writing {out}: it already exists and may hold verdicts someone typed. "
                  f"Use another name, or --force to overwrite.")
            return
        with open(out, "w", newline="", encoding="utf-8-sig") as fh:   # utf-8-sig so Excel reads accents correctly
            w = csv.writer(fh)
            w.writerow(["paper", "pdf", "first_pdf_page", "last_pdf_page", "table_title", "reason",
                        "verdict (real / false alarm)", "notes"])
            w.writerows(sheet)
        print(f"\nWrote {out} with {len(sheet)} rows.")


if __name__ == "__main__":
    main()
