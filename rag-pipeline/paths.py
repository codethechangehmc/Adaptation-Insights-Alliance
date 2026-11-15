"""
paths.py - where every step reads and writes. Change a folder here and every step follows.

Step N reads from the folder of step N-1 and writes only to its own folder.
data/ is not in git; the team copy lives on Google Drive.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent        # rag-pipeline/
DATA = ROOT / "data"

RAW = DATA / "01_raw"                # PDFs (scraped or added by hand); extra/ = PDFs not parsed by default
PARSED = DATA / "02_parsed"          # step 02 output: one folder per paper
CHUNKS = DATA / "03_chunks"          # step 03 output: one folder per paper
EXTRACTED = DATA / "04_extracted"    # step 04 output: one folder per run
EVAL = DATA / "05_eval"              # checks and scores from every step
GOLD = DATA / "gold"                 # Lolita's hand-made reference CSVs
LOGS = DATA / "logs"                 # error logs
DOC_INDEX = DATA / "doc_index.csv"   # optional: paper titles used by step 03
