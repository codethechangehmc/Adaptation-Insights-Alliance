# zotero_pull.R - bring files that teammates added to Zotero by hand into the
# corpus, so the pipeline knows everything the library knows.
#
# The sync (04_catalogue/zotero_upload.R) pushes the corpus INTO Zotero. This
# is the other direction: a teammate drops a PDF into an institution's
# collection (a standalone attachment, or an item without our doc tags); the
# pipeline has never seen it, so it is neither censused, screened nor
# extractable. This script lists the library's attachments, keeps those with
# no record of ours behind them and whose bytes are not already in the corpus
# (MD5 against review/family_census.csv), works out the institution from the
# collection they sit in, downloads each into that source's to_screen folder,
# and writes a register. The normal steps follow: doc_census.R, dedup_corpus.R,
# screen_scope.R; the sync then creates the proper record for each.
#
#   Rscript R/01_retrieve/zotero_pull.R --dry       list what would be pulled
#   Rscript R/01_retrieve/zotero_pull.R             pull
#   -> 03_Documents/{source}/Docs/to_screen/zotero_{key}_{filename}
#      04_Screening/inputs/reports/zotero_pulled.csv

suppressPackageStartupMessages({ library(httr); library(jsonlite) })
full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
args <- commandArgs(trailingOnly = TRUE)
DRY <- any(args == "--dry")

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
    if (!length(page)) break
    out <- c(out, page); start <- start + 100
    if (length(page) < 100) break
  }
  out
}

# collections: which institution does each status collection belong to
cols <- get_all("/collections")
cname <- setNames(vapply(cols, function(c) c$data$name, ""), vapply(cols, function(c) c$key, ""))
cpar  <- setNames(vapply(cols, function(c) if (is.logical(c$data$parentCollection)) "" else c$data$parentCollection, ""),
                  vapply(cols, function(c) c$key, ""))
inst_of_col <- function(k) {
  if (is.na(cname[k])) return("")
  if (nzchar(cpar[k])) k <- cpar[k]
  unname(cname[k])
}
SRC <- c("World Bank" = "Worldbank", "GEF" = "gef", "GCF" = "gcf", "AfDB" = "afdb", "Adaptation Fund" = "af", "CIF" = "cif")

# top-level items: which carry our doc tags (then their attachments are ours)
top <- get_all("/items/top")
ours <- vapply(top, function(it) any(grepl("doc:", vapply(it$data$tags, function(t) t$tag, ""), fixed = TRUE)), logical(1))
top_key <- vapply(top, function(it) it$key, "")
top_cols <- setNames(lapply(top, function(it) unlist(it$data$collections)), top_key)
is_ours <- setNames(ours, top_key)

# attachments: standalone (no parent) or under a hand-made item
atts <- get_all("/items?itemType=attachment")
cat("library:", length(top), "top-level items,", length(atts), "attachments\n")

# what the corpus already holds, by content
cen_p <- file.path(SCREEN_DIR, "inputs", "decisions", "family_census.csv")
cen <- if (file.exists(cen_p)) read.csv(cen_p, stringsAsFactors = FALSE, colClasses = "character") else data.frame(md5 = character(0), filename = character(0))
have_md5 <- unique(cen$md5)
file_of_md5 <- setNames(cen$filename, cen$md5)      # first corpus file with these bytes

