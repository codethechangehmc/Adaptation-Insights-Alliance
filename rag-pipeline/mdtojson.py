import json
from pathlib import Path


def convert_md_to_json(md_file: str | Path, json_file: str | Path) -> None:
    """
    Convert Markdown into a simple JSON structure split by "## " headings.

    Args:
        md_file: Path to the Markdown file to read.
        json_file: Path to the JSON file to write.
    """
    md_file = Path(md_file)
    json_file = Path(json_file)

    # --- Read Markdown as lines ---
    with md_file.open("r", encoding="utf-8") as f:
        md_lines = f.readlines()

    # --- Initialize parsed structure ---
    md_structure = {"sections": []}
    current_section = {"heading": None, "content": []}

    # --- Parse Markdown line-by-line ---
    for line in md_lines:
        line = line.strip()

        # Start a new section on second-level headings ("## ").
        if line.startswith("## "):
            # Save the previous section (if it has any content/heading).
            if current_section["heading"] or current_section["content"]:
                md_structure["sections"].append(current_section)
                current_section = {"heading": None, "content": []}

            # Store the new heading text (strip leading hashes/spaces).
            current_section["heading"] = line.lstrip("# ").strip()
            continue

        # Collect non-empty lines as section content.
        if line:
            current_section["content"].append(line)

    # --- Flush the final section ---
    if current_section["heading"] or current_section["content"]:
        md_structure["sections"].append(current_section)

    # --- Write JSON output ---
    with json_file.open("w", encoding="utf-8") as f:
        json.dump(md_structure, f, ensure_ascii=False, indent=4)

    print(f"Markdown content successfully converted to {json_file}")