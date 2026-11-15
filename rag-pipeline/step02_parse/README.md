# Step 02: parse

Turns each PDF into clean text, tables and sections, using Docling.

| | |
|---|---|
| Reads | `data/01_raw/*.pdf` (PDFs in `data/01_raw/extra/` are skipped) |
| Writes | `data/02_parsed/<paper_id>/` |
| Paper id | the PDF's file name without `.pdf` |

## Files

- `parse.py` - runs Docling and saves the outputs. A paper with a `meta.json` is done and gets skipped.
- `postprocess.py` - all the cleanup: tables, footnotes, headings, running headers, figures.
- `review.py` - the quick check: lists tables the cleanup flagged as possibly mis-parsed.

## Outputs per paper

| File | What it is |
|---|---|
| `docling.json` | Docling's full output; the source of truth |
| `raw.md` | Docling's own markdown, untouched (for comparison) |
| `clean.md` | the cleaned document, readable |
| `sections.json` | the document split by headings, with pages; step 03 reads this |
| `figures/` | cropped images of charts and diagrams |
| `meta.json` | run info and cleanup counts; written last, so it marks the paper as done |

## Run

```powershell
python -m step02_parse.parse                    # every new PDF
python -m step02_parse.parse --only P001_doc3   # one or more papers
python -m step02_parse.parse --pages 1-10       # quick test on a few pages
python -m step02_parse.parse --reprocess        # redo only the cleanup from saved docling.json (seconds)
python -m step02_parse.parse --force            # parse again even if done
```

## Check it worked

```powershell
python -m step02_parse.review                   # flagged tables, by paper
python -m step02_parse.review --csv flags.csv   # same, as a sheet with verdict columns to fill in
```

A flag means "look at this table in the PDF", not "this table is wrong". Failures are logged
in `data/logs/parse_errors.log`.

## Known limits

- Some tables come out with scrambled or fused cells. These are flagged, not repaired.
- Bold lead-in sentences are sometimes read as headings. No text is lost.
- Scanned pages (images, no text) come out empty; there is no OCR.
