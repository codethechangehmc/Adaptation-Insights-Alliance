##############################################################################
# gef_funding_sweep.R — LDCF + SCCF funding-source sweep (corpus completion,
# Oct 2026). The per-country enumeration in gef.R misses regional and
# multi-country African projects; the funding_source facet (LDCF = 479,
# SCCF = 490) reaches them directly and covers both adaptation windows.
#
# What it does:
#   1. canary: the LDCF listing must pass gef_listing_expect(), a nonsense
#      facet id must fail it (the nonsense view returns HTTP 200 with
#      "Displaying 0 - 0 of 0" and no results table).
#   2. enumerate both funds (rel=next pagination, every page asserted).
#   3. classify Africa: a project is African when any comma-separated token of
#      its Countries cell equals an African country name or "Africa"
#      (token equality, so "Papua New Guinea" never matches "Guinea").
#   4. scrape project pages of African projects NOT yet in the catalogue and
#      append their document rows to gef_all_documents.csv (both the corpus
#      copy in 03_Documents/gef/List/ and the pipeline copy in
#      catalogues/gef/), deduplicated by gef_id + doc_url.
#
# Writes:
#   catalogues/gef/gef_funding_source_projects.csv   (+ copy in List/)
#   catalogues/gef/gef_all_documents_pre_sweep_backup.csv  (once)
#   updated gef_all_documents.csv (both copies)
#
# Usage:  GL_LOG_SUFFIX=gef Rscript R/01_retrieve/gef_funding_sweep.R
##############################################################################

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."),
                      mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "00_config.R"))
source(file.path(REPO, "R", "00_shared", "01_utils.R"))
source(file.path(REPO, "R", "01_retrieve", "gef.R"))   # functions only (run guard)

if (!nzchar(Sys.getenv("GL_LOG_SUFFIX"))) Sys.setenv(GL_LOG_SUFFIX = "gef")

CORPUS_GEF <- normalizePath(file.path(dirname(PROJECT_ROOT), "03_Documents", "gef"),
                            mustWork = TRUE)
LIST_DIR   <- file.path(CORPUS_GEF, "List")
CAT_DIR    <- file.path(PROJECT_ROOT, "catalogues", "gef")
CAT_COLS   <- c("gef_id", "project_title", "project_url", "doc_title",
                "doc_url", "doc_type", "country")

gef_set_referer()

## ---- 1. canary ---------------------------------------------------------------
# A nonsense facet id must FAIL the listing assertion; pass the nonsense id's
# own expectation so the echo check is not what fails it - the structural
# checks (results table, non-zero count) must do the telling-apart.
canary_check(
  source       = "gef",
  good_url     = build_gef_funding_url(GEF_FUNDING_SOURCES[["LDCF"]]),
  expect       = gef_listing_expect(GEF_FUNDING_SOURCES[["LDCF"]]),
  nonsense_url = build_gef_funding_url("9999999"),
  nonsense_expect = gef_listing_expect("9999999")
)

## ---- 2. enumerate both funds ---------------------------------------------------
projects <- collect_funding_source_projects()

## ---- 3. Africa classification --------------------------------------------------
africa_names <- c(names(GEF_AFRICA_COUNTRIES), "Africa")
strip_accents <- function(s) {
  out <- iconv(s, to = "ASCII//TRANSLIT")
  ifelse(is.na(out), s, out)
}
is_african <- function(countries) {
  toks <- strsplit(strip_accents(countries %||% ""), "\\s*,\\s*")
  vapply(toks, function(t) any(trimws(t) %in% africa_names), logical(1))
}
projects$africa <- is_african(projects$country)

n_total  <- nrow(projects)
n_africa <- sum(projects$africa)
by_fund  <- table(projects$fund)
cli::cli_h2("Funding sweep totals")
cli::cli_alert_success("{n_total} distinct projects ({paste(names(by_fund), by_fund, sep = ': ', collapse = ', ')})")
cli::cli_alert_success("{n_africa} African (token rule: a named African country or 'Africa')")

## ---- 4. persist the project-level sweep ----------------------------------------
sweep_cols <- c("gef_id", "project_title", "project_url", "gef_project_id",
                "country", "focal_areas", "project_type", "agencies",
                "gef_grant", "cofinancing", "status", "fund", "africa")
