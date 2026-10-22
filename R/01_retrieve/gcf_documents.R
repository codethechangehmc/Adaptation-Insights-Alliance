##############################################################################
# gcf_documents.R — Green Climate Fund project documents (rebuilt site)
#
# Targets: evaluations, annual performance reports and completion reports for
#          GCF-funded projects in Africa. Proposals, safeguards paperwork and
#          gender assessments are deliberately skipped: they are not evidence
#          of what was implemented.
# Website: https://www.greenclimate.fund
# Strategy: plain GET. The rebuilt site is server-rendered, so three requests
#          per document and no AJAX:
#            1. /project/{ref}      lists the project's documents in the HTML
#            2. /document/{slug}    the document's own page
#            3. /sites/default/files/documents/.../*.pdf
# Pagination: none needed; the project list comes from api.gcfund.org, already
#          assessed into review/gcf_portfolio_assessment.csv.
#
# WHY THIS REPLACES gcf.R. R/01_retrieve/gcf.R posts to a Drupal 7 Views AJAX
# endpoint at /views/ajax. GCF rebuilt the site and that endpoint now returns
# 404, so the scraper silently stopped retrieving. The corpus held 53 GCF files
# covering a handful of projects while GCF had funded 78 African agriculture
# adaptation projects. A dead scraper and a thin source look identical from the
# output folder, which is how this went unnoticed.
#
# Quirks:
#   - project refs are lower-cased in the URL path (/project/fp246)
#   - a document page occasionally carries no PDF (link-only record)
#   - PDFs live on the same host, no bot protection, no browser needed
#
#   Rscript R/01_retrieve/gcf_documents.R [--refs FP246,FP072] [--limit N] [--dry]
##############################################################################

# ── Setup ──────────────────────────────────────────────────────────────────
.find_r_dir <- function() {
  tryCatch({
    d <- dirname(sys.frame(2)$ofile)
    if (!is.null(d) && nzchar(d)) return(normalizePath(d, mustWork = FALSE))
  }, error = function(e) NULL)
  tryCatch({
    args <- commandArgs(trailingOnly = FALSE)
    fa <- grep("^--file=", args, value = TRUE)
    if (length(fa)) return(normalizePath(dirname(sub("^--file=", "", fa[1])), mustWork = FALSE))
  }, error = function(e) NULL)
  wd <- getwd()
  if (file.exists(file.path(wd, "R", "00_shared", "00_config.R"))) return(file.path(wd, "R", "00_shared"))
  if (file.exists(file.path(wd, "00_config.R"))) return(wd)
  return(wd)
}
if (!exists("PATHS")) {
  .r_dir <- .find_r_dir()
  for (.p in file.path(.r_dir, c(".", "..", "../00_shared", "00_shared", "R/00_shared"), "00_config.R")) if (file.exists(.p)) { source(.p); break }
  for (.p in file.path(.r_dir, c(".", "..", "../00_shared", "00_shared", "R/00_shared"), "01_utils.R")) if (file.exists(.p)) { source(.p); break }
}
suppressPackageStartupMessages({ library(httr); library(rvest); library(xml2); library(dplyr) })

SOURCE_NAME  <- "gcf"
DOWNLOAD_DIR <- file.path(PATHS$downloads, "gcf_new")
dir.create(DOWNLOAD_DIR, recursive = TRUE, showWarnings = FALSE)

# ── Constants ──────────────────────────────────────────────────────────────
GCF_BASE <- "https://www.greenclimate.fund"

# document slugs worth having: evidence of what was implemented
GCF_KEEP <- paste0("evaluation|annual-performance-report|completion-report|",
                   "completion-summary|terminal-review|interim-review|mid-term-review")
# and what to leave: intent, compliance and paperwork
GCF_DROP <- paste0("funding-proposal|concept-note|no-objection|gender-action-plan|",
                   "gender-assessment|environmental-and-social|ess-report|safeguard|",
                   "accreditation|board-decision|call-for|term-sheet|disbursement|",
                   "legal|annex|readiness-proposal|feasibility|procurement")

GCF_DOC_LABEL <- function(slug) {
  s <- tolower(slug)
  if (grepl("completion", s))              return("Project completion report")
  if (grepl("annual-performance", s))      return("Annual performance report")
  if (grepl("interim|mid-term", s))        return("Interim evaluation")
  if (grepl("terminal|final", s))          return("Final evaluation")
  "Evaluation report"
}

# ── Helpers ────────────────────────────────────────────────────────────────
#' Document slugs listed on a project page.
gcf_project_docs <- function(ref) {
  r <- polite_get(paste0(GCF_BASE, "/project/", tolower(ref)))
  if (is.null(r) || status_code(r) != 200) return(character(0))
  h <- tryCatch(read_html(content(r, "text", encoding = "UTF-8")), error = function(e) NULL)
  if (is.null(h)) return(character(0))
  s <- unique(xml_attr(xml_find_all(h, "//a[@href]"), "href"))
  s <- s[!is.na(s) & grepl("^/document/", s)]
  s[grepl(GCF_KEEP, s, ignore.case = TRUE) & !grepl(GCF_DROP, s, ignore.case = TRUE)]
}

