##############################################################################
# afdb.R — African Development Bank (AfDB) Evaluation Document Scraper
#          2026-10 corpus-completion campaign rewrite.
#
# Targets: project EVALUATION documents (PCRs, evaluation reports, IDEV
#          independent evaluations). NO retrieval-time publication window:
#          the screening phase owns the window; dates are extracted as
#          metadata only.
#
# Strategies:
#   A. www.afdb.org Drupal category listings (?page=N, 0-indexed):
#        - /en/documents/project-operations/projectprogramme-completion-reports
#          (21/page, "Displaying 1 - N of M" counter)
#        - /en/documents/evaluation-reports?tid_1=7  — the REAL agriculture
#          sector facet (18/page). NOTE: any *path* under
#          /en/documents/evaluation-reports/<anything> is a Drupal WILDCARD
#          that serves the generic parent view ("Evaluation Reports");
#          sub-paths must never be trusted — the run-start canary checks this.
#   B. idev.afdb.org (rebuilt on Drupal 9/10, server-rendered, 5/page):
#        /en/page/evaluations/search?field_category_doc_target_id=<id>
#          &field_region_target_id=All&field_topic_target_id=All
#          &field_sector_target_id=<id>&title=&page=N
#        field_sector_target_id=106 = Agriculture & Agro-industry.
#        Document pages expose a direct https://.../sites/default/files/...pdf
#        link in the HTML (old pdf.js-iframe workaround obsolete on IDEV;
#        www.afdb.org doc pages still embed pdf.js but the direct URL is in
#        the page source).
#
# TRANSPORT (verified 2026-10-02): afdb.org 403s clients without standard
#   Accept headers, and discriminates on TLS fingerprint — R httr is refused
#   or stalled even with identical headers. curl.exe (Windows) with the
#   honest GreyLit UA PLUS the full browser-standard Accept /
#   Accept-Language / Upgrade-Insecure-Requests / Referer header set and
#   --compressed gets HTTP 200 on both hosts. All afdb.org and idev.afdb.org
#   requests therefore shell out to curl.exe via afdb_get()/afdb_download().
#   Do NOT impersonate a browser UA; identify honestly.
#
# Dispositions written to catalogues/afdb/attestation.csv via
# write_attestation(); vocabulary in 01_utils.R (ATTEST_DISPOSITIONS).
# USER DECISION 2026-10: "PCR & XSR Validation Synthesis" documents are desk
# reviews -> excluded_desk_review, never downloaded. PPERs and PCR
# Evaluation Notes are discontinued by AfDB (nothing post-2014) — not chased.
#
# Run modes via env var AFDB_MODE: "load" (source only), "canary"
# (canary check only), "campaign" (default: full completion campaign).
##############################################################################

# ── Setup ──────────────────────────────────────────────────────────────────
# Locate R/00_shared/00_config.R. Each candidate anchor is only accepted if
# the config is ACTUALLY findable from it, so that sourcing this file from a
# script living somewhere else (the case the .afdb_is_main guard exists to
# support) still resolves the shared setup instead of dying on PROJECT_ROOT.
.afdb_rel_dirs <- c(".", "..", "../00_shared", "00_shared", "R/00_shared",
                    "../R/00_shared", "../../R/00_shared")

.afdb_find_shared <- function() {
  anchors <- character(0)
  anchors <- c(anchors, tryCatch({
    d <- dirname(sys.frame(2)$ofile)
    if (!is.null(d) && nzchar(d)) normalizePath(d, mustWork = FALSE) else character(0)
  }, error = function(e) character(0)))
  anchors <- c(anchors, tryCatch({
    fa <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
    if (length(fa)) normalizePath(dirname(sub("^--file=", "", fa[1])), mustWork = FALSE)
    else character(0)
  }, error = function(e) character(0)))
  anchors <- c(anchors, getwd())
  for (a in unique(anchors)) {
    for (rel in .afdb_rel_dirs) {
      cfg <- file.path(a, rel, "00_config.R")
      if (file.exists(cfg)) return(normalizePath(dirname(cfg), mustWork = FALSE))
    }
  }
  NULL
}

if (!exists("PATHS")) {
  .shared <- .afdb_find_shared()
  if (is.null(.shared))
    stop("afdb.R: cannot locate R/00_shared/00_config.R from ", getwd(),
         " — run from the 07_Pipeline root or source the shared setup first",
         call. = FALSE)
  source(file.path(.shared, "00_config.R"))
  source(file.path(.shared, "01_utils.R"))
}

SOURCE_NAME <- "afdb"

# Corpus lives at the sibling 03_Documents directory; new files go to
# Docs/to_screen. NEVER delete or overwrite existing corpus files.
CORPUS_AFDB  <- normalizePath(file.path(PROJECT_ROOT, "..", "03_Documents", "afdb"),
                              mustWork = FALSE)
DOWNLOAD_DIR <- file.path(CORPUS_AFDB, "Docs", "to_screen")
dir.create(DOWNLOAD_DIR, recursive = TRUE, showWarnings = FALSE)

CATALOGUE_DIR <- file.path(PROJECT_ROOT, "catalogues", "afdb")
dir.create(CATALOGUE_DIR, recursive = TRUE, showWarnings = FALSE)

AUDIT_MISSING_PCRS <- file.path(PROJECT_ROOT, "audit", "2026-10_completeness",
                                "afdb_missing_pcrs.csv")
CIF_HANDOFF_CSV    <- file.path(PROJECT_ROOT, "catalogues", "cif", "mdb_handoff.csv")
IDEV_TAXONOMY_CSV  <- file.path(CATALOGUE_DIR, "idev_taxonomy.csv")
AFDB_METADATA_CSV  <- file.path(CATALOGUE_DIR, "afdb_metadata.csv")

# ── AfDB Configuration ─────────────────────────────────────────────────────
AFDB_BASE <- "https://www.afdb.org"
IDEV_BASE <- "https://idev.afdb.org"

IDEV_SEARCH_URL <- paste0(IDEV_BASE, "/en/page/evaluations/search")

# Strategy A: category listings (?page=N, 0-indexed). Each entry carries its
# own assertion spec (title regex + "Displaying 1 - N of M" counter echo);
# the harvest ASSERTS rows == M at the end and fails loudly otherwise.
# The three old wildcard sub-paths (completion-report-reviews,
# projects-performance-evaluation-report, agriculture-agro-industries/6) are
# GONE: they all served the generic parent view. The real agriculture facet
# is ?tid_1=7 on /en/documents/evaluation-reports.
AFDB_CATEGORY_LISTINGS <- list(
  pcr = list(
    path     = "/en/documents/project-operations/projectprogramme-completion-reports",
    label    = "Project Completion Reports",
    implied  = "PCR",
    confirm  = "completion report|[- ]pcr\\b|rapport d.ach.vement",
    per_page = 21L,
    max_pages = 80L,
    expect   = list(
      title    = "Completion Reports",
      contains = c("Displaying\\s+\\d+\\s*-\\s*\\d+\\s+of\\s+\\d+",
                   "views-field-title")
    )
  ),
  agri_eval = list(
    path     = "/en/documents/evaluation-reports?tid_1=7",
    label    = "Evaluation Reports (Agriculture & Agro-industries facet tid_1=7)",
    implied  = "EVAL",
    confirm  = "evaluation|\\bevaluat|examen",
    per_page = 18L,
    max_pages = 20L,
    expect   = list(
      title    = "Evaluation Reports",
      contains = c("Displaying\\s+\\d+\\s*-\\s*\\d+\\s+of\\s+\\d+",
                   "value=\"7\" selected",     # the facet must echo back
                   "views-field-title")
    )
  )
)

# Strategy B: IDEV sweeps. Sector 106 = Agriculture & Agro-industry swept
# across EVERY document category in idev_taxonomy.csv (plus category=All as a
# catch-all), because the result row's own document-type field is sometimes
# blank — sweeping per category recovers the label from the query itself.
# Then category 186 (PCR & XSR Validation synthesis) across all sectors, so
# the 7 desk reviews land in the ledger as excluded_desk_review.
IDEV_AGRI_SECTOR <- "106"
IDEV_VALIDATION_CATEGORY <- "186"