sweep_out <- as.data.frame(projects[, sweep_cols])
dir.create(CAT_DIR, recursive = TRUE, showWarnings = FALSE)
readr::write_csv(sweep_out, file.path(CAT_DIR, "gef_funding_source_projects.csv"))
readr::write_csv(sweep_out, file.path(LIST_DIR, "gef_funding_source_projects.csv"))
cli::cli_alert_success("wrote gef_funding_source_projects.csv (catalogues/gef + List)")

## ---- 5. document rows for African projects new to the catalogue ----------------
cat_path_list <- file.path(LIST_DIR, "gef_all_documents.csv")
cat_path_pipe <- file.path(CAT_DIR, "gef_all_documents.csv")
catalogue <- readr::read_csv(cat_path_list, col_types = readr::cols(.default = "c"))

backup <- file.path(CAT_DIR, "gef_all_documents_pre_sweep_backup.csv")
if (!file.exists(backup)) {
  file.copy(cat_path_list, backup)
  cli::cli_alert_info("backed up pre-sweep catalogue to {basename(backup)}")
}

new_ids <- setdiff(projects$gef_id[projects$africa], unique(catalogue$gef_id))
cli::cli_h2("{length(new_ids)} African funding-sweep projects not in the catalogue")

new_docs <- list()
pages_failed <- character(0)
for (i in seq_along(new_ids)) {
  gid  <- new_ids[i]
  prow <- projects[projects$gef_id == gid, ][1, ]
  cli::cli_alert_info("[{i}/{length(new_ids)}] project page GEF {gid}")
  resp <- polite_get(prow$project_url)
  status <- if (is.null(resp)) NA_integer_ else httr::status_code(resp)
  if (is.null(resp) || (!status %in% c(200L, 404L))) {
    # NULL / throttled: stopping keeps a truncated doc inventory from ever
    # looking complete.
    stop("project page fetch failed (GEF ", gid, ", HTTP ",
         ifelse(is.null(resp), "none", status), "): ", prow$project_url, call. = FALSE)
  }
  if (status == 404L) {
    cli::cli_alert_warning("  project page 404s - recording and moving on")
    log_download("gef", gid, NA, prow$project_title, prow$project_url, NA,
                 "failed", "project page HTTP 404 during funding sweep")
    pages_failed <- c(pages_failed, gid)
    next
  }
  html <- tryCatch(xml2::read_html(httr::content(resp, as = "text", encoding = "UTF-8")),
                   error = function(e) NULL)
  if (is.null(html)) {
    stop("project page parse failed (GEF ", gid, "): ", prow$project_url, call. = FALSE)
  }
  docs <- extract_documents_from_page(html, gid, prow$project_title,
                                      prow$project_url, prow$country)
  cli::cli_alert_success("  {nrow(docs)} documents")
  if (nrow(docs) > 0) new_docs[[length(new_docs) + 1]] <- docs
}

n_added <- 0L
if (length(new_docs)) {
  add <- dplyr::bind_rows(new_docs)[, CAT_COLS]
  add <- add[!duplicated(paste(add$gef_id, add$doc_url)), ]
  # no duplicates against the existing catalogue by gef_id + doc_url
  key_old <- paste(catalogue$gef_id, catalogue$doc_url)
  add <- add[!(paste(add$gef_id, add$doc_url) %in% key_old), ]
  n_added <- nrow(add)
  merged <- dplyr::bind_rows(catalogue[, CAT_COLS], add)
  readr::write_csv(merged, cat_path_list)
  readr::write_csv(merged, cat_path_pipe)
  cli::cli_alert_success(
    "appended {nrow(add)} document rows for {length(unique(add$gef_id))} new projects; catalogue now {nrow(merged)} rows (both copies)")
} else {
  cli::cli_alert_info("no new document rows to append")
}

## ---- 6. machine-readable summary ------------------------------------------------
summary_df <- data.frame(
  metric = c("projects_total", paste0("projects_", names(by_fund)), "projects_africa",
             "new_africa_projects", "new_doc_rows", "project_pages_404"),
  value  = c(n_total, as.integer(by_fund), n_africa, length(new_ids),
             n_added, length(pages_failed)),
  stringsAsFactors = FALSE
)
readr::write_csv(summary_df, file.path(CAT_DIR, "gef_sweep_counts.csv"))
cli::cli_h2("Done")
print(summary_df)
