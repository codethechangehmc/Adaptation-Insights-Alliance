# zotero_apply_progress_rule.R - move every progress document into its
# funder's "screened out" collection.
#
# The protocol's first criterion names progress reports as out of scope, in
# the same sentence as proposals and appraisals. screen_rules.R now applies
# that, and this moves the Zotero side to match: an item whose ledger verdict
# is "out of scope" by the progress rule leaves "included" and "to screen"
# and joins "screened out" under the same funder.
#
# Collection membership is changed by patching the item's own `collections`
# array. Only the three screening collections of that funder are touched, so
# an item that also sits in a thematic collection keeps it.
#
#   Rscript R/04_catalogue/zotero_apply_progress_rule.R --dry
#   Rscript R/04_catalogue/zotero_apply_progress_rule.R

suppressPackageStartupMessages({ library(httr); library(jsonlite); library(glue); library(cli) })
DRY <- "--dry" %in% commandArgs(trailingOnly = TRUE)

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))

for (p in c(file.path(Sys.getenv("OneDrive"), "Documents", ".Renviron"),
            file.path(Sys.getenv("USERPROFILE"), "Documents", ".Renviron")))
  if (file.exists(p)) { readRenviron(p); break }
K <- Sys.getenv("ZOTERO_API_KEY"); L <- Sys.getenv("ZOTERO_LIBRARY_ID")
TY <- Sys.getenv("ZOTERO_LIBRARY_TYPE", "groups")
stopifnot(nzchar(K), nzchar(L))
B <- glue("https://api.zotero.org/{TY}/{L}")
zh  <- function(...) add_headers("Zotero-API-Key" = K, "Zotero-API-Version" = "3",
                                 "Content-Type" = "application/json", ...)
zhp <- function() add_headers("Zotero-API-Key" = K, "Zotero-API-Version" = "3")

get_all <- function(path, query = list()) {
  out <- list(); s <- 0
  repeat {
    r <- GET(glue("{B}/{path}"), query = c(query, list(format = "json", limit = 100, start = s)),
             zhp(), timeout(60))
    stop_for_status(r)
    js <- fromJSON(content(r, "text", encoding = "UTF-8"), simplifyVector = FALSE)
    out <- c(out, js); tot <- as.integer(headers(r)[["total-results"]]); s <- s + 100
    if (is.na(tot) || s >= tot || length(js) == 0) break
  }
  out
}

FUNDER <- c(worldbank = "World Bank", gef = "GEF", gcf = "GCF",
            afdb = "AfDB", af = "Adaptation Fund", cif = "CIF")

cli_h1("Progress documents -> screened out")
cols <- get_all("collections")
key_of <- function(name, parent_name) {
  pk <- NULL
  for (c in cols) {
    pc <- c$data$parentCollection
    if (identical(c$data$name, parent_name) && (is.null(pc) || isFALSE(pc))) pk <- c$key
  }
  if (is.null(pk)) return(NULL)
  for (c in cols) if (identical(c$data$name, name) && identical(c$data$parentCollection, pk)) return(c$key)
  NULL
}
SET <- list()
for (s in names(FUNDER)) {
  SET[[s]] <- list(inc = key_of("included", FUNDER[[s]]),
                   scr = key_of("to screen", FUNDER[[s]]),
                   out = key_of("screened out", FUNDER[[s]]))
  if (is.null(SET[[s]]$out)) cli_alert_danger("no 'screened out' under {FUNDER[[s]]}")
}

sc <- read.csv(file.path(SCREEN_DIR, "scope_screen.csv"), colClasses = "character")
sc[is.na(sc)] <- ""
prog <- sc[grepl("progress report", sc$rule_applied) & sc$verdict_ruled == "out of scope", ]
cli_alert_info("progress documents ruled out of scope: {nrow(prog)}")

atts <- get_all("items", list(itemType = "attachment"))
parent_of <- list()
for (it in atts) {
  f <- it$data$filename
  if (!is.null(f) && nzchar(f) && !is.null(it$data$parentItem))
    parent_of[[tolower(f)]] <- as.character(it$data$parentItem)
}
cli_alert_info("attachments indexed: {length(parent_of)}")

get_item <- function(k) {
  r <- GET(glue("{B}/items/{k}"), query = list(format = "json"), zhp(), timeout(60))
  if (status_code(r) != 200) return(NULL)
  fromJSON(content(r, "text", encoding = "UTF-8"), simplifyVector = FALSE)
}

n_move <- 0; n_ok <- 0; n_miss <- 0; n_fail <- 0
for (i in seq_len(nrow(prog))) {
  src <- prog$source[i]; fn <- prog$filename[i]
  s <- SET[[src]]
  if (is.null(s) || is.null(s$out)) { n_miss <- n_miss + 1; next }
  pk <- parent_of[[tolower(fn)]]
  if (is.null(pk)) { n_miss <- n_miss + 1; next }
  it <- get_item(pk); if (is.null(it)) { n_miss <- n_miss + 1; next }
  cur <- it$data$collections
  cur <- if (is.null(cur)) character(0) else as.character(unlist(cur))
  want <- union(setdiff(cur, c(s$inc, s$scr)), s$out)
  if (setequal(cur, want)) { n_ok <- n_ok + 1; next }
  if (DRY) { n_move <- n_move + 1; next }
  r <- PATCH(glue("{B}/items/{pk}"), zh("If-Unmodified-Since-Version" = it$version),
             body = toJSON(list(collections = I(want)), auto_unbox = TRUE), timeout(60))
  if (status_code(r) %in% c(200, 204)) n_move <- n_move + 1 else {
    n_fail <- n_fail + 1
    cli_alert_danger("{substr(fn,1,46)}: HTTP {status_code(r)}")
  }
}
cli_h2("moved {n_move}, already correct {n_ok}, not in Zotero {n_miss}, failed {n_fail}{if (DRY) ' (dry run)' else ''}")
