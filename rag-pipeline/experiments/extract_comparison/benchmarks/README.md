# Reviewed evidence benchmark

`run.py evaluate --init-review` creates `review.json` from the reference tables
in `test_set/`. It is ignored by git and never overwritten, so back up your
reviewed copy yourself.

Imported labels are suggestions, not answers. The references contain coded
categories, alternatives, incomplete result lists and known disagreements.
Confirm each label against the PDF before setting `reviewed: true`. Only
reviewed labels are scored.

## A reviewed label

An illustration, not a real answer:

```json
{
  "id": "L0001",
  "document": "P001",
  "group": "results",
  "field": "result",
  "values": ["12.5", "12.50"],
  "metric_aliases": ["land restored", "area restored"],
  "unit_aliases": ["hectares", "ha"],
  "scope_aliases": ["whole project", "project total"],
  "reviewed": true,
  "absence": false,
  "evidence_groups": [
    [{"quote": "The project restored 12.5 hectares.", "pages": [12]}]
  ],
  "comment": "Checked actual achieved, not baseline or target."
}
```

- `values` are accepted alternatives. Numbers match exactly after removing
  thousands commas; nothing is rounded.
- A result matches only if value, metric, unit and scope all match an
  accepted alias. Each prediction can claim one label at most.
- Pages are physical PDF pages, counting the cover. Reference pages may be
  printed page numbers; check them.
- Each `evidence_groups` entry is one required piece of evidence; put
  alternatives for the same piece in the same group. Labels without quotes
  can still score values, but cannot diagnose retrieval or parse gaps.
- For a confirmed absence, set `absence: true`, `values: []` and
  `evidence_groups: []`.
- Quote checks and content correctness are reported separately.

## Complete answer sets

Unmatched predictions count as wrong only once a person has checked that the
labels list every valid answer for that field:

```json
"exhaustive": [
  {"document": "P001", "group": "results", "field": "result", "reviewed": true}
]
```

Until then they are `needs_review`, not false positives.

## Blind review

`reports/review.html` hides method names (A, B, C) and shows a token beside
each fact. Do not open `review_key.json` until you finish. Record decisions:

```json
"judgements": {
  "token_from_report": {"verdict": "correct", "label": "L0001"},
  "another_token": {"verdict": "incorrect", "comment": "This is a target."}
}
```

Add `label` when a correct answer uses different wording, so it counts toward
recall. A judgement is tied to the exact answer text, so it does not carry over
to a changed answer in a later run. Run `evaluate` again after editing; the
benchmark used is saved beside the scores.
