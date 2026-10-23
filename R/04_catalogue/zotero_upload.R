##############################################################################
# zotero_upload.R — Sync the corpus catalogue to the shared Zotero library
#
# One Zotero "report" item per corpus document, organised in collections
#   {Institution} / included | to screen | screened out | duplicates
# Since 18 Sep 2026 the SCREENING decides membership and status: every
# document judged in 04_Screening/scope_screen.csv is an item, with status from
# its verdict (in scope -> included, unsure -> to screen, out of scope ->
# screened out). The six source builders below supply the metadata (title,
# URL, report number, Call Number, doc tags) as a pool that
# zotero_from_screening.R joins on filename; unjudged documents keep the
# builders' folder-based status.
# Identifier fields:
#   Report Number = the document's own number (WB repnb, e.g. ICR4348) —
#                   only where the source provides one
#   Call Number   = the PROJECT identifier (WB P-code, GEF project ID,
#                   AfDB project code, GCF code) — Zotero has no dedicated
#                   project-number field; Call Number is the sortable stand-in
# File attachments: the actual documents are uploaded from the OneDrive
# corpus into Zotero storage (group has unlimited storage) via the 3-step
# file-upload API; idempotent (items that already have an attachment are
# skipped).
#
# Idempotency reads doc tags (wbdoc:/gefdoc:/afdbdoc:/gcfdoc:) from the
# items listing — NOT the /tags endpoint, whose search index lags uploads.
#
# Credentials from ~/.Renviron: ZOTERO_API_KEY / ZOTERO_LIBRARY_ID /
# ZOTERO_LIBRARY_TYPE. Usage: Rscript R/zotero_upload.R
##############################################################################

suppressPackageStartupMessages({
  library(httr)
  library(jsonlite)
  library(dplyr)
  library(cli)
  library(glue)
  library(readr)
  library(stringr)
})

# credentials live in the OneDrive-redirected Documents/.Renviron; a shell
# whose HOME points elsewhere (Git Bash) would miss them, so look there too
if (!nzchar(Sys.getenv("ZOTERO_API_KEY")))
  for (.p in c(file.path(Sys.getenv("OneDrive"), "Documents", ".Renviron"),
               file.path(Sys.getenv("USERPROFILE"), "Documents", ".Renviron"),
               file.path(Sys.getenv("USERPROFILE"), ".Renviron")))
    if (file.exists(.p)) { readRenviron(.p); break }
API_KEY      <- Sys.getenv("ZOTERO_API_KEY")
LIBRARY_ID   <- Sys.getenv("ZOTERO_LIBRARY_ID")
LIBRARY_TYPE <- Sys.getenv("ZOTERO_LIBRARY_TYPE", "groups")
stopifnot(nzchar(API_KEY), nzchar(LIBRARY_ID))

ZOTERO_BASE <- glue("https://api.zotero.org/{LIBRARY_TYPE}/{LIBRARY_ID}")
BATCH_SIZE  <- 50
ATTACH_FILES <- TRUE

GL   <- "C:/Users/mlolita/OneDrive - CGIAR/WP2_Evidence Synthesis/Grey Literature"
DATA <- file.path(GL, "03_Documents")

SOURCES  <- c("World Bank", "GEF", "GCF", "AfDB", "Adaptation Fund", "CIF")
STATUSES <- c("included", "to screen", "screened out", "duplicates")
# duplicates: aliases the dedup step moved to 03_Documents/duplicates (zotero_duplicates.R)
.self <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
.self_dir <- if (length(.self)) dirname(sub("^--file=", "", .self[1])) else file.path("R", "04_catalogue")
source(file.path(.self_dir, "zotero_duplicates.R"))
source(file.path(.self_dir, "zotero_from_screening.R"))
source(file.path(.self_dir, "zotero_adopt_pulled.R"))

zotero_headers <- function() {
  add_headers("Zotero-API-Key" = API_KEY, "Zotero-API-Version" = "3",
              "Content-Type" = "application/json")
}
zotero_headers_plain <- function() {
  add_headers("Zotero-API-Key" = API_KEY, "Zotero-API-Version" = "3")
}

CONTENT_TYPES <- c(pdf = "application/pdf",
  docx = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
  doc = "application/msword",
  xlsx = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
  xls = "application/vnd.ms-excel", zip = "application/zip")
guess_ct <- function(f) {
  ct <- CONTENT_TYPES[tolower(tools::file_ext(f))]
  ifelse(is.na(ct), "application/octet-stream", ct)
}

