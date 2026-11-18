"""
chunk.py - turn each paper's sections.json into retrieval chunks.

Reads   data/02_parsed/<paper_id>/sections.json     (from step 02)
Writes  data/03_chunks/<paper_id>/chunks.jsonl      one chunk per line
        data/03_chunks/<paper_id>/chunks_meta.json  written LAST = done marker
        data/03_chunks/<paper_id>/chunks.md         only with --dump-md (for humans)

Run from rag-pipeline/:
    python -m step03_chunk.chunk                        # chunk every parsed paper that needs it
    python -m step03_chunk.chunk --only af_01 cif_02    # just these papers
    python -m step03_chunk.chunk --force                # rebuild even if up to date
    python -m step03_chunk.chunk --dump-md              # also write a readable chunks.md
    python -m step03_chunk.chunk --max-tokens 800       # try different sizes (see --help)

From Python (this is what run.py does):
    from step03_chunk import chunk
    chunk.run(only=["af_01"], write_md=True)

A paper is re-chunked automatically when its sections.json is newer than its
chunks, or when the chunking parameters changed. Chunking takes seconds, so
rerunning is cheap. Nothing is ever deleted; outputs are overwritten in place.
"""

import argparse
import csv
import json
import os
import re
import statistics
import traceback
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

from paths import CHUNKS, DOC_INDEX, LOGS, PARSED

CHUNKER_VERSION = "0.3"
ERROR_LOG = LOGS / "chunk_errors.log"

# Chunk sizes (in tokens) and cleanup thresholds. Command-line flags or run(settings={...}) override these.
DEFAULT_SETTINGS = {
    "target_tokens": 450,       # text chunks stop growing near this
    "max_tokens": 600,          # hard cap for text chunks
    "min_tokens": 100,          # smaller sections merge into the next
    "max_table_tokens": 1500,   # bigger tables split by rows
    "footnote_cap": 150,        # a page's footnotes above this many tokens get their own chunk
    "header_min_pages": 3,      # short text repeated on this many pages counts as a running header
}


# --------------------------------------------------------------------------
# Token counting
# --------------------------------------------------------------------------

def make_token_counter():
    """tiktoken's cl100k_base matches OpenAI's embedding models. If it can't
    load (not installed / offline), fall back to a rough word-based estimate
    so the script still runs; the tokenizer used is recorded in chunks_meta."""
    try:
        import tiktoken
        enc = tiktoken.get_encoding("cl100k_base")
        return (lambda s: len(enc.encode(s, disallowed_special=()))), "tiktoken/cl100k_base"
    except Exception as e:
        print(f"[warn] tiktoken unavailable ({e.__class__.__name__}); using a word-count "
              f"estimate. `pip install tiktoken` for exact counts.")
        return (lambda s: int(len(s.split()) * 1.35) + 1), "estimate/words*1.35"


# --------------------------------------------------------------------------
# Small helpers
# --------------------------------------------------------------------------

def item_pages(item):
    """Text/table items use "pages": [start, end]; footnotes use "page": n."""
    p = item.get("pages")
    if p:
        return (int(p[0]), int(p[-1]))
    if item.get("page") is not None:
        return (int(item["page"]), int(item["page"]))
    return None


def norm_for_repeat(text):
    """Normalise text for running-header detection: lowercase, collapse
    whitespace, and turn digits into # so 'Page 3 of 40' == 'Page 4 of 40'."""
    return re.sub(r"\d+", "#", re.sub(r"\s+", " ", text.strip().lower()))


def merge_pages(ranges):
    ranges = [r for r in ranges if r]
    if not ranges:
        return None
    return [min(r[0] for r in ranges), max(r[1] for r in ranges)]


def fmt_pages(pages):
    if not pages:
        return ""
    return f"Page {pages[0]}" if pages[0] == pages[1] else f"Pages {pages[0]}-{pages[1]}"


# --------------------------------------------------------------------------
# Section structure: hierarchy and kinds
# --------------------------------------------------------------------------

# "3.1. Aim of ..." -> "3.1". Each part must be < 100 so "2015 Annual report"
# is not mistaken for section 2015.
HEADING_NUM_RE = re.compile(r"^\s*((?:\d{1,2}\.)*\d{1,2})\.?\s+\S")

