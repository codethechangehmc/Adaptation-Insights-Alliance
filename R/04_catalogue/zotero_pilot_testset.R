# zotero_pilot_testset.R - put the pilot test set in its own Zotero collection
# so collaborators can reach the documents the reference answers describe.
#
# Two different situations, handled differently on purpose:
#
#   GOLD (P001-P010, 22 PDFs) live only in 03_Documents/pilot/gold_set_P001-P010.
#     They are not in the corpus and not in Zotero, so they are uploaded.
#     Four of them sit behind paths over 300 characters, past the Windows
#     limit of 260, so every file read here goes through the extended-length
#     prefix. Without it those four silently fail to open.
#
#   HOLDOUT (H001-H010) are ALREADY in Zotero: they are ordinary corpus
#     documents and the holdout deliberately keeps no copies of its own. They
#     are therefore ADDED TO THE COLLECTION, never re-uploaded. A Zotero item
#     can belong to several collections; uploading again would create
#     duplicates of documents the library already holds, which is the exact
#     thing the dedup layer exists to prevent.
#
# Not to be confused with the "Pilot extraction" collection under Charity:
# that is a different pilot.
#
#   Rscript R/04_catalogue/zotero_pilot_testset.R --dry
#   Rscript R/04_catalogue/zotero_pilot_testset.R

suppressPackageStartupMessages({
  library(httr); library(jsonlite); library(glue); library(cli); library(tools)
})
DRY <- "--dry" %in% commandArgs(trailingOnly = TRUE)

for (p in c(file.path(Sys.getenv("OneDrive"), "Documents", ".Renviron"),
            file.path(Sys.getenv("USERPROFILE"), "Documents", ".Renviron")))
  if (file.exists(p)) { readRenviron(p); break }
API_KEY <- Sys.getenv("ZOTERO_API_KEY"); LIBRARY_ID <- Sys.getenv("ZOTERO_LIBRARY_ID")
LIBRARY_TYPE <- Sys.getenv("ZOTERO_LIBRARY_TYPE", "groups")
stopifnot(nzchar(API_KEY), nzchar(LIBRARY_ID))
ZOTERO_BASE <- glue("https://api.zotero.org/{LIBRARY_TYPE}/{LIBRARY_ID}")

GL   <- "C:/Users/mlolita/OneDrive - CGIAR/WP2_Evidence Synthesis/Grey Literature"
GOLD <- file.path(GL, "03_Documents/pilot/gold_set_P001-P010")
HMAN <- file.path(GL, "07_Pipeline/outputs/extraction/holdout/holdout_manifest.csv")
PARENT_NAME  <- "Pilot test set (reference answers)"
GOLD_NAME    <- "Gold P001-P010"
HOLDOUT_NAME <- "Holdout H001-H010"

zh  <- function() add_headers("Zotero-API-Key" = API_KEY, "Zotero-API-Version" = "3",
                             "Content-Type" = "application/json")
zhp <- function() add_headers("Zotero-API-Key" = API_KEY, "Zotero-API-Version" = "3")

# Windows stops at 260 characters; four gold paths are over 300.
longpath <- function(p) {
  p <- normalizePath(p, winslash = "\\", mustWork = FALSE)
  if (.Platform$OS.type == "windows" && !startsWith(p, "\\\\?\\")) paste0("\\\\?\\", p) else p
}

get_all <- function(path, query = list()) {
  out <- list(); start <- 0
  repeat {
    r <- GET(glue("{ZOTERO_BASE}/{path}"),
             query = c(query, list(format = "json", limit = 100, start = start)),
             zhp(), timeout(60))
    stop_for_status(r)
    js <- fromJSON(content(r, "text", encoding = "UTF-8"), simplifyVector = FALSE)
    out <- c(out, js)
    tot <- as.integer(headers(r)[["total-results"]]); start <- start + 100
    if (is.na(tot) || start >= tot || length(js) == 0) break
  }
  out
}

ensure_collection <- function(name, parent = NULL) {
  cols <- get_all("collections")
  for (c in cols) {
    pc <- c$data$parentCollection
    same_parent <- if (is.null(parent)) (is.logical(pc) || is.null(pc) || identical(pc, FALSE)) else identical(pc, parent)
    if (identical(c$data$name, name) && same_parent) return(c$key)
  }
  if (DRY) { cli_alert_info("would create collection: {name}"); return(paste0("DRY-", substr(name, 1, 6))) }
  body <- list(list(name = name))
  if (!is.null(parent)) body[[1]]$parentCollection <- parent
  r <- POST(glue("{ZOTERO_BASE}/collections"), zh(), body = toJSON(body, auto_unbox = TRUE))
  stop_for_status(r)
  js <- fromJSON(content(r, "text", encoding = "UTF-8"), simplifyVector = FALSE)
  key <- js$successful[["0"]]$key
  cli_alert_success("created collection: {name}")
  key
}

guess_ct <- function(f) if (grepl("[.]pdf$", f, ignore.case = TRUE)) "application/pdf" else "application/octet-stream"

post_batch <- function(items) {
  r <- POST(glue("{ZOTERO_BASE}/items"), zh(), body = toJSON(items, auto_unbox = TRUE))
  stop_for_status(r)
  fromJSON(content(r, "text", encoding = "UTF-8"), simplifyVector = FALSE)
}

