# zotero_adopt_pulled.R - give the files teammates dropped into Zotero a
# proper record.
#
# zotero_pull.R downloaded each bare attachment (a file with no record behind
# it) into the source's to_screen folder and wrote review/zotero_pulled.csv
# (zotero_key, filename). Once such a file has been censused and screened,
# the sync creates a record for it, tagged <src>doc:file:<filename>. This
# step then re-parents the bare attachment under that record, so the
# collection shows one titled row instead of a blank one, and nothing is
# deleted. Attachments whose bytes were already in the corpus (status
# in_corpus in the register) go under the record of that corpus file.
# Zotero copies a re-parented attachment's collection onto the parent, so
# this runs BEFORE the sync's collection patch, which puts it right. A pulled file that dedup moved to 03_Documents/duplicates is
# attached to the KEPT copy's record instead (duplicates_register / the dedup
# report say which). Sourced by zotero_upload.R after items exist.

adopt_pulled <- function(existing) {
  reg_p <- file.path(GL, "04_Screening", "inputs", "reports", "zotero_pulled.csv")
  if (!file.exists(reg_p)) return(invisible(0))
  reg <- read.csv(reg_p, stringsAsFactors = FALSE, colClasses = "character")
  reg <- reg[reg$status %in% c("pulled", "in_corpus"), ]   # in_corpus: bytes already in the corpus, filename = that corpus file
  if (!nrow(reg)) return(invisible(0))

  # a dropped duplicate points at the kept copy
  dup_p <- file.path(GL, "04_Screening", "inputs", "decisions", "duplicates.csv")
  kept_of <- character(0)
  if (file.exists(dup_p)) {
    d <- read.csv(dup_p, stringsAsFactors = FALSE, colClasses = "character")
    kept_of <- setNames(d$keep_file, d$drop_file)
  }
  pfx <- c(Worldbank = "wbdoc", gef = "gefdoc", gcf = "gcfdoc", afdb = "afdbdoc", af = "afdoc", cif = "cifdoc")

  # our items by doc tag
  tag_of <- existing$doctag
  key_by_tag <- setNames(existing$key, tag_of)
  patches <- list(); log <- list()
  for (i in seq_len(nrow(reg))) {
    target <- if (!is.na(kept_of[reg$filename[i]])) unname(kept_of[reg$filename[i]]) else reg$filename[i]
    tag <- paste0(pfx[[reg$source[i]]], ":file:", target)
    parent <- unname(key_by_tag[tag])
    if (is.na(parent)) {                    # the kept copy may be a catalogue document with an id tag
      cand <- existing$key[!is.na(existing$doctag) & grepl(paste0(pfx[[reg$source[i]]], ":"), existing$doctag, fixed = TRUE) &
                           grepl(tools::file_path_sans_ext(target), paste(existing$title, existing$extra), fixed = TRUE)]
      parent <- if (length(cand)) cand[1] else NA_character_
    }
    if (is.na(parent)) {
      log[[length(log) + 1]] <- tibble(zotero_key = reg$zotero_key[i], filename = reg$filename[i], action = "no record yet (not screened or not synced)")
      next
    }
    # the attachment's current version is needed for the PATCH
    it <- tryCatch(fromJSON(content(GET(glue("{ZOTERO_BASE}/items/{reg$zotero_key[i]}"), zotero_headers_plain()),
                                    as = "text", encoding = "UTF-8"), simplifyVector = FALSE), error = function(e) NULL)
    if (is.null(it) || !is.null(it$data$parentItem)) {
      log[[length(log) + 1]] <- tibble(zotero_key = reg$zotero_key[i], filename = reg$filename[i],
                                       action = if (is.null(it)) "attachment not found" else "already has a parent"); next
    }
    patches[[length(patches) + 1]] <- list(key = reg$zotero_key[i], version = it$version,
                                           parentItem = parent, collections = list())
    log[[length(log) + 1]] <- tibble(zotero_key = reg$zotero_key[i], filename = reg$filename[i],
                                     action = paste("attached to", parent, if (target != reg$filename[i]) "(kept copy)" else ""))
  }
  cli_h2("Pulled files: {nrow(reg)} in the register, {length(patches)} bare attachments to place under their record")
  if (length(patches)) {
    for (b in split(patches, ceiling(seq_along(patches) / BATCH_SIZE))) {
      res <- post_batch(unname(b))
      if (length(res$failed) > 0) for (f in res$failed) cli_alert_danger("  adopt failed: {f$message}")
      Sys.sleep(1)
    }
    cli_alert_success("placed {length(patches)} attachments")
  }
  if (length(log)) {
    lp <- file.path(GL, "04_Screening", "inputs", "reports", "zotero_adopt_pulled_log.csv")
    readr::write_csv(bind_rows(log), lp); cli_alert_info("log: {lp}")
  }
  invisible(length(patches))
}