# ── Collections ─────────────────────────────────────────────────────────────
ensure_collections <- function() {
  cli_h2("Ensuring collection structure")
  cols <- list(); start <- 0
  repeat {
    resp <- GET(glue("{ZOTERO_BASE}/collections?limit=100&start={start}"),
                zotero_headers())
    stop_for_status(resp)
    js <- fromJSON(content(resp, "text", encoding = "UTF-8"),
                   simplifyVector = FALSE)
    if (length(js) == 0) break
    cols <- c(cols, js)
    total <- suppressWarnings(as.numeric(headers(resp)[["total-results"]]))
    start <- start + 100
    if (is.na(total) || start >= total) break
  }
  existing <- bind_rows(lapply(cols, function(cc) {
    tibble(key = cc$key, name = cc$data$name,
           parent = ifelse(isFALSE(cc$data$parentCollection), "",
                           as.character(cc$data$parentCollection)))
  }))
  if (nrow(existing) == 0) existing <- tibble(key = character(),
                                              name = character(),
                                              parent = character())
  create <- function(name, parent = "") {
    payload <- list(list(name = name))
    if (nzchar(parent)) payload[[1]]$parentCollection <- parent
    resp <- POST(glue("{ZOTERO_BASE}/collections"), zotero_headers(),
                 body = toJSON(payload, auto_unbox = TRUE))
    stop_for_status(resp)
    fromJSON(content(resp, "text", encoding = "UTF-8"),
             simplifyVector = FALSE)$successful[["0"]]$key
  }
  keymap <- list()
  for (src in SOURCES) {
    top <- existing %>% filter(name == src, parent == "")
    top_key <- if (nrow(top) >= 1) top$key[1] else create(src)
    for (st in STATUSES) {
      sub <- existing %>% filter(name == st, parent == top_key)
      keymap[[paste(src, st, sep = "|")]] <-
        if (nrow(sub) >= 1) sub$key[1] else create(st, top_key)
    }
  }
  keymap
}

# ── Item constructor ────────────────────────────────────────────────────────
mk_item <- function(title, institution, date, url, report_type,
                    report_number, call_number, extra, tags, abstract = "") {
  list(
    itemType     = "report",
    title        = title,
    creators     = list(list(creatorType = "author", name = institution)),
    reportType   = coalesce(report_type, ""),
    reportNumber = coalesce(report_number, ""),
    callNumber   = coalesce(call_number, ""),
    institution  = institution,
    date         = coalesce(as.character(date), ""),
    url          = coalesce(url, ""),
    abstractNote = coalesce(abstract, ""),
    extra        = extra,
    tags         = lapply(unique(tags[nzchar(tags)]), function(t) list(tag = t))
  )
}

split_countries <- function(x) trimws(strsplit(coalesce(x, ""), "[;,]")[[1]])

# Each builder returns entries: list(doctag, source, status, item, file)
# where file = absolute path of the document on disk (NA if none).

# ── World Bank ──────────────────────────────────────────────────────────────
wb_file_index <- function() {
  dirs <- file.path(DATA, "Worldbank/Docs", c("2015_2026", "to_screen", "screened_out"))
  files <- unlist(lapply(dirs, list.files, full.names = TRUE))
  ix_key <- list(); ix_id <- list()
  for (f in files) {
    b <- basename(f)
    p <- paste(sort(unlist(str_extract_all(b, "P\\d{6}"))), collapse = "+")
    y <- str_match(b, "_(\\d{4})\\.pdf$")[, 2]
    if (!is.na(y)) ix_key[[paste0(p, "|", y)]] <- f
    m <- str_match(b, "_(\\d{8})(_ICR)?_\\d{4}\\.pdf$")[, 2]
    if (!is.na(m)) ix_id[[m]] <- f
  }
  list(key = ix_key, id = ix_id)
}

