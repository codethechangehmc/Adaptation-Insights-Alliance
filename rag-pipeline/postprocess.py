"""
postprocess.py - turn a saved docling.json into clean markdown + sections.json.

WHY WE RENDER FROM docling.json INSTEAD OF USING DOCLING'S MARKDOWN EXPORT
Reading your docling.json showed that most of the table problems are export problems, not parse problems:
  * Each table has `table_cells` (one entry per real cell, with row/col spans) AND `grid` (a 2D expansion
    where a spanning cell is copied into every position it covers). The markdown export reads `grid`,
    which is where "A A A" repeats come from. We read `table_cells`, so a span is emitted once.
  * Markdown tables must start with a header row, so the export promotes the first row to a header even
    when Docling itself didn't flag it as one (that is the fake header + extra |---| line after page breaks).
  * Table footnotes are attached to the table as children and never make it into the markdown export.
  * Docling already labels the table of contents as `document_index` and headers/footers as
    content_layer "furniture", so we can drop those by label instead of guessing from text.

This module only uses plain dicts (json.load of docling.json), so it needs no Docling install and can be
re-run in seconds on saved files (see `python parse.py --reprocess`).
"""
import difflib
import re
from collections import Counter

import ftfy

# ---- thresholds (points; a US-letter page is 612 x 792) ----
MARGIN_PT = 30         # text lying entirely inside this outer strip is a margin stamp, not content
TOP_ZONE_PT = 110      # a table starting within this distance of the page top "starts at the top"
BOTTOM_ZONE_FRAC = 0.2 # a table whose lowest text is within this fraction of page height of the bottom "ends at the bottom"

# --------------------------------------------------------------------------
# Text cleaning (carried over from json_editor.py)
# --------------------------------------------------------------------------
LIGATURES = {
    "/uniFB01": "fi", "/uniFB02": "fl", "/uniFB00": "ff", "/uniFB03": "ffi",
    "/C0": "-", "/C6": "+-", "/C1": "·", "/C2": "x", "/C211": "@",
    "/C24": "~", "/C21": ">", "/C3": "*",
}
GENERAL = {
    "\n": " ",
    "\u2013": "-",   # en dash -> hyphen
    "\u0002": "|",   # control char sometimes used as a pipe-like delimiter
    "\u0003": "",    # stray control char
}


# Word lists use a Symbol/Wingdings font whose bullet glyphs live in Unicode's Private Use Area. They are
# not real characters (they show as boxes or nothing), so we map the common bullet glyphs to a real bullet.
# We map only known bullets, not the whole range: other glyphs in that range can be real letters from a
# symbol font (U+F061 is a Greek alpha in Symbol), and silently deleting those would lose content.
PRIVATE_USE_BULLETS = "\uf0b7\uf0a7\uf0d8\uf076\uf06e"   # written as escapes on purpose: the raw characters are invisible in editors


def clean_text(text: str) -> str:
    text = ftfy.fix_text(text)
    for ch in PRIVATE_USE_BULLETS:
        text = text.replace(ch, "•")
    for src, dst in LIGATURES.items():
        text = text.replace(src, dst)
    for src, dst in GENERAL.items():
        text = text.replace(src, dst)
    return re.sub(r"\s+", " ", text).strip()


# --------------------------------------------------------------------------
# Walking the document in reading order
# --------------------------------------------------------------------------
def resolve(doc: dict, ref: dict):
    """{"$ref": "#/texts/12"} -> ("texts", the item)."""
    _, coll, idx = ref["$ref"].split("/")
    return coll, doc[coll][int(idx)]


def iter_blocks(doc: dict):
    """
    Yield ("text", item) / ("table", item) in reading order (body.children order).
    Groups (key-value areas, lists) and pictures are walked into: the group itself has no text, its
    children do. A table's own children are its footnotes; those are read via table["footnotes"] instead.
    """
    def walk(children):
        for ref in children:
            coll, item = resolve(doc, ref)
            if coll in ("groups", "pictures"):
                yield from walk(item.get("children", []))
            elif coll == "texts":
                yield ("text", item)
                yield from walk(item.get("children", []))
            elif coll == "tables":
                yield ("table", item)
    yield from walk(doc["body"]["children"])


def page_size(doc: dict, page_no: int):
    size = doc.get("pages", {}).get(str(page_no), {}).get("size", {})
    return size.get("width", 612.0), size.get("height", 792.0)