TOC_RE = re.compile(r"^\s*(table of contents|contents|sommaire|table des mati[eè]res)\s*:?\s*$", re.I)
NUM_PREFIX = r"^\s*(?:(?:\d+\.)*\d+\.?\s*)?"
REF_RE = re.compile(NUM_PREFIX + r"(references|bibliography|works cited|literature cited|r[ée]f[ée]rences)\b", re.I)
ANNEX_RE = re.compile(NUM_PREFIX + r"(annex|annexe|annexes|appendix|appendices|attachment)\b", re.I)
# "Lists of" (tables, boxes, annexes...) that belong to the table of contents.
TOC_LIST_RE = re.compile(r"^\s*(list of )?(tables|figures|boxes|maps|charts|graphs|annexes|appendices)\s*:?\s*$", re.I)
DATA_RE = re.compile(r"\b(data ?sheet|results framework|results matrix|logical framework|logframe)\b", re.I)


def infer_heading_paths(sections):
    """Docling gives a flat hierarchy (every heading level 2). Recover parents
    from section numbers: '3.1.' gets parent '3.' if we've seen a '3.' heading.
    If sections.json ever carries a real multi-level heading_path, keep it."""
    seen = {}
    for s in sections:
        given = s.get("heading_path") or []
        heading = (s.get("heading") or "").strip()
        if len(given) > 1:
            s["_path"] = list(given)
            continue
        m = HEADING_NUM_RE.match(heading)
        if not m:
            s["_path"] = [heading] if heading else []
            continue
        num = m.group(1)
        seen[num] = heading
        parts = num.split(".")
        ancestors = [seen[".".join(parts[:i])] for i in range(1, len(parts))
                     if ".".join(parts[:i]) in seen]
        s["_path"] = ancestors + [heading]


def classify_sections(sections):
    """Tag each section body / annex / references, and drop the table of
    contents. Annex and references are 'sticky': everything after an Annex
    heading is annex until a References heading (and vice versa). Data-heavy
    sections (data sheet, results framework) are flagged wherever they are,
    since e.g. World Bank ICRs put the data sheet at the front.

    A heading with no text directly under it ('Appendix 1: Terms of Reference'
    followed straight by 'BACKGROUND') never becomes a section of its own, so
    it is only visible in its children's heading_path. Parents therefore count
    too, but only to leave the body: a parent never switches annex <->
    references (that's what the section's own heading is for). A data-heavy
    parent ('ANNEX 1. RESULTS FRAMEWORK') flags its children as data too."""
    state = "body"
    for s in sections:
        h = (s.get("heading") or "").strip()
        # postprocess drops the TOC section but leaves its heading in later
        # sections' heading_path (all of P001's body sits "under" it). Remove it
        # from paths; a "list of" heading directly under it is part of the TOC.
        raw_path = s.get("heading_path") or []
        toc_parent = len(raw_path) > 1 and bool(TOC_RE.match(raw_path[-2]))
        s["heading_path"] = [p for p in raw_path if not TOC_RE.match(p)]
        if TOC_RE.match(h) or (TOC_LIST_RE.match(h) and (toc_parent or h.lower().startswith("list of"))):
            s["_kind"] = "toc"
            continue
        parents = [p.strip() for p in s["heading_path"][:-1]]
        if ANNEX_RE.match(h):
            state = "annex"
        elif REF_RE.match(h):
            state = "references"
        elif state == "body":
            if any(ANNEX_RE.match(p) for p in parents):
                state = "annex"
            elif any(REF_RE.match(p) for p in parents):
                state = "references"
        s["_kind"] = state
        s["_data"] = bool(DATA_RE.search(h)) or any(DATA_RE.search(p) for p in parents)


def find_running_headers(sections, min_pages, max_chars=120):
    """Short texts (or headings) that repeat on >= min_pages different pages
    are page headers/footers leaking in, not content."""
    pages_by_text = defaultdict(set)
    for s in sections:
        h = (s.get("heading") or "").strip()
        if h and s.get("pages"):
            pages_by_text[norm_for_repeat(h)].add(int(s["pages"][0]))
        for it in s.get("content", []):
            if it.get("type") != "text":
                continue
            t = (it.get("text") or "").strip()
            pr = item_pages(it)
            if t and len(t) <= max_chars and pr:
                pages_by_text[norm_for_repeat(t)].add(pr[0])
    return {t for t, pages in pages_by_text.items() if len(pages) >= min_pages}


