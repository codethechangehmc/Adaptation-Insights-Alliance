"""Rule checks shared by every source: keywords, African places, language and dates."""

from __future__ import annotations

import json
import re
import unicodedata
from datetime import date, datetime
from functools import lru_cache
from pathlib import Path

AFRICA = json.loads(
    (Path(__file__).resolve().parents[1] / "config" / "africa.json").read_text(encoding="utf-8")
)
AGRICULTURE_KEYWORDS: list[str] = AFRICA["agriculture_keywords"]
ADAPTATION_KEYWORDS: list[str] = AFRICA["adaptation_keywords"]
SCOPE_KEYWORDS = AGRICULTURE_KEYWORDS + ADAPTATION_KEYWORDS

ENGLISH_WORDS = {"the", "and", "of", "to", "in", "for", "with", "on", "by", "from"}
FRENCH_WORDS = {"le", "la", "les", "des", "et", "du", "pour", "dans", "sur", "au", "aux"}
PORTUGUESE_WORDS = {"o", "os", "dos", "das", "e", "do", "da", "para", "com", "nos", "nas"}
ENGLISH_CODES = {"en", "eng", "english"}

DATE_FORMATS = ("%Y-%m-%d", "%d %B %Y", "%B %d, %Y", "%d %b %Y", "%b %d, %Y", "%B %Y", "%b %Y")


def fold(text: str) -> str:
    """Lower-case text, remove accents and unify apostrophes, for place-name matching."""
    text = text.replace("’", "'").replace("‘", "'").casefold()
    decomposed = unicodedata.normalize("NFKD", text)
    return "".join(char for char in decomposed if not unicodedata.combining(char))


@lru_cache(maxsize=1024)
def keyword_pattern(keyword: str) -> re.Pattern:
    """Return a whole-word, case-insensitive pattern that also accepts a regular plural."""
    # Accents stay: folding a word could turn it into a common English word.
    word = unicodedata.normalize("NFC", keyword.casefold())
    forms = {word, word + "s"}
    if word.endswith(("s", "x", "z", "ch", "sh")):
        forms.add(word + "es")
    if re.search(r"[^aeiou]y$", word):
        forms.add(word[:-1] + "ies")
    alternatives = "|".join(re.escape(form) for form in sorted(forms, key=len, reverse=True))
    return re.compile(r"(?<!\w)(?:" + alternatives + r")(?!\w)")


def find_keywords(text: str, keywords: list[str] | None = None) -> list[str]:
    """Return the keywords found in text, in list order. Defaults to the scope keywords."""
    prepared = unicodedata.normalize("NFC", text.casefold())
    terms = SCOPE_KEYWORDS if keywords is None else keywords
    return [term for term in terms if keyword_pattern(term).search(prepared)]


@lru_cache(maxsize=1)
def place_pattern() -> tuple[re.Pattern, dict[str, str]]:
    """Build one pattern for every country, region and non-African look-alike name."""
    # Map each folded alias to what it names. Non-African names map to "".
    names: dict[str, str] = {}
    for country, aliases in AFRICA["countries"].items():
        names.update({fold(alias): f"country:{country}" for alias in aliases})
    for region, aliases in AFRICA["regions"].items():
        names.update({fold(alias): f"region:{region}" for alias in aliases})
    names.update({fold(alias): "" for alias in AFRICA["not_african"]})

    # Longest names first, so "Papua New Guinea" wins over "Guinea" at the same place.
    alternatives = "|".join(re.escape(name) for name in sorted(names, key=len, reverse=True))
    return re.compile(r"(?<!\w)(?:" + alternatives + r")(?!\w)"), names


def find_places(text: str) -> tuple[list[str], list[str]]:
    """Return the African countries and regions named in text, without repeats.

    Multi-country fields such as "Kenya,Uganda" work, and names that only contain
    an African name, such as "Papua New Guinea", are ignored.
    """
    pattern, names = place_pattern()
    countries: list[str] = []
    regions: list[str] = []
    for match in pattern.finditer(fold(text)):
        kind, _, name = names[match.group()].partition(":")
        if kind == "country" and name not in countries:
            countries.append(name)
        elif kind == "region" and name not in regions:
            regions.append(name)
    return countries, regions


def find_countries(text: str) -> list[str]:
    """Return the African countries named in text."""
    return find_places(text)[0]


def is_african(text: str) -> bool:
    """Return True when text names an African country or region."""
    countries, regions = find_places(text)
    return bool(countries or regions)


def guess_language(text: str) -> str:
    """Guess english, french or portuguese from common short words; "" when unsure."""
    words = re.findall(r"[^\W\d_]+", text.casefold())
    counts = {
        "english": sum(word in ENGLISH_WORDS for word in words),
        "french": sum(word in FRENCH_WORDS for word in words),
        "portuguese": sum(word in PORTUGUESE_WORDS for word in words),
    }
    best = max(counts, key=lambda language: counts[language])
    others = [count for language, count in counts.items() if language != best]
    if counts[best] < 2 or counts[best] <= max(others):
        return ""
    return best


def is_english(language: str, text: str) -> bool:
    """Return True unless the record is clearly not in English.

    The source's language field decides when it is filled: any English value
    passes ("English,French" passes). An empty field falls back to guess_language
    on the title and abstract, and a record that cannot be told is kept.
    """
    if language.strip():
        values = {fold(value).strip() for value in re.split(r"[;,/|]", language)}
        return any(value in ENGLISH_CODES or value.startswith("en-") for value in values)
    return guess_language(text) in {"english", ""}


def parse_date(text: str) -> date | None:
    """Read a date such as 2020-05-31, 2020-05-31T04:00:00Z, 31 May 2020 or 2020."""
    text = text.strip()
    if not text:
        return None
    iso = re.match(r"(\d{4})-(\d{2})-(\d{2})", text)
    if iso:
        try:
            return date(int(iso[1]), int(iso[2]), int(iso[3]))
        except ValueError:
            return None
    for date_format in DATE_FORMATS:
        try:
            return datetime.strptime(text, date_format).date()
        except ValueError:
            continue
    if re.fullmatch(r"(19|20)\d{2}", text):
        return date(int(text), 1, 1)
    return None


def record_date(record: dict) -> tuple[date | None, bool]:
    """Return the document date, else the project's closing date, and whether it is a year only.

    Sources with no document date put the project's closing or completion date
    in a project_end_date column.
    """
    for field in ("doc_date", "project_end_date"):
        raw = (record.get(field) or "").strip()
        found = parse_date(raw)
        if found:
            return found, bool(re.fullmatch(r"\d{4}", raw))
    return None, False


def date_problem(record: dict, start: date, end: date) -> str:
    """Return "outside_date_range", "unknown_document_date" or "" for one record.

    A year-only date counts for the whole year, so 2015 passes a 2015-06-01 start.
    """
    found, year_only = record_date(record)
    if found is None:
        return "unknown_document_date"
    last_day = date(found.year, 12, 31) if year_only else found
    inside = last_day >= start and found <= end
    return "" if inside else "outside_date_range"