#' Build the IDEV sweep list from the taxonomy CSV (facet
#' field_category_doc_target_id). Returns a list of sweep specs.
build_idev_sweeps <- function(taxonomy_csv = IDEV_TAXONOMY_CSV) {
  tax <- readr::read_csv(taxonomy_csv, show_col_types = FALSE,
                         col_types = readr::cols(.default = "c"))
  cats <- tax[tax$facet == "field_category_doc_target_id", c("id", "label")]
  cats <- cats[!duplicated(cats$id), ]
  # Concrete categories FIRST so their specific label wins the later
  # distinct(web_url); "All" last, as the catch-all for uncategorised docs.
  ids <- unique(c(cats$id[cats$id != "All"], "All"))
  sweeps <- lapply(ids, function(id) {
    lab <- cats$label[match(id, cats$id)]
    if (is.na(lab)) lab <- id
    list(category = id, sector = IDEV_AGRI_SECTOR, category_label = lab,
         label = paste0("IDEV sector=106 x category=", id, " (", lab, ")"))
  })
  names(sweeps) <- paste0("agri_cat_", ids)
  # the validation-synthesis sweep: category 186 across ALL sectors
  vs_lab <- cats$label[match(IDEV_VALIDATION_CATEGORY, cats$id)]
  if (is.na(vs_lab)) vs_lab <- "PCR & XSR Validation synthesis"
  sweeps[["validation_synthesis"]] <- list(
    category = IDEV_VALIDATION_CATEGORY, sector = "All", category_label = vs_lab,
    label = paste0("IDEV category=", IDEV_VALIDATION_CATEGORY, " (", vs_lab, ")"))
  sweeps
}
IDEV_MAX_PAGES <- 100L
IDEV_VALIDATION_PATTERN <- "validation\\s+synthesis|pcr\\s*(and|&)\\s*xsr"

# IDEV document categories considered in-scope evaluation products when they
# appear on the sector=106 sweep (everything else -> out_by_type).
IDEV_RELEVANT_CATEGORIES <- paste(
  "project cluster evaluation", "impact evaluation", "sector evaluation",
  "evaluation synthesis", "thematic evaluation", "corporate evaluation",
  "country strategy and program evaluation", "knowledge product",
  "project performance evaluation", "evaluation report",
  "regional integration strategy evaluation",
  sep = "|")

# Recognized but out of scope (proposals / safeguard / progress docs)
AFDB_EXCLUDED_TYPES <- c("PAR", "ESIA", "IPR", "ISR")

# ── Transport: curl.exe helpers ─────────────────────────────────────────────
# All afdb.org / idev.afdb.org traffic goes through these. Honest UA from
# HTTP_CONFIG plus browser-standard Accept headers (without them the edge
# 403s), politeness sleep 1-2.5s before every request, retry/backoff on
# 403/429/5xx, and on PERSISTENT 403 a single 5-minute pause before aborting
# the run.
.afdb_state <- new.env(parent = emptyenv())
.afdb_state$paused403 <- FALSE

.afdb_referer <- function(url) {
  if (grepl("^https?://idev\\.", url)) paste0(IDEV_BASE, "/en/page/evaluations")
  else paste0(AFDB_BASE, "/en/documents")
}

.afdb_curl_headers <- function(url) {
  c("-A", shQuote(HTTP_CONFIG$user_agent),
    "-H", shQuote("Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"),
    "-H", shQuote("Accept-Language: en-US,en;q=0.9"),
    "-H", shQuote("Upgrade-Insecure-Requests: 1"),
    "-H", shQuote(paste0("Referer: ", .afdb_referer(url))))
}

#' One raw curl.exe call. Body written to `out_file`; returns the HTTP status
#' code as integer (NA on transport failure).
.afdb_curl <- function(url, out_file, max_time = HTTP_CONFIG$timeout_sec) {
  args <- c("-sS", "--compressed", "-L", "--max-time", as.character(max_time),
            .afdb_curl_headers(url),
            "-o", shQuote(out_file),
            "-w", shQuote("%{http_code}"),
            shQuote(url))
  out <- tryCatch(
    suppressWarnings(system2("curl.exe", args, stdout = TRUE, stderr = FALSE)),
    error = function(e) character(0))
  code <- grep("^[0-9]{3}$", out, value = TRUE)
  if (length(code)) as.integer(code[length(code)]) else NA_integer_
}

#' The single 5-minute pause allowed on persistent 403, then abort if still
#' refused (politeness contract for this campaign).
.afdb_handle_persistent_403 <- function(url, retry_fun) {
  if (!.afdb_state$paused403) {
    .afdb_state$paused403 <- TRUE
    cli::cli_alert_warning("Persistent 403 — pausing 5 minutes once, then one more attempt: {url}")
    Sys.sleep(300)
    return(retry_fun())
  }
  stop("afdb: still refused (403) after backoff and the one-time 5-minute pause — ",
       "stopping the run as instructed. Last url: ", url, call. = FALSE)
}

#' Polite GET through curl.exe. Returns list(status, body, url); body is ""
#' when nothing was received. Retries 403/429/5xx with backoff.
#' NOTE (measured 2026-10-02): the edge in front of BOTH www.afdb.org and
#' idev.afdb.org intermittently answers 403 with a Cloudflare "Just a
#' moment..." interstitial, on requests that succeed when repeated. It is not
#' host-specific and not a ban, so GETs get more attempts than
#' HTTP_CONFIG$max_retries: the backoff keeps it polite and the one-time
#' 5-minute pause still guards against a genuine block.
afdb_get <- function(url, max_retries = max(5L, HTTP_CONFIG$max_retries)) {
  attempt_once_final <- function() {
    tmp <- tempfile(fileext = ".bin")
    on.exit(unlink(tmp), add = TRUE)
    Sys.sleep(runif(1, HTTP_CONFIG$delay_min, HTTP_CONFIG$delay_max))
    status <- .afdb_curl(url, tmp)
    body <- .afdb_read_body(tmp)
    if (!is.na(status) && status == 403)
      return(.afdb_handle_persistent_403(url, attempt_once_final))
    list(status = status, body = body, url = url)
  }

  for (attempt in seq_len(max_retries)) {
    Sys.sleep(runif(1, HTTP_CONFIG$delay_min, HTTP_CONFIG$delay_max))
    tmp <- tempfile(fileext = ".bin")
    status <- .afdb_curl(url, tmp)
    body <- .afdb_read_body(tmp)
    unlink(tmp)

    if (is.na(status)) {
      cli::cli_alert_warning("transport failure (attempt {attempt}/{max_retries}): {url}")
      Sys.sleep(2^attempt); next
    }
    if (status == 200) return(list(status = status, body = body, url = url))
    if (status == 429) {
      cli::cli_alert_warning("429 rate limited (attempt {attempt}) — waiting 30s")
      Sys.sleep(30); next
    }
    if (status >= 500) {
      cli::cli_alert_warning("HTTP {status} (attempt {attempt}) — backing off")
      Sys.sleep(2^attempt); next
    }
    if (status == 403) {
      backoff <- max(20, 2^(attempt + 1)) + runif(1, 0, 10)
      cli::cli_alert_warning("403 (attempt {attempt}/{max_retries}) — backing off {round(backoff)}s: {url}")
      Sys.sleep(backoff); next
    }
    # other 4xx: no point retrying
    return(list(status = status, body = body, url = url))
  }
  # retries exhausted; if the last failure class was a refusal, use the
  # one-time long pause, else report the transport failure upward.
  final <- attempt_once_final()
  final
}

.afdb_read_body <- function(path) {
  if (!file.exists(path) || is.na(file.info(path)$size) || file.info(path)$size == 0)
    return("")
  raw <- readBin(path, "raw", n = file.info(path)$size)
  raw <- raw[raw != as.raw(0)]
  txt <- tryCatch(rawToChar(raw), error = function(e) "")
  Encoding(txt) <- "UTF-8"
  txt
}

#' Download a PDF through curl.exe -o, then validate size + %PDF- magic via
#' the shared valid_local_file(). Never overwrites: existing dest => "skipped".
#' Returns TRUE / FALSE / "skipped" (same contract as download_pdf()).
afdb_download <- function(url, dest, max_retries = HTTP_CONFIG$max_retries) {
  if (file.exists(dest)) return("skipped")
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  tmp <- paste0(dest, ".part")
  for (attempt in seq_len(max_retries)) {
    Sys.sleep(runif(1, HTTP_CONFIG$delay_min, HTTP_CONFIG$delay_max))
    status <- .afdb_curl(url, tmp, max_time = 300)
    if (!is.na(status) && status == 200 && valid_local_file(tmp, "pdf")) {
      file.rename(tmp, dest)
      cli::cli_alert_success("downloaded: {basename(dest)} ({round(file.info(dest)$size/1024)}KB)")
      return(TRUE)
    }
    if (file.exists(tmp)) unlink(tmp)
    if (!is.na(status) && status == 403) {
      backoff <- max(20, 2^(attempt + 1)) + runif(1, 0, 10)
      cli::cli_alert_warning("403 on PDF (attempt {attempt}) — backing off {round(backoff)}s")
      Sys.sleep(backoff)
    } else if (!is.na(status) && status == 429) {
      Sys.sleep(30)
    } else if (is.na(status) || status >= 500) {
      Sys.sleep(2^attempt)
    } else {
      cli::cli_alert_warning("HTTP {status} or invalid PDF for: {url}")
      return(FALSE)   # 4xx / wrong content: retrying won't help
    }
  }
  FALSE
}