def y_range(bbox: dict, page_h: float):
    """(top, bottom) in bottom-left coordinates, so top > bottom. Docling mixes origins, so convert."""
    t, b = bbox["t"], bbox["b"]
    if bbox.get("coord_origin") == "TOPLEFT":
        t, b = page_h - t, page_h - b
    return max(t, b), min(t, b)


# --------------------------------------------------------------------------
# Text items
# --------------------------------------------------------------------------
def is_margin_stamp(doc: dict, item: dict) -> bool:
    """
    The rotated 'Public Disclosure Authorized' stamp on page 1 is labelled as ordinary body text (4 copies,
    two of them marked furniture, two not). It sits entirely inside the left margin, so: text that lies
    wholly in the outer MARGIN_PT strip of the page is dropped. Real body text never does.
    """
    prov = item.get("prov") or []
    if not prov:
        return False
    width, _ = page_size(doc, prov[0]["page_no"])
    bb = prov[0]["bbox"]
    return bb["r"] < MARGIN_PT or bb["l"] > width - MARGIN_PT


def render_text(doc: dict, item: dict, stats: Counter):
    """Return (kind, level, text) or None if the item should be invisible."""
    label = item.get("label")
    if item.get("content_layer") == "furniture" or label in ("page_header", "page_footer"):
        stats["furniture_dropped"] += 1
        return None
    text = clean_text(item.get("text", ""))
    if not text:
        return None
    if is_margin_stamp(doc, item):
        stats["margin_text_dropped"] += 1
        return None
    if label in ("title", "section_header") and len(text) > MAX_HEADING_CHARS:
        # e.g. an acronym list read as one giant heading. Keep the words as ordinary text (so they still
        # reach sections.json and the chunker) and record it so a human can look at the page.
        prov = item.get("prov") or []
        stats["headings_demoted_long"] += 1
        stats.setdefault("demoted_heading_list", []).append(
            {"page": prov[0]["page_no"] if prov else None, "chars": len(text), "preview": text[:80]})
        return ("text", 0, text)
    if label == "title":
        return ("heading", 1, text)
    if label == "section_header":
        # Docling's markdown export writes level-1 headers as "##"; keep that convention.
        return ("heading", item.get("level", 1) + 1, text)
    if label == "list_item":
        # Some PDFs keep the bullet glyph inside the item text; we add our own "- ", so drop theirs.
        return ("text", 0, "- " + text.lstrip("\u2022 ").strip())
    if label == "footnote":
        return None   # footnotes are collected from the whole document by collect_footnotes()
    return ("text", 0, text)


# --------------------------------------------------------------------------
# Footnotes
# --------------------------------------------------------------------------
# A footnote starts with a marker: a number ("1 There were..."), a symbol, or "(a)".
FOOTNOTE_MARKER_RE = re.compile(r"^\s*(\d{1,3}|[*†‡§¶#]+|\(\w{1,3}\)|\[\w{1,3}\])(\s|[.):])")
MAX_HEADING_CHARS = 200   # a real heading is a short line; anything longer is body text the layout model mislabelled
CONTINUATION_GAP = 0.5   # a line starting less than 0.5 line-heights below the previous one is the same footnote


