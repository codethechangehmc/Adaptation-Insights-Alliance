import re
from typing import Any

import ftfy


# --- Replacement tables for common PDF/Docling artifacts ---

_LIGATURE_REPLACEMENTS: dict[str, str] = {
    "/uniFB01": "fi",
    "/uniFB02": "fl",
    "/uniFB00": "ff",
    "/uniFB03": "ffi",
    "/C0": "-",
    "/C6": "+-",
    "/C1": "·",
    "/C2": "x",
    "/C211": "@",
    "/C24": "~",
    "/C21": ">",
    "/C3": "*",
}

_GENERAL_REPLACEMENTS: dict[str, str] = {
    "\n": " ",        # keep content on one line
    "\u2013": "-",    # en dash -> hyphen
    "\u0002": "|",    # control char sometimes used as a pipe-like delimiter
    "\u0003": "",     # drop stray control chars
}


def clean_text_with_ftfy(text: str) -> str:
    """
    Clean a single string:
      - fix Unicode issues
      - replace known ligature/glyph artifacts
      - normalize whitespace
    """
    # Fix common Unicode/encoding problems.
    fixed_text = ftfy.fix_text(text)

    # Apply targeted glyph/ligature replacements.
    for src, dst in _LIGATURE_REPLACEMENTS.items():
        fixed_text = fixed_text.replace(src, dst)

    # Apply general text normalization replacements.
    for src, dst in _GENERAL_REPLACEMENTS.items():
        fixed_text = fixed_text.replace(src, dst)

    # Collapse repeated whitespace into single spaces.
    fixed_text = re.sub(r"\s+", " ", fixed_text).strip()
    return fixed_text


def clean_json(data: Any) -> Any:
    """
    Recursively clean strings in a JSON-like structure.

    - dict: clean each value
    - list: clean each element
    - str: clean with `clean_text_with_ftfy`
    - other scalar: return unchanged
    """
    if isinstance(data, dict):
        return {key: clean_json(value) for key, value in data.items()}

    if isinstance(data, list):
        return [clean_json(item) for item in data]

    if isinstance(data, str):
        return clean_text_with_ftfy(data)

    return data