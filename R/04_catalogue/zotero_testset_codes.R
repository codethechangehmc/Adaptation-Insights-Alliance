# zotero_testset_codes.R - write the pilot code (P001.., H001..) onto the
# Zotero items of the test set, so collaborators can read it as a column.
#
# Field choice. Zotero has no custom columns, so the code has to go in a
# built-in field that the column picker offers. Three were considered:
#
#   callNumber      occupied. 802 of 1639 items carry the funder's own project
#                   id there (FP049, AF00000109, P-BJ-AA0-007). World Bank ids
#                   read P149269, the same shape as our P001, so writing the
#                   pilot code into that field would both destroy data and
#                   produce a column mixing two unrelated numbering schemes.
#   extra           occupied, and holds pipeline metadata of varying length.
#   archiveLocation empty across all 1639 items. Shown as "Loc. in Archive".
#
# archiveLocation is therefore used. Nothing else in the project reads or
# writes it; catalogues/<src>/attestation.csv remains the machine-readable
# record.
#
# Holdout items are ordinary corpus records shared with the team. Only
# archiveLocation and the pilot tags are touched; title, callNumber and extra
# are left as they are.
#
# Idempotent: an item already carrying the right code and tags is skipped, so a
# second run writes nothing.
#
#   Rscript R/04_catalogue/zotero_testset_codes.R --dry
#   Rscript R/04_catalogue/zotero_testset_codes.R

suppressPackageStartupMessages({
  library(httr); library(jsonlite); library(glue); library(cli)
})
DRY <- "--dry" %in% commandArgs(trailingOnly = TRUE)
`%||%` <- function(a, b) if (is.null(a)) b else a

for (p in c(file.path(Sys.getenv("OneDrive"), "Documents", ".Renviron"),
            file.path(Sys.getenv("USERPROFILE"), "Documents", ".Renviron")))
  if (file.exists(p)) { readRenviron(p); break }
API_KEY <- Sys.getenv("ZOTERO_API_KEY"); LIBRARY_ID <- Sys.getenv("ZOTERO_LIBRARY_ID")
LIBRARY_TYPE <- Sys.getenv("ZOTERO_LIBRARY_TYPE", "groups")
stopifnot(nzchar(API_KEY), nzchar(LIBRARY_ID))
BASE <- glue("https://api.zotero.org/{LIBRARY_TYPE}/{LIBRARY_ID}")

GL   <- "C:/Users/mlolita/OneDrive - CGIAR/WP2_Evidence Synthesis/Grey Literature"
HMAN <- file.path(GL, "07_Pipeline/outputs/extraction/holdout/holdout_manifest.csv")
PARENT_NAME  <- "Pilot test set (reference answers)"
GOLD_NAME    <- "Gold P001-P010"
HOLDOUT_NAME <- "Holdout H001-H010"

zhp <- function(...) add_headers("Zotero-API-Key" = API_KEY, "Zotero-API-Version" = "3", ...)
zh  <- function(...) add_headers("Zotero-API-Key" = API_KEY, "Zotero-API-Version" = "3",
                                 "Content-Type" = "application/json", ...)