def collect_footnotes(doc: dict, stats: Counter) -> list:
    """
    Gather EVERY item Docling labelled `footnote`, wherever it hangs in the tree, and return them as
    [{"page", "text"}] in page / top-to-bottom order.

    Why not use table["footnotes"]: Docling attaches a footnote to whichever table is nearest on the page.
    Footnotes 1 and 2 of our test file annotate the paragraphs ABOVE a table but were attached to it,
    so rendering them with the table put them pages away from the text they explain.

    Docling also splits one wrapped footnote into several items (footnote 1 arrived as two). We merge
    item B into the previous item A only if BOTH hold: B has no footnote marker, and B starts directly
    under A (gap under CONTINUATION_GAP of a line height). Requiring both is the conservative choice:
    when unsure we leave two notes rather than gluing two unrelated ones together.
    """
    items = []
    for t in doc["texts"]:
        if t.get("label") != "footnote" or t.get("content_layer") == "furniture" or not t.get("prov"):
            continue
        text = clean_text(t.get("text", ""))
        if not text or is_margin_stamp(doc, t):
            continue
        p = t["prov"][0]
        top, bottom = y_range(p["bbox"], page_size(doc, p["page_no"])[1])
        items.append({"page": p["page_no"], "text": text, "top": top, "bottom": bottom})
    items.sort(key=lambda n: (n["page"], -n["top"]))

    notes = []
    for it in items:
        prev = notes[-1] if notes else None
        if prev and prev["page"] == it["page"] and not FOOTNOTE_MARKER_RE.match(it["text"]):
            gap = prev["bottom"] - it["top"]
            line_h = min(prev["bottom_h"], it["top"] - it["bottom"])
            if gap < CONTINUATION_GAP * line_h:
                prev["text"] += " " + it["text"]
                prev["bottom"], prev["bottom_h"] = it["bottom"], it["top"] - it["bottom"]
                stats["footnote_pieces_merged"] += 1
                continue
        notes.append({"page": it["page"], "text": it["text"], "bottom": it["bottom"],
                      "bottom_h": it["top"] - it["bottom"]})
    stats["footnotes_kept"] += len(notes)
    return [{"page": n["page"], "text": n["text"]} for n in notes]


def place_footnotes(blocks: list, notes: list) -> list:
    """
    Put each footnote after the last block of the SECTION it most plausibly annotates.
    A footnote is usually cited from prose on its page, so: (1) the last section with a prose block on
    that page; else (2) the last section with any block on that page (e.g. a footnote cited inside a
    table); else (3) the last section that started before that page.
    Known limit: if two sections share a page, a footnote can land in the wrong one. Only matching the
    footnote number to its marker in the text would settle that, and Docling doesn't record superscripts.
    """
    if not notes:
        return blocks
    sec_of, sid = [], 0
    for b in blocks:
        if b["kind"] == "heading":
            sid += 1
        sec_of.append(sid)

    def covers(b, p):
        a, z = b["pages"]
        return a is not None and a <= p <= (z if z is not None else a)

    def pick(p):
        for test in (lambda b: b["kind"] == "text" and covers(b, p),
                     lambda b: b["kind"] != "heading" and covers(b, p),
                     lambda b: b["pages"][0] is not None and b["pages"][0] <= p):
            hits = [sec_of[i] for i, b in enumerate(blocks) if test(b)]
            if hits:
                return max(hits)
        return sec_of[-1] if sec_of else 0

    by_section: dict = {}
    for n in notes:
        by_section.setdefault(pick(n["page"]), []).append(n)
    last_index = {}
    for i, s in enumerate(sec_of):
        last_index[s] = i

    out = []
    for i, b in enumerate(blocks):
        out.append(b)
        if last_index[sec_of[i]] == i:
            for n in by_section.pop(sec_of[i], []):
                out.append({"kind": "footnote", "level": 0, "text": n["text"], "pages": (n["page"], n["page"])})
    return out


# --------------------------------------------------------------------------
# Tables
# --------------------------------------------------------------------------
def grid(item: dict):
    """
    Build rows from table_cells (NOT from `grid`, which repeats spanning cells).
    rows[r][c] is: the cell text at the cell's first column, None where a horizontal span covers it,
    "" for a genuinely empty cell. A cell spanning several ROWS repeats its text on each row (so a
    row label that spans 3 rows is still attached to all 3 rows after chunking). Returns (rows, flags)
    where flags[r] lists the column_header flag of each non-empty cell in row r.
    """
    d = item["data"]
    n_rows, n_cols = d["num_rows"], d["num_cols"]
    rows = [[""] * n_cols for _ in range(n_rows)]
    flags = [[] for _ in range(n_rows)]
    for c in d["table_cells"]:
        r0, r1 = c["start_row_offset_idx"], min(c["end_row_offset_idx"], n_rows)
        c0, c1 = c["start_col_offset_idx"], min(c["end_col_offset_idx"], n_cols)
        text = clean_text(c.get("text", "")).replace("|", "/")   # keep "|" for structure only
        for r in range(r0, r1):
            for k in range(c0, c1):
                rows[r][k] = text if k == c0 else None
        if text:
            flags[r0].append(bool(c.get("column_header")))
    return rows, flags


def nonempty(row):
    return [x for x in row if x]


