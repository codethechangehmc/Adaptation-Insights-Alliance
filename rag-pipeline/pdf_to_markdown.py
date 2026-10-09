from pathlib import Path
from docling.document_converter import DocumentConverter


def run(source: str | Path, output_dir: str | Path, filename: str = "output.md") -> Path:
    """
    Convert a PDF (or other Docling-supported document) to Markdown and save it.

    Args:
        source: Path to the source document.
        output_dir: Directory where the Markdown file should be written.
        filename: Output Markdown filename (defaults to "output.md").

    Returns:
        The full path to the written Markdown file.
    """
    source = Path(source)
    output_dir = Path(output_dir)
    PAGE_RANGE = (1, 10)

    # --- Validate inputs ---
    if not source.exists():
        raise FileNotFoundError(f"Source document not found: {source}")

    # --- Ensure output directory exists ---
    output_dir.mkdir(parents=True, exist_ok=True)

    # --- Convert document -> Markdown ---
    converter = DocumentConverter()
    kwargs = {"page_range": PAGE_RANGE} if PAGE_RANGE else {}
    result = converter.convert(str(source), **kwargs)
    md_content = result.document.export_to_markdown()

    # --- Write Markdown ---
    out_path = output_dir / filename
    out_path.write_text(md_content, encoding="utf-8")

    print(f"Markdown content saved to {out_path}")
    return out_path