build_worldbank <- function() {
  meta <- read_csv(file.path(DATA, "Worldbank/List/worldbank_metadata.csv"),
                   show_col_types = FALSE, col_types = cols(.default = "c"))
  cat_df <- read_csv(file.path(DATA, "Worldbank/List/wb_new_method_catalogue.csv"),
                     show_col_types = FALSE, col_types = cols(.default = "c")) %>%
    left_join(meta %>% select(id, abstract), by = "id")
  if (!"report_no" %in% names(cat_df)) cat_df$report_no <- NA_character_
  fix <- wb_file_index()

  find_file <- function(id, project_id, doc_date) {
    f <- fix$id[[as.character(id)]]
    if (!is.null(f)) return(f)
    p <- paste(sort(unlist(str_extract_all(coalesce(project_id, ""), "P\\d{6}"))),
               collapse = "+")
    f <- fix$key[[paste0(p, "|", substr(coalesce(doc_date, ""), 1, 4))]]
    if (!is.null(f)) f else NA_character_
  }

  rows <- bind_rows(
    cat_df %>% filter(screen_status == "in_scope") %>% mutate(.status = "included"),
    cat_df %>% filter(screen_status == "to_screen", already_have == "TRUE") %>%
      mutate(.status = "to screen")
  )
  wb_one <- function(r, status, file) {
    pcodes <- paste(unlist(str_extract_all(coalesce(r$project_id, ""), "P\\d{6}")),
                    collapse = " / ")
    list(
      doctag = paste0("wbdoc:", r$id), source = "World Bank", status = status,
      file = file,
      item = mk_item(
        title = str_squish(r$title), institution = "World Bank",
        date = substr(coalesce(r$doc_date, ""), 1, 10), url = r$web_url,
        report_type = r$doc_type,
        report_number = ifelse(coalesce(r$report_no, "NA") %in% c("NA", ""), "", r$report_no),
        call_number = pcodes,
        extra = glue("Project(s): {pcodes} | Topics: {coalesce(r$topics,'')} | PDF: {coalesce(r$pdf_url,'')}"),
        abstract = ifelse(coalesce(r$abstract, "NA") == "NA", "",
                          str_squish(coalesce(r$abstract, ""))),
        tags = c("worldbank", split_countries(r$country), paste0("wbdoc:", r$id))
      )
    )
  }
  out <- lapply(seq_len(nrow(rows)), function(i)
    wb_one(rows[i, ], rows$.status[i],
           find_file(rows$id[i], rows$project_id[i], rows$doc_date[i])))

  # screened_out folder → match back to old metadata
  so_files <- list.files(file.path(DATA, "Worldbank/Docs/screened_out"),
                         full.names = TRUE)
  meta_ix <- meta %>%
    mutate(pkey = vapply(project_id, function(p)
             paste(sort(unlist(str_extract_all(coalesce(p, ""), "P\\d{6}"))),
                   collapse = "+"), character(1)),
           yr = substr(doc_date, 1, 4))
  for (fp in so_files) {
    f <- basename(fp)
    pcodes <- sort(unlist(str_extract_all(f, "P\\d{6}")))
    yr <- str_match(f, "_(\\d{4})\\.pdf$")[, 2]
    m <- meta_ix %>% filter(pkey == paste(pcodes, collapse = "+"), yr == !!yr)
    if (nrow(m) >= 1) {
      r <- m[1, ]
      r$report_no <- NA_character_; r$topics <- ""
      out[[length(out) + 1]] <- wb_one(r, "screened out", fp)
    } else {
      out[[length(out) + 1]] <- list(
        doctag = paste0("wbdoc:file:", f), source = "World Bank",
        status = "screened out", file = fp,
        item = mk_item(
          title = str_squish(str_replace_all(tools::file_path_sans_ext(f), "_", " ")),
          institution = "World Bank", date = yr, url = "",
          report_type = "Implementation Completion and Results Report",
          report_number = "", call_number = paste(pcodes, collapse = " / "),
          extra = glue("file: {f}"),
          tags = c("worldbank", paste0("wbdoc:file:", f))
        )
      )
    }
  }
  out
}

# ── GEF ─────────────────────────────────────────────────────────────────────
build_gef <- function() {
  dates <- read_csv(file.path(DATA, "gef/List/gef_evaluation_dates.csv"),
                    show_col_types = FALSE, col_types = cols(.default = "c"))
  meta <- read_csv(file.path(DATA, "gef/List/gef_all_documents.csv"),
                   show_col_types = FALSE, col_types = cols(.default = "c"))
  proj <- meta %>% group_by(gef_id) %>% slice(1) %>% ungroup()

  folders <- list(
    `included`  = file.path(DATA, "gef/Docs/evaluation_docs/2015_2026"),
    `to screen` = file.path(DATA, "gef/Docs/evaluation_docs/undated")
  )
  out <- list()
  for (status in names(folders)) {
    fls <- list.files(folders[[status]], full.names = TRUE)
    rows <- dates %>% filter(file %in% basename(fls))
    paths <- setNames(fls, basename(fls))
    for (i in seq_len(nrow(rows))) {
      r <- rows[i, ]
      p <- proj %>% filter(gef_id == r$gef_id)
      dtype <- str_replace_all(str_remove(r$doc_type, "_\\d+$"), "_", " ")
      title <- if (nrow(p) == 1) paste0(str_squish(p$project_title), " — ", dtype)
               else paste0("GEF ", r$gef_id, " — ", dtype)
      drow <- meta %>% filter(gef_id == r$gef_id, doc_type == dtype) %>% slice(1)
      out[[length(out) + 1]] <- list(
        doctag = paste0("gefdoc:", r$file), source = "GEF", status = status,
        file = unname(paths[r$file]),
        item = mk_item(
          title = title, institution = "Global Environment Facility",
          date = coalesce(r$final_year, ""),
          url = if (nrow(p) == 1) p$project_url else "",
          report_type = dtype, report_number = "",
          call_number = paste0("GEF ", r$gef_id),
          extra = glue("GEF project ID: {r$gef_id} | year from: {r$method} | PDF: {if (nrow(drow) == 1) coalesce(drow$doc_url, '') else ''}"),
          tags = c("gef", if (nrow(p) == 1) split_countries(p$country),
                   paste0("gefdoc:", r$file))
        )
      )
    }
  }
  out
}

