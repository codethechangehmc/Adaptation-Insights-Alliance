# Step 03: chunk

Cuts each parsed paper into chunks small enough to search and to hand to the model in step 04.

| | |
|---|---|
| Reads | `data/02_parsed/<paper_id>/sections.json` |
| Writes | `data/03_chunks/<paper_id>/` |

## How it chunks

- Splits on headings, then groups text into chunks of about 450 tokens (600 at most).
  The sizes are in `DEFAULT_SETTINGS` at the top of `chunk.py`.
- Keeps tables whole; a table over 1,500 tokens is split by rows, with the header repeated.
  A table that crosses a page break gets a `(PDF page N)` marker row, and each piece gets the pages
  of its own rows.
- Gives tables and figures a "Context:" line for search (the text just before them; from the
  previous section if it is on the same or the previous page).
- Attaches footnotes to the text on their page.
- Drops the table of contents and running headers.
- Tags each chunk as body, annex or references.

## Files

- `chunk.py` - makes the chunks. A paper is redone automatically when its `sections.json` changes
  or the settings change.
- `check_chunks.py` - the quick check: are the gold values still findable in the chunks?

## Outputs per paper

| File | What it is |
|---|---|
| `chunks.jsonl` | one chunk per line; step 04 reads this |
| `chunks_meta.json` | settings and counts; written last, so it marks the paper as done |
| `chunks.md` | the chunks in a readable form (only with `--dump-md`) |

## Run

```powershell
python -m step03_chunk.chunk                       # every parsed paper that needs it
python -m step03_chunk.chunk --only P001_doc3      # one or more papers
python -m step03_chunk.chunk --dump-md             # also write chunks.md
python -m step03_chunk.chunk --max-tokens 800      # try other sizes (see --help)
```

## Check it worked

```powershell
python -m step03_chunk.check_chunks                # every gold project
python -m step03_chunk.check_chunks --only P001    # project codes, not paper ids
```

For each gold value it reports whether the value is in a chunk, on the gold page, and next to its
label. Results go to `data/05_eval/chunk_check.csv`. On Nov 15 2026: 52 of 55 values found; the
3 misses are values the gold set itself could not locate or rounded.
