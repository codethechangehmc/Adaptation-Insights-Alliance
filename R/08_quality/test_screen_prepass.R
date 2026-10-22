# test_screen_prepass.R - unit tests for the Phase 4a screening pre-pass:
# pretreat_text (GEF machine footers, AfDB boilerplate label), docx
# extraction, the boilerplate-quote detector, and the determinism of
# seed_year_overrides.R. Exit status 1 on any failure.
#
#   Rscript R/08_quality/test_screen_prepass.R

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
source(file.path(REPO, "R", "03_screen", "screen_text.R"))

fails <- 0
check <- function(desc, ok) {
  cat(if (isTRUE(ok)) "  ok  " else "FAIL  ", desc, "\n")
  if (!isTRUE(ok)) fails <<- fails + 1
}

## ---- 1. GEF machine footer ---------------------------------------------------
# the real footer layout from gef_5580_Terminal_Evaluation.pdf page 1:
# date hard left, page marker hard right, one line
footer_line <- paste0("1/13/2026", strrep(" ", 86), "Page 1 of 7")
txt <- paste("Project Name:   Development of an Improved and Innovative Management System",
             "Countr(ies):    Mauritania", footer_line,
             "The project responds to recurrent drought and erratic rainfall.", sep = "\n")
out <- pretreat_text(txt)
check("combined date+page footer line is stripped", !grepl("1/13/2026", out, fixed = TRUE))
check("page marker goes with it", !grepl("Page 1 of 7", out, fixed = TRUE))
check("surrounding content survives", grepl("Mauritania", out) &&
        grepl("recurrent drought and erratic rainfall", out))

# standalone date-stamp line adjacent to a page marker line
txt2 <- "some text\n9/27/2025\nPage 3 of 18\nmore text"
out2 <- pretreat_text(txt2)
check("standalone date next to a page marker is stripped", !grepl("9/27/2025", out2, fixed = TRUE))
# ... but a lone date line with no page marker beside it stays
txt3 <- "The workshop was held on\n9/27/2025\nin Banjul."
check("lone date line far from page markers is kept",
      grepl("9/27/2025", pretreat_text(txt3), fixed = TRUE))
# ... and a date inside prose is never touched
txt4 <- "Disbursement closed on 3/4/2021 Page references follow in the annex."
check("date inside prose is kept", grepl("3/4/2021", pretreat_text(txt4), fixed = TRUE))

## ---- 2. AfDB boilerplate label -------------------------------------------------
# contiguous (as a model quote or a docx extraction carries it)
lab <- "Type (e.g. gender, climate change, social, other)"
out <- pretreat_text(paste("Unanticipated outcomes.", lab, "Positive or negative."))
check("contiguous label is stripped", !grepl("gender", out) && !grepl("climate change", out))
out <- pretreat_text("Type (eg. gender,  climate   change, social, others)")
check("label variant 'eg.' / 'others' / odd spacing is stripped", !grepl("climate", out))

# fragmented over three table-header lines with other columns interleaved
# (real layout from afdb_PCR_Angola_-_Bom_Jesus-Calenga..., pdftools output)
frag <- paste(
  " Description                                                                    Type (eg. gender,    Positive or     Impact on project",
  "                                                                                climate change,       negative        (High, Medium,",
  "                                                                                social, other)                             Low)",
  sep = "\n")
out <- pretreat_text(frag)
check("fragmented label: 'climate change' removed from the header block",
      !grepl("climate change", out, ignore.case = TRUE))
check("fragmented label: 'gender' and 'social, other)' removed",
      !grepl("gender", out) && !grepl("social, other)", out, fixed = TRUE))
check("fragmented label: other columns' text survives",
      grepl("Description", out) && grepl("negative", out))

# a real climate sentence is never collateral damage
sent <- "The project addressed climate change adaptation for smallholders facing drought."
check("normal climate sentence is intact", identical(pretreat_text(sent), sent))

## ---- 3. boilerplate-quote detector ---------------------------------------------
check("exact label is boilerplate", is_boilerplate_quote(lab))
check("label plus stray chars is boilerplate",
      is_boilerplate_quote("Risk type (e.g. gender, climate change, social, other)"))
check("label inside a real long quote is NOT boilerplate",
      !is_boilerplate_quote(paste(lab, "- recurrent drought reduced yields by 40% in the project area")))
check("real climate quote is NOT boilerplate",
      !is_boilerplate_quote("prolonged drought and erratic rainfall threaten livestock"))
check("empty quote is NOT boilerplate (plain <12 rule handles it)", !is_boilerplate_quote(""))

## ---- 4. docx extraction ---------------------------------------------------------
dx <- file.path(DOCS_ROOT, "gef", "Docs", "evaluation_docs", "2015_2026",
                "gef_4368_Terminal_Evaluation.docx")