# ── AfDB ────────────────────────────────────────────────────────────────────
build_afdb <- function() {
  meta <- read_csv(file.path(DATA, "afdb/List/afdb_metadata.csv"),
                   show_col_types = FALSE, col_types = cols(.default = "c")) %>%
    mutate(.yr = suppressWarnings(as.integer(year)),
           .status = case_when(
             is.na(doc_type) | doc_type == "" ~ "to screen",
             is.na(.yr)                        ~ "to screen",
             .yr >= 2015 & .yr <= 2025         ~ "included",
             TRUE                              ~ "screened out"
           ))
  # disk lookup: reconstruct the EXACT filename the scraper generated
  # (same logic as afdb.R download_results, incl. the shared safe_filename)
  if (!exists("safe_filename")) {
    .here <- { fa <- grep("^--file=", commandArgs(FALSE), value = TRUE)
               if (length(fa)) dirname(sub("^--file=", "", fa[1]))
               else file.path(getwd(), "R", "04_catalogue") }
    source(file.path(.here, "..", "00_shared", "00_config.R"))
    source(file.path(.here, "..", "00_shared", "01_utils.R"))
  }
  dirs <- file.path(DATA, "afdb/Docs", c("2015_2026", "to_screen", "undated"))
  files <- unlist(lapply(dirs, list.files, full.names = TRUE))
  file_by_name <- setNames(files, basename(files))
  find_file <- function(r) {
    year_str <- ifelse(is.na(r$year) | !nzchar(coalesce(r$year, "")), "XXXX", r$year)
    # try both filename variants: code-based and title-based (project codes
    # recovered from PDFs after download mean the disk name may use either)
    cands <- c(
      if (!is.na(r$project_id) && nzchar(r$project_id)) r$project_id,
      safe_filename(substr(coalesce(r$project_name, r$title, "notitle"), 1, 60))
    )
    for (proj_str in cands) {
      fname <- paste0(substr(
        glue("afdb_{coalesce(r$doc_type, 'DOC')}_{proj_str}_{year_str}"),
        1, 100), ".pdf")
      f <- file_by_name[fname]
      if (!is.na(f)) return(unname(f))
    }
    NA_character_
  }

  # AfDB project code: use the metadata field, else parse P-XX-YYY-NNN out
  # of the title / PDF URL (codes are embedded in most PDF filenames)
  afdb_code <- function(r) {
    if (!is.na(r$project_id) && nzchar(r$project_id)) return(toupper(r$project_id))
    m <- str_extract(paste(coalesce(r$title, ""), coalesce(r$pdf_url, "")),
                     regex("P-[A-Za-z0-9]{2}-[A-Za-z0-9]{3}-\\d{3}",
                           ignore_case = TRUE))
    ifelse(is.na(m), "", toupper(m))
  }

  lapply(seq_len(nrow(meta)), function(i) {
    r <- meta[i, ]
    list(
      doctag = paste0("afdbdoc:", r$id), source = "AfDB", status = r$.status,
      file = find_file(r),
      item = mk_item(
        title = str_squish(r$title), institution = "African Development Bank",
        date = if (grepl("^\\d{4}-", coalesce(r$doc_date, ""))) substr(r$doc_date, 1, 10)
               else coalesce(r$year, ""),
        url = r$web_url, report_type = r$doc_type, report_number = "",
        call_number = afdb_code(r),
        extra = glue("Project code: {afdb_code(r)} | Listing: {coalesce(r$listing,'')} | PDF: {coalesce(r$pdf_url,'')}"),
        tags = c("afdb", split_countries(r$country), paste0("afdbdoc:", r$id))
      )
    )
  })
}

# ── GCF ─────────────────────────────────────────────────────────────────────
build_gcf <- function() {
  folders <- list(
    `included`     = file.path(DATA, "gcf/Docs/evaluation_docs"),
    `screened out` = file.path(DATA, "gcf/Docs/proposal_stage")
  )
  out <- list()
  for (status in names(folders)) {
    for (fp in list.files(folders[[status]], full.names = TRUE)) {
      f <- basename(fp)
      base <- tools::file_path_sans_ext(f)
      code <- str_match(base, "^gcf_([A-Z0-9]+)_")[, 2]
      dtype <- str_replace_all(str_remove(sub("^gcf_[A-Z0-9]+_", "", base), "_\\d+$"), "_", " ")
      out[[length(out) + 1]] <- list(
        doctag = paste0("gcfdoc:", f), source = "GCF", status = status,
        file = fp,
        item = mk_item(
          title = glue("GCF {code} — {dtype}"), institution = "Green Climate Fund",
          date = "", url = glue("https://www.greenclimate.fund/project/{tolower(code)}"),
          report_type = dtype, report_number = "", call_number = code,
          extra = glue("GCF project: {code} | file: {f}"),
          tags = c("gcf", paste0("gcfdoc:", f))
        )
      )
    }
  }
  out
}

