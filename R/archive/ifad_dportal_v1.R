##############################################################################
# ifad.R — International Fund for Agricultural Development (IFAD)
#
# Targets: Project evaluations, completion reports, supervision reports,
#          and project design documents for IFAD-financed agriculture /
#          food-security projects in Africa (2000-2025).
#
# Website:  https://www.ifad.org/en/projects-list
#
# Strategy: D-Portal JSON API (primary source).
#   www.ifad.org runs Liferay DXP behind Cloudflare and only serves ~81
#   currently-active projects on /en/projects-list (server-side HTML).
#   Completed/closed projects — the majority of the historical corpus —
#   are not listed. PDF download links on project pages are JS-rendered
#   and cannot be resolved with httr. Auto-download is not possible.
#
#   D-Portal (d-portal.org) mirrors IFAD's full IATI dataset (1,251
#   activities, publisher ref XM-DAC-41108) with no authentication or
#   bot-protection, giving 10× more African projects than the website.
#
#   Two complementary D-Portal endpoints are used:
#     1. q.json?reporting_ref=XM-DAC-41108&country_code={CC}&limit=500
#        → paginated project metadata per African country
#        → fields: aid, title, description, day_start, day_end, status_code
#     2. q.json?aid={AID}  (XSON format)
#        → per-activity document links (url, IATI category code, title)
#
# Africa filter:  iterate over WB_AFRICA_CODES (ISO2 uppercase), pass as
#                 country_code= query parameter to D-Portal
# Pagination:     offset/limit (500 per page) on D-Portal q.json
#
# Document type priority (IATI category codes, most → least complete):
#   A08 = 1  Final evaluation / PPAR / Terminal Evaluation / PPE
#   B05 = 2  Country programme evaluation (CPE)
#   B09 = 3  Performance audit
#   A06 = 4  Supervision / M&E report
#   A04 = 5  Appraisal / PDR / President's Report
#   A07 = 6  Annual / progress report
#   A09 = 7  Other project document
#   A01 = 8  Pre-project / proposal
#   A02 = 9  Objectives / results framework
#
# Quirks:
#   - www.ifad.org: Cloudflare WAF → 403 all automated clients
#   - /en/projects-list: only ~81 active projects server-side (Liferay DXP);
#     closed/completed projects require JS rendering — not scrapeable
#   - operations.ifad.org / ioe.ifad.org: SSL error on Windows schannel
#     (SEC_E_ILLEGAL_MESSAGE) → log as "blocked"
#   - D-Portal q.json with from=act,country redirects → use country_code=
#   - IFAD IATI publisher ref: XM-DAC-41108
#   - IFAD project IDs: 10-digit numeric embedded in AID after last hyphen
#   - PDF links on /en/w/corporate-documents/ pages are JS-rendered;
#     static HTML resolution returns no .pdf href → metadata_only fallback
#   - web_url provided for every project for manual PDF retrieval
##############################################################################

# ── Setup ──────────────────────────────────────────────────────────────────
.find_r_dir <- function() {
  tryCatch({
    d <- dirname(sys.frame(2)$ofile)
    if (!is.null(d) && nzchar(d))
      return(normalizePath(file.path(d, ".."), mustWork = FALSE))
  }, error = function(e) NULL)
  # Return the PIPELINE ROOT, the directory that contains R/. The caller
  # appends "R/00_shared" itself. This branch used to go up only one level
  # from R/01_retrieve/, giving R/, so the caller looked in R/R/00_shared,
  # never found 00_config.R and died on a missing PATHS. That is why this
  # scraper had never produced anything.
  tryCatch({
    args <- commandArgs(trailingOnly = FALSE)
    fa   <- grep("^--file=", args, value = TRUE)
    if (length(fa))
      return(normalizePath(
        file.path(dirname(sub("^--file=", "", fa[1])), "..", ".."),
        mustWork = FALSE))
  }, error = function(e) NULL)
  wd <- getwd()
  if (file.exists(file.path(wd, "R", "00_shared", "00_config.R"))) return(wd)
  if (file.exists(file.path(wd, "00_config.R")))       return(wd)
  return(wd)
}