cand <- list()
for (a in atts) {
  d <- a$data
  if (!identical(d$linkMode, "imported_file") && !identical(d$linkMode, "imported_url")) next
  parent <- d$parentItem
  if (!is.null(parent) && isTRUE(is_ours[parent])) next             # ours already
  colkeys <- if (is.null(parent)) unlist(d$collections) else top_cols[[parent]]
  inst <- unique(Filter(nzchar, vapply(colkeys %||% character(0), inst_of_col, "")))
  inst <- inst[inst %in% names(SRC)]
  md5 <- if (is.null(d$md5)) "" else d$md5
  fname <- if (is.null(d$filename) || !nzchar(d$filename)) paste0(a$key, ".pdf") else d$filename
  cand[[length(cand) + 1]] <- data.frame(
    key = a$key, parent = if (is.null(parent)) "" else parent,
    institution = if (length(inst)) inst[1] else "", filename = fname,
    content_type = if (is.null(d$contentType)) "" else d$contentType, md5 = md5,
    already_in_corpus = md5 %in% have_md5, stringsAsFactors = FALSE)
}
cand <- if (length(cand)) do.call(rbind, cand) else data.frame()
cat("attachments not behind one of our records:", nrow(cand), "\n")
if (nrow(cand)) {
  print(table(institution = ifelse(nzchar(cand$institution), cand$institution, "(no institution collection)"),
              already_in_corpus = cand$already_in_corpus))
  print(table(type = cand$content_type))
}
todo <- cand[nrow(cand) > 0 & nzchar(cand$institution) & !cand$already_in_corpus, , drop = FALSE]
cat("to pull:", nrow(todo), "\n")
# bytes already in the corpus: nothing to download, but the attachment is
# still a blank row in Zotero. Register it against the corpus file that has
# the same bytes so the sync (zotero_adopt_pulled.R) places it under that
# file's record.
have <- cand[nrow(cand) > 0 & nzchar(cand$institution) & cand$already_in_corpus, , drop = FALSE]
cat("already in the corpus (to adopt under the existing record):", nrow(have), "\n")
if (DRY || (!nrow(todo) && !nrow(have))) quit(save = "no")
REG <- file.path(SCREEN_DIR, "inputs", "reports", "zotero_pulled.csv")
old <- if (file.exists(REG)) read.csv(REG, stringsAsFactors = FALSE, colClasses = "character") else NULL
have <- have[!(have$key %in% old$zotero_key), , drop = FALSE]      # registered on an earlier run
todo <- todo[!(todo$key %in% old$zotero_key), , drop = FALSE]
reg <- list()
for (i in seq_len(nrow(have))) {
  r <- have[i, ]
  reg[[length(reg) + 1]] <- data.frame(date = format(Sys.Date()), zotero_key = r$key, institution = r$institution,
                                       source = SRC[[r$institution]], filename = unname(file_of_md5[r$md5]), zotero_filename = r$filename,
                                       md5 = r$md5, saved_to = "", status = "in_corpus", stringsAsFactors = FALSE)
}

safe <- function(x) { x <- gsub("[^A-Za-z0-9._-]+", "_", x); substr(x, 1, 90) }
for (i in seq_len(nrow(todo))) {
  r <- todo[i, ]
  dir <- file.path(DOCS_ROOT, SRC[[r$institution]], "Docs", "to_screen")
  dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  dest <- file.path(dir, paste0("zotero_", r$key, "_", safe(r$filename)))
  ok <- tryCatch({
    resp <- GET(paste0(BASE, "/items/", r$key, "/file"), HDR, write_disk(dest, overwrite = TRUE))
    status_code(resp) == 200 && file.exists(dest) && file.info(dest)$size > 1000
  }, error = function(e) FALSE)
  reg[[length(reg) + 1]] <- data.frame(date = format(Sys.Date()), zotero_key = r$key, institution = r$institution,
                                       source = SRC[[r$institution]], filename = basename(dest), zotero_filename = r$filename,
                                       md5 = r$md5, saved_to = if (ok) dest else "", status = if (ok) "pulled" else "FAILED",
                                       stringsAsFactors = FALSE)
  cat(sprintf("  %3d/%d %-8s %s %s\n", i, nrow(todo), if (ok) "pulled" else "FAILED", r$institution, substr(r$filename, 1, 60)))
}
new <- do.call(rbind, reg)
reg <- rbind(old, new)
write.csv(reg, REG, row.names = FALSE)
cat("\nthis run:", sum(new$status == "pulled"), "pulled,", sum(new$status == "in_corpus"), "already in the corpus (registered for adoption); register:", REG, "\n",
    "next: doc_census.R, dedup_corpus.R, screen_scope.R, then zotero_upload.R\n")
