# zotero_from_screening.R - the screening decides what is in Zotero and with
# which status; the source catalogues supply the metadata.
#
# Input: 04_Screening/scope_screen.csv (one judged document per row; verdict_ruled
# when screen_rules.R has run) and review/family_census.csv (family and the
# identifiers read from the cover). The six source builders in
# zotero_upload.R still run, but as a POOL of metadata keyed by filename:
# title as scraped, web URL, report number, Call Number (project identifier),
# source tags and, above all, the doc tag that makes the sync idempotent
# (wbdoc:<id>, gefdoc:<file>, afdbdoc:<id>, gcfdoc:<file>, afdoc:<id>,
# cifdoc:<id>). For each judged document:
#   - its pool entry, if any, keeps its doc tag and metadata; the status
#     becomes included / to screen / screened out from the verdict; Call
#     Number is filled from the census when the catalogue left it empty;
#     tags family:<id> and screen:<verdict> are added.
#   - a parked file no catalogue knows (World Bank pre_2015, GEF undated...)
#     gets an item of its own, tagged <src>doc:file:<filename>, with title
#     and year from the screener and Call Number from the census.
# Documents the screener has not judged keep their pool entry unchanged.
# Sourced by zotero_upload.R; uses its mk_item(), DATA, GL.

build_from_screening <- function(pool) {
  scr <- file.path(GL, "04_Screening", "scope_screen.csv")
  if (!file.exists(scr)) { cli_alert_warning("no scope_screen.csv: statuses stay as the builders set them"); return(pool) }
  sv <- read.csv(scr, stringsAsFactors = FALSE, colClasses = "character", encoding = "UTF-8")
  sv[is.na(sv)] <- ""
  v <- if ("verdict_ruled" %in% names(sv)) sv$verdict_ruled else sv$verdict
  status_of <- c("in scope" = "included", "unsure" = "to screen", "out of scope" = "screened out")

  cen_p <- file.path(GL, "04_Screening", "inputs", "decisions", "family_census.csv")
  cen <- NULL
  if (file.exists(cen_p)) {
    cen <- read.csv(cen_p, stringsAsFactors = FALSE, colClasses = "character", encoding = "UTF-8")
    cen[is.na(cen)] <- ""
    rownames(cen) <- paste(cen$source, cen$filename)
  }
  inst      <- c(worldbank = "World Bank", gef = "Global Environment Facility", gcf = "Green Climate Fund",
                 afdb = "African Development Bank", af = "Adaptation Fund", cif = "Climate Investment Funds")
  src_label <- c(worldbank = "World Bank", gef = "GEF", gcf = "GCF", afdb = "AfDB", af = "Adaptation Fund", cif = "CIF")
  pfx       <- c(worldbank = "wbdoc", gef = "gefdoc", gcf = "gcfdoc", afdb = "afdbdoc", af = "afdoc", cif = "cifdoc")

  # the pool, keyed by source label and filename
  pkey <- vapply(pool, function(x) if (is.na(x$file)) "" else paste(x$source, basename(x$file)), character(1))
  pix  <- setNames(seq_along(pool), pkey)
  used <- logical(length(pool))

  first_id <- function(c1) {
    if (is.null(c1)) return("")
    ids <- c(c1$wb_project, c1$afdb_code, c1$gef_id, c1$gcf_fp, c1$af_id)
    ids <- ids[nzchar(ids)]
    if (length(ids)) sub(";.*$", "", ids[1]) else ""
  }

  out <- list(); n_pool <- 0; n_new <- 0; n_status <- 0
  for (i in seq_len(nrow(sv))) {
    s <- sv$source[i]; f <- sv$filename[i]
    if (!s %in% names(src_label) || !v[i] %in% names(status_of)) next
    ck <- paste(s, f)
    c1 <- if (!is.null(cen) && ck %in% rownames(cen)) cen[ck, ] else NULL
    pid <- first_id(c1)
    fam <- if (nzchar(sv$family[i])) sv$family[i] else if (!is.null(c1)) c1$family else ""
    screen_tags <- c(if (nzchar(fam)) paste0("family:", fam), paste0("screen:", v[i]))
    reason <- substr(gsub("\\s+", " ", sv$reason[i]), 1, 300)
    k <- paste(src_label[[s]], f)
    if (!is.na(pix[k])) {
      x <- pool[[pix[k]]]; used[pix[k]] <- TRUE
      if (!identical(x$status, unname(status_of[v[i]]))) n_status <- n_status + 1
      x$status <- unname(status_of[v[i]])
      if (!nzchar(coalesce(x$item$callNumber, "")) && nzchar(pid)) x$item$callNumber <- pid
      old_tags <- vapply(x$item$tags, function(t) t$tag, character(1))
      x$item$tags <- lapply(unique(c(old_tags, screen_tags)), function(t) list(tag = t))
      x$item$extra <- paste(c(x$item$extra, paste0("screen: ", v[i], " (", fam, "): ", reason)), collapse = " | ")
      n_pool <- n_pool + 1
    } else {
      path <- file.path(DATA, sv$folder[i], f)
      kind <- str_squish(sv$doc_kind_stated[i])
      title <- if (nzchar(sv$project_name[i]))
        paste0(str_squish(sv$project_name[i]), if (nzchar(kind)) paste0(" — ", kind) else "")
      else str_squish(str_replace_all(tools::file_path_sans_ext(f), "_", " "))
      x <- list(
        doctag = paste0(pfx[[s]], ":file:", f), source = src_label[[s]],
        status = unname(status_of[v[i]]),
        file = if (file.exists(path)) path else NA_character_,
        item = mk_item(
          title = title, institution = inst[[s]], date = sv$publication_year[i], url = "",
          report_type = kind,
          report_number = if (!is.null(c1)) sub(";.*$", "", c1$wb_report) else "",
          call_number = pid,
          extra = paste0("file: ", f, " | screen: ", v[i], " (", fam, "): ", reason),
          tags = c(s, paste0(pfx[[s]], ":file:", f), screen_tags)))
      n_new <- n_new + 1
    }
    out[[length(out) + 1]] <- x
  }
  cli_alert_info("screening join: {n_pool} catalogue documents take their status from the verdict ({n_status} change), {n_new} parked files get an item of their own, {sum(!used)} unjudged documents keep their builder status")
  c(out, pool[!used])
}