#' Parse the body of an afdb_get() result into an xml2 document (or NULL).
afdb_html <- function(res) {
  if (is.null(res) || is.na(res$status) || res$status != 200) return(NULL)
  if (nchar(res$body) < 200) return(NULL)
  tryCatch(xml2::read_html(res$body), error = function(e) NULL)
}

# ── Response assertions (curl-transport analogue of assert_response) ───────
#' Same expectation fields as assert_response() in 01_utils.R (status, title
#' regex, contains, not_contains, min_bytes, check) but takes the
#' list(status, body, url) returned by afdb_get().
afdb_assert <- function(res, url, expect = list(),
                        on_fail = c("stop", "warn", "quiet")) {
  on_fail <- match.arg(on_fail)
  fail <- function(why) {
    if (on_fail != "quiet") {
      cli::cli_alert_danger("response assertion failed: {why}")
      cli::cli_alert_danger("  for: {url}")
      log_download(source = SOURCE_NAME, url = url,
                   status = "assertion_failed", notes = why)
      if (on_fail == "stop") stop("afdb_assert: ", why, "\n  url: ", url, call. = FALSE)
    }
    NULL
  }
  if (is.null(res) || is.na(res$status))
    return(fail("no response (transport failure or retries exhausted)"))
  allowed <- if (is.null(expect$status)) 200:299 else expect$status
  if (!res$status %in% allowed) return(fail(paste0("HTTP ", res$status)))
  body <- res$body
  if (!is.null(expect$min_bytes) && nchar(body, type = "bytes") < expect$min_bytes)
    return(fail(paste0("body under ", expect$min_bytes, " bytes")))
  if (!is.null(expect$title)) {
    title <- sub(".*<title[^>]*>\\s*(.*?)\\s*</title>.*", "\\1",
                 gsub("[\r\n]", " ", body))
    if (!grepl(expect$title, title, ignore.case = TRUE))
      return(fail(paste0("page title '", substr(title, 1, 60), "' !~ /", expect$title, "/")))
  }
  for (re in expect$contains)
    if (!grepl(re, body, ignore.case = TRUE))
      return(fail(paste0("body does not contain /", re, "/")))
  for (re in expect$not_contains)
    if (grepl(re, body, ignore.case = TRUE))
      return(fail(paste0("body CONTAINS forbidden /", re, "/")))
  if (!is.null(expect$check)) {
    r <- expect$check(body)
    if (!isTRUE(r)) return(fail(if (is.character(r)) r else "custom check failed"))
  }
  invisible(res)
}

.afdb_page_title <- function(body) {
  sub(".*<title[^>]*>\\s*(.*?)\\s*</title>.*", "\\1", gsub("[\r\n]", " ", body))
}

#' Canary (run start): the PCR listing must PASS its assertion (title contains
#' "Completion Reports" + a "Displaying 1 - N of M" counter) and the nonsense
#' path /en/documents/evaluation-reports/zzz-canary-nonexistent must FAIL the
#' same expectations (the Drupal wildcard serves the generic "Evaluation
#' Reports" view there). Aborts the run if the canary is wrong either way.
afdb_canary <- function() {
  cli::cli_h2("AfDB canary")
  pcr <- AFDB_CATEGORY_LISTINGS$pcr
  good_url <- paste0(AFDB_BASE, pcr$path, "?page=0")
  good <- afdb_get(good_url)
  g <- afdb_assert(good, good_url, pcr$expect, on_fail = "warn")
  if (is.null(g))
    stop("canary (afdb): the known-good PCR listing failed its own assertion; ",
         "the site changed or the expectation is wrong - do not scrape blind",
         call. = FALSE)
  cnt <- afdb_parse_counter(good$body)
  cli::cli_alert_success(
    "canary GOOD: PCR listing passes — HTTP {good$status}, title '{substr(.afdb_page_title(good$body), 1, 50)}', counter 'Displaying {cnt$from} - {cnt$to} of {cnt$total}'")

  nonsense_url <- paste0(AFDB_BASE, "/en/documents/evaluation-reports/zzz-canary-nonexistent")
  bad <- afdb_get(nonsense_url)
  b <- afdb_assert(bad, nonsense_url, pcr$expect, on_fail = "quiet")
  if (!is.null(b))
    stop("canary (afdb): the NONSENSE path PASSED the PCR expectation - the ",
         "wildcard view is indistinguishable; tighten the expectation",
         call. = FALSE)
  cli::cli_alert_success(
    "canary NONSENSE: zzz path FAILS the PCR expectation as required — HTTP {bad$status}, title '{substr(.afdb_page_title(bad$body), 1, 50)}'")
  invisible(list(
    good = paste0("HTTP ", good$status, " title='", .afdb_page_title(good$body),
                  "' counter='Displaying ", cnt$from, " - ", cnt$to, " of ", cnt$total, "' => PASS"),
    nonsense = paste0("HTTP ", bad$status, " title='", .afdb_page_title(bad$body),
                      "' => FAILS PCR expectation (correct)")))
}

# ── Helper: "Displaying 1 - N of M" counter ────────────────────────────────
afdb_parse_counter <- function(body) {
  m <- regmatches(body, regexpr("Displaying\\s+(\\d+)\\s*-\\s*(\\d+)\\s+of\\s+(\\d+)", body))
  if (!length(m)) return(NULL)
  parts <- strsplit(gsub("[^0-9 ]+", " ", m), "\\s+")[[1]]
  nums <- as.integer(parts[nzchar(parts)])
  list(from = nums[1], to = nums[2], total = nums[3])
}

# ── Helper: Parse document type from title suffix ─────────────────────────
#' AfDB titles embed doc type as " - PCR October 2025" or " - IPR novembre 2024"
parse_doc_type_from_title <- function(title) {
  if (is.na(title) || nchar(title) == 0) return(NA_character_)
  pattern <- "\\b(PPER|EER|PCREN|PCR|MTEv|MTEV|MTR|IPR|ISR|PAR|ESIA)\\b"
  m <- regmatches(title, regexpr(pattern, title, ignore.case = TRUE))
  if (length(m) == 0 || nchar(m) == 0) return(NA_character_)
  toupper(m)
}

# ── Helper: normalize a doc-type label/abbr to a canonical abbreviation ────
normalize_doc_type <- function(x) {
  if (is.na(x) || nchar(x) == 0) return(NA_character_)
  u <- toupper(x)
  if (u %in% c("PPER", "EER", "EVAL", "PCREN", "PCR", "MTR", "MTEV", AFDB_EXCLUDED_TYPES)) return(u)
  if (grepl("PERFORMANCE EVALUATION|PPER", u)) return("PPER")
  if (grepl("EVALUATION NOTE|PCR EVALUATION|COMPLETION REPORT REVIEW|VALIDATION", u)) return("PCREN")
  if (grepl("COMPLETION", u)) return("PCR")
  if (grepl("MID[- ]?TERM", u)) return("MTR")
  if (grepl("APPRAISAL", u)) return("PAR")
  if (grepl("EVALUATION", u)) return("EVAL")
  NA_character_
}

# ── Helper: Strip doc type suffix to get project name ────────────────────
extract_project_name <- function(title) {
  if (is.na(title) || nchar(title) == 0) return(NA_character_)
  pattern <- "\\s*-\\s*(PPER|EER|PCREN|PCR|MTEv|MTEV|MTR|IPR|ISR|PAR|ESIA)(\\s.*)?$"
  trimws(sub(pattern, "", title, ignore.case = TRUE))
}

# ── Helper: extract AfDB project code (P-XX-YYY-NNN) ───────────────────────
afdb_parse_project_code <- function(...) {
  txt <- paste(c(...), collapse = " ")
  m <- regmatches(txt, regexpr("P-[A-Za-z0-9]{2}-[A-Za-z0-9]{3}-\\d{3}", txt))
  if (length(m) == 0) return(NA_character_)
  toupper(m)
}

# ── Helper: best-effort document year (METADATA ONLY — never a filter) ─────
afdb_extract_year <- function(doc_date = NA, pdf_url = NA, title = NA) {
  pick <- function(x) {
    x <- as.character(x)[1]
    if (!is.na(x) && grepl("^(199[0-9]|20[0-2][0-9])$", x)) as.integer(x) else NA_integer_
  }
  # 1. ISO listing date
  if (!is.na(doc_date) && grepl("^\\d{4}-", doc_date))
    return(pick(substr(doc_date, 1, 4)))
  # 2. year in the PDF filename
  if (!is.na(pdf_url)) {
    m <- regmatches(pdf_url, gregexpr("(19|20)\\d{2}", basename(pdf_url)))[[1]]
    if (length(m)) return(pick(m[length(m)]))
    # 3. dated folder /files/YYYY-MM/ or /Evaluations/YYYY-MM/
    m2 <- regmatches(pdf_url, regexpr("/(files|Evaluations)/(19|20)\\d{2}-\\d{2}/", pdf_url))
    if (length(m2) && nchar(m2)) return(pick(substr(gsub("[^0-9]", "", m2), 1, 4)))
  }
  # 4. year in the title
  if (!is.na(title)) {
    m3 <- regmatches(title, gregexpr("(19|20)\\d{2}", title))[[1]]
    if (length(m3)) return(pick(m3[length(m3)]))
  }
  NA_integer_
}

