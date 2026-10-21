"""
check_chunks.py - the "gold locator". Checks whether chunking kept the gold
values findable, using gold_v1_results.csv. No API calls, costs nothing.

For every gold value (e.g. P010, 4612946, "direct project beneficiaries", p.37):
  found       is the value in ANY chunk of that paper (in any common format)?
  on_page     is it in a chunk whose page range includes the gold page?
  label       do words from the gold label (metric_stated) appear in the SAME
              chunk as the value? If the number and its label are in different
              chunks, retrieval can't hand the model a usable answer.

Run from rag-pipeline/ after parse.py and chunk.py:
    python check_chunks.py
    python check_chunks.py --only P010 P001
    python check_chunks.py --gold-dir path/to/gold_files

Inputs (defaults in data/gold/):
    gold_v1_results.csv   project_code, value, metric_stated, page, note, ...
    gold_v1_general.csv   project_code -> document (P010_doc3.pdf -> paper id P010_doc3)
Output:
    data/eval/chunk_check.csv   one row per gold value (overwritten each run)
    a summary printed per project and overall
"""

import argparse
import csv
import json
import re
from collections import defaultdict
from pathlib import Path

PARSED_DIR = Path("data/parsed")
OUT_PATH = Path("data/eval/chunk_check.csv")

STOPWORDS = set("""a an the of in on at to for by with from and or as is are was were be been
that this these those which who whom its it their there than per into under over not no
share number total overall project projects programme program""".split())

SPACES_RE = re.compile(r"[    ]")   # non-breaking / thin spaces


# --------------------------------------------------------------------------
# Value variants: the same number written the ways reports write it
# --------------------------------------------------------------------------

def parse_number(raw):
    """'4612946' -> 4612946.0, '>1000' -> 1000.0, '88.4' -> 88.4, 'N' -> None."""
    s = raw.strip().lstrip("<>~≈≥≤").replace(",", "").strip()
    try:
        return float(s)
    except ValueError:
        return None


def int_groupings(n):
    """4612946 -> ['4612946', '4,612,946', '4 612 946', '4.612.946'] (exact forms)."""
    plain = str(n)
    if n < 1000:
        return [plain]
    comma = f"{n:,}"
    return [plain, comma, comma.replace(",", " "), comma.replace(",", ".")]


def variants(raw):
    """Return (exact_variants, rounded_variants). Rounded = '4.6 million' style
    restatements; we report those separately since they may be a different
    mention of the number than the one gold cites."""
    v = parse_number(raw)
    if v is None:
        return [], []
    exact, rounded = [], []
    if v == int(v):
        exact += int_groupings(int(v))
    else:
        s = repr(v).rstrip("0").rstrip(".")
        exact += [s, s.replace(".", ",")]
    for scale, words in ((1e9, ("billion", "bn")), (1e6, ("million", "mn", "m"))):
        if v >= scale:
            x = v / scale
            forms = {f"{x:.1f}", f"{x:.2f}"}
            if abs(x - round(x)) < 1e-9:
                forms.add(str(int(round(x))))
            for f in forms:
                f = f.rstrip("0").rstrip(".") if "." in f else f
                for w in words:
                    rounded += [f"{f} {w}", f"{f}{w}", f"{f.replace('.', ',')} {w}"]
            break
    return exact, rounded


def number_pattern(form):
    """Match the form as a whole number: not glued to other digits, and not
    the start/end of a longer number like 4,612,9460 or 1.25."""
    esc = re.escape(form).replace(r"\ ", r"\s")
    return re.compile(r"(?<![\d])(?<!\d[.,])" + esc + r"(?![\d])(?![.,]\d)", re.I)


# --------------------------------------------------------------------------
# Label words
# --------------------------------------------------------------------------

def label_words(metric_stated):
    words = re.findall(r"[a-zA-Z]{3,}", (metric_stated or "").lower())
    return [w for w in dict.fromkeys(words) if w not in STOPWORDS]


def label_score(words, text):
    """Fraction of label words found in the chunk. Matches on a 5-letter prefix
    so 'beneficiaries' ~ 'beneficiary', 'trained' ~ 'training'."""
    if not words:
        return None
    low = text.lower()
    hits = sum(1 for w in words if w[:5] in low)
    return hits / len(words)


# --------------------------------------------------------------------------
# Loading
# --------------------------------------------------------------------------

def load_csv(path):
    with open(path, newline="", encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))


def project_to_paper(general_rows):
    """gold_v1_general.csv has project_code and document (P010_doc3.pdf);
    the paper id is the filename stem, same as parse.py uses."""
    out = {}
    for r in general_rows:
        doc = (r.get("document") or "").strip()
        if r.get("project_code") and doc:
            out[r["project_code"].strip()] = Path(doc).stem
    return out


def load_chunks(paper_id):
    path = PARSED_DIR / paper_id / "chunks.jsonl"
    if not path.exists():
        return None
    chunks = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.strip():
            c = json.loads(line)
            c["_search"] = SPACES_RE.sub(" ", c["text"])
            chunks.append(c)
    return chunks


# --------------------------------------------------------------------------
# Checking one gold value
# --------------------------------------------------------------------------

def on_page(chunk, page):
    p = chunk.get("pages")
    return bool(p) and page is not None and p[0] <= page <= p[1]


def near_page(chunk, page, slack=1):
    p = chunk.get("pages")
    return bool(p) and page is not None and p[0] - slack <= page <= p[1] + slack


