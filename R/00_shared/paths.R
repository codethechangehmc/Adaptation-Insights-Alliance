##############################################################################
# paths.R — single source of truth for the project's folder layout
# (reorganised 2026-09-09; see the root README.md).
#
# New code should source this file instead of hardcoding locations:
#   source(file.path(REPO, "R", "00_shared", "paths.R"))
# Existing scripts still carry inline constants pointing at the same places;
# they are kept in sync with this file.
##############################################################################

GL_ROOT    <- "C:/Users/mlolita/OneDrive - CGIAR/WP2_Evidence Synthesis/Grey Literature"

PROTOCOL_DIR <- file.path(GL_ROOT, "01_Protocol")     # protocol + QC docx
TEMPLATE_DIR <- file.path(GL_ROOT, "02_Template")     # Lucy's template + working DBs
DOCS_ROOT    <- file.path(GL_ROOT, "03_Documents")    # the corpus (per source)
# Screening comes before extraction and is its own stage: the scope ledger,
# the queues a person still has to rule on, and the Zotero ingestion logs.
# It used to sit under the extraction results, where two thirds of the review
# folder was screening material that had nothing to do with extraction.
SCREEN_DIR   <- file.path(GL_ROOT, "04_Screening")

RESULTS_DIR  <- file.path(GL_ROOT, "05_Extraction_Results")  # team-facing outputs

# Quality check is the stage after extraction: the workbooks a consultant
# fills in, and what comes back from them. The workbooks used to be written
# into the pipeline's scratch directory, where the people who have to fill
# them in would never find them.
QC_DIR       <- file.path(GL_ROOT, "06_Quality_Check")

# The two extraction pilots, each gathered in one folder. Nothing else has
# been extracted: the published workbooks hold the ten gold projects and the
# ten holdout documents, not the corpus.
PILOT_RESULTS <- file.path(RESULTS_DIR, "pilot")   # gold/ and holdout/, side by side
CHARITY_DIR  <- file.path(RESULTS_DIR, "charity_pilot")
ARCHIVE_DIR  <- file.path(GL_ROOT, "99_Archive")

# The template workbook. Four scripts read it directly (harmonise, locations,
# the location scorer, the actor audit), so a clone without it cannot run
# them. A copy is therefore committed under template/. The OneDrive master
# wins when it is reachable, so edits by the template owner take effect
# immediately; the committed copy is the fallback for anyone who has only the
# repository. Refresh it with R/00_shared/export_template.R on each release.
# The master keeps its full name on OneDrive. The committed copy is named
# short on purpose: git clone fails on Windows with the full name, because
# the path exceeds the limit during checkout and the working tree is left
# incomplete.
TEMPLATE_FILE      <- "EvidenceSynthesis_GreyLiterature_AfricanAgricultureAdaptation_UpdatedTemplate_27Aug2026.xlsx"
TEMPLATE_FILE_REPO <- "template_27Aug2026.xlsx"

# The repository root, found without relying on how the caller was invoked:
# walk up from the working directory until R/00_shared/paths.R is underneath.
REPO_ROOT <- local({
  d <- normalizePath(getwd(), winslash = "/", mustWork = FALSE)
  for (i in 1:6) {
    if (file.exists(file.path(d, "R", "00_shared", "paths.R"))) return(d)
    p <- dirname(d); if (identical(p, d)) break; d <- p
  }
  file.path(GL_ROOT, "07_Pipeline")       # the usual location
})

# Vocabulary work: the terms the machine proposes and the audit workbooks a
# person checks them in. It lives in the repository, not on OneDrive, so a
# hand-maintained file like location_aliases.csv is version-controlled.
VOCAB_DIR    <- file.path(REPO_ROOT, "catalogues", "vocabulary")

# Score files from a run. Scratch: the published comparison for each pilot
# sits in 05_Extraction_Results/pilot/<set>/ai_score.csv.
SCORES_DIR   <- file.path(REPO_ROOT, "outputs", "scores")

TEMPLATE_XLSX <- local({
  master <- file.path(TEMPLATE_DIR, TEMPLATE_FILE)
  if (file.exists(master)) master
  else file.path(REPO_ROOT, "template", TEMPLATE_FILE_REPO)
})
PILOT_DIR     <- file.path(DOCS_ROOT, "pilot")   # gold set, holdout set, candidate pool
GOLD_DOCS_DIR <- file.path(PILOT_DIR, "gold_set_P001-P010")

# in-scope corpus folders per source (relative to DOCS_ROOT)
CORPUS_DIRS <- c(
  worldbank = "Worldbank/Docs/2015_2026",
  gef       = "gef/Docs/evaluation_docs/2015_2026",
  gcf       = "gcf/Docs/evaluation_docs",
  afdb      = "afdb/Docs/2015_2026",
  af        = "af/Docs/evaluation_docs",
  cif       = "cif/Docs/evaluation_docs")

# Every folder a document can sit in, in scope or parked. The census, the
# dedup step and the screener all walk this list, so a file parked for a
# reason is still known to the pipeline and never re-screened blind.
SCAN_DIRS <- list(
  worldbank = c("Worldbank/Docs/2015_2026", "Worldbank/Docs/pre_2015",
                "Worldbank/Docs/to_screen", "Worldbank/Docs/screened_out"),
  # tracking_tools holds GEF's AMAT/PMAT indicator workbooks. The GEF
  # catalogue labels them "Terminal Evaluation", so 73 spreadsheets sat in
  # the corpus under names claiming they were evaluations. They are parked,
  # not deleted, and stay in the census for the same reason as every other
  # parked file.
  gef       = c("gef/Docs/evaluation_docs/2015_2026",
                "gef/Docs/evaluation_docs/pre_2015",
                "gef/Docs/evaluation_docs/undated", "gef/Docs/to_screen",
                "gef/Docs/tracking_tools"),
  # progress_reports and proposal_stage were missing here, so 228 GCF files
  # sat outside the census and the screener entirely. A parked file must still
  # be known to the pipeline, per the note above, or it is simply invisible.
  gcf       = c("gcf/Docs/evaluation_docs", "gcf/Docs/to_screen",
                "gcf/Docs/progress_reports", "gcf/Docs/proposal_stage"),
  afdb      = c("afdb/Docs/2015_2026", "afdb/Docs/to_screen", "afdb/Docs/undated"),
  af        = c("af/Docs/evaluation_docs", "af/Docs/progress_reports", "af/Docs/to_screen"),
  cif       = c("cif/Docs/evaluation_docs", "cif/Docs/to_screen"))

# ── filename-safe identifiers ───────────────────────────────────────────────
# A project_code is built as "source:project_id" or "source:filename.pdf"
# (run_corpus.R), and a colon is illegal in a Windows path. Both extraction
# scripts interpolate the code straight into the raw-JSON filename, so every
# corpus document would fail on its first write. Base R only, so the
# extraction scripts can source this file without pulling in stringr.
# A no-op for codes that are already clean, such as the pilot's P001.
safe_name <- function(x, max_len = 80) {
  x <- as.character(x)
  x[is.na(x)] <- ""
  x <- iconv(x, to = "ASCII//TRANSLIT", sub = "")
  x[is.na(x)] <- ""
  x <- gsub("[^A-Za-z0-9_-]", "_", x)
  x <- gsub("_+", "_", x)
  x <- gsub("^_+|_+$", "", x)
  x <- substr(x, 1, max_len)
  ifelse(nchar(x) == 0, "unnamed", x)
}
