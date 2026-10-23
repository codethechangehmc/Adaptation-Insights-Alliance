# worldbank_fetch_inscope.R - fetch the in-scope half of the World Bank gap.
#
# The live gap derivation produced 470 documents, far past the ceiling that
# says "stop and look", so the retrieval agent correctly halted. The
# breakdown showed why: 445 of them are kept by the scraper's abstract
# keyword tier, where "resilience", "soil", "seed" and "flood" match the
# abstracts of health, power, roads and education evaluations. Those are a
# filter problem, not a corpus gap, and they are listed for adjudication.
#
# The remaining 21 carry the Bank's own in-scope classification and are the
# genuine gap: 2 implementation completion reports and 19 Project Performance
# Assessment Reports. The PPARs matter most. They are the evaluation
# department's independent field assessments, the corpus holds none at all,
# and the team decision of 2026-10-02 keeps them while excluding desk reviews.
#
#   Rscript R/01_retrieve/worldbank_fetch_inscope.R [--dry]

.find_r_dir <- function() {
  fa <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  normalizePath(file.path(dirname(sub("^--file=", "", fa[1])), ".."), mustWork = TRUE)
}
R_DIR <- .find_r_dir()
suppressMessages({
  source(file.path(R_DIR, "00_shared", "00_config.R"))
  source(file.path(R_DIR, "00_shared", "01_utils.R"))
  source(file.path(R_DIR, "00_shared", "paths.R"))
})
Sys.setenv(GL_LOG_SUFFIX = "worldbank")
DRY <- "--dry" %in% commandArgs(trailingOnly = TRUE)

GAP  <- file.path(PROJECT_ROOT, "outputs", "worldbank_gap_list.csv")
DEST <- file.path(DOCS_ROOT, "Worldbank", "Docs", "to_screen")
stopifnot(file.exists(GAP))
dir.create(DEST, recursive = TRUE, showWarnings = FALSE)

g <- read.csv(GAP, stringsAsFactors = FALSE, colClasses = "character")
g[is.na(g)] <- ""
g <- g[g$screen_status_cached == "in_scope", ]
cat("in-scope gap rows:", nrow(g), "\n")
print(table(g$doc_type))

held <- basename(list.files(file.path(DOCS_ROOT, "Worldbank"), recursive = TRUE))

type_token <- function(dt) ifelse(grepl("Performance Assessment", dt), "PPAR", "ICR")
year_of <- function(d) {
  y <- sub("^(\\d{4}).*", "\\1", d)
  ifelse(grepl("^\\d{4}$", y), y, "")
}

res <- list()
for (i in seq_len(nrow(g))) {
  r <- g[i, ]
  pcode <- if (nzchar(r$pcode)) r$pcode else gsub("[^A-Za-z0-9]", "", r$project_id)
  pcode <- strsplit(pcode, ",")[[1]][1]
  yr <- year_of(r$doc_date)
  nm <- sprintf("worldbank_%s_%s_%s%s.pdf", safe_filename(pcode, 24), safe_filename(r$id, 16),
                type_token(r$doc_type), if (nzchar(yr)) paste0("_", yr) else "")
  if (nm %in% held) {
    cat(sprintf("  [%2d/%d] already held: %s\n", i, nrow(g), nm)); res[[i]] <- "already_held"; next
  }
  if (DRY) { cat(sprintf("  [%2d/%d] would fetch: %-58s %s\n", i, nrow(g), substr(r$title,1,58), nm)); next }
  ok <- download_pdf(r$pdf_url, file.path(DEST, nm))
  status <- if (isTRUE(ok)) "success" else if (identical(ok, "skipped")) "skipped" else "failed"
  log_download(source = "worldbank", project_code = pcode, doc_type = type_token(r$doc_type),
               title = r$title, url = r$pdf_url,
               filepath = if (status == "success") file.path(DEST, nm) else NA,
               status = status, notes = "in-scope half of the live gap (worldbank_gap_list.csv)")
  res[[i]] <- status
  cat(sprintf("  [%2d/%d] %-8s %s\n", i, nrow(g), status, nm))
}
if (!DRY) {
  tb <- table(unlist(res))
  cat("\n"); print(tb)
  cat("\nto_screen now holds", length(list.files(DEST)), "files\n")
}
