"""Conservative checks and a separate headline view; raw facts are never discarded."""

import re
from decimal import Decimal, InvalidOperation

from common.files import norm


def number(value: str) -> Decimal | None:
    """Parse an unqualified decimal without rounding or losing signs."""
    text = value.strip()
    if re.fullmatch(r"[+-]?\d{1,3}(,\d{3})+(\.\d+)?", text):
        text = text.replace(",", "")
    if not re.fullmatch(r"[+-]?\d+(\.\d+)?", text):
        return None
    try:
        return Decimal(text)
    except InvalidOperation:
        return None


def fact_flags(fact: dict) -> list[str]:
    """Flag consequential evidence and result-rule failures without changing the fact."""
    flags = []
    if fact["value"] and not any(e["quote"].strip() for e in fact["evidence"]):
        flags.append("missing_evidence")
    if fact["value"] and fact["status"] == "not_found_in_input":
        flags.append("value_despite_abstention")
    numeric_fields = {
        "publication_year",
        "start_year",
        "closure_year",
        "location_count",
        "budget_total",
        "budget_lead_share",
        "disbursed",
    }
    if fact["field"] in numeric_fields and fact["value"] and number(fact["value"]) is None:
        flags.append("not_plain_numeric")
    if fact["field"] != "result":
        return flags
    if fact["value_type"] != "achieved":
        flags.append("not_actual_result")
    if number(fact["value"]) is None:
        flags.append("not_plain_numeric")
    text = norm(fact["metric"] + " " + fact["unit"])
    if re.search(r"\b(usd|eur|dollars?|budget|disbursement|expenditure)\b", text):
        flags.append("finance_not_result")
    if re.search(
        r"sample size|respondents? surveyed|focus groups? held|interviews? conducted", text
    ):
        flags.append("evaluation_method_not_result")
    if re.search(r"percent(age)? of target|progress towards target|achievement rating", text):
        flags.append("target_progress_or_rating")
    return flags


def content_flags(fact: dict) -> list[str]:
    """Separate content eligibility from evidence availability across output schemas."""
    return [flag for flag in fact_flags(fact) if flag != "missing_evidence"]


def scoring_fact(fact: dict) -> dict:
    """Align R's explicit GESI absence marker with an empty extraction, leaving raw data intact."""
    marker = "The document does not address gender equality or social inclusion."
    if fact["field"] == "GESI_project" and norm(fact["value"]) == norm(marker):
        return {**fact, "value": "", "status": "not_found_in_input"}
    return fact


def headline(facts: list[dict]) -> list[dict]:
    """Select reach, physical and effect slots, then framework order, without cross-unit sums."""
    eligible = [f for f in facts if f["field"] == "result" and not content_flags(f)]
    eligible.sort(
        key=lambda f: (
            f["project_total"] != "yes",
            {"impact": 0, "outcome": 1, "output": 2, "process": 3, "input": 4}.get(
                f["indicator_level"], 5
            ),
        )
    )
    chosen, seen = [], set()
    for category in ("reach_people", "physical_quantity", "effect_rate", None):
        for fact in eligible:
            key = norm(fact["metric"])
            if key in seen or (category and fact["category"] != category):
                continue
            chosen.append(fact)
            seen.add(key)
            if len(chosen) == 3:
                return chosen
            if category:
                break
    return chosen