# ── Helper: Parse a www.afdb.org document listing page ─────────────────────
#' Listing markup (confirmed live 2026-10): rows are the PARENTS of
#' .views-field-title; the publication date sits in a sibling
#' span.date-display-single whose @content attribute carries ISO 8601.
parse_afdb_listing <- function(page_html, category_label,
                               implied_type = NA_character_,
                               confirm_pattern = NULL) {
  if (is.null(page_html)) return(afdb_empty_rows())

  title_els <- tryCatch(
    rvest::html_elements(page_html, ".views-field-title"),
    error = function(e) list()
  )
  if (length(title_els) == 0) return(afdb_empty_rows())

  records <- purrr::map(title_els, function(t_el) {
    tryCatch({
      entry <- xml2::xml_parent(t_el)

      title_a <- rvest::html_element(t_el, "a")
      if (is.na(title_a)) return(NULL)
      title <- trimws(rvest::html_text2(title_a))
      href  <- rvest::html_attr(title_a, "href")
      if (is.na(title) || nchar(title) < 5) return(NULL)

      web_url <- if (!is.na(href)) {
        if (startsWith(href, "http")) href else paste0(AFDB_BASE, href)
      } else NA_character_

      date_el <- rvest::html_element(entry, "span.date-display-single")
      doc_date_iso <- NA_character_
      if (!is.na(date_el)) {
        iso <- rvest::html_attr(date_el, "content")
        if (!is.na(iso) && grepl("^\\d{4}-\\d{2}-\\d{2}", iso)) {
          doc_date_iso <- substr(iso, 1, 10)
        } else {
          parsed <- suppressWarnings(lubridate::dmy(trimws(rvest::html_text2(date_el)), quiet = TRUE))
          if (!is.na(parsed)) doc_date_iso <- format(parsed, "%Y-%m-%d")
        }
      }

      pdf_el  <- rvest::html_element(entry, "a[href$='.pdf'], a[href$='.PDF']")
      pdf_url <- if (!is.na(pdf_el)) {
        h <- rvest::html_attr(pdf_el, "href")
        if (!is.na(h)) { if (startsWith(h, "http")) h else paste0(AFDB_BASE, h) }
      } else NA_character_

      title_lower <- tolower(title)
      country <- NA_character_
      for (cn in AFRICA_COUNTRIES_EN) {
        if (grepl(tolower(cn), title_lower, fixed = TRUE)) { country <- cn; break }
      }

      dtype <- parse_doc_type_from_title(title)
      if (is.na(dtype) && !is.null(confirm_pattern) &&
          grepl(confirm_pattern, title_lower)) {
        dtype <- implied_type
      }

      tibble(
        id         = safe_filename(title),
        title      = title,
        pdf_url    = pdf_url,
        doc_date   = doc_date_iso,
        doc_type   = dtype,
        country    = country,
        project_id = afdb_parse_project_code(title, pdf_url, href),
        web_url    = web_url,
        listing    = category_label
      )
    }, error = function(e) NULL)
  })

  # NO per-page dedup here: the counter M counts VIEW ROWS, so the harvest
  # asserts raw rows == M and only then collapses duplicate URLs.
  out <- bind_rows(purrr::compact(records))
  attr(out, "n_title_elements") <- length(title_els)
  out
}

# ── Strategy A harvest: one category listing, counter-asserted ─────────────
harvest_afdb_listing <- function(cat) {
  cli::cli_h2("Listing: {cat$label}")
  sep <- if (grepl("\\?", cat$path)) "&" else "?"
  all_rows <- afdb_empty_rows()
  total <- NA_integer_

  for (page_num in 0:cat$max_pages) {
    url <- paste0(AFDB_BASE, cat$path, sep, "page=", page_num)
    res <- afdb_get(url)
    afdb_assert(res, url, cat$expect, on_fail = "stop")
    cnt <- afdb_parse_counter(res$body)
    if (is.null(cnt))
      stop("harvest (", cat$label, "): no 'Displaying 1 - N of M' counter on page ",
           page_num, " — refusing to harvest blind", call. = FALSE)
    if (is.na(total)) {
      total <- cnt$total
      cli::cli_alert_info("counter says M = {total} items ({cat$per_page}/page)")
    } else if (cnt$total != total) {
      stop("harvest (", cat$label, "): counter total changed mid-run (",
           total, " -> ", cnt$total, ") — listing shifted, rerun", call. = FALSE)
    }
    page_html <- afdb_html(res)
    rows <- parse_afdb_listing(page_html, cat$label, cat$implied, cat$confirm)
    n_el <- attr(rows, "n_title_elements") %||% nrow(rows)
    if (n_el != nrow(rows))
      cli::cli_alert_warning("  page {page_num}: {n_el} title elements but {nrow(rows)} parsed rows")
    if (nrow(rows) == 0) break
    all_rows <- bind_rows(all_rows, rows)
    cli::cli_alert_success("  page {page_num}: {nrow(rows)} rows (cumulative {nrow(all_rows)})")
    if (cnt$to >= cnt$total) break
  }

  # The counter counts VIEW ROWS, so the gate compares RAW harvested rows to M.
  n_raw <- nrow(all_rows)
  if (n_raw != total)
    stop("harvest (", cat$label, "): harvested rows (", n_raw,
         ") != counter M (", total, ") — FAILING LOUDLY as required", call. = FALSE)
  cli::cli_alert_success("{cat$label}: harvested rows == counter M == {total}")

  all_rows <- distinct(all_rows, web_url, .keep_all = TRUE)
  if (nrow(all_rows) != n_raw)
    cli::cli_alert_info("{cat$label}: {n_raw - nrow(all_rows)} duplicate URL(s) in the view collapsed -> {nrow(all_rows)} unique documents")
  attr(all_rows, "counter_total") <- total
  attr(all_rows, "n_raw") <- n_raw
  all_rows
}

# ── Strategy B: IDEV faceted search (Drupal 9/10 markup, 5/page) ───────────
idev_search_url <- function(category = "All", sector = "All", page = 0) {
  paste0(IDEV_SEARCH_URL,
         "?field_category_doc_target_id=", category,
         "&field_region_target_id=All",
         "&field_topic_target_id=All",
         "&field_sector_target_id=", sector,
         "&title=&page=", page)
}

#' Parse one IDEV search-result page (markup confirmed live 2026-10):
#' .views-row > .views-field-field-date (dd/mm/yyyy),
#' .views-field-field-document-type, .views-field-title a
#' (href /en/document/... — sometimes /index.php/en/...).
#' The canonical empty harvest result. Most of the 31 IDEV facet combinations
#' legitimately return "No results", and bind_rows() on an empty list yields a
#' ZERO-COLUMN tibble that blows up the next distinct(web_url) — so empty must
#' be typed, not just empty.
afdb_empty_rows <- function() {
  tibble(id = character(), title = character(), pdf_url = character(),
         doc_date = character(), doc_type = character(), country = character(),
         project_id = character(), web_url = character(), listing = character())
}

parse_idev_listing <- function(page_html, sweep_label) {
  if (is.null(page_html)) return(afdb_empty_rows())
  rows <- rvest::html_elements(page_html, ".views-row")
  records <- purrr::map(rows, function(row) {
    tryCatch({
      a <- rvest::html_element(row, ".views-field-title a, h3 a, h2 a")
      if (is.na(a)) return(NULL)
      title <- trimws(rvest::html_text2(a))
      href  <- rvest::html_attr(a, "href")
      if (is.na(title) || nchar(title) < 5 || is.na(href)) return(NULL)
      href <- sub("^/index\\.php", "", href)
      web_url <- if (startsWith(href, "http")) href else paste0(IDEV_BASE, href)

      date_el <- rvest::html_element(row, ".views-field-field-date .field-content")
      doc_date_iso <- NA_character_
      if (!is.na(date_el)) {
        parsed <- suppressWarnings(lubridate::dmy(trimws(rvest::html_text2(date_el)), quiet = TRUE))
        if (!is.na(parsed)) doc_date_iso <- format(parsed, "%Y-%m-%d")
      }

      cat_el <- rvest::html_element(row, ".views-field-field-document-type .field-content")
      category <- if (!is.na(cat_el)) trimws(rvest::html_text2(cat_el)) else NA_character_
      if (!is.na(category) && !nzchar(category)) category <- NA_character_

      title_lower <- tolower(title)
      country <- NA_character_
      for (cn in AFRICA_COUNTRIES_EN) {
        if (grepl(tolower(cn), title_lower, fixed = TRUE)) { country <- cn; break }
      }

      tibble(
        id         = safe_filename(title),
        title      = title,
        pdf_url    = NA_character_,
        doc_date   = doc_date_iso,
        doc_type   = category,
        country    = country,
        project_id = afdb_parse_project_code(title, href),
        web_url    = web_url,
        listing    = sweep_label
      )
    }, error = function(e) NULL)
  })
  recs <- purrr::compact(records)
  if (!length(recs)) return(afdb_empty_rows())
  bind_rows(recs) %>% distinct(web_url, .keep_all = TRUE)
}