# ── Adaptation Fund ─────────────────────────────────────────────────────────
build_af <- function() {
  meta_path <- file.path(DATA, "af/List/af_metadata.csv")
  if (!file.exists(meta_path)) return(list())
  meta <- read_csv(meta_path, show_col_types = FALSE,
                   col_types = cols(.default = "c")) %>%
    filter(status == "kept")
  docs_dir <- file.path(DATA, "af/Docs/evaluation_docs")
  files <- setNames(list.files(docs_dir, full.names = TRUE),
                    basename(list.files(docs_dir)))
  lapply(seq_len(nrow(meta)), function(i) {
    r <- meta[i, ]
    ext <- tolower(tools::file_ext(sub("\\?.*$", "", r$pdf_url)))
    if (!nzchar(ext) || nchar(ext) > 4) ext <- "pdf"
    cand <- c(
      glue("af_{r$project_id}_{safe_filename(r$doc_type)}_{coalesce(r$family_year,'XXXX')}.{ext}"),
      glue("af_{r$project_id}_{safe_filename(r$doc_type)}_XXXX.{ext}")
    )
    f <- NA_character_
    for (cn in cand) if (!is.na(files[cn])) { f <- unname(files[cn]); break }
    list(
      doctag = paste0("afdoc:", r$id), source = "Adaptation Fund",
      status = "included", file = f,
      item = mk_item(
        title = str_squish(r$title), institution = "Adaptation Fund",
        date = coalesce(r$family_year, ""), url = r$web_url,
        report_type = r$doc_type, report_number = "",
        call_number = coalesce(r$project_id, ""),
        extra = glue("AF project: {coalesce(r$project_id,'')} | CPR id: {r$id} | PDF: {coalesce(r$pdf_url,'')}"),
        tags = c("adaptation-fund", paste0("afdoc:", r$id))
      )
    )
  })
}

# ── CIF ─────────────────────────────────────────────────────────────────────
build_cif <- function() {
  meta_path <- file.path(DATA, "cif/List/cif_metadata.csv")
  if (!file.exists(meta_path)) return(list())
  meta <- read_csv(meta_path, show_col_types = FALSE,
                   col_types = cols(.default = "c")) %>%
    filter(status %in% c("kept", "kept_global"))
  docs_dir <- file.path(DATA, "cif/Docs/evaluation_docs")
  files <- setNames(list.files(docs_dir, full.names = TRUE),
                    basename(list.files(docs_dir)))
  lapply(seq_len(nrow(meta)), function(i) {
    r <- meta[i, ]
    cand <- unique(vapply(c(coalesce(r$doc_date, ""), "", "XXXX"), function(y)
      paste0(substr(glue("cif_{safe_filename(r$id)}_{y}"), 1, 100), ".pdf"),
      character(1)))
    f <- NA_character_
    for (cn in cand) if (!is.na(files[cn])) { f <- unname(files[cn]); break }
    list(
      doctag = paste0("cifdoc:", r$id), source = "CIF",
      status = "included", file = f,
      item = mk_item(
        title = str_squish(r$title), institution = "Climate Investment Funds",
        date = coalesce(r$doc_date, ""), url = r$web_url,
        report_type = r$doc_type, report_number = "",
        call_number = "",
        extra = glue("Scope: {r$status} | PDF: {coalesce(r$pdf_url,'')}"),
        tags = c("cif", r$status, paste0("cifdoc:", r$id))
      )
    )
  })
}

# ── Existing items ──────────────────────────────────────────────────────────
fetch_existing_items <- function() {
  cli_h2("Reading library items")
  rows <- list(); start <- 0
  repeat {
    resp <- GET(glue("{ZOTERO_BASE}/items?limit=100&start={start}&itemType=report"),
                zotero_headers())
    stop_for_status(resp)
    items <- fromJSON(content(resp, "text", encoding = "UTF-8"),
                      simplifyVector = FALSE)
    if (length(items) == 0) break
    for (it in items) {
      tags <- vapply(it$data$tags, function(t) t$tag, character(1))
      doc <- tags[grepl("^(wbdoc|gefdoc|afdbdoc|gcfdoc|afdoc|cifdoc):", tags)]
      rows[[length(rows) + 1]] <- tibble(
        key = it$key, version = it$version,
        doctag = if (length(doc)) doc[1] else NA_character_,
        report_number = coalesce(it$data$reportNumber, ""),
        call_number = coalesce(it$data$callNumber, ""),
        collections = paste(unlist(it$data$collections), collapse = ","),
        title = coalesce(it$data$title, ""),
        url = coalesce(it$data$url, ""),
        extra = coalesce(it$data$extra, ""),
        all_tags = paste(tags, collapse = "|")
      )
    }
    total <- suppressWarnings(as.numeric(headers(resp)[["total-results"]]))
    start <- start + 100
    if (is.na(total) || start >= total) break
  }
  if (length(rows) == 0) return(tibble())
  bind_rows(rows)
}