get_all <- function(path, query = list()) {
  out <- list(); start <- 0
  repeat {
    r <- GET(glue("{BASE}/{path}"),
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

find_collection <- function(cols, name, parent = NULL) {
  for (c in cols) {
    pc <- c$data$parentCollection
    same <- if (is.null(parent)) (is.logical(pc) || is.null(pc) || identical(pc, FALSE)) else identical(pc, parent)
    if (identical(c$data$name, name) && same) return(c$key)
  }
  NULL
}

# PATCH one item. The version header is what stops a concurrent edit by a
# teammate being silently overwritten; a 412 means someone else changed the
# item, and the run should be repeated rather than forced.
patch_item <- function(key, version, fields) {
  r <- PATCH(glue("{BASE}/items/{key}"), zh("If-Unmodified-Since-Version" = version),
             body = toJSON(fields, auto_unbox = TRUE), timeout(60))
  if (status_code(r) == 412) {
    cli_alert_danger("{key}: changed by someone else (412), re-run")
    return(FALSE)
  }
  stop_for_status(r)
  status_code(r) %in% c(200, 204)
}

cli_h1("Pilot codes -> Zotero (Loc. in Archive)")
cols <- get_all("collections")
pk <- find_collection(cols, PARENT_NAME)
if (is.null(pk)) stop("collection not found: ", PARENT_NAME)
gold_key    <- find_collection(cols, GOLD_NAME, pk)
holdout_key <- find_collection(cols, HOLDOUT_NAME, pk)
stopifnot(!is.null(gold_key), !is.null(holdout_key))

## ---- what code does each top-level item carry? ------------------------------
# Gold: the item title is the filename, which begins with the code
#       (P001_, and P002-004_ for the evaluation covering three programmes).
# Holdout: the manifest gives code -> pdf filename; the filename identifies an
#       attachment, whose parent is the item that gets the code.
wanted <- list()   # item key -> list(code, set, title, version, have, tags)

gold_items <- get_all(glue("collections/{gold_key}/items/top"))
n_gold <- 0
for (it in gold_items) {
  ttl <- it$data$title
  code <- sub("^(P[0-9]{3}(-[0-9]{3})?)_.*$", "\\1", ttl)
  if (identical(code, ttl)) {
    cli_alert_warning("gold, no code in title: {substr(ttl,1,54)}")
    next
  }
  wanted[[it$key]] <- list(code = code, set = "gold", title = ttl, version = it$version,
                           have = it$data$archiveLocation, tags = it$data$tags)
  n_gold <- n_gold + 1
}
cli_alert_info("gold: {length(gold_items)} items, {n_gold} carry a code in the title")

hold <- if (file.exists(HMAN)) read.csv(HMAN, stringsAsFactors = FALSE) else data.frame()
hold_items <- get_all(glue("collections/{holdout_key}/items"))

# attachment filename -> parent key, and -> the attachment's own key
att_parent <- list(); att_key <- list()
for (it in hold_items) {
  d <- it$data
  if (!identical(d$itemType, "attachment")) next
  f <- d$filename
  if (!is.null(f) && nzchar(f)) {
    att_parent[[tolower(f)]] <- d$parentItem
    att_key[[tolower(f)]]    <- it$key
  }
}
top_by_key <- list()
for (it in hold_items) {
  pi <- it$data$parentItem
  if (is.null(pi) || !nzchar(as.character(pi))) top_by_key[[it$key]] <- it
}

get_item <- function(key) {
  r <- GET(glue("{BASE}/items/{key}"), query = list(format = "json"), zhp(), timeout(60))
  if (status_code(r) != 200) return(NULL)
  fromJSON(content(r, "text", encoding = "UTF-8"), simplifyVector = FALSE)
}

# Four holdout documents (H001-H004) showed in the collection as a bare PDF
# with no titled record above it. The cause: their parent records are in the
# trash. A trashed item keeps its collection membership and its children, but
# is left out of every listing, so the collection returned the child
# attachment and not the parent. Each was trashed by the deduplication pass
# and has a live twin carrying the same file, so nothing was lost and the
# trashed copy should stay trashed.
#
# The collection is therefore pointed at the live twin, and the trashed copy
# is taken out of the collection and stripped of its code, so that restoring
# it later cannot produce two records claiming H001.
#
# Collection membership is changed by patching the item's own `collections`
# array, which also makes the operation idempotent and reports honestly.
# POST /collections/K/items works too, and the earlier upload run did add all
# ten holdout items with it; four of them simply never appeared, because a
# trashed item keeps its membership and is still left out of every listing.
# An "added" message from that endpoint therefore does not mean the item is
# visible in the collection.
set_collections <- function(item, keys) {
  r <- PATCH(glue("{BASE}/items/{item$key}"), zh("If-Unmodified-Since-Version" = item$version),
             body = toJSON(list(collections = I(as.character(keys))), auto_unbox = TRUE),
             timeout(60))
  status_code(r) %in% c(200, 204)
}
coll_of <- function(item) {
  cs <- item$data$collections
  if (is.null(cs)) character(0) else as.character(unlist(cs))
}
add_to_collection <- function(item, coll) {
  cur <- coll_of(item)
  if (coll %in% cur) return(TRUE)
  set_collections(item, union(cur, coll))
}
drop_from_collection <- function(item, coll) {
  cur <- coll_of(item)
  if (!(coll %in% cur)) return(TRUE)
  set_collections(item, setdiff(cur, coll))
}

is_trashed <- function(item) {
  d <- item$data$deleted
  !is.null(d) && !identical(as.integer(d), 0L)
}

# The live twin of a trashed record: same exact title, and holding an
# attachment with the same filename. The filename test is what makes this
# safe; title alone matches several mid-term reviews of the same project.
live_twin <- function(parent, filename) {
  ti <- parent$data$title
  r <- GET(glue("{BASE}/items/top"),
           query = list(format = "json", q = substr(ti, 1, 60),
                        qmode = "titleCreatorYear", limit = 25), zhp(), timeout(60))
  if (status_code(r) != 200) return(NULL)
  js <- fromJSON(content(r, "text", encoding = "UTF-8"), simplifyVector = FALSE)
  cand <- Filter(function(it) identical(trimws(it$data$title), trimws(ti)), js)
  for (it in cand) {
    cr <- GET(glue("{BASE}/items/{it$key}/children"),
              query = list(format = "json", limit = 50), zhp(), timeout(60))
    if (status_code(cr) != 200) next
    cj <- fromJSON(content(cr, "text", encoding = "UTF-8"), simplifyVector = FALSE)
    fns <- tolower(unlist(lapply(cj, function(c) c$data$filename)))
    if (tolower(filename) %in% fns) return(it)
  }
  NULL
}

n_unmatched <- 0; n_promoted <- 0
for (i in seq_len(nrow(hold))) {
  b <- basename(hold$pdf[i]); code <- hold$project_code[i]
  pkey <- att_parent[[tolower(b)]]
  if (is.null(pkey)) {
    cli_alert_warning("[{code}] no attachment in the collection for {substr(b,1,42)}")
    n_unmatched <- n_unmatched + 1
    next
  }
  if (is.null(top_by_key[[pkey]])) {
    parent <- get_item(pkey)
    if (is.null(parent)) {
      cli_alert_warning("[{code}] parent {pkey} not readable")
      n_unmatched <- n_unmatched + 1
      next
    }
    if (!is_trashed(parent)) {
      cli_alert_warning("[{code}] parent {pkey} is live but outside the collection; left alone")
      n_unmatched <- n_unmatched + 1
      next
    }
    twin <- live_twin(parent, b)
    if (is.null(twin)) {
      cli_alert_danger("[{code}] parent {pkey} is in the trash and has no live twin holding {substr(b,1,34)}")
      n_unmatched <- n_unmatched + 1
      next
    }
    if (DRY) {
      cli_alert_info("would point [{code}] at the live record {twin$key}, and clear the trashed {pkey}")
    } else {
      if (!add_to_collection(twin, holdout_key)) {
        cli_alert_danger("[{code}] could not add {twin$key} to the collection")
        n_unmatched <- n_unmatched + 1
        next
      }
      # Take the trashed copy out of the collection and off the code, so a
      # later restore cannot produce two records claiming the same code.
      parent <- get_item(pkey) %||% parent
      set_collections(parent, setdiff(coll_of(parent), holdout_key))
      parent <- get_item(pkey) %||% parent
      patch_item(parent$key, parent$version, list(archiveLocation = ""))
      # Adding to a collection bumps the version, so re-read before the PATCH
      # below, which would otherwise get a 412.
      twin <- get_item(twin$key) %||% twin
      cli_alert_success("[{code}] -> live record {twin$key}; trashed {pkey} cleared")
    }
    top_by_key[[twin$key]] <- twin
    pkey <- twin$key
    n_promoted <- n_promoted + 1
  }
  it <- top_by_key[[pkey]]
  prev <- wanted[[pkey]]
  if (!is.null(prev) && !identical(prev$code, code)) {
    # one item carrying two codes would make the column a lie; report it.
    cli_alert_danger("item {pkey} matches both {prev$code} and {code}; left alone")
    wanted[[pkey]] <- NULL
    next
  }
  wanted[[pkey]] <- list(code = code, set = "holdout", title = it$data$title,
                         version = it$version, have = it$data$archiveLocation,
                         tags = it$data$tags)
}
cli_alert_info("holdout: {nrow(hold)} in the manifest, {n_promoted} parent records added to the collection, {n_unmatched} unmatched")

## ---- write ------------------------------------------------------------------
n_set <- 0; n_ok <- 0; n_fail <- 0
for (key in names(wanted)) {
  w <- wanted[[key]]
  have <- if (is.null(w$have)) "" else as.character(w$have)
  tagv <- if (length(w$tags)) vapply(w$tags, function(t) as.character(t$tag), character(1)) else character(0)
  want_tags <- c(paste0("pilot:", w$code), paste0("pilot:", w$set))
  add_tags <- setdiff(want_tags, tagv)
  if (identical(have, w$code) && length(add_tags) == 0) { n_ok <- n_ok + 1; next }

  fields <- list(archiveLocation = w$code)
  if (length(add_tags)) {
    keep <- lapply(tagv, function(t) list(tag = t))
    fields$tags <- c(keep, lapply(add_tags, function(t) list(tag = t)))
  }
  note <- if (length(add_tags)) paste0("  +tags: ", paste(add_tags, collapse = ", ")) else ""
  if (DRY) {
    cli_alert_info("would set [{w$code}] {substr(w$title,1,48)}{note}")
    n_set <- n_set + 1
    next
  }
  if (isTRUE(patch_item(key, w$version, fields))) {
    cli_alert_success("[{w$code}] {substr(w$title,1,52)}")
    n_set <- n_set + 1
  } else n_fail <- n_fail + 1
}
dry_note <- if (DRY) " (dry run, nothing written)" else ""
cli_h2("set {n_set}, already correct {n_ok}, failed {n_fail}{dry_note}")
cli_alert_info('In Zotero: right-click the column headings and tick "Loc. in Archive".')