# --------------------------------------------------------------------------
# Splitting long text
# --------------------------------------------------------------------------

SENT_SPLIT_RE = re.compile(r"(?<=[.!?;])\s+(?=[A-Z0-9\"“(\-•])")


def split_long_text(text, max_tokens, count):
    """Paragraph too big for one chunk: split on sentences, packing sentences
    up to max_tokens. A single sentence still too long is cut on words."""
    pieces, cur = [], []
    for sent in SENT_SPLIT_RE.split(text):
        if count(sent) > max_tokens:
            if cur:
                pieces.append(" ".join(cur))
                cur = []
            words = sent.split()
            step = max(1, int(len(words) * max_tokens / max(count(sent), 1)))
            pieces.extend(" ".join(words[i:i + step]) for i in range(0, len(words), step))
            continue
        if cur and count(" ".join(cur + [sent])) > max_tokens:
            pieces.append(" ".join(cur))
            cur = []
        cur.append(sent)
    if cur:
        pieces.append(" ".join(cur))
    return pieces


# --------------------------------------------------------------------------
# Tables
# --------------------------------------------------------------------------

def _cell(v):
    return re.sub(r"\s+", " ", str(v if v is not None else "")).replace("|", "\\|").strip()


def table_columns(header_rows, ncols):
    """Docling headers are a list of rows (multi-row headers happen). Combine
    them per column: ['Budget', 'US$'] -> 'Budget / US$'."""
    cols = []
    for j in range(ncols):
        parts = []
        for hr in header_rows:
            if j < len(hr):
                v = _cell(hr[j])
                if v and (not parts or parts[-1] != v):
                    parts.append(v)
        cols.append(" / ".join(parts))
    return cols


def md_row(cells, ncols):
    cells = [_cell(c) for c in cells] + [""] * (ncols - len(cells))
    return "| " + " | ".join(cells) + " |"


def serialize_row(cells, columns):
    """'header: value' pairs so every number sits next to its column name.
    Used for embedding only; the markdown stays in `text`."""
    out = []
    for j, v in enumerate(cells):
        v = _cell(v)
        if not v:
            continue
        name = columns[j] if j < len(columns) else ""
        out.append(f"{name}: {v}" if name else v)
    return "; ".join(out)


def nearby_text(prev, item):
    """The latest text from an earlier section, if it sits on the same or the previous page as
    item. Search context for a table or figure that has no text before it in its own section."""
    pages = item_pages(item)
    if not prev or prev[1] is None or not pages:
        return None
    return prev[0] if 0 <= pages[0] - prev[1] <= 1 else None


# --------------------------------------------------------------------------
# The chunker
# --------------------------------------------------------------------------