def is_title_row(row) -> bool:
    """
    A title row has exactly one non-empty cell AND that cell starts in the first column.
    The second condition matters: in af_01 a table that continued on the next page began with a row whose
    only filled cell was a piece of the 'Expected results' column (columns 2-3 of 4). It has one cell, but
    it is body text, not a caption. Every real title in our 3 test files starts at column 0 (some span the
    whole width, some only the first column), so "starts at column 0" is the rule that separates them.
    grid() puts a cell's text at its first column, so row[0] being non-empty means "starts at column 0".
    """
    return len(nonempty(row)) == 1 and bool(row[0])


def peel(rows, flags):
    """
    Split a table into (titles, header_rows, body_rows).
    Title row  = a leading row that is_title_row() ("B. Key Dates" spanning all columns, or
                 "D. Sector and Theme Codes" with the rest empty). It is a caption, not a row.
    Header row = leading rows where every non-empty cell has Docling's column_header flag.
    Both only look at the TOP of a table; mid-table rows are never reclassified.
    """
    titles, header, i = [], [], 0
    while i < len(rows) - 1 and i < 3 and is_title_row(rows[i]):
        titles.append(nonempty(rows[i])[0])
        i += 1
    while i < len(rows) - 1 and flags[i] and all(flags[i]):
        header.append(rows[i])
        i += 1
    return titles, header, rows[i:]


OVERLAP_FRAC = 0.2      # cells in different rows whose boxes overlap by more than this (of the smaller box)
INTRUSION_PT = 12       # a cell reaching this far into the next column's text area


def table_suspects(item: dict) -> list:
    """
    Detect tables where Docling's table model probably assigned text to the wrong cells. We can't repair
    these without guessing, so we flag them for human review instead. Two checks, both pure geometry
    from the cell boxes in docling.json (nothing about this particular document):
      1. Overlap across rows: two cells in DIFFERENT rows whose text boxes overlap. A real row never
         overlaps the next one, so the model must have pulled text from another row into this cell
         (Table A: the 'Cofinanciers...' line was absorbed into the 'Revised Amount' row).
      2. Column intrusion: a one-column cell whose text box reaches INTRUSION_PT or more into the next
         column's text area, i.e. text from two neighbouring cells fused into one
         (C.2: 'Moderately SatisfactoryGovernment:').
    Thresholds were tuned by eye on one file. Flagged tables are for review, so a false alarm is cheap,
    but check they aren't noisy when you run more PDFs.
    """
    cells = [c for c in item["data"]["table_cells"] if c.get("bbox") and c.get("text", "").strip()]
    reasons = []

    ordered = sorted(cells, key=lambda c: c["start_row_offset_idx"])
    for i, a in enumerate(ordered):
        for b in ordered[i + 1:]:
            if b["start_row_offset_idx"] - a["start_row_offset_idx"] > 3:
                break                                        # only neighbouring rows can bleed into each other
            if b["start_row_offset_idx"] < a["end_row_offset_idx"]:
                continue                                     # share a row (or a row span): not a cross-row case
            A, B = a["bbox"], b["bbox"]
            ix = min(A["r"], B["r"]) - max(A["l"], B["l"])
            iy = min(max(A["t"], A["b"]), max(B["t"], B["b"])) - max(min(A["t"], A["b"]), min(B["t"], B["b"]))
            if ix <= 0 or iy <= 0:
                continue
            small = min((A["r"] - A["l"]) * abs(A["t"] - A["b"]), (B["r"] - B["l"]) * abs(B["t"] - B["b"])) or 1
            if ix * iy / small > OVERLAP_FRAC:
                reasons.append(f"cells in different rows overlap: '{a['text'][:30]}' / '{b['text'][:30]}'")
                break
        if reasons:
            break

    by_col: dict = {}
    for c in cells:
        if c["end_col_offset_idx"] - c["start_col_offset_idx"] == 1:
            by_col.setdefault(c["start_col_offset_idx"], []).append(c)
    for col, items in by_col.items():
        nxt = by_col.get(col + 1, [])
        if len(nxt) < 2:
            continue                                         # need a few neighbours to know where the next column starts
        next_left = min(c["bbox"]["l"] for c in nxt)
        for c in items:
            if c["bbox"]["r"] > next_left + INTRUSION_PT:
                reasons.append(f"cell runs into the next column (fused text?): '{c['text'][:40]}'")
                break
    return reasons