def check_value(row, chunks, label_threshold):
    raw = (row.get("value") or "").strip()
    page = int(row["page"]) if (row.get("page") or "").strip().isdigit() else None
    words = label_words(row.get("metric_stated"))
    exact, rounded = variants(raw)

    res = {"status": "", "match_kind": "", "n_chunks_with_value": 0,
           "best_chunk": "", "best_chunk_pages": "", "best_chunk_type": "",
           "label_score": "", "label_together": "", "snippet": ""}

    if not exact:
        res["status"] = "not_checkable"          # e.g. 'N' (a yes/no milestone)
        return res

    max_page = max((c["pages"][1] for c in chunks if c.get("pages")), default=0)

    def hits_for(forms):
        pats = [number_pattern(f) for f in forms]
        found = []
        for c in chunks:
            m = next((m for p in pats for m in [p.search(c["_search"])] if m), None)
            if m:
                found.append((c, m))
        return found

    hits, kind = hits_for(exact), "exact"
    if not hits:
        hits, kind = hits_for(rounded), "rounded"
    res["n_chunks_with_value"] = len(hits)

    if not hits:
        if page and page > max_page:
            res["status"] = "page_not_chunked"   # e.g. paper parsed with --pages
        else:
            res["status"] = "not_found"
        return res

    res["match_kind"] = kind
    # Prefer chunks on the gold page, then near it, then any; among those,
    # the one with the best label score.
    def rank(hit):
        c, _ = hit
        ls = label_score(words, c["_search"]) or 0
        return (on_page(c, page), near_page(c, page), ls)

    best, m = max(hits, key=rank)
    if page is None:
        res["status"] = "found_no_gold_page"
    elif on_page(best, page):
        res["status"] = "found_on_page"
    elif near_page(best, page):
        res["status"] = "found_near_page"
    else:
        res["status"] = "found_other_page"

    ls = label_score(words, best["_search"])
    # One generic word ('beneficiaries') is too easy to hit by accident, so
    # also require at least two label words when the label has two or more.
    n_hit = round((ls or 0) * len(words))
    together = ls is not None and ls >= label_threshold and n_hit >= min(2, len(words))
    res.update({
        "best_chunk": best["chunk_id"],
        "best_chunk_pages": "-".join(map(str, best["pages"])) if best.get("pages") else "",
        "best_chunk_type": best["type"],
        "label_score": "" if ls is None else f"{ls:.2f}",
        "label_together": "" if ls is None else ("yes" if together else "no"),
    })
    s = best["_search"]
    res["snippet"] = re.sub(r"\s+", " ", s[max(0, m.start() - 80): m.end() + 80]).strip()
    return res


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--gold-dir", type=Path, default=Path("data/gold"))
    ap.add_argument("--only", nargs="+", metavar="PROJECT_CODE")
    ap.add_argument("--out", type=Path, default=OUT_PATH)
    ap.add_argument("--label-threshold", type=float, default=0.5,
                    help="share of label words that must be in the value's chunk")
    args = ap.parse_args()

    results_path = args.gold_dir / "gold_v1_results.csv"
    general_path = args.gold_dir / "gold_v1_general.csv"
    for p in (results_path, general_path):
        if not p.exists():
            print(f"Missing {p}. Put the gold CSVs there or pass --gold-dir.")
            return

    gold = load_csv(results_path)
    paper_of = project_to_paper(load_csv(general_path))
    if args.only:
        gold = [r for r in gold if r["project_code"] in set(args.only)]

    chunk_cache, out_rows = {}, []
    for r in gold:
        code = r["project_code"].strip()
        pid = paper_of.get(code, "")
        if pid not in chunk_cache:
            chunk_cache[pid] = load_chunks(pid) if pid else None
        chunks = chunk_cache[pid]
        if chunks is None:
            res = {"status": "no_chunks"}
        else:
            res = check_value(r, chunks, args.label_threshold)
        out_rows.append({
            "project_code": code, "paper_id": pid,
            "value": r.get("value", ""), "metric_stated": r.get("metric_stated", ""),
            "gold_page": r.get("page", ""), "gold_note": r.get("note", ""), **res,
        })

    cols = ["project_code", "paper_id", "value", "metric_stated", "gold_page", "status",
            "match_kind", "n_chunks_with_value", "best_chunk", "best_chunk_pages",
            "best_chunk_type", "label_score", "label_together", "snippet", "gold_note"]
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(out_rows)

    # ---- summary ----
    by_proj = defaultdict(list)
    for row in out_rows:
        by_proj[row["project_code"]].append(row)

    def line(rows):
        st = defaultdict(int)
        for x in rows:
            st[x["status"]] += 1
        checkable = sum(v for k, v in st.items() if k not in ("not_checkable", "no_chunks"))
        found = sum(v for k, v in st.items() if k.startswith("found"))
        onpage = st["found_on_page"]
        lab = sum(1 for x in rows if x["status"] == "found_on_page" and x.get("label_together") == "yes")
        parts = [f"{found}/{checkable} found", f"{onpage} on gold page",
                 f"{lab} with label in same chunk"]
        extra = [f"{k} {v}" for k, v in sorted(st.items())
                 if k in ("no_chunks", "page_not_chunked", "not_checkable", "found_near_page",
                          "found_other_page", "found_no_gold_page") and v]
        return ", ".join(parts) + (f"  ({', '.join(extra)})" if extra else "")

    for code in sorted(by_proj):
        print(f"{code:6} {by_proj[code][0]['paper_id'] or '(no paper id)':14} {line(by_proj[code])}")
    print(f"\nOVERALL               {line(out_rows)}")
    print(f"Details: {args.out}  (sort by status; misses are the to-do list)")


if __name__ == "__main__":
    main()