if (!exists("PATHS")) {
  .r_dir <- file.path(.find_r_dir(), "R", "00_shared")
  for (.p in file.path(.r_dir, c(".", "..", "../00_shared", "00_shared", "R/00_shared"), "00_config.R")) if (file.exists(.p)) { source(.p); break }
  for (.p in file.path(.r_dir, c(".", "..", "../00_shared", "00_shared", "R/00_shared"), "01_utils.R")) if (file.exists(.p)) { source(.p); break }
}

DOWNLOAD_DIR <- file.path(PATHS$downloads, "ifad")
dir.create(DOWNLOAD_DIR, recursive = TRUE, showWarnings = FALSE)
SOURCE_NAME  <- "ifad"

# ── Constants ──────────────────────────────────────────────────────────────
IFAD_PUBLISHER_REF <- "XM-DAC-41108"
DPORTAL_Q          <- "https://d-portal.org/q.json"
IFAD_AFRICA_CODES  <- toupper(WB_AFRICA_CODES)
DPORTAL_LIMIT      <- 500L

# Keep active (2), finalisation (3), and closed (4) — exclude pipeline (1)
IFAD_INCLUDE_STATUS <- c("2", "3", "4")

# Domains with SSL/TLS errors on Windows schannel
IFAD_BLOCKED_DOMAINS <- c(
  "operations.ifad.org", "ioe.ifad.org",
  "open.ifad.org",       "webapps.ifad.org",
  "www.ifad.org"
)

# Document category priority (lower = more complete for evidence synthesis)
IFAD_DOC_PRIORITY <- c(
  A08 = 1L,  # Final evaluation (Terminal Evaluation, PPE, PPAR)
  B05 = 2L,  # Country programme evaluation (CPE)
  B09 = 3L,  # Performance audit
  A06 = 4L,  # Supervision / M&E report
  A04 = 5L,  # Appraisal (PDR, President's Report)
  A07 = 6L,  # Annual / progress report
  A09 = 7L,  # Other project document
  A01 = 8L,  # Pre-project / proposal
  A02 = 9L   # Objectives / results framework
)

# Title-pattern → human-readable doc type label
IFAD_DOC_TYPE_PATTERNS <- list(
  "Terminal Evaluation"          = "terminal.?eval|te.?report",
  "Project Completion Report"    = "completion.?report|\\bPCR\\b",
  "Country Programme Evaluation" = "country.?programme.?eval|\\bCPE\\b",
  "Mid-Term Review"              = "mid.?term.?review|\\bMTR\\b|midterm",
  "Supervision Report"           = "supervision.?report",
  "President's Report"           = "president.?s?.?report",
  "Project Design Report"        = "project.?design.?report|\\bPDR\\b|appraisal",
  "PPAR/PPE"                     = "\\bPPAR\\b|\\bPPE\\b|performance.*eval",
  "ESIA"                         = "\\bESIA\\b|environmental.*social.*impact",
  "Country Strategy"             = "country.*strategy|\\bCOSOP\\b"
)

# Industrial-agriculture exclusion (doc-retriever agent spec)
INDUSTRIAL_PATTERN <- paste0(
  "(?i)(industrial.agri|agro.industr|plantation.industr|",
  "commercial.farm(?!er)|large.scale.plantation|",
  "fertilizer.manufactur|pesticide.manufactur|",
  "agro.processing.plant|commodity.exchange)"
)

# ── Helpers ────────────────────────────────────────────────────────────────

