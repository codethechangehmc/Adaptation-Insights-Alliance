# zotero_duplicates.R - the aliases the dedup step moved out of the source
# folders (03_Documents/duplicates, see R/02_dedup/dedup_corpus.R) get their
# own status collection in Zotero, {Institution}/duplicates, so the library
# stops counting them as included.
#
# Matching is in two steps. The attachment MD5 finds every library item that
# carries the file's bytes. But a re-hosted document is often byte-identical
# to the copy we KEPT (a World Bank ICR in the GEF folder is the same PDF as
# the one in the World Bank folder), so the item's own doc tag must also point
# at the moved file: gefdoc:<filename>, afdoc:<...project id...>,
# afdbdoc:<title slug in the filename>, wbdoc:<document id in the filename>.
# An item whose tag points elsewhere is the kept copy and is left alone.
#
# Also repairs: any item tagged "duplicate" that is no longer an alias loses
# those tags here; its collections are restored by the reconciliation step
# in zotero_upload.R, which reads the catalogue.
#
# Sourced by zotero_upload.R; needs its helpers (fetch_attachments,
# post_batch, BATCH_SIZE, DATA, GL), the `existing` items table and the
# collection keymap from main(). Returns the keys it moved, so the status
# reconciliation skips them.

mark_duplicates <- function(existing, keymap) {
  dup_dir <- file.path(DATA, "duplicates")
  files <- list.files(dup_dir, pattern = "\\.(pdf|PDF|docx?|xlsx?)$", full.names = TRUE)
  files <- files[basename(files) != "duplicates_register.xlsx"]   # the register, not a document
  ours <- unlist(keymap)
  inst   <- c(worldbank = "World Bank", gef = "GEF", gcf = "GCF", afdb = "AfDB",
              af = "Adaptation Fund", cif = "CIF")
  tagpfx <- c(worldbank = "wbdoc:", gef = "gefdoc:", gcf = "gcfdoc:", afdb = "afdbdoc:",
              af = "afdoc:", cif = "cifdoc:")

  # which copy was kept, from the dedup report, for the duplicate-of tag
  reg <- file.path(GL, "04_Screening", "inputs", "decisions", "duplicates.csv")
  kept_of <- if (file.exists(reg)) {
    a <- read.csv(reg, stringsAsFactors = FALSE, colClasses = "character")
    setNames(paste0(a$keep_source, "/", a$keep_file), paste0(a$drop_source, "__", a$drop_file))
  } else character(0)

  item_tags <- function(e) {
    t <- strsplit(coalesce(e$all_tags, ""), "|", fixed = TRUE)[[1]]; t[nzchar(t)]
  }
  norm <- function(x) gsub("[^a-z0-9]", "", tolower(x))
  # does this item's doc tag point at the moved file (and not at a twin)?
  points_at <- function(e, pfx, fname) {
    tg <- item_tags(e)
    dt <- tg[startsWith(tg, tagpfx[[pfx]])]
    if (!length(dt)) return(FALSE)
    id <- norm(sub("^[a-z]+doc:", "", dt[1])); nf <- norm(fname)
    if (!nzchar(id)) return(FALSE)
    if (grepl(id, nf, fixed = TRUE) || grepl(nf, id, fixed = TRUE)) return(TRUE)
    # the scrapers cap long filenames, so a title-slug tag (afdbdoc) may be
    # longer than the filename it belongs to: a long shared prefix is enough
    core <- norm(sub("_[0-9]{4}\\.[A-Za-z]+$", "", sub("^[a-z]+_(pcr|eval|pper)_", "", fname, ignore.case = TRUE)))
    n <- min(nchar(core), nchar(id))
    if (n >= 30 && substr(core, 1, n) == substr(id, 1, n)) return(TRUE)
    if (n >= 30 && grepl(substr(core, 1, 30), id, fixed = TRUE)) return(TRUE)
    if (pfx == "af") {                       # afdoc carries the CPR id, which holds the project id
      pid <- norm(sub("^af_([^_]+)_.*$", "\\1", fname))
      return(nzchar(pid) && grepl(pid, id, fixed = TRUE))
    }
    FALSE
  }

  atts <- fetch_attachments()                      # parent key + md5 per attachment
  patches <- list(); log <- list(); keys <- character(0)
  for (f in files) {
    b     <- basename(f)
    pfx   <- sub("__.*$", "", b)
    fname <- sub("^[a-z]+__", "", b)
    src   <- unname(inst[pfx])
    if (is.na(src)) {
      log[[length(log) + 1]] <- tibble(file = b, zotero_key = "", action = "unknown source prefix"); next
    }
    md5 <- unname(tools::md5sum(f))
    parents <- unique(atts$parent[atts$md5 == md5])
    parents <- parents[parents %in% existing$key]
    if (!length(parents)) {
      log[[length(log) + 1]] <- tibble(file = b, zotero_key = "", action = "no library item carries this file"); next
    }
    own <- Filter(function(k) points_at(existing[existing$key == k, ][1, ], pfx, fname), parents)
    if (!length(own)) {
      log[[length(log) + 1]] <- tibble(file = b, zotero_key = paste(parents, collapse = ";"),
        action = "same bytes in the library only under the kept copy; left alone"); next
    }
    want <- keymap[[paste(src, "duplicates", sep = "|")]]
    for (k in own) {
      e <- existing[existing$key == k, ][1, ]
      curr <- strsplit(coalesce(e$collections, ""), ",")[[1]]; curr <- curr[nzchar(curr)]
      old_tags <- item_tags(e)
      old_tags <- old_tags[!(old_tags == "duplicate" | startsWith(old_tags, "duplicate-of:"))]
      new_tags <- unique(c(old_tags, "duplicate",
                           if (!is.na(kept_of[b])) paste0("duplicate-of:", kept_of[b])))
      patches[[length(patches) + 1]] <- list(
        key = e$key, version = e$version,
        collections = as.list(unique(c(setdiff(curr, ours), want))),
        tags = lapply(new_tags, function(t) list(tag = t)))
      keys <- c(keys, k)
      log[[length(log) + 1]] <- tibble(file = b, zotero_key = k,
                                       action = paste("moved to", src, "/ duplicates"))
    }
  }

  # repair: an item tagged duplicate that is not an alias any more (or never
  # was) loses the tags; the reconciliation step restores its collection
  tagged <- existing[grepl("duplicate", coalesce(existing$all_tags, ""), fixed = TRUE), ]
  n_rep <- 0
  for (i in seq_len(nrow(tagged))) {
    e <- tagged[i, ]
    if (e$key %in% keys) next
    tg <- item_tags(e)
    keep <- tg[!(tg == "duplicate" | startsWith(tg, "duplicate-of:"))]
    if (length(keep) == length(tg)) next
    patches[[length(patches) + 1]] <- list(key = e$key, version = e$version,
                                           tags = lapply(keep, function(t) list(tag = t)))
    n_rep <- n_rep + 1
    log[[length(log) + 1]] <- tibble(file = "", zotero_key = e$key,
                                     action = "kept copy: duplicate tags removed, collection restored by reconciliation")
  }

  cli_h2("Duplicates: {length(files)} files in 03_Documents/duplicates, {length(keys)} library items to move, {n_rep} kept copies to repair")
  if (length(patches)) {
    for (bt in split(patches, ceiling(seq_along(patches) / BATCH_SIZE))) {
      res <- post_batch(unname(bt))
      if (length(res$failed) > 0)
        for (fl in res$failed) cli_alert_danger("  duplicate patch failed: {fl$message}")
      Sys.sleep(1)
    }
    cli_alert_success("patched {length(patches)} items")
  }
  if (length(log)) {
    lp <- file.path(GL, "04_Screening", "inputs", "reports", "zotero_duplicates_log.csv")
    readr::write_csv(bind_rows(log), lp)
    cli_alert_info("log: {lp}")
  }
  keys
}