#' One IDEV sweep. The search view echoes BOTH facet values back in its own
#' markup even on a zero-result page (verified live 2026-10), so the assertion
#' can demand them: that is what proves the facet was actually applied rather
#' than silently dropped.
harvest_idev_sweep <- function(sweep, quiet_empty = TRUE) {
  all_rows <- afdb_empty_rows()
  for (page_num in 0:IDEV_MAX_PAGES) {
    url <- idev_search_url(sweep$category, sweep$sector, page_num)
    res <- afdb_get(url)
    afdb_assert(res, url, list(
      title    = "IDEV|Document search",
      contains = c(paste0("field_sector_target_id=", sweep$sector),
                   paste0("field_category_doc_target_id=", sweep$category),
                   "search-doc|view-id-admin_views")
    ), on_fail = "stop")
    page_html <- afdb_html(res)
    rows <- parse_idev_listing(page_html, sweep$label)
    if (nrow(rows) == 0) break
    # the row's own document-type cell is sometimes empty; the sweep's own
    # category is then the authoritative label.
    if (!is.null(sweep$category_label) && !identical(sweep$category, "All"))
      rows$doc_type <- coalesce(rows$doc_type, sweep$category_label)
    if (nrow(all_rows) == 0) cli::cli_h3("{sweep$label}")
    all_rows <- bind_rows(all_rows, rows)
    cli::cli_alert_success("  page {page_num}: {nrow(rows)} rows (cumulative {nrow(all_rows)})")
    has_next <- length(rvest::html_elements(page_html, ".pager__item--next a")) > 0
    if (!has_next) break
  }
  if (nrow(all_rows) == 0 && !quiet_empty)
    cli::cli_alert_info("{sweep$label}: no results")
  distinct(all_rows, web_url, .keep_all = TRUE)
}

#' Run every sweep from build_idev_sweeps() and stack the results.
harvest_idev_all <- function(sweeps = build_idev_sweeps()) {
  cli::cli_h2("IDEV sweeps ({length(sweeps)} facet combinations)")
  out <- afdb_empty_rows()
  for (nm in names(sweeps)) {
    rows <- harvest_idev_sweep(sweeps[[nm]])
    if (nrow(rows)) out <- bind_rows(out, rows)
  }
  if (!nrow(out)) return(out)
  # a document can appear under several sweeps: keep the first (its
  # category-specific listing label) and record how many sweeps saw it.
  out %>% distinct(web_url, .keep_all = TRUE)
}

# ── PDF resolution from document pages ──────────────────────────────────────
.afdb_unescape <- function(x) gsub("&amp;", "&", x, fixed = TRUE)

#' www.afdb.org document page: the pdf.js iframe's ?file= parameter carries
#' the urlencoded direct URL, and the same /sites/default/files/...pdf URL
#' also appears plainly in the page source.
resolve_pdf_www <- function(res) {
  body <- res$body
  m <- regmatches(body, regexpr("viewer\\.html\\?file=[^\"'<> ]+", body))
  if (length(m)) {
    f <- utils::URLdecode(sub(".*file=", "", m))
    f <- sub("[&#].*$", "", f)
    if (grepl("\\.pdf$", f, ignore.case = TRUE))
      return(if (startsWith(f, "http")) f else paste0(AFDB_BASE, f))
  }
  mm <- unlist(regmatches(body, gregexpr(
    "(https?://www\\.afdb\\.org)?/sites/default/files/[^\"'<>[:space:]]+\\.pdf",
    body, ignore.case = TRUE)))
  mm <- unique(.afdb_unescape(mm))
  if (!length(mm)) return(NA_character_)
  docs <- mm[grepl("/documents/", mm)]
  f <- if (length(docs)) docs[1] else mm[1]
  if (startsWith(f, "http")) f else paste0(AFDB_BASE, f)
}

#' IDEV document page: plain hrefs to .pdf. Filter boilerplate (brochures,
#' flyers) and concept notes; prefer links sharing title tokens, then
#' English-looking names. Returns NA when the page has no report PDF
#' (ongoing evaluations expose only a concept note).
resolve_pdf_idev <- function(res, title) {
  body <- res$body

  # 1. STRUCTURAL: the primary document block (div.doc-viewed) wraps the cover
  #    thumbnail in a link to the main report PDF. Everything else on the page
  #    (concept note, approach paper, annexes, executive summary, lessons
  #    note, brochures) sits outside it. Confirmed live 2026-10.
  doc <- tryCatch(xml2::read_html(body), error = function(e) NULL)
  if (!is.null(doc)) {
    el <- rvest::html_element(doc, "div.doc-viewed a[href$='.pdf'], div.doc-viewed a[href$='.PDF']")
    if (!is.na(el)) {
      h <- rvest::html_attr(el, "href")
      if (!is.na(h) && nzchar(h))
        return(if (startsWith(h, "http")) h else paste0(IDEV_BASE, h))
    }
  }

  # 2. Fallback: score the page's PDF links by title-token overlap.
  hrefs <- unlist(regmatches(body, gregexpr("href=\"[^\"]+\\.pdf[^\"]*\"", body, ignore.case = TRUE)))
  hrefs <- unique(.afdb_unescape(sub("\"$", "", sub("^href=\"", "", hrefs))))
  if (!length(hrefs)) return(NA_character_)
  abs <- vapply(hrefs, function(h) if (startsWith(h, "http")) h else paste0(IDEV_BASE, h), "")
  dec <- vapply(abs, function(h) tryCatch(utils::URLdecode(h), error = function(e) h), "")
  keep <- !grepl(paste("brochure|flyer|newsletter|evaluation[ _-]?matters",
                       "evaluation[ _-]?week|concept[ _-]?note|approach[ _-]?paper",
                       "inception[ _-]?report|technical[ _-]?annex|lessons[ _-]?note",
                       sep = "|"),
                 dec, ignore.case = TRUE)
  abs <- abs[keep]; dec <- dec[keep]
  if (!length(abs)) return(NA_character_)
  toks <- unique(strsplit(gsub("[^a-z0-9]+", " ", tolower(title)), " ")[[1]])
  toks <- toks[nchar(toks) > 3]
  score <- vapply(seq_along(abs), function(i) {
    base <- tolower(basename(dec[i]))
    s <- sum(vapply(toks, function(t) grepl(t, base, fixed = TRUE), logical(1)))
    if (grepl("summary|report|evaluation|synthesis|cluster|idev", base)) s <- s + 1
    if (grepl("(^|[_ .-])fr([_ .-]|$)|french|francais", base)) s <- s - 2
    s
  }, numeric(1))
  abs[order(-score)][1]
}

# ── Holdings: disk inventory + normalised-title matching ───────────────────
.afdb_norm_key <- function(x) {
  x <- iconv(as.character(x), to = "ASCII//TRANSLIT", sub = " ")
  x <- tolower(x)
  trimws(gsub("[^a-z0-9]+", " ", x))
}

#' The naming convention used by the previous runs and mimicked here:
#'   afdb_{TYPE}_{safe_filename(substr(project_name, 1, 60))}_{year}.pdf
#' truncated so the stem is at most 100 chars (total path stays < 240).
afdb_name_part <- function(title) {
  safe_filename(substr(coalesce(extract_project_name(title), title, "notitle"), 1, 60))
}

afdb_build_filename <- function(doc_type, title, year) {
  year_str <- if (!is.na(year)) as.character(year) else "XXXX"
  type_str <- coalesce(doc_type, "DOC")
  paste0(substr(glue("{SOURCE_NAME}_{type_str}_{afdb_name_part(title)}_{year_str}"),
                1, 100), ".pdf")
}

afdb_disk_inventory <- function() {
  files <- list.files(CORPUS_AFDB, pattern = "\\.pdf$", recursive = TRUE,
                      full.names = TRUE, ignore.case = TRUE)
  if (!length(files)) {
    return(tibble(path = character(), basename = character(), norm = character()))
  }
  stem <- sub("\\.pdf$", "", basename(files), ignore.case = TRUE)
  name_part <- sub("_([0-9]{4}|XXXX)$", "", sub("^afdb_[A-Za-z]+_", "", stem))
  tibble(path = files, basename = basename(files), norm = .afdb_norm_key(name_part))
}