`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0 && !is.na(a[1])) a else b

infer_doc_type <- function(title) {
  if (is.na(title) || !nzchar(title)) return("Project Document")
  for (lbl in names(IFAD_DOC_TYPE_PATTERNS))
    if (grepl(IFAD_DOC_TYPE_PATTERNS[[lbl]], title, ignore.case = TRUE, perl = TRUE))
      return(lbl)
  "Project Document"
}

is_blocked_domain <- function(url) {
  if (is.na(url) || !nzchar(url)) return(FALSE)
  any(vapply(IFAD_BLOCKED_DOMAINS,
             function(d) grepl(d, url, fixed = TRUE), logical(1)))
}

# ── D-Portal: fetch one page of projects for a country ────────────────────
dportal_fetch_country <- function(country_code, offset = 0L) {
  url <- paste0(DPORTAL_Q,
                "?reporting_ref=", IFAD_PUBLISHER_REF,
                "&country_code=",  country_code,
                "&limit=",         DPORTAL_LIMIT,
                "&offset=",        offset)

  resp <- polite_get(url, max_retries = HTTP_CONFIG$max_retries,
                     delay_range = c(0.5, 1.5))
  if (is.null(resp) || httr::status_code(resp) != 200) {
    cli::cli_alert_warning("D-Portal {country_code} HTTP {httr::status_code(resp) %||% 'no resp'}")
    return(NULL)
  }
  tryCatch({
    rows <- jsonlite::fromJSON(
      httr::content(resp, as = "text", encoding = "UTF-8"),
      simplifyDataFrame = TRUE
    )[["rows"]]
    if (is.null(rows) || length(rows) == 0) return(data.frame())
    as.data.frame(rows, stringsAsFactors = FALSE)
  }, error = function(e) {
    cli::cli_alert_warning("D-Portal parse error ({country_code}): {e$message}")
    NULL
  })
}

# ── D-Portal: fetch document links for one activity (XSON) ────────────────
dportal_fetch_docs <- function(aid) {
  if (is.na(aid) || !nzchar(aid)) return(list())
  url  <- paste0(DPORTAL_Q, "?aid=", utils::URLencode(aid, reserved = TRUE))
  resp <- polite_get(url, max_retries = 2L, delay_range = c(0.5, 1.2))
  if (is.null(resp) || httr::status_code(resp) != 200) return(list())

  tryCatch({
    xson <- jsonlite::fromJSON(
      httr::content(resp, as = "text", encoding = "UTF-8"),
      simplifyDataFrame = FALSE
    )[["xson"]]
    if (is.null(xson) || length(xson) == 0) return(list())

    dlinks <- xson[[1]][["/iati-activities/iati-activity"]][[1]][["/document-link"]]
    if (is.null(dlinks) || length(dlinks) == 0) return(list())

    purrr::compact(purrr::map(dlinks, function(dl) {
      # IATI document-link/category is MULTI-VALUED and the codes are not
      # ordered by usefulness: a real IFAD record carries A02,A03,A04,A05,A06
      # and the evaluation code can sit anywhere in that list. Reading only
      # the first one filed final evaluations as "objectives" and broke the
      # DOC_CATEGORY_PRIORITY ranking below. Take the best-ranked code across
      # all of them, and keep the full list for the catalogue.
      cats <- purrr::map_chr(dl[["/category"]] %||% list(),
                             ~ .x[["@code"]] %||% NA_character_)
      cats <- cats[!is.na(cats) & nzchar(cats)]
      if (!length(cats)) cats <- NA_character_
      ranks <- vapply(cats, function(cc) {
        r <- IFAD_DOC_PRIORITY[cc]
        if (is.na(r)) 99L else as.integer(r)
      }, integer(1), USE.NAMES = FALSE)
      cat_code <- cats[which.min(ranks)]
      # a link that is ONLY a web page carries no document
      if (all(cats %in% "A12")) return(NULL)
      list(
        pdf_url    = dl[["@url"]]                             %||% NA_character_,
        cat_code   = cat_code,
        cat_all    = paste(cats, collapse = ","),
        doc_title  = dl[["/title/narrative"]][[1]][[""] ]     %||% NA_character_,
        format     = dl[["@format"]]                          %||% NA_character_
      )
    }))
  }, error = function(e) {
    cli::cli_alert_warning("XSON parse error ({aid}): {e$message}")
    list()
  })
}

# ── collect_ifad_documents() ───────────────────────────────────────────────
collect_ifad_documents <- function() {
  cli::cli_h2("D-Portal: collecting IFAD project metadata for Africa")
  all_rows <- list()

  for (cc in IFAD_AFRICA_CODES) {
    offset <- 0L; page <- 1L
    repeat {
      cli::cli_alert_info("  {cc} p{page} (offset {offset})")
      rows <- dportal_fetch_country(cc, offset = offset)
      if (is.null(rows)) { break }
      if (is.data.frame(rows) && nrow(rows) == 0) {
        if (page == 1L) cli::cli_alert_info("  {cc}: no projects.")
        break
      }
      rows$country_iso <- cc
      all_rows <- c(all_rows, list(rows))
      cli::cli_alert_success("  {cc} p{page}: {nrow(rows)} activities")
      if (nrow(rows) < DPORTAL_LIMIT) break
      offset <- offset + DPORTAL_LIMIT; page <- page + 1L
    }
  }

  if (length(all_rows) == 0) {
    cli::cli_alert_danger("No data from D-Portal.")
    return(tibble::tibble())
  }
  combined <- dplyr::bind_rows(all_rows)
  cli::cli_alert_success("D-Portal total: {nrow(combined)} activity-country rows")
  combined
}

# ── flatten_dportal_rows() ─────────────────────────────────────────────────
flatten_dportal_rows <- function(dp_rows) {
  if (nrow(dp_rows) == 0) return(tibble::tibble())
  epoch <- as.Date("1970-01-01")

  dp_rows %>%
    dplyr::mutate(
      project_id  = sub(".*-", "", as.character(.data$aid)),
      country     = dplyr::coalesce(WB_AFRICA_NAMES[toupper(.data$country_iso)],
                                    .data$country_iso),
      doc_date    = dplyr::case_when(
        !is.na(.data$day_end)   & .data$day_end   > 0 ~
          as.character(epoch + .data$day_end),
        !is.na(.data$day_start) & .data$day_start > 0 ~
          as.character(epoch + .data$day_start),
        TRUE ~ NA_character_
      ),
      web_url     = dplyr::if_else(
        !is.na(.data$project_id) & nzchar(.data$project_id),
        paste0("https://www.ifad.org/en/web/operations/-/project/", .data$project_id),
        NA_character_
      ),
      id          = vapply(as.character(.data$aid), safe_filename,
                           character(1), USE.NAMES = FALSE),
      title       = as.character(.data$title),
      description = as.character(.data$description),
      status_code = as.character(.data$status_code),
      doc_type    = "Project Document",
      cat_code    = NA_character_,
      pdf_url     = NA_character_
    ) %>%
    dplyr::select(id, title, description, pdf_url, doc_date, doc_type,
                  cat_code, country, country_iso, project_id, web_url, status_code)
}

# ── enrich_with_doc_links() ────────────────────────────────────────────────
enrich_with_doc_links <- function(results, max_fetch = 400L) {
  cli::cli_h2("Enriching with document links (D-Portal XSON)")
  if (nrow(results) == 0) return(results)

  needs  <- results %>%
    dplyr::filter(is.na(.data$pdf_url) | !nzchar(.data$pdf_url)) %>%
    dplyr::distinct(.data$project_id, .keep_all = TRUE) %>%
    utils::head(max_fetch)
  ok     <- results %>%
    dplyr::filter(!is.na(.data$pdf_url) & nzchar(.data$pdf_url))

  cli::cli_alert_info("Fetching doc links for {nrow(needs)} projects (cap {max_fetch})")

  enriched <- purrr::map(seq_len(nrow(needs)), function(i) {
    row <- needs[i, , drop = FALSE]
    aid <- paste0(IFAD_PUBLISHER_REF, "-", row$project_id)
    cli::cli_alert_info("  [{i}/{nrow(needs)}] {substr(row$title, 1, 60)}")
    docs <- tryCatch(dportal_fetch_docs(aid), error = function(e) list())
    if (length(docs) == 0) return(row)
    purrr::map(docs, function(d) {
      row %>% dplyr::mutate(
        id       = safe_filename(paste0(.data$project_id, "_",
                                        dplyr::coalesce(d$cat_code, "doc"))),
        pdf_url  = as.character(d$pdf_url  %||% NA_character_),
        doc_type = infer_doc_type(dplyr::coalesce(d$doc_title, .data$title, "")),
        cat_code = as.character(d$cat_code %||% NA_character_)
      )
    }) %>% dplyr::bind_rows()
  }) %>% dplyr::bind_rows()

  dplyr::bind_rows(ok, enriched)
}

# ── select_best_ifad_document() ────────────────────────────────────────────
select_best_ifad_document <- function(results) {
  if (nrow(results) == 0) return(results)
  cli::cli_h2("Selecting one document per project")
  n_before <- nrow(results)

  best <- results %>%
    dplyr::mutate(
      cat_priority = dplyr::if_else(
        is.na(IFAD_DOC_PRIORITY[.data$cat_code]),
        99L,
        as.integer(IFAD_DOC_PRIORITY[.data$cat_code])
      )
    ) %>%
    dplyr::group_by(.data$project_id) %>%
    dplyr::arrange(.data$cat_priority, dplyr::desc(.data$doc_date)) %>%
    dplyr::slice(1) %>%
    dplyr::ungroup() %>%
    dplyr::select(-cat_priority)

  cli::cli_alert_success("Reduced {n_before} → {nrow(best)} (one per project)")
  best
}

# ── run_ifad_scraper() ─────────────────────────────────────────────────────
run_ifad_scraper <- function() {
  cli::cli_h1("IFAD Grey Literature Scraper")
  cli::cli_alert_info("Source: D-Portal API (d-portal.org) — full IFAD IATI dataset")
  cli::cli_alert_info("Download dir: {DOWNLOAD_DIR}")
  cli::cli_alert_info(paste(
    "Note: www.ifad.org PDF downloads are JS-gated and cannot be automated.",
    "All entries include web_url for manual retrieval."
  ))

  # 1. Collect
  raw <- tryCatch(collect_ifad_documents(),
                  error = function(e) { cli::cli_alert_danger(e$message); tibble::tibble() })
  if (nrow(raw) == 0) { cli::cli_alert_danger("No data. Aborting."); return(invisible(NULL)) }

  # 2. Flatten
  flat <- flatten_dportal_rows(raw)

  # 3. Dedup by project × country
  flat <- dplyr::distinct(flat, .data$project_id, .data$country_iso, .keep_all = TRUE)
  cli::cli_alert_info("After dedup: {nrow(flat)} project-country rows")

  # 4. Status filter (exclude pipeline)
  flat <- dplyr::filter(flat, is.na(.data$status_code) |
                               .data$status_code %in% IFAD_INCLUDE_STATUS)
  cli::cli_alert_info("After status filter: {nrow(flat)}")

  # 5. Date filter (2000-2025)
  flat <- dplyr::filter(flat,
    is.na(.data$doc_date) |
    (.data$doc_date >= "2000-01-01" & .data$doc_date <= "2025-12-31"))
  cli::cli_alert_info("After date filter: {nrow(flat)}")

  if (nrow(flat) == 0) { cli::cli_alert_danger("Nothing after filters."); return(invisible(NULL)) }

  # 6. Relevance filter (sector keywords; Africa already enforced by country_code)
  cli::cli_h2("Relevance filtering (agriculture + adaptation)")
  n_before <- nrow(flat)
  flat <- flat %>%
    dplyr::rowwise() %>%
    dplyr::mutate(relevant = passes_relevance_fast(
      paste(dplyr::coalesce(.data$title, ""),
            dplyr::coalesce(.data$description, ""), sep = " "),
      require_africa = FALSE, require_sector = TRUE
    )) %>%
    dplyr::ungroup() %>%
    dplyr::filter(.data$relevant) %>%
    dplyr::select(-relevant)
  cli::cli_alert_info("Relevance: {n_before} → {nrow(flat)}")

  if (nrow(flat) == 0) {
    cli::cli_alert_warning("No documents passed relevance filter.")
    readr::write_csv(raw %>% utils::head(500),
                     file.path(PATHS$data, "ifad_metadata.csv"))
    return(invisible(NULL))
  }

  # 7. Industrial exclusion
  is_ind <- grepl(INDUSTRIAL_PATTERN,
                  paste(flat$title, dplyr::coalesce(flat$description, "")),
                  perl = TRUE)
  if (any(is_ind)) {
    cli::cli_alert_info("Excluding {sum(is_ind)} industrial agriculture docs")
    flat <- flat[!is_ind, ]
  }

  # 8. Enrich with document links
  flat <- tryCatch(enrich_with_doc_links(flat, max_fetch = 400L),
                   error = function(e) { cli::cli_alert_warning(e$message); flat })

  # 9. One per project
  best <- select_best_ifad_document(flat)

  # 10. Save metadata
  meta_path <- file.path(PATHS$data, "ifad_metadata.csv")
  readr::write_csv(best, meta_path)
  cli::cli_alert_success("Metadata saved ({nrow(best)} rows): {meta_path}")

  # 11. Download PDFs
  cli::cli_h2("Downloading PDFs")
  with_pdf <- dplyr::filter(best, !is.na(.data$pdf_url) & nzchar(.data$pdf_url))
  no_pdf   <- dplyr::filter(best,  is.na(.data$pdf_url) | !nzchar(.data$pdf_url))
  cli::cli_alert_info("{nrow(with_pdf)} PDF URLs | {nrow(no_pdf)} metadata-only")

  for (i in seq_len(nrow(no_pdf))) {
    row <- no_pdf[i, , drop = FALSE]
    log_download(SOURCE_NAME, row$project_id, row$doc_type, row$title,
                 NA, NA, "metadata_only",
                 paste0("No PDF in IATI data — manual: ", row$web_url))
  }

  success <- 0L; failed <- 0L; skipped <- 0L; blocked <- 0L

  for (i in seq_len(nrow(with_pdf))) {
    row      <- with_pdf[i, , drop = FALSE]
    year     <- substr(dplyr::coalesce(row$doc_date, ""), 1, 4)
    if (!nzchar(year)) year <- "XXXX"
    fname    <- paste0(substr(glue::glue(
      "{SOURCE_NAME}_{safe_filename(dplyr::coalesce(row$project_id,'x'))}",
      "_{safe_filename(dplyr::coalesce(row$doc_type,'doc'))}_{year}"), 1, 150), ".pdf")
    dest     <- file.path(DOWNLOAD_DIR, fname)

    if (file.exists(dest)) {
      log_download(SOURCE_NAME, row$project_id, row$doc_type, row$title,
                   row$pdf_url, dest, "skipped", "Already exists")
      skipped <- skipped + 1L; next
    }
    if (is_blocked_domain(row$pdf_url)) {
      log_download(SOURCE_NAME, row$project_id, row$doc_type, row$title,
                   row$pdf_url, NA, "blocked", "SSL/TLS blocked on Windows")
      blocked <- blocked + 1L; next
    }

    resp  <- polite_get(row$pdf_url,
                        httr::add_headers(Accept = "application/pdf,*/*;q=0.8",
                                          `Accept-Encoding` = "gzip, deflate"))
    dl_ok <- FALSE
    if (!is.null(resp) && httr::status_code(resp) == 200) {
      tryCatch({
        writeBin(httr::content(resp, as = "raw"), dest)
        fsize <- file.info(dest)$size
        if (!is.na(fsize) && fsize >= HTTP_CONFIG$min_pdf_bytes) {
          con <- file(dest, "rb"); magic <- rawToChar(readBin(con, "raw", n = 5)); close(con)
          if (magic == "%PDF-") dl_ok <- TRUE
        }
        if (!dl_ok && file.exists(dest)) file.remove(dest)
      }, error = function(e) { if (file.exists(dest)) file.remove(dest) })
    } else if (!is.null(resp) && httr::status_code(resp) == 403) {
      log_download(SOURCE_NAME, row$project_id, row$doc_type, row$title,
                   row$pdf_url, NA, "blocked", "HTTP 403 Cloudflare")
      blocked <- blocked + 1L; next
    }

    if (dl_ok) {
      log_download(SOURCE_NAME, row$project_id, row$doc_type, row$title,
                   row$pdf_url, dest, "success")
      success <- success + 1L
    } else {
      log_download(SOURCE_NAME, row$project_id, row$doc_type, row$title,
                   row$pdf_url, NA, "failed",
                   paste0("HTTP ", if (!is.null(resp)) httr::status_code(resp) else "no resp"))
      failed <- failed + 1L
    }
    if (i %% 20 == 0)
      cli::cli_alert_info(
        "Progress: {i}/{nrow(with_pdf)} (OK:{success} blocked:{blocked} fail:{failed} skip:{skipped})")
  }

  cli::cli_h3("Download Summary")
  cli::cli_alert_success("Downloaded: {success}")
  cli::cli_alert_warning("Blocked:    {blocked}")
  cli::cli_alert_danger("Failed:     {failed}")
  cli::cli_alert_info("Skipped:    {skipped}")
  cli::cli_alert_info("No URL:     {nrow(no_pdf)}")
  if (blocked + failed > 0)
    cli::cli_alert_info(paste0(
      blocked + failed, " PDFs inaccessible (JS-gated or SSL-blocked). ",
      "Manual download from https://www.ifad.org/en/web/operations/-/project/[PROJECT_ID]"))

  print_source_summary(SOURCE_NAME)
  cli::cli_h2("Done!")
  invisible(best)
}

if (sys.nframe() == 0 || !interactive()) run_ifad_scraper()