upload_file_to_item <- function(parent_key, filepath) {
  fname <- basename(filepath); lp <- longpath(filepath)
  att <- list(list(itemType = "attachment", linkMode = "imported_file",
                   parentItem = parent_key, title = fname,
                   contentType = guess_ct(fname), filename = fname))
  res <- post_batch(att)
  if (length(res$successful) == 0) return(FALSE)
  akey <- res$successful[["0"]]$key
  md5 <- unname(md5sum(lp)); sz <- file.size(lp)
  auth <- POST(glue("{ZOTERO_BASE}/items/{akey}/file"), zhp(),
               add_headers("If-None-Match" = "*"),
               body = list(md5 = md5, filename = fname, filesize = sz,
                           mtime = round(as.numeric(file.mtime(lp)) * 1000)),
               encode = "form")
  if (status_code(auth) == 413) return("quota")
  stop_for_status(auth)
  aj <- fromJSON(content(auth, "text", encoding = "UTF-8"), simplifyVector = FALSE)
  if (isTRUE(aj$exists == 1)) return(TRUE)
  body_raw <- c(charToRaw(aj$prefix), readBin(lp, "raw", n = sz), charToRaw(aj$suffix))
  up <- POST(aj$url, body = body_raw, add_headers("Content-Type" = aj$contentType))
  stop_for_status(up)
  reg <- POST(glue("{ZOTERO_BASE}/items/{akey}/file"), zhp(),
              add_headers("If-None-Match" = "*"),
              body = list(upload = aj$uploadKey), encode = "form")
  status_code(reg) %in% c(200, 204)
}

## ---- what is already in the library ----------------------------------------
cli_h1("Pilot test set -> Zotero")
atts <- get_all("items", list(itemType = "attachment"))
by_file <- list()
for (it in atts) {
  f <- it$data$filename
  if (!is.null(f) && nzchar(f))
    by_file[[tolower(f)]] <- list(att = it$key, parent = it$data$parentItem)
}
cli_alert_info("attachments in the library: {length(by_file)}")

parent_key  <- ensure_collection(PARENT_NAME)
gold_key    <- ensure_collection(GOLD_NAME, parent_key)
holdout_key <- ensure_collection(HOLDOUT_NAME, parent_key)

## ---- GOLD: upload what is missing -------------------------------------------
gold_files <- list.files(GOLD, pattern = "[.]pdf$", recursive = TRUE, full.names = TRUE)
gold_files <- gold_files[!duplicated(basename(gold_files))]
cli_h2("Gold: {length(gold_files)} documents")
n_up <- 0; n_have <- 0; n_fail <- 0; quota <- FALSE
for (f in gold_files) {
  b <- basename(f)
  pcode <- sub("^(P[0-9]{3}(-[0-9]{3})?)_.*$", "\\1", b)
  if (!is.null(by_file[[tolower(b)]])) { n_have <- n_have + 1; next }
  if (!file.exists(longpath(f))) { cli_alert_danger("missing on disk: {substr(b,1,60)}"); n_fail <- n_fail + 1; next }
  if (DRY) { cli_alert_info("would upload [{pcode}] {substr(b,1,58)}"); n_up <- n_up + 1; next }
  item <- list(list(itemType = "report", title = b,
                    collections = list(gold_key),
                    tags = list(list(tag = "pilot:gold"), list(tag = paste0("pilot:", pcode))),
                    extra = paste0("Pilot reference document ", pcode)))
  res <- post_batch(item)
  if (length(res$successful) == 0) { n_fail <- n_fail + 1; next }
  key <- res$successful[["0"]]$key
  r <- tryCatch(upload_file_to_item(key, f), error = function(e) FALSE)
  if (identical(r, "quota")) { quota <- TRUE; break }
  if (isTRUE(r)) { n_up <- n_up + 1; cli_alert_success("[{pcode}] {substr(b,1,56)}") } else n_fail <- n_fail + 1
}
cli_alert_info("gold: uploaded {n_up}, already present {n_have}, failed {n_fail}")
if (quota) cli_alert_danger("stopped: Zotero storage quota exceeded")

## ---- HOLDOUT: add existing items to the collection, never re-upload ---------
hold <- if (file.exists(HMAN)) read.csv(HMAN, stringsAsFactors = FALSE) else data.frame()
cli_h2("Holdout: {nrow(hold)} documents (already in the library; adding to the collection)")
n_add <- 0; n_miss <- 0
for (i in seq_len(nrow(hold))) {
  b <- basename(hold$pdf[i]); code <- hold$project_code[i]
  e <- by_file[[tolower(b)]]
  if (is.null(e) || is.null(e$parent)) { cli_alert_warning("[{code}] not in Zotero: {substr(b,1,52)}"); n_miss <- n_miss + 1; next }
  if (DRY) { cli_alert_info("would add [{code}] {substr(b,1,52)}"); n_add <- n_add + 1; next }
  r <- POST(glue("{ZOTERO_BASE}/collections/{holdout_key}/items"), zhp(),
            body = e$parent, encode = "raw")
  if (status_code(r) %in% c(200, 204)) { n_add <- n_add + 1; cli_alert_success("[{code}] added") }
  else { cli_alert_danger("[{code}] HTTP {status_code(r)}"); n_miss <- n_miss + 1 }
}
cli_alert_info("holdout: added {n_add}, not found {n_miss}")
cli_h2("Done{if (DRY) ' (dry run, nothing written)' else ''}")