class PaperChunker:
    def __init__(self, paper_id, title, count, settings):
        self.paper_id = paper_id
        self.title = title
        self.count = count
        self.settings = settings
        self.chunks = []
        self.footnotes = []          # (page, text, path, kind)
        self.pos = 0                 # reading-order counter
        self.stats = defaultdict(int)
        self._reset_buf()
        self.cur_path, self.cur_kind, self.cur_data = [], "body", False

    # ---- text buffer ------------------------------------------------------

    def _reset_buf(self):
        self.buf = []                # list of (text, pages_or_None, order)
        self.buf_tokens = 0
        self.buf_path, self.buf_kind, self.buf_data = [], "body", False
        self.buf_headings = []

    def _has_content(self):
        return any(p is not None for _, p, _ in self.buf)

    def _append(self, text, pages, order):
        if not self.buf:
            self.buf_path = list(self.cur_path)
            self.buf_kind = self.cur_kind
            self.buf_data = self.cur_data
            self.buf_headings = [self.cur_path[-1]] if self.cur_path else []
        self.buf.append((text, pages, order))
        self.buf_tokens += self.count(text)

    def try_merge_back(self):
        """A small leftover at the end of a section (e.g. the last two bullets
        of a list) goes back into the previous chunk of the SAME section if it
        fits, instead of becoming a tiny chunk of its own."""
        if not (self.buf and self._has_content() and self.buf_tokens < self.settings["min_tokens"]):
            return False
        prev = self.chunks[-1] if self.chunks else None
        if not prev or prev["type"] != "text" or prev["heading_path"] != self.buf_path \
                or prev["section_kind"] != self.buf_kind:
            return False
        if self.count(prev["text"]) + self.buf_tokens > self.settings["max_tokens"]:
            return False
        prev["text"] += "\n\n" + "\n\n".join(t for t, _, _ in self.buf)
        prev["pages"] = merge_pages([prev["pages"]] + [p for _, p, _ in self.buf])
        self.stats["tails_merged_back"] += 1
        self._reset_buf()
        return True

    def flush(self):
        if self.try_merge_back():
            return
        if self.buf and self._has_content():
            self.chunks.append({
                "type": "text",
                "section_kind": self.buf_kind,
                "data_section": self.buf_data,
                "heading_path": self.buf_path,
                "headings": self.buf_headings,
                "pages": merge_pages([p for _, p, _ in self.buf]),
                "text": "\n\n".join(t for t, _, _ in self.buf),
                "_order": min(o for _, p, o in self.buf if p is not None),
            })
        self._reset_buf()

    def begin_section(self, path, kind, data):
        # Close the running chunk at a section boundary, unless it's still
        # tiny: then this section is merged into it (with its heading inline).
        if not self.try_merge_back() and self.buf and \
                (self.buf_tokens >= self.settings["min_tokens"] or kind != self.buf_kind):
            self.flush()
        self.cur_path, self.cur_kind, self.cur_data = path, kind, data
        if self.buf and path:
            self._append(f"## {path[-1]}", None, self.pos)
            self.buf_headings.append(path[-1])
            self.buf_data = self.buf_data or data
            self.stats["sections_merged"] += 1

    def add_text(self, text, pages):
        self.pos += 1
        n = self.count(text)
        if n > self.settings["max_tokens"]:
            self.stats["paragraphs_split"] += 1
            for piece in split_long_text(text, self.settings["max_tokens"], self.count):
                self._add_piece(piece, pages, self.pos)
            return
        self._add_piece(text, pages, self.pos)

    def _add_piece(self, text, pages, order):
        n = self.count(text)
        if self.buf and self._has_content():
            # Prefer to stop near target size; never exceed max size.
            if (self.buf_tokens + n > self.settings["target_tokens"] and self.buf_tokens >= self.settings["min_tokens"]) \
                    or self.buf_tokens + n > self.settings["max_tokens"]:
                self.flush()
        self._append(text, pages, order)

    # ---- tables -----------------------------------------------------------

    def add_table(self, item, context):
        # A table ends the running text chunk. Otherwise a tiny text buffer
        # stays open across table-only sections (forms, data sheets), collects
        # their headings, and then swallows text from pages later under the
        # wrong section. Headings with no text after them are dropped first.
        while self.buf and self.buf[-1][1] is None:
            t, _, _ = self.buf.pop()
            self.buf_tokens -= self.count(t)
            if len(self.buf_headings) > 1:
                self.buf_headings.pop()
        self.flush()
        self.pos += 1
        all_rows = item.get("rows") or []
        all_pages = item.get("row_pages") or [None] * len(all_rows)   # older sections.json: no row pages
        kept = [(r, p) for r, p in zip(all_rows, all_pages) if any(_cell(c) for c in r)]
        rows = [r for r, _ in kept]
        row_pages = [p for _, p in kept]
        header_rows = item.get("header") or []
        ncols = max([len(r) for r in header_rows + rows] or [1])
        columns = table_columns(header_rows, ncols)
        title = (item.get("title") or "").strip()
        suspect = item.get("suspect") or []
        pages = item_pages(item)

        head_md = md_row(columns, ncols) + "\n" + "|" + "---|" * ncols
        row_md = [md_row(r, ncols) for r in rows]
        fixed = self.count(head_md) + (self.count(title) if title else 0) + 10

        # Group rows so each piece (header repeated) stays under the table cap.
        groups, cur, cur_tok = [], [], fixed
        for i, line in enumerate(row_md):
            t = self.count(line)
            if cur and cur_tok + t > self.settings["max_table_tokens"]:
                groups.append(cur)
                cur, cur_tok = [], fixed
            cur.append(i)
            cur_tok += t
        if cur or not groups:
            groups.append(cur)
        if len(groups) > 1:
            self.stats["tables_split"] += 1

        n_rows = len(rows)
        for g in groups:
            lo, hi = (g[0] + 1, g[-1] + 1) if g else (0, 0)
            label = []
            if title:
                label.append(f"Table: {title}")
            if len(groups) > 1:
                label.append(f"(rows {lo}-{hi} of {n_rows})")
            # A table that crosses a page break: a "(PDF page N)" marker row where the new page
            # starts, and each piece gets the pages of its own rows, not the whole table's.
            body_md, body_rows = [], []
            for k, i in enumerate(g):
                if k and row_pages[i] and row_pages[i] != row_pages[g[k - 1]]:
                    marker = f"(PDF page {row_pages[i]})"
                    body_md.append(md_row([marker], ncols))
                    body_rows.append(marker)
                body_md.append(row_md[i])
                body_rows.append("Row: " + serialize_row(rows[i], columns))
            own = [row_pages[i] for i in g if row_pages[i]]
            piece_pages = [min(own), max(own)] if own else (list(pages) if pages else None)
            text = ("\n".join(label) + "\n" if label else "") + head_md + "\n" + "\n".join(body_md)
            serialized = "\n".join(body_rows)
            self.chunks.append({
                "type": "table",
                "section_kind": self.cur_kind,
                "data_section": self.cur_data,
                "heading_path": list(self.cur_path),
                "headings": [self.cur_path[-1]] if self.cur_path else [],
                "pages": piece_pages,
                "text": text,
                "table": {"title": title or None, "columns": columns,
                          "row_range": [lo, hi], "n_rows_total": n_rows},
                "suspect_table": bool(suspect),
                "suspect_reasons": suspect,
                "_context": context,
                "_embed_body": serialized,
                "_order": self.pos,
            })
            self.pos += 1

    # ---- figures ----------------------------------------------------------

    def add_figure(self, item, context=None):
        """A figure (chart, diagram, picture) becomes its own chunk: caption + the text found inside it,
        with the path of its PNG crop in `image` so the extraction step can show the picture to a model
        that reads images (the labels alone can't say which bar has which value). Like a table, it ends the
        running text chunk. A figure with very long label text (big diagrams) is split, caption repeated.
        Like tables, its embedding gets a "Context:" line (end of the text just before it), because many
        figures have no caption and only numbers as labels, which leaves nothing to search on."""
        while self.buf and self.buf[-1][1] is None:
            t, _, _ = self.buf.pop()
            self.buf_tokens -= self.count(t)
            if len(self.buf_headings) > 1:
                self.buf_headings.pop()
        self.flush()
        caption = (item.get("caption") or "").strip()
        head = "Figure: " + (caption or "(no caption)")
        labels = (item.get("labels") or "").strip()
        room = max(self.settings["max_tokens"] - self.count(head) - 10, 50)
        pieces = split_long_text(labels, room, self.count) if labels else [""]
        if len(pieces) > 1:
            self.stats["figures_split"] += 1
        pages = item_pages(item)
        for k, piece in enumerate(pieces):
            part = f" (part {k + 1} of {len(pieces)})" if len(pieces) > 1 else ""
            text = head + part + (("\nFigure text: " + piece) if piece else "")
            self.chunks.append({
                "type": "figure",
                "section_kind": self.cur_kind,
                "data_section": self.cur_data,
                "heading_path": list(self.cur_path),
                "headings": [self.cur_path[-1]] if self.cur_path else [],
                "pages": list(pages) if pages else None,
                "text": text,
                "image": item.get("image"),
                "_context": context,
                "_order": self.pos,
            })
            self.pos += 1

    # ---- footnotes --------------------------------------------------------

    def attach_footnotes(self):
        """Put each footnote with the text it explains. Superscript markers are
        lost in parsing (they show up as ' 1 ,'), so we match by page: try to
        find the bare marker number in a text chunk on that page, otherwise use
        the last text chunk on that page. If a page's footnotes are long, or no
        text chunk covers the page, they become their own footnote chunk."""
        by_page = defaultdict(list)
        for f in self.footnotes:
            by_page[f[0]].append(f)

        for page, fns in sorted(by_page.items()):
            cands = [c for c in self.chunks if c["type"] == "text" and c["pages"]
                     and c["pages"][0] <= page <= c["pages"][1]]
            total = sum(self.count(f[1]) for f in fns)
            if not cands or total > self.settings["footnote_cap"]:
                self.stats["footnote_chunks"] += 1
                # Sort it after the last chunk that starts on or before its page.
                before = [c["_order"] for c in self.chunks
                          if c["pages"] and c["pages"][0] <= page and c["type"] != "footnote"]
                order = (max(before) + 0.5) if before else -1
                self.chunks.append({
                    "type": "footnote",
                    "section_kind": fns[0][3],
                    "data_section": False,
                    "heading_path": fns[0][2],
                    "headings": [fns[0][2][-1]] if fns[0][2] else [],
                    "pages": [page, page],
                    "text": f"Footnotes (p. {page}):\n" + "\n".join(f[1] for f in fns),
                    "_order": order,
                })
                continue
            for page_, text, _, _ in fns:
                target = None
                m = re.match(r"\s*(\d{1,3})\b", text)
                if m:
                    num = m.group(1)
                    after_word = r"(?:(?<=[A-Za-z\)\]\"'’”%])|(?<=[A-Za-z\)\]\"'’”%]\s))"
                    # Strict: a lost superscript usually looks like 'study 1 ,'
                    # or 'group 2 .' - the number followed by punctuation.
                    strict = re.compile(after_word + num + r"\s?(?=[,.;:)\]](?!\d))")
                    # Loose: the number after a word, not part of 1.2 / 1,000.
                    loose = re.compile(after_word + num + r"(?![.,]\d)(?=\s|[,.;:)\]]|$)")
                    for pattern in (strict, loose):
                        hits = [c for c in cands if pattern.search(c["text"])]
                        if hits:
                            target = hits[0]
                            break
                if target is None:
                    target = cands[-1]
                target.setdefault("_fns", []).append((page_, text))
                self.stats["footnotes_attached"] += 1

        for c in self.chunks:
            fns = c.pop("_fns", None)
            if fns:
                c["text"] += "\n\nFootnotes:\n" + "\n".join(f"(p. {p}) {t}" for p, t in fns)

    # ---- driver -----------------------------------------------------------

    def run(self, sections):
        classify_sections(sections)      # first: it also strips the TOC from heading paths
        infer_heading_paths(sections)
        running = find_running_headers(sections, self.settings["header_min_pages"])
        prev_text = None     # (text, last page) of the latest text item, across sections

        for s in sections:
            if s.get("_kind") == "toc":
                self.stats["toc_sections_dropped"] += 1
                continue
            path = [h for h in s["_path"] if norm_for_repeat(h) not in running]
            self.begin_section(path, s["_kind"], s.get("_data", False))
            last_text = None
            for it in s.get("content", []):
                typ = it.get("type")
                text = (it.get("text") or "").strip()
                if typ == "text":
                    if not text:
                        continue
                    if len(text) <= 120 and norm_for_repeat(text) in running:
                        self.stats["running_headers_dropped"] += 1
                        continue
                    self.add_text(text, item_pages(it))
                    last_text = text
                    prev_text = (text, (item_pages(it) or [None, None])[1])
                elif typ in ("table", "figure"):
                    context = last_text or nearby_text(prev_text, it)
                    if context and not last_text:
                        self.stats["context_from_previous_section"] += 1
                    (self.add_table if typ == "table" else self.add_figure)(it, context)
                elif typ == "footnote":
                    pr = item_pages(it)
                    if text and pr:
                        self.footnotes.append((pr[0], text, path, s["_kind"]))
                else:
                    self.stats[f"unknown_item_type:{typ}"] += 1
        self.flush()
        self.attach_footnotes()
        return self.finalize()

    def finalize(self):
        self.chunks.sort(key=lambda c: c["_order"])
        out = []
        for seq, c in enumerate(self.chunks):
            prefix = [f"Document: {self.title}"]
            if c["heading_path"]:
                prefix.append("Section: " + " > ".join(c["heading_path"]))
            extra = [h for h in c["headings"][1:]]
            if extra:
                prefix.append("Also covers: " + "; ".join(extra))
            if c["pages"]:
                prefix.append(fmt_pages(c["pages"]))
            if c["section_kind"] != "body":
                prefix.append(f"Part: {c['section_kind']}")
            head = " | ".join(prefix)

            ctx = c.pop("_context", None)
            ctx_line = ("Context: " + " ".join(ctx.split()[-60:])) if ctx else None
            if c["type"] == "table":
                body = [ctx_line] if ctx_line else []
                if c["table"]["title"]:
                    body.append(f"Table: {c['table']['title']}")
                body.append(c.pop("_embed_body"))
                embed = head + "\n\n" + "\n".join(body)
            elif c["type"] == "figure" and ctx_line:
                embed = head + "\n\n" + ctx_line + "\n" + c["text"]
            else:
                embed = head + "\n\n" + c["text"]

            c.pop("_order", None)
            rec = {
                "chunk_id": f"{self.paper_id}_c{seq:04d}",
                "paper_id": self.paper_id,
                "seq": seq,
                "type": c["type"],
                "section_kind": c["section_kind"],
                "data_section": c["data_section"],
                "heading_path": c["heading_path"],
                "headings": c["headings"],
                "pages": c["pages"],
                "text": c["text"],
                "embed_text": embed,
                "n_tokens": self.count(c["text"]),
                "n_embed_tokens": self.count(embed),
                "table": c.get("table"),
                "suspect_table": c.get("suspect_table", False),
                "suspect_reasons": c.get("suspect_reasons", []),
                "image": c.get("image"),     # figures only: PNG path relative to the paper folder
            }
            out.append(rec)
        return out