fetch_attachments <- function() {
  rows <- list(); start <- 0
  repeat {
    resp <- GET(glue("{ZOTERO_BASE}/items?limit=100&start={start}&itemType=attachment"),
                zotero_headers())
    stop_for_status(resp)
    items <- fromJSON(content(resp, "text", encoding = "UTF-8"),
                      simplifyVector = FALSE)
    if (length(items) == 0) break
    for (it in items) {
      rows[[length(rows) + 1]] <- tibble(
        parent = coalesce(it$data$parentItem, ""),
        md5 = coalesce(it$data$md5, "")
      )
    }
    total <- suppressWarnings(as.numeric(headers(resp)[["total-results"]]))
    start <- start + 100
    if (is.na(total) || start >= total) break
  }
  if (length(rows) == 0) return(tibble(parent = character(), md5 = character()))
  bind_rows(rows)
}
fetch_attachment_parents <- function() unique(fetch_attachments()$parent)

post_batch <- function(payload) {
  resp <- POST(glue("{ZOTERO_BASE}/items"), zotero_headers(),
               body = toJSON(payload, auto_unbox = TRUE))
  if (status_code(resp) == 429) {
    wait <- suppressWarnings(as.numeric(headers(resp)[["retry-after"]]))
    Sys.sleep(ifelse(is.na(wait), 30, wait))
    resp <- POST(glue("{ZOTERO_BASE}/items"), zotero_headers(),
                 body = toJSON(payload, auto_unbox = TRUE))
  }
  stop_for_status(resp)
  fromJSON(content(resp, "text", encoding = "UTF-8"), simplifyVector = FALSE)
}

# ── File upload (3-step Zotero storage flow) ────────────────────────────────
upload_file_to_item <- function(parent_key, filepath) {
  fname <- basename(filepath)
  ct <- guess_ct(fname)
  # 1. create the attachment item
  att <- list(list(itemType = "attachment", linkMode = "imported_file",
                   parentItem = parent_key, title = fname,
                   contentType = ct, filename = fname))
  res <- post_batch(att)
  if (length(res$successful) == 0) {
    if (length(res$failed) > 0)
      cli_alert_danger("  attachment rejected for {fname}: {res$failed[[1]]$message}")
    return(FALSE)
  }
  akey <- res$successful[["0"]]$key
  # 2. authorise upload
  md5 <- unname(tools::md5sum(filepath))
  auth <- POST(glue("{ZOTERO_BASE}/items/{akey}/file"),
               zotero_headers_plain(),
               add_headers("If-None-Match" = "*"),
               body = list(md5 = md5, filename = fname,
                           filesize = file.size(filepath),
                           mtime = round(as.numeric(file.mtime(filepath)) * 1000)),
               encode = "form")
  if (status_code(auth) == 413) { cli_alert_danger("quota exceeded"); return("quota") }
  stop_for_status(auth)
  aj <- fromJSON(content(auth, "text", encoding = "UTF-8"), simplifyVector = FALSE)
  if (isTRUE(aj$exists == 1)) return(TRUE)
  # 3. upload bytes then register
  body_raw <- c(charToRaw(aj$prefix),
                readBin(filepath, "raw", n = file.size(filepath)),
                charToRaw(aj$suffix))
  up <- POST(aj$url, body = body_raw,
             add_headers("Content-Type" = aj$contentType))
  stop_for_status(up)
  reg <- POST(glue("{ZOTERO_BASE}/items/{akey}/file"),
              zotero_headers_plain(),
              add_headers("If-None-Match" = "*"),
              body = list(upload = aj$uploadKey), encode = "form")
  status_code(reg) %in% c(200, 204)
}

