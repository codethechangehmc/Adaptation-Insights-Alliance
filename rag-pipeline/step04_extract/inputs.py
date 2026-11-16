"""Read each report's inputs: the PDF, step 02's sections.json and step 03's chunks.jsonl."""

import json
import re
from collections import Counter
from pathlib import Path

from paths import CHUNKS, PARSED, RAW
from step04_extract.files import MANIFEST, file_hash, fingerprint, read_json, tokens


def load_manifest(path: Path = MANIFEST, selected: list[str] | None = None) -> list[dict]:
    """List the reports to extract, with their files found through paths.py.

    selected: project codes (P001) or paper ids (P001_doc3); None means every report.
    """
    documents = read_json(path)["documents"]
    ids = [d["id"] for d in documents]
    if len(ids) != len(set(ids)) or any(not re.fullmatch(r"[\w-]+", i) for i in ids):
        raise ValueError("Document IDs must be unique safe names.")
    known = set(ids) | {d["paper"] for d in documents}
    if selected and set(selected) - known:
        raise ValueError(f"Not in the manifest: {sorted(set(selected) - known)}")
    resolved = []
    for item in documents:
        if selected and item["id"] not in selected and item["paper"] not in selected:
            continue
        paper = item["paper"]
        resolved.append({
            **item,
            "pdf": RAW / f"{paper}.pdf",
            "sections": PARSED / paper / "sections.json",
            "chunks": CHUNKS / paper / "chunks.jsonl",
        })
    return resolved


def page_range(value: object, page_count: int) -> list[int]:
    """Validate a 1-based PDF page or inclusive page range."""
    raw = [value] if isinstance(value, int) and not isinstance(value, bool) else value
    if not isinstance(raw, list) or not raw:
        raise ValueError("Every nonempty input block needs original PDF pages.")
    if any(type(p) is not int for p in raw):
        raise ValueError("PDF pages must be integers.")
    if raw != sorted(raw) or raw[0] < 1 or raw[-1] > page_count:
        raise ValueError(f"Invalid PDF page range {raw}; document has {page_count} pages.")
    return [raw[0], raw[-1]]


def markdown_table(item: dict) -> str:
    """Render a structured table when the input has no pre-rendered text."""
    header = item.get("header", [])
    rows = header + item.get("rows", [])
    if not rows:
        return ""
    width = max(len(row) for row in rows)
    lines = [
        "| " + " | ".join(str(v) for v in row + [""] * (width - len(row))) + " |" for row in rows
    ]
    if header:
        lines.insert(len(header), "|" + "---|" * width)
    else:
        lines[0:0] = ["|" + " |" * width, "|" + "---|" * width]
    title = f"Table: {item['title']}\n\n" if item.get("title") else ""
    return title + "\n".join(lines)


def item_text(item: dict) -> str:
    """Use rendered parser text once, falling back to structured tables or figure labels."""
    text = item.get("text") or ""
    if not isinstance(text, str):
        raise ValueError("Parsed block text must be a string.")
    # postprocess.py emits this placeholder even when a figure has no extracted words.
    if item.get("type") == "figure" and text.strip() == "Figure: (no caption)":
        text = ""
    if text.strip():
        return text
    if item.get("type") == "figure":
        return "\n".join(value for value in (item.get("caption"), item.get("labels")) if value)
    return markdown_table(item)


def content_block(raw: dict | str, section: dict, page_count: int) -> dict | None:
    """Normalize one typed item while retaining figure references and parser flags."""
    item = {"text": raw} if isinstance(raw, str) else raw
    if not isinstance(item, dict):
        raise ValueError("Section content must contain typed objects or legacy strings.")
    text = item_text(item)
    kind = item.get("type", "table" if text.lstrip().startswith("|") else "text")
    if kind not in ("text", "table", "footnote", "figure"):
        raise ValueError(f"Unsupported parsed block type: {kind}")
    if not text.strip() and kind not in ("figure", "table"):
        return None

    # A footnote's single page takes precedence over the enclosing section range.
    block = {
        "text": text,
        "pages": page_range(item.get("pages", item.get("page", section.get("pages"))), page_count),
        "type": kind,
        "citation_resolution": "section_range" if isinstance(raw, str) else "block_range",
        "suspect": item.get("suspect", []),
    }
    if kind == "figure":
        block.update({key: item.get(key) for key in ("caption", "labels", "image")})
    return block


def normalize_blocks(sections: list[dict], page_count: int) -> list[dict]:
    """Keep every content block once, joining adjacent legacy Markdown table lines."""
    blocks = []
    if not isinstance(sections, list) or any(not isinstance(s, dict) for s in sections):
        raise ValueError("Expected a list of sections with typed content blocks.")
    for section_index, section in enumerate(sections):
        heading = " > ".join(section.get("heading_path") or [section.get("heading") or ""])
        for raw in section.get("content", []):
            block = content_block(raw, section, page_count)
            if block is None:
                continue
            block = {
                **block,
                "id": f"b{len(blocks):04d}",
                "heading": heading,
                "section_id": f"s{section_index:04d}",
            }

            # Older JSON exports each Markdown table row as a separate string.
            if isinstance(raw, str) and block["type"] == "table" and blocks:
                previous = blocks[-1]
                if previous["type"] == "table" and previous["section_id"] == block["section_id"]:
                    previous["text"] += "\n" + block["text"]
                    previous["pages"][1] = max(previous["pages"][1], block["pages"][1])
                    continue
            blocks.append(block)
    if not any(block["text"].strip() for block in blocks):
        raise ValueError("Prepared document contains no nonempty content.")
    return blocks


