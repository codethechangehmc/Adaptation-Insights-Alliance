# zotero_tidy_attachments.R - tidy records that hold the same file twice.
#
# How it happens: a teammate drops a PDF into Zotero by hand; zotero_pull.R
# brings it into the corpus; the sync creates a record, uploads the corpus
# copy, and then places the teammate's original under the same record. The
# record ends up with two byte-identical files (or more, when the same
# evaluation was dropped two or three times). Since 21 Sep 2026 the sync
# adopts before it uploads, so new cases should not arise; this script tidies
# the ones that exist.
#
# Rule: under one record, files with the same MD5 are the same document.
# The OLDEST copy stays (the teammate's original, with its own filename and
# history); the later copies go to Zotero's TRASH, not deleted, so anything
# can be restored from the trash in the Zotero client. A log lists every
# move. Files with different MD5s are never touched.
#
#   Rscript R/04_catalogue/zotero_tidy_attachments.R --dry    list what would move
#   Rscript R/04_catalogue/zotero_tidy_attachments.R          move to trash
#   -> 04_Screening/inputs/reports/zotero_tidy_attachments_log.csv

suppressPackageStartupMessages({ library(httr); library(jsonlite) })
full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
DRY <- any(commandArgs(trailingOnly = TRUE) == "--dry")

if (!nzchar(Sys.getenv("ZOTERO_API_KEY")))
  for (p in c(file.path(Sys.getenv("OneDrive"), "Documents", ".Renviron"),
              file.path(Sys.getenv("USERPROFILE"), "Documents", ".Renviron")))
    if (file.exists(p)) { readRenviron(p); break }
KEY <- Sys.getenv("ZOTERO_API_KEY"); LIB <- Sys.getenv("ZOTERO_LIBRARY_ID")
stopifnot(nzchar(KEY), nzchar(LIB))
BASE <- paste0("https://api.zotero.org/", Sys.getenv("ZOTERO_LIBRARY_TYPE", "groups"), "/", LIB)
HDR  <- add_headers("Zotero-API-Key" = KEY, "Zotero-API-Version" = "3")

get_all <- function(path) {
  out <- list(); start <- 0
  repeat {
    r <- GET(paste0(BASE, path, if (grepl("\\?", path)) "&" else "?", "limit=100&start=", start), HDR)
    stop_for_status(r)
    page <- fromJSON(content(r, as = "text", encoding = "UTF-8"), simplifyVector = FALSE)
    out <- c(out, page); start <- start + 100
    total <- suppressWarnings(as.integer(headers(r)[["total-results"]]))
    if (!length(page) || (!is.na(total) && start >= total)) break
  }
  out
}

atts <- get_all("/items?itemType=attachment")
atts <- Filter(function(a) !is.null(a$data$parentItem) && !is.null(a$data$md5) &&
                 !isTRUE(a$data$deleted), atts)
df <- do.call(rbind, lapply(atts, function(a) data.frame(
  key = a$key, version = a$version, parent = a$data$parentItem, md5 = a$data$md5,
  filename = if (is.null(a$data$filename)) "" else a$data$filename,
  added = a$data$dateAdded, stringsAsFactors = FALSE)))
cat("attachments with a parent and an MD5:", nrow(df), "\n")

# same parent + same md5, more than once: keep the oldest
df <- df[order(df$parent, df$md5, df$added), ]
grp <- paste(df$parent, df$md5)
df$rank <- ave(seq_len(nrow(df)), grp, FUN = seq_along)
dup <- df[df$rank > 1, ]
keep <- df[df$rank == 1, ]
dup$kept_key <- keep$key[match(paste(dup$parent, dup$md5), paste(keep$parent, keep$md5))]
dup$kept_filename <- keep$filename[match(dup$kept_key, keep$key)]
cat("records holding the same file more than once:", length(unique(dup$parent)),
    "| extra copies to move to the trash:", nrow(dup), "\n")
if (nrow(dup)) print(head(dup[, c("parent", "filename", "kept_filename", "added")], 15), row.names = FALSE)
if (DRY || !nrow(dup)) quit(save = "no")

log <- list()
for (i in seq_len(nrow(dup))) {
  r <- dup[i, ]
  resp <- PATCH(paste0(BASE, "/items/", r$key), HDR,
                add_headers("Content-Type" = "application/json", "If-Unmodified-Since-Version" = as.character(r$version)),
                body = toJSON(list(deleted = TRUE), auto_unbox = TRUE))
  ok <- status_code(resp) %in% c(200, 204)
  log[[i]] <- data.frame(date = format(Sys.Date()), parent = r$parent, trashed_key = r$key, trashed_filename = r$filename,
                         kept_key = r$kept_key, kept_filename = r$kept_filename, md5 = r$md5,
                         result = if (ok) "moved to trash" else paste("FAILED", status_code(resp)), stringsAsFactors = FALSE)
  cat(sprintf("  %3d/%d %-14s %s\n", i, nrow(dup), if (ok) "trashed" else "FAILED", substr(r$filename, 1, 70)))
  Sys.sleep(0.3)
}
log <- do.call(rbind, log)
LOG <- file.path(VOCAB_DIR, "zotero_tidy_attachments_log.csv")
if (file.exists(LOG)) log <- rbind(read.csv(LOG, stringsAsFactors = FALSE, colClasses = "character"), log)
write.csv(log, LOG, row.names = FALSE)
cat("\nmoved to trash:", sum(log$result == "moved to trash"), "| log:", LOG, "\n",
    "Restore anything from Trash in the Zotero client if needed.\n")