# --------------------------------------------------------------------------
# Titles from doc_index.csv
# --------------------------------------------------------------------------

def load_titles(path):
    """Map filename stem -> title. Column names are guessed (a column with
    'file' in its name, and one called 'title'); adjust if doc_index differs."""
    if not path.exists():
        print(f"[warn] {path} not found; chunk prefixes will use the paper id as the title.")
        return {}
    with open(path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        cols = reader.fieldnames or []
        file_col = next((c for c in cols if "file" in c.lower()), None)
        title_col = next((c for c in cols if c.lower() == "title"), None) or \
            next((c for c in cols if "title" in c.lower()), None)
        if not file_col or not title_col:
            print(f"[warn] {path}: couldn't find filename/title columns in {cols}; using paper ids.")
            return {}
        return {Path(r[file_col]).stem: r[title_col].strip()
                for r in reader if r.get(file_col) and r.get(title_col)}


# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

def write_atomic(path, text):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def dump_md(chunks, path):
    lines = []
    for c in chunks:
        flags = [c["type"], c["section_kind"]]
        if c["suspect_table"]:
            flags.append("SUSPECT TABLE")
        lines.append(f"## {c['chunk_id']}  [{', '.join(flags)}]  "
                     f"{fmt_pages(c['pages'])}  ({c['n_tokens']} tok)")
        lines.append(f"**Section:** {' > '.join(c['heading_path']) or '(none)'}")
        if len(c["headings"]) > 1:
            lines.append(f"**Also covers:** {'; '.join(c['headings'][1:])}")
        if c.get("image"):
            lines.append(f"**Image:** {c['image']}")
        lines.append("")
        lines.append(c["text"])
        lines.append("\n---\n")
    write_atomic(path, "\n".join(lines))


def summarize(paper_id, chunks, stats):
    toks = [c["n_tokens"] for c in chunks] or [0]
    by_type = defaultdict(int)
    for c in chunks:
        by_type[c["type"]] += 1
    types = ", ".join(f"{k} {v}" for k, v in sorted(by_type.items()))
    extra = ", ".join(f"{k} {v}" for k, v in sorted(stats.items()) if v)
    return (f"{paper_id}: {len(chunks)} chunks ({types}) | tokens min/med/max "
            f"{min(toks)}/{int(statistics.median(toks))}/{max(toks)}"
            + (f" | {extra}" if extra else ""))


def needs_rebuild(paper_dir, out_dir, params, force):
    """paper_dir holds sections.json (step 02); out_dir holds the chunks (step 03)."""
    meta = out_dir / "chunks_meta.json"
    if force or not meta.exists() or not (out_dir / "chunks.jsonl").exists():
        return True
    if (paper_dir / "sections.json").stat().st_mtime > meta.stat().st_mtime:
        return True
    try:
        return json.loads(meta.read_text(encoding="utf-8")).get("params") != params
    except Exception:
        return True


# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

def run(only=None, force=False, write_md=False, doc_index=DOC_INDEX, settings=None):
    """Chunk parsed papers. only = list of paper ids (None = all); settings = dict overriding DEFAULT_SETTINGS."""
    s = dict(DEFAULT_SETTINGS)              # start from the defaults...
    s.update(settings or {})                # ...then apply any overrides
    count, tokenizer = make_token_counter()
    params = {"chunker_version": CHUNKER_VERSION, "tokenizer": tokenizer}
    params.update(s)                        # recorded in chunks_meta.json; a change triggers a rebuild
    titles = load_titles(doc_index)

    paper_dirs = sorted(d for d in PARSED.iterdir() if (d / "sections.json").exists()) \
        if PARSED.exists() else []
    if only:
        wanted = set(only)
        missing = wanted - {d.name for d in paper_dirs}
        for m in sorted(missing):
            print(f"[skip] {m}: no {PARSED / m / 'sections.json'}")
        paper_dirs = [d for d in paper_dirs if d.name in wanted]
    if not paper_dirs:
        print(f"No papers with sections.json under {PARSED}/. Run step 02 (parse) first.")
        return

    done = skipped = failed = 0
    for d in paper_dirs:
        pid = d.name
        out = CHUNKS / pid
        if not needs_rebuild(d, out, params, force):
            skipped += 1
            continue
        try:
            sections = json.loads((d / "sections.json").read_text(encoding="utf-8"))["sections"]
            chunker = PaperChunker(pid, titles.get(pid, pid), count, s)
            chunks = chunker.run(sections)
            out.mkdir(parents=True, exist_ok=True)
            write_atomic(out / "chunks.jsonl",
                         "".join(json.dumps(c, ensure_ascii=False) + "\n" for c in chunks))
            if write_md:
                dump_md(chunks, out / "chunks.md")
            meta = {
                "paper_id": pid,
                "params": params,
                "created": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "n_chunks": len(chunks),
                "stats": dict(chunker.stats),
            }
            write_atomic(out / "chunks_meta.json", json.dumps(meta, indent=2))   # last = done marker
            print(summarize(pid, chunks, chunker.stats))
            done += 1
        except Exception as e:
            failed += 1
            print(f"[error] {pid}: {e} (details in {ERROR_LOG})")
            ERROR_LOG.parent.mkdir(parents=True, exist_ok=True)
            with open(ERROR_LOG, "a", encoding="utf-8") as f:
                f.write(f"--- {datetime.now(timezone.utc).isoformat(timespec='seconds')} {pid}\n")
                f.write(traceback.format_exc() + "\n")

    print(f"\nChunked {done}, up to date {skipped}, failed {failed}.")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--only", nargs="+", metavar="PAPER_ID", help="chunk only these papers")
    ap.add_argument("--force", action="store_true", help="rebuild even if up to date")
    ap.add_argument("--dump-md", action="store_true", help="also write chunks.md for reading")
    ap.add_argument("--doc-index", type=Path, default=DOC_INDEX, help="for document titles")
    ap.add_argument("--target-tokens", type=int, default=DEFAULT_SETTINGS["target_tokens"], help="text chunks stop growing near this")
    ap.add_argument("--max-tokens", type=int, default=DEFAULT_SETTINGS["max_tokens"], help="hard cap for text chunks")
    ap.add_argument("--min-tokens", type=int, default=DEFAULT_SETTINGS["min_tokens"], help="smaller sections merge into the next")
    ap.add_argument("--max-table-tokens", type=int, default=DEFAULT_SETTINGS["max_table_tokens"], help="bigger tables split by rows")
    ap.add_argument("--footnote-cap", type=int, default=DEFAULT_SETTINGS["footnote_cap"],
                    help="a page's footnotes above this many tokens get their own chunk")
    ap.add_argument("--header-min-pages", type=int, default=DEFAULT_SETTINGS["header_min_pages"],
                    help="short text repeated on this many pages counts as a running header")
    args = ap.parse_args()
    settings = {name: getattr(args, name) for name in DEFAULT_SETTINGS}
    run(only=args.only, force=args.force, write_md=args.dump_md, doc_index=args.doc_index, settings=settings)


if __name__ == "__main__":
    main()
