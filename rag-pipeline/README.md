# rag-pipeline

Turns project evaluation PDFs into a table of extracted results for the Adaptation Insights
project. The work happens in numbered steps. Each step reads what the step before it wrote
and writes only to its own data folder, so if something looks wrong you know which step to check.

| Step | Code | Reads | Writes | Status |
|---|---|---|---|---|
| 01 scrape | `scraper/` | funder websites | PDFs | works; moves to `step01_scrape/` later |
| 02 parse | `step02_parse/` | `data/01_raw/` | `data/02_parsed/<paper>/` | done |
| 03 chunk | `step03_chunk/` | `data/02_parsed/` | `data/03_chunks/<paper>/` | done |
| 04 extract | `step04_extract/` | `data/03_chunks/` | `data/04_extracted/<run>/` | not built yet |
| 05 evaluate | `step05_evaluate/` | `data/04_extracted/` + gold | `data/05_eval/` | not built yet |

Each step folder has a README: what it does, what it reads and writes, how to run it,
and how to check it worked.

## Running

Always run from this folder (`rag-pipeline/`), with the virtual environment on.

```powershell
python run.py                          # every step, in order
python run.py --from 03 --to 03        # one step
python run.py --only P001_doc3         # one paper through every step
python run.py --check                  # plus each step's quick check

python -m step03_chunk.chunk --only P001_doc3     # a single step, with all its options
```

A step on its own is run with `python -m`, not `python step03_chunk/chunk.py`, so it can find
`paths.py`.

## Setup

```powershell
python -m venv .venv
.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

Parsing (step 02) needs Docling and is much faster on a GPU. We parse on Google Colab with a
separate notebook that uses its own folders; the other steps run fine on a laptop.

## Where things live

| What | Where |
|---|---|
| Folder locations, all in one place | `paths.py` |
| Data (PDFs and every step's output) | `data/` - not in git; the team copy is on Google Drive |
| Gold reference answers | `../catalogues/gold_v1_*.csv` - Lolita's files, in git |
| Error logs | `data/logs/` |
| The three-way extraction comparison (Nov 2026) | `experiments/extract_comparison/` - kept as a record |