def lowest_y(doc: dict, item: dict) -> float:
    """Lowest y of the table or its footnotes. Footnotes sit below the table but are still 'at the bottom'."""
    ys = []
    for it in [item] + [resolve(doc, r)[1] for r in item.get("footnotes", [])]:
        p = it["prov"][-1]
        ys.append(y_range(p["bbox"], page_size(doc, p["page_no"])[1])[1])
    return min(ys)


def continues(doc: dict, prev: dict, nxt: dict) -> bool:
    """
    Is `nxt` the continuation of `prev` across a page break? All must hold:
      1. nxt is on the very next page and has the same number of columns;
      2. prev reaches the bottom of its page and nxt starts at the top of the next one;
      3. nxt does NOT open with a title row. (Without this, 'C.2 Detailed Ratings' (page 5) and
         'C.3 Quality at Entry' (page 6) look identical to a split table: both 4 columns, one at the
         bottom, one at the top. C.3 opens with its own title row, so it is a new table.)
    Reading-order adjacency (nothing but furniture in between) is enforced by the caller.
    """
    p_last, n_first = prev["prov"][-1], nxt["prov"][0]
    if n_first["page_no"] != p_last["page_no"] + 1:
        return False
    if prev["data"]["num_cols"] != nxt["data"]["num_cols"]:
        return False
    prev_h = page_size(doc, p_last["page_no"])[1]
    next_h = page_size(doc, n_first["page_no"])[1]
    top_next = y_range(n_first["bbox"], next_h)[0]
    if not (next_h - top_next < TOP_ZONE_PT and lowest_y(doc, prev) < prev_h * BOTTOM_ZONE_FRAC):
        return False
    return not is_title_row(grid(nxt)[0][0])   # same test as peel(), so the two can never disagree


def row_line(row) -> str:
    return "| " + " | ".join(x for x in row if x is not None) + " |"


def build_and_render_table(doc: dict, chain: list) -> dict:
    """
    Render one logical table (a chain of Docling tables joined across page breaks) to a single string.
    Format:  Table: <title(s)>  /  header row + |---| separator (only if Docling flagged a header)  /
             body rows  /  Footnote: ... lines.
    Only the FIRST piece is peeled for titles/headers. Continuation pieces are body rows only, because
    Docling wrongly flags their first row as a header (it did for the tables on pages 9 and 10).
    If a continuation repeats the header row at the top of the new page, that repeat is dropped.
    """
    rows, flags = grid(chain[0])
    titles, header, body = peel(rows, flags)
    for piece in chain[1:]:
        more, _ = grid(piece)
        if header and more and row_line(more[0]) == row_line(header[-1]):
            more = more[1:]
        body.extend(more)

    # Markdown only renders a pipe table if it has a header row + |---| separator. Many of these tables
    # (e.g. "A. Basic Information") have no real header, so we emit an EMPTY header row instead of
    # inventing one or promoting a data row. Width = the widest row, since spanning rows are narrower.
    peel_header = header                      # the REAL header (maybe none); the structured output uses this
    if not header and body:
        width = max(len([x for x in r if x is not None]) for r in body)
        header = [[""] * width]
    n_cols = max((len([x for x in r if x is not None]) for r in header), default=0)

    table_lines = [row_line(h) for h in header]
    if header:
        table_lines.append("|" + "---|" * n_cols)
    table_lines.extend(row_line(r) for r in body)

    # Blank lines between title / table / footnotes: otherwise a viewer can read a "Footnote: ..."
    # line directly under the table as one more table row.
    parts = []
    if titles:
        parts.append("Table: " + " / ".join(titles))
    parts.append("\n".join(table_lines))

    # Structured copy for the chunker (sections.json). header is [] when the table has no real header
    # (the empty header row above exists only so markdown renders). Spanned positions (None) are dropped,
    # same as in the markdown rows.
    squash = lambda r: [x for x in r if x is not None]
    suspects = []
    for piece in chain:
        suspects += table_suspects(piece)
    return {
        "text": "\n\n".join(parts),
        "pages": (chain[0]["prov"][0]["page_no"], chain[-1]["prov"][-1]["page_no"]),
        "title": " / ".join(titles) or None,
        "header": [squash(h) for h in peel_header],
        "rows": [squash(r) for r in body],
        "suspect": suspects,
    }