if (file.exists(dx)) {
  t <- read_docx_text(dx)
  check(sprintf("gef_4368 docx yields >50k chars (got %d)", nchar(t)), nchar(t) > 50000)
  check("gef_4368 docx text contains 'ProVACCA'", grepl("ProVACCA", t, fixed = TRUE))
} else check("gef_4368_Terminal_Evaluation.docx present", FALSE)

## ---- 5. year_overrides seeding is deterministic ---------------------------------
RSCRIPT <- file.path(R.home("bin"), "Rscript.exe")
SEED <- file.path(REPO, "R", "03_screen", "seed_year_overrides.R")
YOVR <- file.path(SCREEN_DIR, "inputs", "decisions", "year_overrides.csv")
invisible(system2(RSCRIPT, shQuote(SEED), stdout = TRUE, stderr = TRUE))
h1 <- unname(tools::md5sum(YOVR))
invisible(system2(RSCRIPT, shQuote(SEED), stdout = TRUE, stderr = TRUE))
h2 <- unname(tools::md5sum(YOVR))
check("seed_year_overrides.R re-run reproduces the file byte for byte",
      !is.na(h1) && identical(h1, h2))

## ---- 6. pre-pass on the real portal sheet ---------------------------------------
pdf <- file.path(DOCS_ROOT, "gef", "Docs", "evaluation_docs", "2015_2026",
                 "gef_5580_Terminal_Evaluation.pdf")
if (file.exists(pdf) && requireNamespace("pdftools", quietly = TRUE)) {
  raw <- paste(pdftools::pdf_text(pdf), collapse = "\n")
  pre <- pretreat_text(raw)
  n_date <- function(x) length(gregexpr("1/13/2026", x, fixed = TRUE)[[1]][
    gregexpr("1/13/2026", x, fixed = TRUE)[[1]] > 0])
  raw_footers <- sum(grepl(GEF_FOOTER_RE, strsplit(raw, "\n", fixed = TRUE)[[1]], ignore.case = TRUE))
  check("gef_5580: raw text carries footer lines on its pages", raw_footers >= 5)
  check("gef_5580: no footer-shaped line survives the pre-pass",
        !any(grepl(GEF_FOOTER_RE, strsplit(pre, "\n", fixed = TRUE)[[1]], ignore.case = TRUE)))
  # the per-page footer copies of the date go; the document's own data dates
  # (the TE Submission / Final Disbursement table) stay
  check(sprintf("gef_5580: footer date count falls by the footer lines (%d -> %d)",
                n_date(raw), n_date(pre)), n_date(pre) <= n_date(raw) - raw_footers)
  check("gef_5580: the document's content survives", grepl("Mauritania", pre, fixed = TRUE))
} else check("gef_5580_Terminal_Evaluation.pdf present", FALSE)

## ---- World Bank SECTORS AND THEMES taxonomy -------------------------------
# Assigned at appraisal, printed as label/percentage pairs, and counted as
# climate evidence by anything that reads the raw text. Two adjudicators
# reading different batches traced false positives to it independently.
synthetic <- paste(
  "The project trained 1,692 farmers in improved production techniques.",
  "SECTORS AND THEMES",
  "Sectors",
  "Agriculture, Fishing and Forestry",
  "  22",
  "Themes",
  "Disaster Risk Management",
  "33",
  "Flood and Drought Risk Management",
  "33",
  "Climate change",
  "33",
  "Adaptation",
  "33",
  "I. PROJECT CONTEXT",
  "Rainfall in the project zone has become increasingly erratic since 2015.",
  sep = "\n")
pre <- pretreat_text(synthetic)
check("wb taxonomy: the heading is removed", !grepl("SECTORS AND THEMES", pre, fixed = TRUE))
check("wb taxonomy: its climate rows are removed",
      !grepl("Flood and Drought Risk Management", pre, fixed = TRUE))
check("wb taxonomy: narrative BEFORE the block survives",
      grepl("1,692 farmers", pre, fixed = TRUE))
check("wb taxonomy: narrative AFTER the block survives",
      grepl("increasingly erratic", pre, fixed = TRUE))
check("wb taxonomy: the next real heading survives",
      grepl("PROJECT CONTEXT", pre, fixed = TRUE))
# and a document with no such block must be left alone
plain <- "Drought in 2016 reduced maize yields.\nFarmers adopted drought-tolerant seed."
check("wb taxonomy: a document without the block is untouched",
      identical(pretreat_text(plain), plain))

cat("\n", if (fails == 0) "ALL TESTS PASS" else paste(fails, "TEST(S) FAILED"), "\n")
if (fails > 0) quit(save = "no", status = 1)