# ── Main ────────────────────────────────────────────────────────────────────
main <- function() {
  cli_h1("Zotero catalogue sync — {LIBRARY_TYPE}/{LIBRARY_ID}")

  keymap <- ensure_collections()
  existing <- fetch_existing_items()
  cli_alert_info("{nrow(existing)} items in the library")

  pool <- c(build_worldbank(), build_gef(), build_afdb(), build_gcf(),
            build_af(), build_cif())
  cli_alert_info("{length(pool)} documents known to the source catalogues")
  catalogue <- build_from_screening(pool)      # the screening decides membership and status
  cli_alert_info("{length(catalogue)} documents in the catalogue after the screening join")

  new_entries <- Filter(function(x) !(x$doctag %in% existing$doctag), catalogue)

  # 0. duplicate adoption: teammates add items by hand (no doc tags). Before
  # creating anything, try to prove identity against untagged items via
  # (a) project/report identifier contained in their text, (b) URL equality,
  # (c) attachment file MD5. On a confident match the manual item is ADOPTED
  # (patched with our tag/fields/collection; their tags & collections kept).
  # Title-only similarity is never auto-adopted — it goes to the log.
  manual <- existing %>% filter(is.na(doctag))
  adopt_patches <- list(); adopted_tags <- character(0); recon_log <- list()
  if (nrow(manual) > 0 && length(new_entries) > 0) {
    atts_all <- fetch_attachments()
    norm_url <- function(u) sub("/$", "", sub("\\?.*$", "", tolower(coalesce(u, ""))))
    manual$blob <- tolower(paste(manual$title, manual$extra, manual$url,
                                 manual$call_number, manual$report_number))
    manual$nurl <- vapply(manual$url, norm_url, character(1))
    still_new <- list()
    for (x in new_entries) {
      code <- coalesce(x$item$callNumber, "")
      urls <- vapply(c(x$item$url, x$item$extra), norm_url, character(1))
      match_ix <- integer(0); matched_on <- ""
      if (nchar(code) >= 5) {
        hit <- which(grepl(tolower(code), manual$blob, fixed = TRUE))
        if (length(hit)) { match_ix <- hit; matched_on <- paste0("identifier:", code) }
      }
      if (!length(match_ix)) {
        hit <- which(manual$nurl %in% urls[nzchar(urls)])
        if (length(hit)) { match_ix <- hit; matched_on <- "url" }
      }
      if (!length(match_ix) && !is.na(x$file) && file.exists(coalesce(x$file, ""))) {
        local_md5 <- unname(tools::md5sum(x$file))
        hit_parents <- atts_all$parent[atts_all$md5 == local_md5]
        hit <- which(manual$key %in% hit_parents)
        if (length(hit)) { match_ix <- hit; matched_on <- "md5" }
      }
      if (length(match_ix)) {
        m <- manual[match_ix[1], ]
        old_tags <- strsplit(m$all_tags, "\\|")[[1]]
        new_tags <- vapply(x$item$tags, function(t) t$tag, character(1))
        curr_cols <- strsplit(m$collections, ",")[[1]]
        curr_cols <- curr_cols[nzchar(curr_cols)]
        want_col <- keymap[[paste(x$source, x$status, sep = "|")]]
        adopt_patches[[length(adopt_patches) + 1]] <- list(
          key = m$key, version = m$version,
          collections = as.list(unique(c(curr_cols, want_col))),
          reportNumber = coalesce(x$item$reportNumber, ""),
          callNumber = coalesce(x$item$callNumber, ""),
          tags = lapply(unique(c(old_tags[nzchar(old_tags)], new_tags)),
                        function(t) list(tag = t))
        )
        adopted_tags <- c(adopted_tags, x$doctag)
        recon_log[[length(recon_log) + 1]] <- tibble(
          when = format(Sys.time(), "%Y-%m-%d %H:%M"), action = "adopted",
          doctag = x$doctag, zotero_key = m$key, matched_on = matched_on,
          manual_title = m$title)
      } else {
        still_new[[length(still_new) + 1]] <- x
      }
    }
    if (length(adopt_patches) > 0) {
      cli_h2("Adopting {length(adopt_patches)} manually-added items")
      for (b in split(adopt_patches, ceiling(seq_along(adopt_patches) / BATCH_SIZE))) {
        res <- post_batch(unname(b))
        if (length(res$failed) > 0)
          for (f in res$failed) cli_alert_danger("  adopt failed: {f$message}")
        Sys.sleep(1)
      }
      log_path <- file.path(GL, "04_Screening/inputs/reports/zotero_reconciliation_log.csv")
      readr::write_csv(bind_rows(recon_log), log_path,
                       append = file.exists(log_path))
      cli_alert_success("adoptions logged to {log_path}")
    }
    new_entries <- still_new
  }

  # 1. create missing items
  cli_h2("Creating {length(new_entries)} new items")
  if (length(new_entries) > 0) {
    items <- lapply(new_entries, function(x) {
      it <- x$item
      it$collections <- list(keymap[[paste(x$source, x$status, sep = "|")]])
      it
    })
    n_ok <- 0
    for (b in split(items, ceiling(seq_along(items) / BATCH_SIZE))) {
      res <- post_batch(unname(b))
      n_ok <- n_ok + length(res$successful)
      if (length(res$failed) > 0)
        for (f in res$failed) cli_alert_danger("  failed: {f$message}")
      Sys.sleep(1)
    }
    cli_alert_success("created {n_ok}")
    existing <- fetch_existing_items()
  }

  # 1a. files teammates dropped into Zotero by hand: once screened and given a
  #     record above, the bare attachment is placed under that record. Done
  #     before the collection patch (re-parenting copies the attachment's
  #     collection onto the parent) and before the upload (the record now has
  #     its file, so nothing is uploaded twice).
  if (adopt_pulled(existing) > 0) existing <- fetch_existing_items()

  # 1b. duplicates taken out of the source folders get their own collection
  #     and are left out of the status reconciliation below
  dup_keys <- mark_duplicates(existing, keymap)
  if (length(dup_keys)) existing <- fetch_existing_items()

  # 2. patch collection / report number / call number where changed.
  # Collections are MERGED, not replaced: the sync only manages its own
  # status collections (keymap values); memberships the team adds manually
  # are preserved.
  ours <- unlist(keymap)
  cat_ix <- setNames(catalogue, vapply(catalogue, function(x) x$doctag, character(1)))
  patches <- list()
  for (i in seq_len(nrow(existing))) {
    e <- existing[i, ]
    if (e$key %in% dup_keys) next
    if (is.na(e$doctag) || is.null(cat_ix[[e$doctag]])) next
    x <- cat_ix[[e$doctag]]
    want_col <- keymap[[paste(x$source, x$status, sep = "|")]]
    want_rn  <- coalesce(x$item$reportNumber, "")
    want_cn  <- coalesce(x$item$callNumber, "")
    want_tags <- vapply(x$item$tags, function(t) t$tag, character(1))
    curr_tags <- strsplit(coalesce(e$all_tags, ""), "|", fixed = TRUE)[[1]]
    curr_tags <- curr_tags[nzchar(curr_tags)]
    # the verdict tag is ours and there is exactly one: an old screen: tag from
    # an earlier verdict goes; every other tag (the team's, family:, doc tags) stays
    keep_tags <- curr_tags[!grepl("^screen:", curr_tags)]
    new_tags  <- unique(c(keep_tags, want_tags))
    curr_cols <- strsplit(e$collections, ",")[[1]]
    curr_cols <- curr_cols[nzchar(curr_cols)]
    new_cols <- unique(c(setdiff(curr_cols, ours), want_col))
    # the screening line ("screen: <verdict> (<family>): <reason>") is written
    # into Extra, replacing an earlier one, so the reason is readable in Zotero
    want_extra <- coalesce(x$item$extra, "")
    screen_line <- regmatches(want_extra, regexpr("screen: .*$", want_extra))
    new_extra <- e$extra
    if (length(screen_line)) {
      base <- sub("\\s*\\|?\\s*screen: .*$", "", e$extra)
      new_extra <- paste(c(base[nzchar(base)], screen_line), collapse = " | ")
    }
    if (!setequal(new_cols, curr_cols) ||
        !identical(e$report_number, want_rn) ||
        !identical(e$call_number, want_cn) ||
        !setequal(new_tags, curr_tags) ||
        !identical(new_extra, e$extra)) {
      patches[[length(patches) + 1]] <- list(
        key = e$key, version = e$version, collections = as.list(new_cols),
        reportNumber = want_rn, callNumber = want_cn, extra = new_extra,
        tags = lapply(new_tags, function(t) list(tag = t))
      )
    }
  }
  cli_h2("Patching {length(patches)} existing items")
  if (length(patches) > 0) {
    n_ok <- 0
    for (b in split(patches, ceiling(seq_along(patches) / BATCH_SIZE))) {
      res <- post_batch(unname(b))
      n_ok <- n_ok + length(res$successful)
      if (length(res$failed) > 0)
        for (f in res$failed) cli_alert_danger("  failed: {f$message}")
      Sys.sleep(1)
    }
    cli_alert_success("patched {n_ok}")
    existing <- fetch_existing_items()
  }

  # 3. upload document files for items without an attachment
  if (ATTACH_FILES) {
    cli_h2("Uploading document files")
    existing <- fetch_existing_items()   # refresh: adoptions/creations above
    have_att <- fetch_attachment_parents()
    todo <- existing %>%
      filter(!is.na(doctag), !(key %in% have_att)) %>%
      left_join(tibble(doctag = names(cat_ix),
                       file = vapply(cat_ix, function(x)
                         coalesce(x$file, NA_character_), character(1))),
                by = "doctag") %>%
      filter(!is.na(file))
    cli_alert_info("{nrow(todo)} items need a file attachment")
    n_ok <- 0; n_fail <- 0; quota <- FALSE
    for (i in seq_len(nrow(todo))) {
      r <- todo[i, ]
      res <- tryCatch(upload_file_to_item(r$key, r$file),
                      error = function(e) { cli_alert_danger("  {basename(r$file)}: {e$message}"); FALSE })
      if (identical(res, "quota")) { quota <- TRUE; break }
      if (isTRUE(res)) n_ok <- n_ok + 1 else n_fail <- n_fail + 1
      if (i %% 25 == 0) cli_alert_info("attachments: {i}/{nrow(todo)} (ok {n_ok}, fail {n_fail})")
    }
    cli_alert_success("attachments uploaded: {n_ok} (failed: {n_fail})")
    if (quota) cli_alert_danger("stopped: storage quota exceeded")
  }

  cli_h2("Done")
}

main()