#' Match a title (and optionally its deterministic filename) against the disk
#' inventory. Returns the matched basename or NA.
afdb_find_held <- function(disk, title, fname = NULL) {
  if (!is.null(fname) && fname %in% disk$basename) return(fname)
  key <- .afdb_norm_key(afdb_name_part(title))
  if (!nzchar(key)) return(NA_character_)
  hit <- which(disk$norm == key)
  if (!length(hit)) {
    # the disk names are 60-char truncations: allow prefix matches both ways
    hit <- which(nchar(disk$norm) >= 25 & startsWith(key, disk$norm))
  }
  if (!length(hit)) {
    hit <- which(nchar(key) >= 25 & startsWith(disk$norm, key))
  }
  if (length(hit)) disk$basename[hit[1]] else NA_character_
}

# ── Ledger helpers ──────────────────────────────────────────────────────────
.afdb_is_2026 <- function(doc_date, year) {
  grepl("\\b2026\\b", paste(coalesce(doc_date, ""), coalesce(as.character(year), "")))
}

afdb_ledger_row <- function(site_id, title, doc_type_site, listing,
                            disposition, local_filename = NA_character_,
                            notes = NA_character_) {
  tibble(source = SOURCE_NAME, site_id = as.character(site_id),
         title = as.character(title), doc_type_site = as.character(doc_type_site),
         listing = as.character(listing), discovered_at = NA_character_,
         disposition = disposition,
         local_filename = as.character(local_filename),
         notes = as.character(notes))
}

#' Fetch one document: resolve the direct PDF from its document page, then
#' download with validation. Returns a ledger row. `resolver` is
#' resolve_pdf_www or a closure over resolve_pdf_idev.
#' A hit against a file THIS RUN downloaded is not a pre-existing holding: the
#' site listed the same document twice (IDEV does this under distinct URLs), so
#' the ledger must say `duplicate`, not `already_held`.
.afdb_held_disposition <- function(state, held) {
  if (held %in% state$new_files) "duplicate" else "already_held"
}
.afdb_held_note <- function(state, held) {
  if (held %in% state$new_files)
    "same document already fetched this run under another listing URL"
  else "matched on disk by name/normalised title"
}

afdb_fetch_document <- function(state, web_url, title, doc_type, doc_date, year,
                                listing_label, host = c("www", "idev"),
                                no_pdf_disposition = "failed_download",
                                no_pdf_note = "no direct PDF link on document page") {
  host <- match.arg(host)
  fname <- afdb_build_filename(doc_type, title, year)
  dest  <- file.path(DOWNLOAD_DIR, fname)

  held <- afdb_find_held(state$disk, title, fname)
  if (!is.na(held)) {
    log_download(SOURCE_NAME, NA, doc_type, title, web_url, held,
                 "skipped", "already held on disk")
    return(afdb_ledger_row(web_url, title, doc_type, listing_label,
                           .afdb_held_disposition(state, held), held,
                           .afdb_held_note(state, held)))
  }

  res <- afdb_get(web_url)
  if (is.null(res) || is.na(res$status) || res$status != 200) {
    why <- paste0("document page HTTP ", res$status %||% NA)
    log_download(SOURCE_NAME, NA, doc_type, title, web_url, NA, "failed", why)
    return(afdb_ledger_row(web_url, title, doc_type, listing_label,
                           "failed_download", NA, why))
  }
  pdf_url <- if (host == "www") resolve_pdf_www(res) else resolve_pdf_idev(res, title)
  if (is.na(pdf_url)) {
    log_download(SOURCE_NAME, NA, doc_type, title, web_url, NA, "failed", no_pdf_note)
    return(afdb_ledger_row(web_url, title, doc_type, listing_label,
                           no_pdf_disposition, NA, no_pdf_note))
  }
  # year may only now be recoverable from the pdf filename (metadata only)
  if (is.na(year)) {
    year <- afdb_extract_year(doc_date, pdf_url, title)
    fname <- afdb_build_filename(doc_type, title, year)
    dest  <- file.path(DOWNLOAD_DIR, fname)
    held <- afdb_find_held(state$disk, title, fname)
    if (!is.na(held)) {
      log_download(SOURCE_NAME, NA, doc_type, title, web_url, held,
                   "skipped", "already held on disk")
      return(afdb_ledger_row(web_url, title, doc_type, listing_label,
                             .afdb_held_disposition(state, held), held,
                             .afdb_held_note(state, held)))
    }
  }

  status <- afdb_download(pdf_url, dest)
  if (identical(status, "skipped")) {
    log_download(SOURCE_NAME, NA, doc_type, title, pdf_url, dest, "skipped",
                 "destination already exists")
    return(afdb_ledger_row(web_url, title, doc_type, listing_label,
                           .afdb_held_disposition(state, fname), fname,
                           .afdb_held_note(state, fname)))
  }
  if (isTRUE(status)) {
    state$new_files <- c(state$new_files, fname)
    state$disk <- bind_rows(state$disk, tibble(
      path = dest, basename = fname,
      norm = .afdb_norm_key(sub("_([0-9]{4}|XXXX)$", "",
                                sub("^afdb_[A-Za-z]+_", "", sub("\\.pdf$", "", fname))))))
    log_download(SOURCE_NAME, NA, doc_type, title, pdf_url, dest, "success",
                 paste0("validated %PDF- magic + size; from ", listing_label))
    disp <- if (.afdb_is_2026(doc_date, year)) "held_pending_window_decision" else "fetched"
    return(afdb_ledger_row(web_url, title, doc_type, listing_label, disp, fname,
                           paste0("pdf: ", pdf_url)))
  }
  log_download(SOURCE_NAME, NA, doc_type, title, pdf_url, dest, "failed",
               "download or %PDF-/size validation failed")
  afdb_ledger_row(web_url, title, doc_type, listing_label, "failed_download", NA,
                  paste0("download/validation failed for ", pdf_url))
}

# ── CIF handoff (optional file written by another agent) ────────────────────
#' Country names as they actually appear in AfDB PCR titles.
.afdb_country_alias <- function(country) {
  if (is.na(country) || !nzchar(country)) return(character(0))
  c0 <- tolower(trimws(country))
  extra <- switch(c0,
    "democratic republic of congo" = c("drc", "dr congo", "rdc", "congo"),
    "cote d'ivoire"                = c("cote d ivoire", "ivory coast"),
    "cabo verde"                   = c("cape verde"),
    "eswatini"                     = c("swaziland"),
    "tanzania"                     = c("united republic of tanzania"),
    character(0))
  unique(c(c0, extra))
}

#' Word-boundary country test against ALREADY NORMALISED title keys.
#' Returns all TRUE when no country is supplied (no evidence, no filter).
.afdb_country_hits <- function(norm_titles, country) {
  al <- .afdb_country_alias(country)
  if (!length(al)) return(rep(TRUE, length(norm_titles)))
  hits <- rep(FALSE, length(norm_titles))
  for (a in al) {
    k <- .afdb_norm_key(a)
    if (!nzchar(k)) next
    hits <- hits | grepl(paste0("\\b", k, "\\b"), norm_titles)
  }
  hits
}

afdb_process_cif_handoff <- function(state, pcr_catalogue) {
  if (!file.exists(CIF_HANDOFF_CSV)) {
    cli::cli_alert_info("CIF handoff file not present ({CIF_HANDOFF_CSV}) — orchestrator runs a second mini-pass")
    return(list(rows = tibble(), covered = tibble(), present = FALSE))
  }
  handoff <- tryCatch(readr::read_csv(CIF_HANDOFF_CSV, show_col_types = FALSE,
                                      col_types = readr::cols(.default = "c")),
                      error = function(e) NULL)
  if (is.null(handoff) || !nrow(handoff)) return(list(rows = tibble(), covered = tibble(), present = TRUE))
  mdb_col <- intersect(c("mdb", "MDB", "bank", "institution"), names(handoff))[1]
  if (is.na(mdb_col)) {
    cli::cli_alert_warning("CIF handoff: no mdb column found; columns: {paste(names(handoff), collapse=', ')}")
    return(list(rows = tibble(), covered = tibble(), present = TRUE))
  }
  afdb_rows <- handoff[grepl("African Development Bank", handoff[[mdb_col]], ignore.case = TRUE), ]
  if (!nrow(afdb_rows)) return(list(rows = tibble(), covered = tibble(), present = TRUE))
  title_col <- intersect(c("title", "project_title", "project", "name"), names(afdb_rows))[1]
  country_col <- intersect(c("country", "countries"), names(afdb_rows))[1]
  cli::cli_h2("CIF handoff: {nrow(afdb_rows)} AfDB rows")

  cat_keys <- .afdb_norm_key(pcr_catalogue$title)
  ctry_keys <- cat_keys
  ledger <- tibble(); covered <- tibble()
  for (i in seq_len(nrow(afdb_rows))) {
    h_title <- if (!is.na(title_col)) afdb_rows[[title_col]][i] else NA_character_
    h_country <- if (!is.na(country_col)) afdb_rows[[country_col]][i] else NA_character_
    if (is.na(h_title)) next
    toks <- strsplit(.afdb_norm_key(h_title), " ")[[1]]
    toks <- toks[nchar(toks) > 3]
    if (!length(toks)) next
    overlap <- vapply(cat_keys, function(k)
      sum(vapply(toks, function(t) grepl(paste0("\\b", t, "\\b"), k), logical(1))) / length(toks),
      numeric(1))
    # Country agreement on WORD BOUNDARIES of the normalised title: a plain
    # substring test makes "Niger" match every "Nigeria" PCR.
    ctry <- .afdb_country_hits(ctry_keys, h_country)
    # A country-confirmed 0.5 beats an uncorroborated 0.6: the CIF project
    # name and the AfDB PCR title are independently worded, so requiring 0.6
    # of tokens with no country check both misses real matches (Ghana REDD+,
    # 0.57) and admits wrong-country ones.
    cand <- which((ctry & overlap >= 0.5) | overlap >= 0.85)
    if (length(cand) > 1) {
      # prefer country agreement, then an English title over its French
      # twin (AfDB publishes both), then the strongest overlap
      eng <- !grepl("\\b(projet|rapport|achevement|dans|bassins|programme de)\\b",
                    cat_keys[cand])
      cand <- cand[order(-as.integer(ctry[cand]), -as.integer(eng), -overlap[cand])]
    }
    matched <- length(cand) > 0
    covered <- bind_rows(covered, tibble(handoff_title = h_title,
                                         handoff_country = h_country %||% NA_character_,
                                         matched = matched,
                                         best_overlap = round(max(overlap), 2),
                                         n_candidates = length(cand),
                                         matched_title = if (matched) pcr_catalogue$title[cand[1]] else NA_character_,
                                         matched_url = if (matched) pcr_catalogue$web_url[cand[1]] else NA_character_))
    if (matched) {
      r <- pcr_catalogue[cand[1], ]
      if (!r$web_url %in% state$seen) {
        state$seen <- c(state$seen, r$web_url)
        row <- afdb_fetch_document(state, r$web_url, r$title, coalesce(r$doc_type, "PCR"),
                                   r$doc_date, r$year, "CIF handoff (PCR catalogue match)",
                                   host = "www")
        ledger <- bind_rows(ledger, row)
      }
    }
  }
  list(rows = ledger, covered = covered, present = TRUE)
}