def render_block(block: dict) -> str:
    """Render a block with its provenance, leaving source text intact."""
    a, b = block["pages"]
    kind = block["type"]
    if not block["text"].strip():
        kind += " without parsed text"
        if block["type"] == "figure":
            kind += "; image not supplied"
    return f"[{block['id']}; PDF pages {a}-{b}; {kind}; {block['heading']}]\n{block['text']}"


def full_text(document: dict) -> str:
    """Return every block once, in reading order: the full parsed method's evidence."""
    return "\n\n".join(render_block(block) for block in document["blocks"])


def load_chunks(path: Path) -> list[dict]:
    """Read step 03's chunks and rename the fields to what search, export and scoring use."""
    chunks = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        c = json.loads(line)
        heading = " > ".join(c.get("heading_path") or [])
        chunks.append({
            "id": c["chunk_id"],
            "text": c["text"],
            "pages": list(c["pages"]),
            "type": c["type"],
            "heading": heading,
            "section_id": heading,                 # neighbours = chunks under the same heading
            "section_kind": c.get("section_kind", "body"),
            "search_text": c["embed_text"],        # text with title/section/page prefix
            "suspect": c.get("suspect_reasons", []),
        })
    if not chunks:
        raise ValueError(f"No chunks in {path}")
    return chunks


def input_diagnostics(blocks: list[dict], metadata: dict, page_count: int) -> dict:
    """Expose parser gaps without treating page-range coverage as proof of a complete parse."""
    text_pages = {
        page
        for block in blocks
        if block["text"].strip()
        for page in range(block["pages"][0], block["pages"][1] + 1)
    }
    return {
        "block_types": dict(Counter(block["type"] for block in blocks)),
        "pages_outside_text_ranges": sorted(set(range(1, page_count + 1)) - text_pages),
        "parser_pages_without_text": metadata.get("fixes", {}).get("pages_without_text", []),
        "figures_without_text": sum(
            b["type"] == "figure" and not b["text"].strip() for b in blocks
        ),
        "tables_without_text": sum(b["type"] == "table" and not b["text"].strip() for b in blocks),
        "suspect_blocks": [b["id"] for b in blocks if b["suspect"]],
    }


def input_warnings(diagnostics: dict) -> list[str]:
    """Describe parse limitations shared by both text-based methods."""
    warnings = ["PDF page ranges are provenance, not proof that every page was parsed."]
    if diagnostics["block_types"].get("figure"):
        warnings.append("Parsed methods use figure text only; figure images are not supplied.")
    if diagnostics["parser_pages_without_text"] or diagnostics["pages_outside_text_ranges"]:
        warnings.append("Some PDF pages have no parsed text; inspect the page-gap diagnostics.")
    if diagnostics["suspect_blocks"]:
        warnings.append("Parser-flagged suspect blocks are retained and need visual review.")
    if diagnostics["tables_without_text"]:
        warnings.append("Some parsed table blocks are empty; no cell values can be extracted.")
    return warnings


def prepare_document(document: dict) -> dict:
    """Read existing artifacts and reject missing or explicitly partial inputs."""
    import pymupdf

    for key in ("pdf", "sections", "chunks"):
        if not document.get(key) or not document[key].is_file():
            raise ValueError(f"missing {key}: {document.get(key)} (run steps 02 and 03 first)")
    if document["pdf"].stat().st_size >= 50_000_000:
        raise ValueError("PDF exceeds the API file size limit.")
    with pymupdf.open(document["pdf"]) as pdf:
        page_count = len(pdf)
    meta = document["sections"].parent / "meta.json"
    metadata = {}
    if meta.exists():
        metadata = read_json(meta)
        if metadata.get("page_range") is not None:
            raise ValueError(f"{document['id']}: parser metadata declares a partial document.")
        if metadata.get("source_file", document["pdf"].name) != document["pdf"].name:
            raise ValueError("Parser source_file does not match the selected PDF.")
    raw = read_json(document["sections"])
    sections = raw["sections"] if isinstance(raw, dict) else raw
    blocks = normalize_blocks(sections, page_count)
    chunks = load_chunks(document["chunks"])
    if any(tokens(c["search_text"]) > 8191 for c in chunks):
        raise ValueError(
            "A chunk exceeds the embedding limit; lower --max-table-tokens in step 03."
        )
    hashes = {k: file_hash(document[k]) for k in ("pdf", "sections", "chunks")}
    if meta.exists():
        hashes["meta"] = file_hash(meta)
    diagnostics = input_diagnostics(blocks, metadata, page_count)
    settings = {"family": document.get("family", "generic"), "focus": document.get("focus", "")}
    return {
        "id": document["id"],
        **settings,
        "pdf": str(document["pdf"]),
        "sections": str(document["sections"]),
        "chunks_file": str(document["chunks"]),
        "page_count": page_count,
        "blocks": blocks,
        "chunks": chunks,
        "input_hash": fingerprint({"source_hashes": hashes, **settings}),
        "source_hashes": hashes,
        "diagnostics": diagnostics,
        "warnings": input_warnings(diagnostics),
    }