# --------------------------------------------------------------------------
# Rebuilding a table row-by-row from the PDF when Docling stopped seeing the table
# --------------------------------------------------------------------------
COL_TOL_PT = 3          # a word starting within this much left of a column's left edge still belongs to that column
REBUILD_MIN_MATCH = 0.9  # rebuilt text must match what Docling read, or the region was wrong -> don't use it
REBUILD_MIN_ROWS = 3


def pdf_words(pdf_path, page_no: int, region: dict, page_h: float):
    """
    Words from the PDF's own text layer that sit inside `region` (a Docling bbox), as a list of lines,
    each line a list of (left, bottom, right, top, text) sorted left to right. Coordinates are PDF points,
    origin bottom-left, the same as Docling's. Uses pypdfium2, which Docling already installs.
    """
    import pypdfium2 as pdfium
    pdf = pdfium.PdfDocument(str(pdf_path))
    try:
        tp = pdf[page_no - 1].get_textpage()
        top, bottom = y_range(region, page_h)
        left, right = region["l"], region["r"]
        chars, space_before = [], False
        for i in range(tp.count_chars()):
            ch = tp.get_text_range(i, 1)
            if not ch.strip():
                space_before = True      # a space has no usable position in the PDF, so remember it by order
                continue
            l, b, r, t = tp.get_charbox(i)
            cx, cy = (l + r) / 2, (b + t) / 2
            if left - 2 <= cx <= right + 2 and bottom - 2 <= cy <= top + 2:
                chars.append((ch, l, b, r, t, space_before))
            space_before = False
    finally:
        pdf.close()
    if not chars:
        return []
    heights = sorted(t - b for ch, l, b, r, t, sp in chars if t > b)
    h = heights[len(heights) // 2] if heights else 10.0
    # group characters into lines by vertical centre (top of the page first)
    lines = []
    for c in sorted(chars, key=lambda c: -(c[2] + c[4]) / 2):
        cy = (c[2] + c[4]) / 2
        if lines and abs(lines[-1]["cy"] - cy) < 0.5 * h:
            lines[-1]["chars"].append(c)
            lines[-1]["cy"] = (lines[-1]["cy"] * (len(lines[-1]["chars"]) - 1) + cy) / len(lines[-1]["chars"])
        else:
            lines.append({"cy": cy, "chars": [c]})
    out = []
    for ln in lines:
        words, cur, prev_r = [], [], None
        for ch, l, b, r, t, sp in sorted(ln["chars"], key=lambda c: c[1]):
            if cur and (sp or (prev_r is not None and l - prev_r > 0.8 * h)):   # a space, or a big gap without one
                words.append(cur)
                cur = []
            cur.append((ch, l, b, r, t))
            prev_r = r
        if cur:
            words.append(cur)
        out.append([(min(c[1] for c in w), min(c[2] for c in w), max(c[3] for c in w), max(c[4] for c in w),
                     "".join(c[0] for c in w)) for w in words])
    return out


def rebuild_continuation(doc: dict, prev: dict, item: dict, text: str, pdf_path):
    """
    A table ends at the bottom of one page and Docling reads the next page's rows as one giant heading
    or paragraph. If `item` (that text) sits at the top of the next page, re-read the page's words from the
    PDF, split them into columns at the same x-positions as `prev`'s columns, and return a table item with
    those rows. Returns (table_item, None) or (None, reason). Never guesses: any mismatch -> (None, reason).
    """
    if not pdf_path:
        return None, "PDF not available"
    prov = (item.get("prov") or [None])[0]
    p_last = prev["prov"][-1]
    if not prov or prov["page_no"] != p_last["page_no"] + 1:
        return None, "not on the page after the table"
    prev_h = page_size(doc, p_last["page_no"])[1]
    next_h = page_size(doc, prov["page_no"])[1]
    if not (next_h - y_range(prov["bbox"], next_h)[0] < TOP_ZONE_PT and lowest_y(doc, prev) < prev_h * BOTTOM_ZONE_FRAC):
        return None, "table does not reach the page bottom / text does not start at the next page top"

    # where each column of the previous table starts (left edge of its leftmost text)
    left_by_col: dict = {}
    for c in prev["data"]["table_cells"]:
        if c.get("bbox") and c.get("text", "").strip() and c["end_col_offset_idx"] - c["start_col_offset_idx"] == 1:
            col = c["start_col_offset_idx"]
            left_by_col[col] = min(left_by_col.get(col, 1e9), c["bbox"]["l"])
    n_cols = prev["data"]["num_cols"]
    if n_cols < 2 or len(left_by_col) != n_cols:
        return None, "could not find every column's position in the table above"
    starts = [left_by_col[k] for k in range(n_cols)]

    try:
        lines = pdf_words(pdf_path, prov["page_no"], prov["bbox"], next_h)
    except Exception as e:                           # missing pypdfium2, unreadable PDF, ...
        return None, f"could not read the PDF ({type(e).__name__})"
    if not lines:
        return None, "no text found in the PDF at that spot"

    rows = []                                        # each row: [ [words] per column ], plus cell boxes
    for words in lines:
        cols = [[] for _ in range(n_cols)]
        for w in words:
            k = max((k for k in range(n_cols) if starts[k] <= w[0] + COL_TOL_PT), default=0)
            cols[k].append(w)
        if cols[0]:
            rows.append(cols)
        elif rows:                                   # wrapped line: no first-column text -> belongs to the row above
            for k in range(n_cols):
                rows[-1][k].extend(cols[k])
        else:
            return None, "text starts mid-row (a row wraps over the page break)"
    if len(rows) < REBUILD_MIN_ROWS:
        return None, f"only {len(rows)} rows found"

    cells = []
    for r, cols in enumerate(rows):
        for k, ws in enumerate(cols):
            if not ws:
                continue
            cells.append({"start_row_offset_idx": r, "end_row_offset_idx": r + 1,
                          "start_col_offset_idx": k, "end_col_offset_idx": k + 1,
                          "text": " ".join(w[4] for w in ws), "column_header": False,
                          "bbox": {"l": min(w[0] for w in ws), "b": min(w[1] for w in ws),
                                   "r": max(w[2] for w in ws), "t": max(w[3] for w in ws),
                                   "coord_origin": "BOTTOMLEFT"}})
    sparse = sum(1 for cols in rows if not any(cols[1:])) / len(rows)
    if sparse > 0.3:
        return None, "many rows have nothing after the first column"

    norm = lambda s: re.sub(r"\W", "", clean_text(s)).lower()
    a, b = norm(" ".join(c["text"] for c in cells)), norm(text)
    if difflib.SequenceMatcher(None, a, b, autojunk=False).ratio() < REBUILD_MIN_MATCH:
        return None, "rebuilt text does not match what Docling read"

    item2 = {"label": "table", "footnotes": [], "prov": [{"page_no": prov["page_no"], "bbox": prov["bbox"]}],
             "data": {"num_rows": len(rows), "num_cols": n_cols, "table_cells": cells}}
    return item2, None


# --------------------------------------------------------------------------
# Whole document -> blocks -> markdown / sections
# --------------------------------------------------------------------------
def render_document(doc: dict, stats: Counter, pdf_path=None) -> list:
    """
    Return blocks in reading order: {"kind": "heading"|"text"|"table", "text", "level", "pages": (first, last)}.
    A table is only merged with the previous table if NOTHING visible sits between them. Furniture and
    margin stamps are invisible (they don't break a chain); real text or a dropped TOC does.
    """
    blocks, chain = [], []

    def flush():
        nonlocal chain
        if chain:
            t = build_and_render_table(doc, chain)
            blocks.append({"kind": "table", "level": 0, **t})
            stats["tables"] += 1
            stats["tables_merged_across_pages"] += len(chain) - 1
            if t["suspect"]:
                stats["suspect_tables"] += 1
            chain = []

    for kind, item in iter_blocks(doc):
        if kind == "text":
            r = render_text(doc, item, stats)
            if r is None:
                continue
            if chain and r[0] == "text" and item.get("label") in ("title", "section_header"):
                # a long heading was just demoted. If it sits right under a table that ran to the bottom of the
                # previous page, it is probably that table's next rows: try to rebuild them from the PDF.
                synth, why = rebuild_continuation(doc, chain[-1], item, r[2], pdf_path)
                note = stats["demoted_heading_list"][-1]
                if synth:
                    chain.append(synth)
                    stats["demoted_headings_rebuilt_as_rows"] += 1
                    note["rebuilt_rows"] = synth["data"]["num_rows"]
                    continue
                note["not_rebuilt"] = why
            flush()
            prov = item.get("prov") or []
            page = prov[0]["page_no"] if prov else None
            blocks.append({"kind": r[0], "level": r[1], "text": r[2], "pages": (page, prov[-1]["page_no"] if prov else None)})
        else:
            if item.get("label") == "document_index":     # Docling's own label for a table of contents
                stats["index_tables_dropped"] += 1
                flush()
                continue
            if chain and continues(doc, chain[-1], item):
                chain.append(item)
            else:
                flush()
                chain = [item]
    flush()
    return place_footnotes(blocks, collect_footnotes(doc, stats))


def to_markdown(blocks: list) -> str:
    parts = []
    for b in blocks:
        if b["kind"] == "heading":
            parts.append("#" * b["level"] + " " + b["text"])
        elif b["kind"] == "footnote":
            parts.append("Footnote: " + b["text"])
        else:
            parts.append(b["text"])
    return "\n\n".join(parts)


TOC_RE = re.compile(r"^(table of )?contents$", re.I)


def typed_item(b: dict) -> dict:
    """
    One entry of a section's `content`. Typed so the chunker never has to guess what a string is:
      {"type": "text",     "text", "pages"}
      {"type": "table",    "title", "header" (list of rows, [] if none), "rows", "text" (rendered markdown),
                           "pages", and "suspect" (reasons) only if the table looks mis-parsed}
      {"type": "footnote", "text", "page"}
    A table is ONE item, so the chunker can keep it whole, or split `rows` and repeat title + header.
    """
    if b["kind"] == "footnote":
        return {"type": "footnote", "text": b["text"], "page": b["pages"][0]}
    if b["kind"] == "table":
        item = {"type": "table", "title": b["title"], "header": b["header"], "rows": b["rows"],
                "text": b["text"], "pages": list(b["pages"])}
        if b["suspect"]:
            item["suspect"] = b["suspect"]
        return item
    return {"type": "text", "text": b["text"], "pages": list(b["pages"])}


def to_sections(blocks: list, stats: Counter) -> list:
    """
    Group blocks into sections at each heading. Each section keeps its heading level, a heading_path
    (built from a stack, so a parent heading with no text still appears in its children's path), and the
    first/last page it covers. `content` is a list of typed items (see typed_item).
    NOTE: Docling gave every heading level 1 in the file we inspected, so heading_path is usually just
    [current heading]. It becomes hierarchical only if levels differ.
    """
    sections, stack = [], []
    cur = {"heading": None, "level": 0, "heading_path": [], "content": [], "_pages": []}

    def flush():
        if cur["content"]:
            pages = [p for p in cur.pop("_pages") if p is not None]
            cur["pages"] = [min(pages), max(pages)] if pages else None
            sections.append(cur)

    for b in blocks:
        if b["kind"] == "heading":
            flush()
            while stack and stack[-1][0] >= b["level"]:
                stack.pop()
            stack.append((b["level"], b["text"]))
            cur = {"heading": b["text"], "level": b["level"], "heading_path": [t for _, t in stack],
                   "content": [], "_pages": list(b["pages"])}
        else:
            cur["content"].append(typed_item(b))
            cur["_pages"].extend(b["pages"])
    flush()

    kept = [s for s in sections if not (s["heading"] and TOC_RE.match(s["heading"]))]
    stats["toc_sections_dropped"] += len(sections) - len(kept)
    return kept


def process(doc: dict, pdf_path=None):
    """docling.json dict (+ the source PDF, if available, for rebuilding rows) -> (clean_markdown, sections, stats)."""
    stats: Counter = Counter()
    blocks = render_document(doc, stats, pdf_path)
    sections = to_sections(blocks, stats)
    out_stats = dict(stats)
    review = [{"pages": list(b["pages"]), "title": b["title"], "reasons": b["suspect"]}
              for b in blocks if b["kind"] == "table" and b["suspect"]]
    out_stats.setdefault("suspect_tables", 0)         # always present, so review.py can tell "none" from "old run"
    if review:
        out_stats["suspect_table_list"] = review      # tables a human should check against the PDF
    out_stats.setdefault("headings_demoted_long", 0)  # always present, like suspect_tables (0 = nothing demoted)
    return to_markdown(blocks), sections, out_stats