# ── Main campaign ───────────────────────────────────────────────────────────
run_afdb_campaign <- function() {
  cli::cli_h1("AfDB corpus-completion campaign (2026-10)")
  cli::cli_alert_info("Corpus dir: {CORPUS_AFDB}")
  cli::cli_alert_info("Download dir: {DOWNLOAD_DIR}")

  if (!file.exists(IDEV_TAXONOMY_CSV))
    stop("IDEV taxonomy file missing: ", IDEV_TAXONOMY_CSV, call. = FALSE)

  # mutable campaign state (disk inventory grows as we download)
  state <- new.env(parent = emptyenv())
  state$disk <- afdb_disk_inventory()
  state$seen <- character(0)
  state$new_files <- character(0)   # basenames written by THIS run
  n_disk_initial <- nrow(state$disk)
  cli::cli_alert_info("{n_disk_initial} PDFs already on disk under {CORPUS_AFDB}")

  # Step 1: canary — abort if the wildcard view is indistinguishable
  canary <- afdb_canary()

  # Step 2: PCR listing — rebuild the full catalogue, counter-asserted
  pcr_cat <- harvest_afdb_listing(AFDB_CATEGORY_LISTINGS$pcr)
  pcr_m <- attr(pcr_cat, "counter_total")
  pcr_cat <- pcr_cat %>%
    rowwise() %>%
    mutate(year = afdb_extract_year(doc_date, pdf_url, title)) %>%
    ungroup()
  readr::write_csv(pcr_cat, file.path(CATALOGUE_DIR, "afdb_pcr_catalogue.csv"))
  cli::cli_alert_success("PCR catalogue written: {nrow(pcr_cat)} rows (counter M = {pcr_m})")

  # Step 3: agriculture facet — counter-asserted (~77)
  agri_cat <- harvest_afdb_listing(AFDB_CATEGORY_LISTINGS$agri_eval)
  agri_m <- attr(agri_cat, "counter_total")
  agri_cat <- agri_cat %>%
    rowwise() %>%
    mutate(year = afdb_extract_year(doc_date, pdf_url, title)) %>%
    ungroup()
  readr::write_csv(agri_cat, file.path(CATALOGUE_DIR, "afdb_agri_facet_catalogue.csv"))
  cli::cli_alert_success("Agriculture facet catalogue written: {nrow(agri_cat)} rows (counter M = {agri_m})")

  # Step 4: IDEV sweeps — sector 106 across every taxonomy category, plus the
  # validation-synthesis category across all sectors.
  idev_all <- harvest_idev_all()
  if (nrow(idev_all) == 0)
    stop("IDEV sweep returned 0 rows across every facet combination — the ",
         "search view changed; refusing to report an empty sweep as complete",
         call. = FALSE)
  idev_all <- idev_all %>%
    rowwise() %>%
    mutate(year = afdb_extract_year(doc_date, pdf_url, title)) %>%
    ungroup()
  n_idev_agri <- sum(grepl("sector=106", idev_all$listing, fixed = TRUE))
  n_idev_vs   <- sum(grepl(paste0("category=", IDEV_VALIDATION_CATEGORY),
                           idev_all$listing, fixed = TRUE))
  readr::write_csv(idev_all, file.path(CATALOGUE_DIR, "afdb_idev_sweep_catalogue.csv"))
  cli::cli_alert_success("IDEV sweep catalogue written: {nrow(idev_all)} unique docs ({n_idev_agri} from sector=106 sweeps, {n_idev_vs} validation syntheses)")

  ledger <- list()
  fetch_abort <- NA_character_
  audit_ids <- character(0)

  # Steps 5-8 do the network fetching and are the only steps that can die on a
  # refusal. They are wrapped so that a failure part-way through still falls
  # through to the disk-residue pass and the attestation write: a partial
  # ledger that records what actually happened is worth far more than no
  # ledger at all. The abort reason is recorded and re-reported in the gate
  # summary so a truncated run can never be mistaken for a complete one.
  .snapshot <- function(tag) {
    if (!length(ledger)) return(invisible(NULL))
    readr::write_csv(bind_rows(ledger),
                     file.path(CATALOGUE_DIR, "afdb_ledger_partial.csv"))
    cli::cli_alert_info("ledger snapshot after {tag}: {length(ledger)} rows")
  }

  fetch_abort <- tryCatch({

  # Step 5: dispositions for the 77 agriculture-facet rows (fetch gaps)
  cli::cli_h2("Agriculture facet dispositions")
  for (i in seq_len(nrow(agri_cat))) {
    r <- agri_cat[i, ]
    if (r$web_url %in% state$seen) next
    state$seen <- c(state$seen, r$web_url)
    dtype_norm <- normalize_doc_type(coalesce(r$doc_type, ""))
    if (!is.na(dtype_norm) && dtype_norm %in% AFDB_EXCLUDED_TYPES) {
      ledger[[length(ledger) + 1]] <- afdb_ledger_row(
        r$web_url, r$title, r$doc_type, r$listing, "out_by_type",
        notes = paste0("type ", dtype_norm, " is out of scope (proposal/safeguard/progress)"))
      next
    }
    ledger[[length(ledger) + 1]] <- tryCatch(
      afdb_fetch_document(state, r$web_url, r$title, r$doc_type, r$doc_date,
                          r$year, r$listing, host = "www"),
      error = function(e) {
        if (grepl("5-minute pause", conditionMessage(e))) stop(e)
        afdb_ledger_row(r$web_url, r$title, r$doc_type, r$listing,
                        "failed_download", NA, paste0("error: ", conditionMessage(e)))
      })
  }

  .snapshot("agriculture facet")

  # Step 6: the 43 audit PCRs
  cli::cli_h2("Audit: missing agriculture PCRs")
  audit <- readr::read_csv(AUDIT_MISSING_PCRS, show_col_types = FALSE,
                           col_types = readr::cols(.default = "c"))
  n_audit <- nrow(audit)
  for (i in seq_len(n_audit)) {
    a <- audit[i, ]
    audit_ids <- c(audit_ids, a$url)
    if (a$url %in% state$seen) next
    state$seen <- c(state$seen, a$url)
    dtype <- coalesce(parse_doc_type_from_title(a$title), "PCR")
    year  <- afdb_extract_year(a$date, NA, a$title)
    ledger[[length(ledger) + 1]] <- tryCatch(
      afdb_fetch_document(state, a$url, a$title, dtype, a$date, year,
                          "audit/afdb_missing_pcrs.csv (PCR listing)", host = "www"),
      error = function(e) {
        if (grepl("5-minute pause", conditionMessage(e))) stop(e)
        afdb_ledger_row(a$url, a$title, dtype, "audit/afdb_missing_pcrs.csv (PCR listing)",
                        "failed_download", NA, paste0("error: ", conditionMessage(e)))
      })
  }

  .snapshot("audit PCRs")

  # Step 7: IDEV dispositions (validation syntheses excluded, gaps fetched)
  cli::cli_h2("IDEV dispositions")
  for (i in seq_len(nrow(idev_all))) {
    r <- idev_all[i, ]
    if (r$web_url %in% state$seen) next
    state$seen <- c(state$seen, r$web_url)
    cat_label <- coalesce(r$doc_type, "")
    is_vs <- grepl(IDEV_VALIDATION_PATTERN, cat_label, ignore.case = TRUE) ||
      grepl(IDEV_VALIDATION_PATTERN, r$title, ignore.case = TRUE) ||
      grepl("category=186", r$listing, fixed = TRUE)
    if (is_vs) {
      ledger[[length(ledger) + 1]] <- afdb_ledger_row(
        r$web_url, r$title, coalesce(r$doc_type, "PCR & XSR Validation synthesis"),
        r$listing, "excluded_desk_review",
        notes = "USER DECISION: validation syntheses are desk reviews — excluded, not downloaded")
      next
    }
    in_scope_cat <- is.na(r$doc_type) ||
      grepl(IDEV_RELEVANT_CATEGORIES, cat_label, ignore.case = TRUE)
    if (!in_scope_cat) {
      ledger[[length(ledger) + 1]] <- afdb_ledger_row(
        r$web_url, r$title, r$doc_type, r$listing, "out_by_type",
        notes = paste0("IDEV category '", cat_label, "' not an evaluation product"))
      next
    }
    held <- afdb_find_held(state$disk, r$title)
    if (!is.na(held)) {
      ledger[[length(ledger) + 1]] <- afdb_ledger_row(
        r$web_url, r$title, r$doc_type, r$listing, "already_held", held,
        "matched on disk by normalised title")
      next
    }
    ledger[[length(ledger) + 1]] <- tryCatch(
      afdb_fetch_document(state, r$web_url, r$title, "EVAL", r$doc_date, r$year,
                          r$listing, host = "idev",
                          no_pdf_disposition = "out_by_type",
                          no_pdf_note = "no report PDF on IDEV document page (ongoing evaluation or landing page only)"),
      error = function(e) {
        if (grepl("5-minute pause", conditionMessage(e))) stop(e)
        afdb_ledger_row(r$web_url, r$title, r$doc_type, r$listing,
                        "failed_download", NA, paste0("error: ", conditionMessage(e)))
      })
  }

  .snapshot("IDEV dispositions")

  # Step 8: CIF handoff
  cif <- afdb_process_cif_handoff(state, pcr_cat)
  if (nrow(cif$rows)) for (i in seq_len(nrow(cif$rows))) ledger[[length(ledger) + 1]] <- cif$rows[i, ]
  if (nrow(cif$covered))
    readr::write_csv(cif$covered, file.path(CATALOGUE_DIR, "afdb_cif_handoff_coverage.csv"))
  .snapshot("CIF handoff")
  NA_character_
  }, error = function(e) {
    cli::cli_alert_danger("FETCH PHASE ABORTED: {conditionMessage(e)}")
    cli::cli_alert_warning("writing the ledger with what was completed so far")
    conditionMessage(e)
  })
  if (!exists("cif", inherits = FALSE))
    cif <- list(rows = afdb_empty_rows(), covered = tibble(), present = file.exists(CIF_HANDOFF_CSV))

  # Step 9: files already on disk not covered above -> already_held rows.
  # site_id = source URL from the metadata catalogue where known, else filename.
  cli::cli_h2("Disk residue")
  ledger_df <- bind_rows(ledger)
  covered_files <- unique(na.omit(ledger_df$local_filename))
  meta <- tryCatch(readr::read_csv(AFDB_METADATA_CSV, show_col_types = FALSE,
                                   col_types = readr::cols(.default = "c")),
                   error = function(e) NULL)
  meta_key <- if (!is.null(meta)) .afdb_norm_key(vapply(meta$title, afdb_name_part, "")) else character(0)
  disk_now <- afdb_disk_inventory()
  residue <- disk_now[!disk_now$basename %in% covered_files, ]
  for (i in seq_len(nrow(residue))) {
    d <- residue[i, ]
    site_id <- d$basename
    m_title <- NA_character_
    if (length(meta_key)) {
      j <- which(meta_key == d$norm)
      if (length(j) && !is.na(meta$web_url[j[1]]) && nzchar(meta$web_url[j[1]])) {
        site_id <- meta$web_url[j[1]]
        m_title <- meta$title[j[1]]
      }
    }
    if (site_id %in% state$seen) next
    state$seen <- c(state$seen, site_id)
    ledger[[length(ledger) + 1]] <- afdb_ledger_row(
      site_id, coalesce(m_title, d$basename), NA_character_,
      "disk inventory (03_Documents/afdb)", "already_held", d$basename,
      if (identical(site_id, d$basename)) "no source URL in afdb_metadata.csv; filename used as site_id"
      else "source URL matched via afdb_metadata.csv")
  }

  # Step 10: write the attestation ledger
  ledger_df <- bind_rows(ledger) %>% distinct(site_id, .keep_all = TRUE)
  stopifnot(!any(is.na(ledger_df$disposition) | ledger_df$disposition == ""))
  write_attestation(SOURCE_NAME, ledger_df)

  # Step 11: gate summary
  cli::cli_h1("GATE SUMMARY")
  if (!is.na(fetch_abort)) {
    cli::cli_alert_danger("RUN INCOMPLETE — fetch phase aborted: {fetch_abort}")
    cli::cli_alert_danger("the ledger below covers only what completed before the abort")
  } else {
    cli::cli_alert_success("fetch phase completed without abort")
  }
  cli::cli_alert_info("canary good: {canary$good}")
  cli::cli_alert_info("canary nonsense: {canary$nonsense}")
  # The ASSERTED quantity is raw view rows vs M; the unique count is lower
  # because both AfDB views emit the same document on several rows. Report
  # both so "harvested == M" is never read as "we hold M documents".
  cli::cli_alert_info(
    "PCR listing: raw rows {attr(pcr_cat, 'n_raw')} == counter M {pcr_m} (ASSERTED); {nrow(pcr_cat)} unique documents")
  cli::cli_alert_info(
    "Agriculture facet: raw rows {attr(agri_cat, 'n_raw')} == counter M {agri_m} (ASSERTED); {nrow(agri_cat)} unique documents")

  audit_rows <- ledger_df %>% filter(site_id %in% audit_ids)
  cli::cli_alert_info(paste0(
    "Audit 43: ", nrow(audit_rows), " dispositioned — ",
    paste(capture.output(print(table(audit_rows$disposition))), collapse = " | ")))

  idev_rows <- ledger_df %>% filter(grepl("^IDEV", listing))
  cli::cli_alert_info(paste0(
    "IDEV rows: ", nrow(idev_rows), " — ",
    paste(capture.output(print(table(idev_rows$disposition))), collapse = " | ")))
  n_vs <- sum(ledger_df$disposition == "excluded_desk_review")
  cli::cli_alert_info("Validation syntheses excluded_desk_review rows: {n_vs} (downloads: 0 by construction)")

  disp_tab <- table(ledger_df$disposition)
  for (d in names(disp_tab)) cli::cli_text("  {d}: {disp_tab[[d]]}")
  cli::cli_alert_info("CIF handoff present: {cif$present}; matched rows: {if (nrow(cif$covered)) sum(cif$covered$matched) else 0} of {nrow(cif$covered)}")

  n_new <- nrow(afdb_disk_inventory()) - n_disk_initial
  cli::cli_alert_success("New files on disk this run: {n_new}")
  cli::cli_h2("Done")
  invisible(list(ledger = ledger_df, pcr = pcr_cat, agri = agri_cat,
                 idev = idev_all, canary = canary, cif = cif))
}

# Run ONLY when this file is the script Rscript was pointed at, so that other
# modules can source() it for its functions without triggering a scrape. (The
# previous guard `sys.nframe() == 0 || !interactive()` fired on EVERY
# non-interactive source() — same bug gef.R fixed with .gef_is_main.)
#
#   Rscript R/01_retrieve/afdb.R         # full campaign
#   AFDB_MODE=canary Rscript R/01_retrieve/afdb.R
.afdb_is_main <- local({
  fa <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  length(fa) > 0 && identical(tolower(basename(sub("^--file=", "", fa[1]))), "afdb.r")
})
if (.afdb_is_main) {
  # Every arm is wrapped in invisible() and the block ends in invisible(NULL):
  # the campaign returns catalogues and a ledger for interactive use, and
  # letting that value reach the top level of an Rscript run only risks an
  # auto-print failure AFTER all the work is safely on disk.
  switch(Sys.getenv("AFDB_MODE", "campaign"),
    load   = invisible(NULL),   # source functions only, no run
    canary = invisible(afdb_canary()),
    invisible(run_afdb_campaign())
  )
  invisible(NULL)
}