#' The PDF behind a document page, plus its date if the page states one.
gcf_doc_pdf <- function(slug) {
  r <- polite_get(paste0(GCF_BASE, slug))
  if (is.null(r) || status_code(r) != 200) return(list(url = NA_character_, date = NA_character_))
  txt <- content(r, "text", encoding = "UTF-8")
  pdfs <- unique(unlist(regmatches(txt, gregexpr('https?://[^"\']+?\\.pdf', txt))))
  dt <- regmatches(slug, regexpr("20[0-9]{2}", slug))
  list(url = if (length(pdfs)) pdfs[1] else NA_character_,
       date = if (length(dt)) dt else NA_character_)
}

# ── Main ───────────────────────────────────────────────────────────────────
run_gcf_documents_scraper <- function() {
  args  <- commandArgs(trailingOnly = TRUE)
  opt   <- function(f, d = "") { i <- which(args == f); if (length(i) && length(args) > i[1]) args[i[1] + 1] else d }
  DRY   <- any(args == "--dry")
  LIMIT <- suppressWarnings(as.integer(opt("--limit", NA)))
  REFS  <- trimws(strsplit(opt("--refs", ""), ",")[[1]]); REFS <- REFS[nzchar(REFS)]

  # PATHS$root is 07_Pipeline; screening sits beside it under the
  # Grey Literature root
  asmt <- file.path(dirname(PATHS$root), "04_Screening", "inputs", "reports",
                    "gcf_portfolio_assessment.csv")
  if (!file.exists(asmt)) {
    cli::cli_alert_danger("gcf_portfolio_assessment.csv not found; run the portfolio assessment first")
    return(invisible(NULL))
  }
  A <- read.csv(asmt, stringsAsFactors = FALSE, colClasses = "character"); A[is.na(A)] <- ""
  want <- A[A$verdict == "IN SCOPE", ]
  if (length(REFS)) want <- want[want$ref %in% REFS, ]
  if (!is.na(LIMIT)) want <- head(want, LIMIT)
  cli::cli_h1("GCF documents: {nrow(want)} in-scope projects")
  if (DRY) { cli::cli_alert_info("--dry: nothing fetched"); return(invisible(NULL)) }

  meta <- list()
  for (i in seq_len(nrow(want))) {
    ref <- want$ref[i]
    cli::cli_h2("[{i}/{nrow(want)}] {ref} — {substr(want$name[i], 1, 52)}")
    slugs <- gcf_project_docs(ref)
    cli::cli_alert_info("{length(slugs)} document(s) of the right kind")
    for (s in slugs) {
      d <- gcf_doc_pdf(s)
      if (is.na(d$url)) {
        log_download(SOURCE_NAME, ref, GCF_DOC_LABEL(s), s, NA, NA, "no_pdf_link")
        next
      }
      label <- GCF_DOC_LABEL(s)
      # Short, human-readable, and matching the names already in the corpus
      # (gcf_FP023_Evaluation_report.pdf). The raw slug runs to 134 characters,
      # which is unusable in a folder and risks the Windows path limit once the
      # file sits under 03_Documents.
      stem <- paste0("gcf_", ref, "_", gsub(" ", "_", label),
                     if (!is.na(d$date)) paste0("_", d$date) else "")
      fn <- paste0(stem, ".pdf"); k <- 1L
      while (file.exists(file.path(DOWNLOAD_DIR, fn))) {
        fn <- paste0(stem, "_", k, ".pdf"); k <- k + 1L
      }
      fp <- file.path(DOWNLOAD_DIR, fn)
      got <- download_pdf(d$url, fp)
      # download_pdf returns TRUE / FALSE / "skipped", not a status string
      st <- if (isTRUE(got)) "success" else if (identical(got, "skipped")) "skipped" else "failed"
      log_download(SOURCE_NAME, ref, label, sub("^/document/", "", s), d$url, fp, st)
      meta[[length(meta) + 1]] <- tibble::tibble(
        id = paste0(ref, "_", safe_filename(sub("^/document/", "", s))),
        title = sub("^/document/", "", s), pdf_url = d$url, doc_date = d$date,
        doc_type = label, country = want$countries[i], project_id = ref,
        web_url = paste0(GCF_BASE, s), project_name = want$name[i],
        local_file = fn, status = st)
    }
  }

  if (length(meta)) {
    M <- dplyr::bind_rows(meta)
    p <- file.path(PATHS$data, "gcf_documents_metadata.csv")
    readr::write_csv(M, p)
    cli::cli_alert_success("metadata: {p} ({nrow(M)} rows)")
    cli::cli_alert_info("downloaded: {sum(M$status == 'success')} | skipped: {sum(M$status == 'skipped')} | failed: {sum(!M$status %in% c('success','skipped'))}")
  } else cli::cli_alert_warning("no documents found")
  print_source_summary(SOURCE_NAME)
}

`%||%` <- function(a, b) if (is.null(a)) b else a
if (sys.nframe() == 0 || !interactive()) run_gcf_documents_scraper()
