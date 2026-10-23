##############################################################################
# worldbank.R — World Bank Documents & Reports API Scraper
#
# Targets: EVALUATION documents only (scope decision 2026-07-17):
#          Implementation Completion and Results Reports (ICRs) and
#          Project Performance Assessment Reports (PPARs),
#          2015+, Africa agriculture/adaptation.
#
# API docs: https://documents.worldbank.org/en/publication/documents-reports/api
# Base URL: https://search.worldbank.org/api/v3/wds
#
# Server-side filters (verified live 2026-07-21):
#   docty_exact    — evaluation document types only
#   count_exact    — each African country
#   teratopic_exact— WB's own topic classification ("Agriculture") — catches
#                    agriculture projects regardless of title wording
#   strdate        — document date floor 2015-01-01
#
# Strategy:
#   1. Query docty × African country × Agriculture topic, date >= 2015
#   2. Keyword queries (date-filtered) as a recall net for adaptation docs
#      not topic-tagged Agriculture
#   3. Deduplicate by document ID; relevance screen; drop budget-support
#      instruments (DPO/DPF/PRSC — policy lending, nothing implemented)
#   4. Download PDFs from documents1.worldbank.org with a browser UA
#      (documents.worldbank.org returns 403 to non-browser clients)
#
# Run modes via env var WB_MODE:
#   probe | capped | gapfill | load | full (default)
#   gapfill — completeness audit 2026-10: derive the gap LIVE from the API,
#             subtract what is on disk under 03_Documents/Worldbank, fetch
#             only the remainder into Docs/to_screen, and attest every listed
#             Africa document (see the GAP-FILL STAGE section below).
##############################################################################

# ── Setup ──────────────────────────────────────────────────────────────────
# Find and source config + utils. Works with Rscript, source(), and interactive R.
.find_r_dir <- function() {
  # returns the directory containing this script (the R/ folder)
  tryCatch({
    d <- dirname(sys.frame(2)$ofile)
    if (!is.null(d) && nzchar(d)) return(normalizePath(d, mustWork = FALSE))
  }, error = function(e) NULL)
  # Try commandArgs (works with Rscript)
  tryCatch({
    args <- commandArgs(trailingOnly = FALSE)
    fa <- grep("^--file=", args, value = TRUE)
    if (length(fa)) return(normalizePath(dirname(sub("^--file=", "", fa[1])), mustWork = FALSE))
  }, error = function(e) NULL)
  # Fall back to working directory
  wd <- getwd()
  if (file.exists(file.path(wd, "R", "00_shared", "00_config.R"))) return(file.path(wd, "R", "00_shared"))
  if (file.exists(file.path(wd, "00_config.R"))) return(wd)
  return(wd)
}
if (!exists("PATHS")) {
  .r_dir <- .find_r_dir()
  for (.p in file.path(.r_dir, c(".", "..", "../00_shared", "00_shared", "R/00_shared"), "00_config.R")) if (file.exists(.p)) { source(.p); break }
  for (.p in file.path(.r_dir, c(".", "..", "../00_shared", "00_shared", "R/00_shared"), "01_utils.R")) if (file.exists(.p)) { source(.p); break }
}

DOWNLOAD_DIR <- file.path(PATHS$downloads, "worldbank")
dir.create(DOWNLOAD_DIR, recursive = TRUE, showWarnings = FALSE)

SOURCE_NAME <- "worldbank"

# ── World Bank API Configuration ───────────────────────────────────────────
WB_API_BASE <- "https://search.worldbank.org/api/v3/wds"

# Document types to search (exact match values for docty_exact).
# Verified live against the docty_exact facet index 2026-10-02:
#   "Implementation Completion and Results Report" -> 8,617 docs
#   "Project Performance Assessment Report"        -> 2,648 docs (IEG full
#       independent field evaluations - in scope)
# Two strings previously listed here are NOT facet values and made the API
# answer HTTP 200 + total=0 silently for every query built on them:
#   "Implementation Completion Report"      (0 docs) - REMOVED. Its nearest
#       real facet, "Implementation Completion Report Review", is an IEG
#       desk review and is deliberately NOT added here: desk reviews are
#       excluded by team decision 2026-10-02.
#   "Project Performance Assessment Review" (0 docs) - replaced by the
#       correct facet label "Project Performance Assessment Report".
WB_DOC_TYPES <- c(
  "Implementation Completion and Results Report",
  "Project Performance Assessment Report"
)

# Page size for API listing pagination (kept modest on purpose)
WB_ROWS <- 50L

# Fields to return in API response (teratopic = WB's own topic
# classification, used as keep/drop evidence in filter_relevant).
# `projectid` added 2026-10-02: it is the only clean P-code field. `projn`
# is the project NAME with the code appended after " -- ", which is where the
# legacy filenames got their codes from; it is kept because filter_relevant
# reads it as keyword evidence. On documents covering several projects
# (typical for PPARs) `projectid` is comma-separated, e.g. "P082396,P109683".
WB_FIELDS <- paste(
  "id", "display_title", "pdfurl", "docdt", "docty", "count",
  "repnme", "projn", "projectid", "abstracts", "lang_exact", "url", "teratopic",
  sep = ","
)

# Keyword search queries (used for broader matching)
WB_KEYWORD_QUERIES <- c(
  "agriculture adaptation climate Africa",
  "climate resilience agriculture Africa",
  "climate smart agriculture Africa",
  "food security climate change Africa",
  "irrigation climate adaptation Africa",
  "livestock resilience Africa drought",
  "agricultural development climate Africa"
)

# ── Scope filters (team decision 2026-07-17) ───────────────────────────────
# Document date floor — applied CLIENT-SIDE on docdt. The API's strdate
# param is unreliable in combination with teratopic_exact/count_exact
# (verified 2026-07-21: Kenya+topic+strdate returns 0 despite matching
# docs existing). No ceiling: evaluations of 2015-2025 activity keep
# being published.
WB_MIN_YEAR <- 2015L

# WB topic classification used as KEEP EVIDENCE (not as a query filter:
# topic coverage is incomplete on recent documents — using it server-side
# verifiably loses in-scope projects, e.g. Uganda ACDP 2024, TerrAfrica).
# A document is kept if its topics include this OR its title matches
# agriculture/adaptation keywords.
WB_TOPICS <- c("Agriculture")

# Regional/global 'count' values: multi-country projects are NOT filed
# under their member countries (verified 2026-07-21: Regional Pastoral
# Livelihoods = 'Africa'; some docs even carry count='World', e.g. DRC
# Agriculture Rehabilitation). Swept in addition to the 54 countries.
# Facet totals re-verified 2026-10-02 (ICR / PPAR): Africa 79/11,
# Eastern Africa 17/2, Western Africa 31/2, Southern Africa 6/0,
# Central Africa 8/1, Western and Central Africa 13/0, World 190/47.
# "Eastern and Southern Africa" returns 0/0 — it is an `admreg` value, not a
# `count` value, so it matches nothing here. Harmless (the member countries
# are swept individually) and kept only so the list reads as the full set of
# regional labels the WB uses; do NOT read its zero as a broken facet.
WB_REGIONAL_COUNTS <- c(
  "Africa", "Eastern Africa", "Western Africa", "Southern Africa",
  "Central Africa", "Western and Central Africa",
  "Eastern and Southern Africa", "World"
)

# Budget-support / policy-lending instruments: excluded — nothing is
# implemented on the ground, so there are no adaptation actions to extract.
WB_EXCLUDE_TITLE_RE <- paste(
  "Development Policy", "Poverty Reduction Support", "Budget Support",
  "Policy Financing", "\\bDPO\\b", "\\bDPF\\b", "\\bDPL\\b", "\\bPRSC\\b",
  sep = "|"
)

# ── Helper: Build WB API URL ──────────────────────────────────────────────
build_wb_url <- function(qterm = NULL, docty = NULL, country = NULL,
                         topic = NULL, strdate = NULL, proid = NULL,
                         rows = 50, offset = 0) {
  params <- list(
    format = "json",
    fl     = WB_FIELDS,
    rows   = rows,
    os     = offset
  )
  if (!is.null(qterm))   params$qterm          <- qterm
  if (!is.null(docty))   params$docty_exact    <- docty
  if (!is.null(country)) params$count_exact    <- country
  if (!is.null(topic))   params$teratopic_exact <- topic
  if (!is.null(strdate)) params$strdate        <- strdate
  # proid: every document attached to one WB project code; combines with
  # docty_exact (verified live 2026-10-02). Used by the CIF handoff lookup.
  if (!is.null(proid))   params$proid          <- proid

  url <- paste0(WB_API_BASE, "?", paste(
    mapply(function(k, v) paste0(k, "=", utils::URLencode(as.character(v), reserved = TRUE)),
           names(params), params),
    collapse = "&"
  ))
  url
}

# ── Response assertions (wired 2026-10-02 after the completeness audit) ────
# The WDS API answers HTTP 200 + valid JSON with total=0 for a docty_exact
# value that is not in the facet index — that is exactly how two misspelled
# WB_DOC_TYPES strings went unnoticed for months. The total>0 requirement
# therefore sits where a zero can ONLY mean a broken facet value:
#   * the start-of-run canary (wb_canary), and
#   * the per-doc-type sweep assertion (wb_assert_doc_types), which checks
#     each WB_DOC_TYPES value ALONE (no country) before any country loop.
# A specific country×type slice (e.g. Seychelles PPARs) can legitimately be
# empty, so ordinary listing calls assert only HTTP 200 + application/json
# + a well-formed WDS body carrying a numeric `total` — never total>0.

# Expectation for ordinary listing slices: valid JSON that is recognisably a
# WDS listing (has `total`); an empty slice (total=0) passes.
WB_EXPECT_JSON <- list(
  content_type = "application/json",
  check = function(b) {
    j <- tryCatch(jsonlite::fromJSON(b), error = function(e) NULL)
    if (is.null(j)) return("body is not parseable JSON")
    if (is.null(j$total)) return("JSON lacks 'total' (not a WDS listing body)")
    TRUE
  }
)

# Expectation for the canary / per-type sweep: the facet must actually match
# documents, otherwise the docty_exact value is wrong (silent zero facet).
WB_EXPECT_TOTAL_POSITIVE <- list(
  content_type = "application/json",
  check = function(b) {
    tot <- tryCatch(jsonlite::fromJSON(b)$total, error = function(e) NULL)
    if (!is.null(tot) && as.integer(tot) > 0) TRUE
    else paste0("total == ", if (is.null(tot)) "<missing>" else tot,
                " (silent zero facet)")
  }
)

#' Start-of-run canary: the known-good ICR facet must return total>0 AND a
#' facet value known NOT to exist ("Implementation Completion Report", one of
#' the two strings removed from WB_DOC_TYPES) must FAIL the same assertion.
#' If the nonsense facet ever passes, the API has started serving a wildcard
#' view this expectation cannot tell apart — stop and tighten it.
wb_canary <- function() {
  canary_check(
    SOURCE_NAME,
    good_url     = build_wb_url(docty = "Implementation Completion and Results Report",
                                rows = 1),
    expect       = WB_EXPECT_TOTAL_POSITIVE,
    nonsense_url = build_wb_url(docty = "Implementation Completion Report",
                                rows = 1)
  )
}

#' Assert every WB_DOC_TYPES value matches documents in the index (facet
#' checked alone, no country) — the type-level guard against silent zeros.
wb_assert_doc_types <- function() {
  for (docty in WB_DOC_TYPES) {
    url <- build_wb_url(docty = docty, rows = 0)
    assert_response(polite_get(url), url, WB_EXPECT_TOTAL_POSITIVE,
                    on_fail = "stop", source = SOURCE_NAME)
    cli::cli_alert_success("doc type facet live: {docty}")
  }
  invisible(TRUE)
}

#' Asserted replacement for safe_get_json on listing calls: fails LOUDLY
#' (stop + log) instead of returning NULL on transport errors, non-JSON
#' bodies, or bodies that are not WDS listings. Empty slices still pass —
#' see the assertion note above for why total>0 is not checked here.
wb_get_json <- function(url, expect = WB_EXPECT_JSON) {
  resp <- assert_response(polite_get(url), url, expect,
                          on_fail = "stop", source = SOURCE_NAME)
  jsonlite::fromJSON(httr::content(resp, as = "text", encoding = "UTF-8"),
                     simplifyDataFrame = FALSE)
}

# ── Helper: Parse WB API response ─────────────────────────────────────────
parse_wb_response <- function(json_data) {
  if (is.null(json_data)) return(tibble())

  # The API returns documents in a named list under "documents"
  docs <- json_data$documents
  if (is.null(docs) || length(docs) == 0) return(tibble())

  # Remove the "facets" entry if present
  docs[["facets"]] <- NULL

  records <- purrr::compact(purrr::map(docs, function(doc) {
    tryCatch({
      # Helper: safely flatten any field to a single character string
      flatten_field <- function(x) {
        if (is.null(x)) return(NA_character_)
        if (is.list(x)) return(paste(unlist(x), collapse = "; "))
        as.character(x)
      }
      
      tibble(
        id            = flatten_field(doc$id),
        title         = flatten_field(doc$display_title),
        pdf_url       = flatten_field(doc$pdfurl),
        doc_date      = flatten_field(doc$docdt),
        doc_type      = flatten_field(doc$docty),
        country       = flatten_field(doc$count),
        report_name   = flatten_field(doc$repnme),
        project_id    = flatten_field(doc$projn),
        pcode         = flatten_field(doc$projectid),
        abstract      = flatten_field(doc$abstracts),
        language      = flatten_field(doc$lang_exact),
        web_url       = flatten_field(doc$url),
        topics        = flatten_field(doc$teratopic)
      )
    }, error = function(e) NULL)
  }))
  
  if (length(records) == 0) return(tibble())
  bind_rows(records)
}

# ── Strategy 1: doc type × African country (recall-first, no topic) ───────
#' Fetches ALL evaluation docs per country; scope precision is applied in
#' filter_relevant() using the returned teratopic field + title keywords.
search_by_doctype_country <- function(countries = c(unname(WB_AFRICA_NAMES),
                                                    WB_REGIONAL_COUNTS)) {
  cli::cli_h2("Strategy 1: doc type × African country (recall-first)")

  all_results <- tibble()

  total_combos <- length(WB_DOC_TYPES) * length(countries)
  combo_count <- 0

  for (docty in WB_DOC_TYPES) {
    for (country in countries) {
      combo_count <- combo_count + 1

      if (combo_count %% 20 == 0) {
        cli::cli_alert_info("Progress: {combo_count}/{total_combos} combinations...")
      }

      offset <- 0
      page_size <- WB_ROWS

      repeat {
        url <- build_wb_url(docty = docty, country = country,
                            rows = page_size, offset = offset)
        # Asserted fetch: HTTP 200 + valid WDS JSON or loud stop. total=0 is
        # legitimate for a country×type slice, so no total>0 check here (that
        # lives in wb_canary / wb_assert_doc_types).
        json <- wb_get_json(url)

        if (is.null(json)) break

        total <- as.numeric(json$total %||% 0)
        if (total == 0) break

        records <- parse_wb_response(json)
        if (nrow(records) == 0) break

        all_results <- bind_rows(all_results, records)
        offset <- offset + page_size

        if (offset >= total) break
      }
    }
  }

  cli::cli_alert_success("Strategy 1 found {nrow(all_results)} raw results")
  all_results
}

# ── Strategy 2: Keyword searches (recall net) ─────────────────────────────
#' Catches agriculture/adaptation evaluation docs the WB did not topic-tag
#' "Agriculture". Restricted to the evaluation doc types and the date floor.
search_by_keywords <- function(max_queries = length(WB_KEYWORD_QUERIES)) {
  cli::cli_h2("Strategy 2: Keyword-based searches (evaluation doc types)")

  all_results <- tibble()

  for (query in head(WB_KEYWORD_QUERIES, max_queries)) {
    cli::cli_alert_info("Searching: {query}")

    for (docty in WB_DOC_TYPES) {
      offset <- 0
      page_size <- WB_ROWS
      max_results <- 500  # cap per query

      repeat {
        url <- build_wb_url(qterm = query, docty = docty,
                            rows = page_size, offset = offset)
        # Asserted fetch; a keyword×type slice may legitimately be empty, so
        # only JSON validity is asserted here (see assertion note above).
        json <- wb_get_json(url)

        if (is.null(json)) break

        total <- as.numeric(json$total %||% 0)
        if (total == 0) break

        records <- parse_wb_response(json)
        if (nrow(records) == 0) break

        all_results <- bind_rows(all_results, records)
        offset <- offset + page_size

        if (offset >= total || offset >= max_results) break
      }
    }
  }

  cli::cli_alert_success("Strategy 2 found {nrow(all_results)} raw results")
  all_results
}

# ── Africa membership (ONE definition, used twice) ─────────────────────────
#' Is a listed document an AFRICA document? Decided on the COUNTRY FIELD
#' (abstract mentions of "Africa" previously admitted Yemen/Lebanon docs);
#' docs filed under count='World' pass only if the TITLE names an African
#' country. filter_relevant() and the attestation ledger both call this, so
#' the ledger's scope is exactly the scraper's Africa scope — no second rule.
wb_is_africa <- function(country, title) {
  africa_re <- paste(c("africa", tolower(AFRICA_COUNTRIES_EN)), collapse = "|")
  ctry <- tolower(coalesce(country, ""))
  ttl  <- tolower(coalesce(title, ""))
  grepl(africa_re, ctry) | (grepl("world", ctry) & grepl(africa_re, ttl))
}

# ── Relevance filtering ───────────────────────────────────────────────────
filter_relevant <- function(results) {
  cli::cli_h2("Filtering for relevance")

  if (nrow(results) == 0) return(results)

  # Deduplicate by document ID
  results <- results %>% distinct(id, .keep_all = TRUE)
  cli::cli_alert_info("After dedup: {nrow(results)} documents")

  # Date floor (client-side; the API strdate param is unreliable)
  n_before <- nrow(results)
  results <- results %>%
    mutate(.yr = suppressWarnings(as.integer(substr(doc_date, 1, 4)))) %>%
    filter(is.na(.yr) | .yr >= WB_MIN_YEAR) %>%
    select(-.yr)
  cli::cli_alert_info("Date floor >= {WB_MIN_YEAR}: dropped {n_before - nrow(results)}")

  # Africa check — see wb_is_africa() for the rule and why it is shared.
  n_before <- nrow(results)
  results <- results %>% filter(wb_is_africa(country, title))
  cli::cli_alert_info("Non-African country dropped: {n_before - nrow(results)}")

  # Three-way scope rule using the WB topic classification as evidence
  # (topic coverage is incomplete, especially on recent documents):
  #   in_scope : Agriculture among the WB topics, OR agriculture/adaptation
  #              keywords in the title/report name
  #   to_screen: neither of the above, but agriculture/adaptation keywords
  #              appear in the ABSTRACT — weak evidence, kept for screening
  #   (dropped): no positive signal in topics, title, or abstract
  results <- results %>%
    rowwise() %>%
    mutate(
      .ag_topic   = grepl("Agriculture", coalesce(topics, ""), fixed = TRUE),
      .kw = passes_relevance_fast(
        paste(coalesce(title, ""), coalesce(report_name, ""),
              coalesce(project_id, ""), sep = " "),
        require_africa = FALSE,
        require_sector = TRUE
      ),
      .kw_abstract = passes_relevance_fast(
        coalesce(abstract, ""),
        require_africa = FALSE,
        require_sector = TRUE
      ),
      screen_status = dplyr::case_when(
        .ag_topic | .kw ~ "in_scope",
        .kw_abstract    ~ "to_screen",
        TRUE            ~ "drop"
      )
    ) %>%
    ungroup()

  n_drop <- sum(results$screen_status == "drop")
  results <- results %>%
    filter(screen_status != "drop") %>%
    select(-.ag_topic, -.kw, -.kw_abstract)

  cli::cli_alert_success(paste0(
    "Scope rule: {sum(results$screen_status == 'in_scope')} in scope, ",
    "{sum(results$screen_status == 'to_screen')} to screen (abstract evidence only), ",
    "{n_drop} dropped (no positive signal)"))

  # Drop budget-support / policy-lending instruments (nothing implemented)
  n_before <- nrow(results)
  results <- results %>%
    filter(!grepl(WB_EXCLUDE_TITLE_RE,
                  paste(coalesce(title, ""), coalesce(report_name, "")),
                  ignore.case = FALSE))
  cli::cli_alert_info("Budget-support instruments dropped: {n_before - nrow(results)}")

  results
}

# ── Download one PDF (documents1 host + browser UA) ───────────────────────
#' documents.worldbank.org returns 403 Forbidden to non-browser clients.
#' Fetch from the documents1 CDN host with a browser User-Agent instead;
#' fall back to the original URL via the shared util. Validation mirrors
#' download_pdf() (min size + %PDF- magic, delete on fail).
WB_BROWSER_UA <- paste0(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) ",
  "AppleWebKit/537.36 (KHTML, like Gecko) ",
  "Chrome/126.0.0.0 Safari/537.36"
)

wb_download_pdf <- function(url, dest) {
  if (file.exists(dest)) return("skipped")
  url1 <- sub("^https?://documents\\.worldbank\\.org",
              "https://documents1.worldbank.org", url)
  Sys.sleep(runif(1, HTTP_CONFIG$delay_min, HTTP_CONFIG$delay_max))
  resp <- tryCatch(
    httr::GET(url1, httr::user_agent(WB_BROWSER_UA),
              httr::timeout(HTTP_CONFIG$timeout_sec)),
    error = function(e) NULL
  )
  if (is.null(resp) || httr::status_code(resp) != 200) {
    # fall back to the original host (https), still with the browser UA —
    # some documents only resolve there; remaining failures are dead links
    resp <- tryCatch(
      httr::GET(sub("^http:", "https:", url), httr::user_agent(WB_BROWSER_UA),
                httr::timeout(HTTP_CONFIG$timeout_sec)),
      error = function(e) NULL
    )
    if (is.null(resp) || httr::status_code(resp) != 200) return(FALSE)
  }
  ok <- tryCatch({
    dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
    writeBin(httr::content(resp, as = "raw"), dest)
    fsize <- file.info(dest)$size
    valid <- FALSE
    if (!is.na(fsize) && fsize >= HTTP_CONFIG$min_pdf_bytes) {
      con   <- file(dest, "rb")
      magic <- rawToChar(readBin(con, "raw", n = 5))
      close(con)
      valid <- identical(magic, "%PDF-")
    }
    if (!valid && file.exists(dest)) file.remove(dest)
    valid
  }, error = function(e) {
    if (file.exists(dest)) file.remove(dest)
    FALSE
  })
  ok
}

# ── Download PDFs ─────────────────────────────────────────────────────────
download_results <- function(results) {
  cli::cli_h2("Downloading PDFs")

  if (nrow(results) == 0) {
    cli::cli_alert_warning("No documents to download.")
    return(invisible(NULL))
  }

  # Filter to those with PDF URLs
  with_pdf <- results %>% filter(!is.na(pdf_url) & nchar(pdf_url) > 0)
  cli::cli_alert_info("{nrow(with_pdf)} documents have PDF URLs")

  success <- 0
  failed <- 0
  skipped <- 0

  for (i in seq_len(nrow(with_pdf))) {
    row <- with_pdf[i, ]

    # Build filename
    year <- tryCatch(
      format(as.Date(row$doc_date), "%Y"),
      error = function(e) "XXXX"
    )
    proj <- safe_filename(coalesce(row$project_id, "noproj"))
    dtype <- safe_filename(coalesce(row$doc_type, "doc"))
    fname <- glue("{SOURCE_NAME}_{proj}_{dtype}_{year}.pdf")
    dest <- file.path(DOWNLOAD_DIR, fname)

    # Check if already exists
    if (file.exists(dest)) {
      log_download(SOURCE_NAME, row$project_id, row$doc_type,
                   row$title, row$pdf_url, dest, "skipped",
                   "File already exists")
      skipped <- skipped + 1
      next
    }

    # Download
    result <- wb_download_pdf(row$pdf_url, dest)

    if (identical(result, TRUE)) {
      log_download(SOURCE_NAME, row$project_id, row$doc_type,
                   row$title, row$pdf_url, dest, "success")
      success <- success + 1
    } else if (identical(result, "skipped")) {
      log_download(SOURCE_NAME, row$project_id, row$doc_type,
                   row$title, row$pdf_url, dest, "skipped")
      skipped <- skipped + 1
    } else {
      log_download(SOURCE_NAME, row$project_id, row$doc_type,
                   row$title, row$pdf_url, dest, "failed",
                   "Download or validation failed")
      failed <- failed + 1
    }

    # Progress
    if (i %% 10 == 0) {
      cli::cli_alert_info("Progress: {i}/{nrow(with_pdf)} " %>%
        paste0("(OK: {success}, fail: {failed}, skip: {skipped})"))
    }
  }

  cli::cli_h3("Download Summary")
  cli::cli_alert_success("Success: {success}")
  cli::cli_alert_danger("Failed: {failed}")
  cli::cli_alert_info("Skipped: {skipped}")
  cli::cli_alert_info("No PDF URL: {nrow(results) - nrow(with_pdf)}")
}

# ── Save metadata ─────────────────────────────────────────────────────────
save_metadata <- function(results) {
  meta_path <- file.path(PATHS$data, "worldbank_metadata.csv")
  readr::write_csv(results, meta_path)
  cli::cli_alert_success("Metadata saved to: {meta_path}")
}

# ── Access/filter probe ────────────────────────────────────────────────────
#' One cheap query verifying the server-side filters work: Kenya ICRs with
#' the Agriculture topic and 2015+ date floor.
wb_probe <- function() {
  cli::cli_h2("World Bank API filter probe (Kenya ICRs)")
  base_url  <- build_wb_url(docty = WB_DOC_TYPES[1], country = "Kenya", rows = 0)
  topic_url <- build_wb_url(docty = WB_DOC_TYPES[1], country = "Kenya",
                            topic = WB_TOPICS[1], rows = 50)
  n_base <- as.numeric(safe_get_json(base_url)$total %||% -1)
  topic_json <- safe_get_json(topic_url)
  n_topic <- as.numeric(topic_json$total %||% -1)
  recs <- parse_wb_response(topic_json)
  n_2015 <- sum(suppressWarnings(as.integer(substr(recs$doc_date, 1, 4))) >= WB_MIN_YEAR,
                na.rm = TRUE)
  cli::cli_alert_info("Kenya ICRs, no filters:              {n_base}")
  cli::cli_alert_info("Kenya ICRs, Agriculture topic:       {n_topic}")
  cli::cli_alert_info("  of which >= {WB_MIN_YEAR} (client-side):   {n_2015}")
  ok <- n_base > 0 && n_topic > 0 && n_topic < n_base && n_2015 > 0
  if (ok) cli::cli_alert_success("Topic filter + client-side date floor working")
  else    cli::cli_alert_danger("Unexpected counts — check API params")
  invisible(c(base = n_base, topic = n_topic, in_scope = n_2015))
}

##############################################################################
# ═══ GAP-FILL STAGE (completeness audit 2026-10) ═══════════════════════════
# Derives the gap LIVE from the API instead of trusting any stored list:
#   1. canary + per-type facet assertions (no blind scraping)
#   2. catalogue sweep: both doc types x African countries + regional counts
#   3. relevance via filter_relevant() — the scraper's existing machinery
#   4. subtract what is already on disk under 03_Documents/Worldbank
#   5. fetch the remainder into Docs/to_screen, never overwriting
#   6. attest EVERY listed Africa document, including the ones filtered out
##############################################################################

# The corpus lives in the sibling 03_Documents tree; new files go to
# Docs/to_screen and are screened later by the scope screener.
WB_CORPUS_DIR <- normalizePath(file.path(dirname(PROJECT_ROOT),
                                         "03_Documents", "Worldbank"),
                               mustWork = FALSE)
WB_TO_SCREEN  <- file.path(WB_CORPUS_DIR, "Docs", "to_screen")

# Filename type token per doc type (the corpus convention:
# worldbank_{pcode}_{docid}_{TYPE}_{year}.pdf).
WB_TYPE_TOKEN <- c(
  "Implementation Completion and Results Report" = "ICR",
  "Project Performance Assessment Report"        = "PPAR"
)

#' All P-codes in a string. The API's `projectid` is comma-separated on
#' multi-project documents; corpus filenames join them with "-"
#' (worldbank_P069896-P132431_30329891_ICR_2018.pdf).
wb_pcodes <- function(x) {
  if (is.null(x) || length(x) == 0) return(character(0))
  m <- regmatches(toupper(x), gregexpr("P[0-9]{6,7}", toupper(x)))[[1]]
  unique(m)
}

#' Inventory of every World Bank PDF already on disk (recursive: 2015_2026,
#' pre_2015, screened_out, to_screen). Filenames embed the P-code(s); the
#' short convention also embeds the WDS document id.
wb_disk_index <- function() {
  files <- list.files(WB_CORPUS_DIR, pattern = "\\.pdf$",
                      recursive = TRUE, full.names = TRUE)
  if (!length(files)) return(tibble(path = character(), base = character(),
                                    docid = character(), type_token = character(),
                                    pcodes = list()))
  base <- basename(files)
  tibble(
    path  = files,
    base  = base,
    # WDS document ids are 7-9 digit runs delimited by underscores; a P-code's
    # digits are preceded by "P", and years are only 4 digits, so neither can
    # be mistaken for one.
    docid = stringr::str_extract(base, "(?<=_)[0-9]{7,9}(?=_)"),
    type_token = ifelse(
      grepl("_PPAR_|Project_Performance_Assessment", base, ignore.case = TRUE),
      "PPAR", "ICR"),
    pcodes = lapply(base, wb_pcodes)
  )
}

#' Do we already hold this listed document?
#' Match order: (a) the WDS document id appears in a filename — exact and
#' authoritative; (b) any of the document's P-codes appears in a filename of
#' the SAME type token. (b) is what lets the 195 long-convention ICR files
#' (project name + P-code, no doc id) count as held. The type token matters:
#' we hold ICRs for ~193 projects and zero PPARs, so without it every PPAR of
#' a project whose ICR we hold would be wrongly scored as already held.
wb_held_by <- function(docid, pcodes, type_token, disk) {
  if (!nrow(disk)) return(NA_character_)
  if (!is.na(docid) && nzchar(docid)) {
    hit <- which(!is.na(disk$docid) & disk$docid == docid)
    if (length(hit)) return(disk$base[hit[1]])
  }
  if (length(pcodes)) {
    same <- which(disk$type_token == type_token)
    for (i in same) if (any(pcodes %in% disk$pcodes[[i]])) return(disk$base[i])
  }
  NA_character_
}

#' Destination filename: worldbank_{pcode}_{docid}_{TYPE}_{year}.pdf.
#' Multi-project documents join their codes with "-" (corpus convention);
#' a document with no P-code at all falls back to a title slug, as the one
#' legacy file of that shape already does.
wb_dest_name <- function(pcodes, docid, type_token, year, title) {
  tag <- if (length(pcodes)) paste(pcodes, collapse = "-") else
    tolower(safe_filename(substr(coalesce(title, "noproj"), 1, 60)))
  glue("{SOURCE_NAME}_{tag}_{docid}_{type_token}_{year}.pdf")
}

#' Vectorised URL encoder: utils::URLencode() only ever encodes its FIRST
#' element, so calling it on a column silently stamps one value onto every row.
.wb_enc <- function(x) vapply(as.character(x), function(s)
  utils::URLencode(ifelse(is.na(s), "", s), reserved = TRUE), character(1),
  USE.NAMES = FALSE)

#' Accent- and case-insensitive key for loose country/title comparison
#' ("Côte d'Ivoire" in the CIF handoff vs "Cote d'Ivoire" in WDS).
.wb_flat <- function(x) {
  x <- iconv(as.character(x), to = "ASCII//TRANSLIT", sub = " ")
  tolower(gsub("[^A-Za-z0-9 ]", " ", ifelse(is.na(x), "", x)))
}

wb_year <- function(doc_date) {
  y <- suppressWarnings(as.integer(substr(doc_date, 1, 4)))
  ifelse(is.na(y), "XXXX", as.character(y))
}

# ── Catalogue stage: the live Africa inventory for the two doc types ───────
#' Sweeps both WB_DOC_TYPES across the 54 African country facets plus the
#' regional/global `count` values, returns every listed AFRICA document
#' (all years), deduplicated by WDS document id.
#' The sweep is ~200 asserted API calls; `cache` lets a re-run (e.g. after a
#' download failure) reuse the same inventory instead of re-listing the site.
#' Delete the file to force a fresh sweep.
WB_CATALOGUE_CACHE <- file.path(PATHS$data, "worldbank_africa_catalogue.csv")

wb_catalogue <- function(countries = c(unname(WB_AFRICA_NAMES), WB_REGIONAL_COUNTS),
                         cache = WB_CATALOGUE_CACHE, use_cache = TRUE) {
  if (use_cache && !is.null(cache) && file.exists(cache)) {
    afr <- readr::read_csv(cache, col_types = readr::cols(.default = "c"),
                           progress = FALSE)
    cli::cli_alert_info("catalogue: reusing cached sweep ({nrow(afr)} Africa documents) from {basename(cache)}")
    return(afr)
  }
  raw <- search_by_doctype_country(countries)
  if (!nrow(raw)) stop("catalogue stage returned 0 rows - refusing to proceed",
                       call. = FALSE)
  inv <- raw %>% distinct(id, .keep_all = TRUE)
  cli::cli_alert_info("catalogue: {nrow(raw)} raw hits, {nrow(inv)} distinct documents")
  afr <- inv %>% filter(wb_is_africa(country, title))
  cli::cli_alert_info("Africa documents (shared wb_is_africa rule): {nrow(afr)}")
  if (!is.null(cache)) {
    dir.create(dirname(cache), recursive = TRUE, showWarnings = FALSE)
    readr::write_csv(afr, cache)
    cli::cli_alert_success("catalogue cached: {cache}")
  }
  afr
}

# ── Fetch one gap document ─────────────────────────────────────────────────
#' Returns a one-row tibble: id, disposition, local_filename, notes.
#' Never overwrites: a destination that already exists, or a basename/doc id
#' already present ANYWHERE under 03_Documents/Worldbank, is a duplicate.
wb_fetch_one <- function(row, disk, dry_run = FALSE) {
  pcodes <- wb_pcodes(row$pcode)
  tok    <- unname(WB_TYPE_TOKEN[row$doc_type])
  if (is.na(tok)) tok <- "doc"
  yr     <- wb_year(row$doc_date)
  docid  <- as.character(row$id)
  fname  <- wb_dest_name(pcodes, docid, tok, yr, row$title)
  dest   <- file.path(WB_TO_SCREEN, fname)

  out <- function(disp, file = NA_character_, notes = NA_character_)
    tibble(id = docid, disposition = disp, local_filename = file, notes = notes)

  if (tolower(fname) %in% tolower(disk$base) || file.exists(dest))
    return(out("duplicate", fname,
               "basename already present under 03_Documents/Worldbank - not overwritten"))

  if (is.na(row$pdf_url) || !nzchar(row$pdf_url))
    return(out("failed_download", NA_character_,
               "API listing carries no pdfurl for this document"))

  if (dry_run) return(out("fetched", fname, "DRY RUN - not downloaded"))

  ok <- wb_download_pdf(row$pdf_url, dest)
  if (identical(ok, TRUE) || identical(ok, "skipped")) {
    if (!valid_local_file(dest, "pdf"))
      return(out("failed_download", NA_character_,
                 paste0("file written but failed %PDF-/size validation: ", row$pdf_url)))
    log_download(SOURCE_NAME, row$pcode, row$doc_type, row$title, row$pdf_url,
                 dest, "success", "gapfill; validated %PDF- magic + size floor")
    return(out("fetched", fname, paste0("pdf: ", row$pdf_url)))
  }
  log_download(SOURCE_NAME, row$pcode, row$doc_type, row$title, row$pdf_url,
               dest, "failed", "gapfill; download or %PDF-/size validation failed")
  out("failed_download", NA_character_,
      paste0("download or %PDF-/size validation failed for ", row$pdf_url))
}

# ── CIF handoff: closed African PPCR/FIP projects whose MDB is the Bank ────
#' catalogues/cif/mdb_handoff.csv rows with mdb = IBRD or IFC are CIF-funded
#' projects implemented through the World Bank Group, so their completion
#' evidence lives in WDS. Query by project id where the handoff carries one,
#' otherwise by title; keep only the two evaluation doc types.
WB_HANDOFF_MDBS <- c("International Bank for Reconstruction and Development",
                     "International Finance Corporation")

wb_cif_handoff <- function(disk, fetch_live = TRUE) {
  p <- file.path(PROJECT_ROOT, "catalogues", "cif", "mdb_handoff.csv")
  if (!file.exists(p)) {
    cli::cli_alert_warning("no CIF handoff file at {p} - skipping")
    return(tibble())
  }
  h <- readr::read_csv(p, col_types = readr::cols(.default = "c"), progress = FALSE)
  h <- h[h$mdb %in% WB_HANDOFF_MDBS, , drop = FALSE]
  cli::cli_h2("CIF handoff: {nrow(h)} IBRD/IFC rows")

  rows <- list()
  for (i in seq_len(nrow(h))) {
    r <- h[i, ]
    hits <- tibble()
    how  <- NA_character_
    for (docty in WB_DOC_TYPES) {
      url <- if (!is.na(r$mdb_project_id) && nzchar(r$mdb_project_id)) {
        how <- paste0("proid=", r$mdb_project_id)
        build_wb_url(docty = docty, proid = r$mdb_project_id, rows = WB_ROWS)
      } else {
        how <- "qterm=title"
        build_wb_url(docty = docty, qterm = r$project_title, rows = WB_ROWS)
      }
      j <- wb_get_json(url)
      recs <- parse_wb_response(j)
      if (nrow(recs)) hits <- bind_rows(hits, recs)
    }
    if (nrow(hits)) hits <- distinct(hits, id, .keep_all = TRUE)

    # A title query is FREE TEXT, not an identifier lookup. Measured on the
    # 2026-10 handoff: the IFC row "Niger Irrigation Program" (no project id)
    # returned 19 documents going back to 1979 — every Niger irrigation ICR
    # and PPAR the search engine ranks, none of them the CIF project. Three
    # guards, in order of how much junk each removes:
    #   (a) the 2015+ scope window — a closed PPCR/FIP project's completion
    #       report cannot predate the programmes themselves;
    #   (b) the country must match the handoff row;
    #   (c) the title tokens must overlap, and only the 3 best hits are kept.
    # Survivors are still only a TITLE match, never a confirmed identity, so
    # they are labelled as such in the ledger rather than silently claimed as
    # the CIF project's evaluation.
    confidence <- if (how == "qterm=title")
      "title_match (free-text; project identity NOT confirmed by project id)"
    else "exact (proid lookup)"

    if (nrow(hits) && how == "qterm=title") {
      yr <- suppressWarnings(as.integer(substr(hits$doc_date, 1, 4)))
      hits <- hits[!is.na(yr) & yr >= WB_MIN_YEAR, , drop = FALSE]
    }
    if (nrow(hits) && how == "qterm=title") {
      ctry_ok <- grepl(substr(.wb_flat(r$country), 1, 5),
                       .wb_flat(coalesce(hits$country, "")), fixed = TRUE)
      hits <- hits[ctry_ok, , drop = FALSE]
    }
    if (nrow(hits) && how == "qterm=title") {
      key <- unlist(strsplit(.wb_flat(r$project_title), "\\s+"))
      key <- key[nchar(key) > 4 & !key %in% c("project", "program", "programme")]
      if (length(key)) {
        hay <- .wb_flat(paste(coalesce(hits$title, ""),
                              coalesce(hits$project_id, ""),
                              coalesce(hits$report_name, "")))
        frac <- vapply(hay, function(s)
          mean(vapply(key, grepl, logical(1), s, fixed = TRUE)), numeric(1),
          USE.NAMES = FALSE)
        ord  <- order(-frac, -suppressWarnings(as.integer(substr(hits$doc_date, 1, 4))))
        keep <- ord[frac[ord] >= 0.6]
        hits <- hits[utils::head(keep, 3L), , drop = FALSE]
      }
    }

    if (!nrow(hits)) {
      rows[[length(rows) + 1]] <- tibble(
        program = r$program, country = r$country, project_title = r$project_title,
        mdb = r$mdb, mdb_project_id = coalesce(r$mdb_project_id, NA_character_),
        already_held_flag = r$already_held, queried_by = how,
        confidence = confidence,
        wds_id = NA_character_, wds_doc_type = NA_character_, wds_year = NA_character_,
        outcome = "no_icr_or_ppar_in_wds", local_filename = NA_character_)
      next
    }
    for (k in seq_len(nrow(hits))) {
      hr   <- hits[k, ]
      held <- wb_held_by(as.character(hr$id), wb_pcodes(hr$pcode),
                         unname(WB_TYPE_TOKEN[hr$doc_type]), disk)
      if (!is.na(held)) {
        outc <- "already_held"; lf <- held
      } else if (!fetch_live) {
        outc <- "gap_not_fetched"; lf <- NA_character_
      } else {
        f <- wb_fetch_one(hr, disk)
        outc <- f$disposition; lf <- f$local_filename
        if (identical(outc, "fetched") && !is.na(lf))
          disk <- bind_rows(disk, tibble(path = file.path(WB_TO_SCREEN, lf),
                                         base = lf, docid = as.character(hr$id),
                                         type_token = unname(WB_TYPE_TOKEN[hr$doc_type]),
                                         pcodes = list(wb_pcodes(hr$pcode))))
      }
      rows[[length(rows) + 1]] <- tibble(
        program = r$program, country = r$country, project_title = r$project_title,
        mdb = r$mdb, mdb_project_id = coalesce(r$mdb_project_id, NA_character_),
        already_held_flag = r$already_held, queried_by = how,
        confidence = confidence,
        wds_id = as.character(hr$id), wds_doc_type = hr$doc_type,
        wds_year = wb_year(hr$doc_date), outcome = outc, local_filename = lf)
    }
  }
  out <- bind_rows(rows)
  attr(out, "disk") <- disk
  out
}

# ── Gap-fill runner ────────────────────────────────────────────────────────
#' @param max_fetch Safety valve. A fetch list larger than this means the
#'   relevance filter is wrong, not that the gap is real — stop and report.
run_wb_gapfill <- function(max_fetch = 80L, dry_run = FALSE, do_handoff = TRUE) {
  cli::cli_h1("World Bank gap-fill (live derivation)")
  cli::cli_alert_info("corpus: {WB_CORPUS_DIR}")
  cli::cli_alert_info("new files -> {WB_TO_SCREEN}")

  ## 1. assertions first — no blind scraping
  wb_canary()
  wb_assert_doc_types()

  ## 2. live catalogue
  afr <- wb_catalogue()

  ## 3. relevance — the scraper's existing machinery, unchanged
  kept <- filter_relevant(afr)
  kept_ids <- as.character(kept$id)
  # carry the scope tier back so the ledger can say WHICH tier kept a row
  # (in_scope = topic/title evidence; to_screen = abstract evidence only)
  afr$screen_status_cached <- kept$screen_status[match(as.character(afr$id), kept_ids)]

  ## 4. subtract the disk
  disk <- wb_disk_index()
  cli::cli_alert_info("on disk under 03_Documents/Worldbank: {nrow(disk)} PDFs, {length(unique(unlist(disk$pcodes)))} distinct P-codes")

  afr <- afr %>%
    mutate(.yr   = suppressWarnings(as.integer(substr(doc_date, 1, 4))),
           .tok  = unname(WB_TYPE_TOKEN[doc_type]),
           .kept = as.character(id) %in% kept_ids)
  afr$.held <- vapply(seq_len(nrow(afr)), function(i)
    wb_held_by(as.character(afr$id[i]), wb_pcodes(afr$pcode[i]), afr$.tok[i], disk),
    character(1))

  in_window <- is.na(afr$.yr) | afr$.yr >= WB_MIN_YEAR
  gap_idx <- which(in_window & afr$.kept & is.na(afr$.held))

  cli::cli_h2("Fetch list (reported BEFORE any download)")
  cli::cli_alert_info("Africa documents listed by the API: {nrow(afr)}")
  cli::cli_alert_info("  in window (>= {WB_MIN_YEAR}): {sum(in_window)}; relevance-kept: {sum(in_window & afr$.kept)}")
  cli::cli_alert_info("  already on disk: {sum(in_window & afr$.kept & !is.na(afr$.held))}")
  cli::cli_alert_success("FETCH LIST SIZE: {length(gap_idx)}")
  print(as.data.frame(table(afr$.tok[gap_idx], afr$screen_status_cached[gap_idx])))
  if (length(gap_idx))
    print(utils::head(as.data.frame(
      afr[gap_idx, c("pcode", "country", "doc_type", "screen_status_cached", "title")]),
      60L), width = 200)

  # The gap list is always written out, halted or not: it is the thing a human
  # adjudicates, and it must not live only in a console scrollback.
  gap_path <- file.path(PATHS$data, "worldbank_gap_list.csv")
  readr::write_csv(afr[gap_idx, setdiff(names(afr), ".held")], gap_path)
  cli::cli_alert_success("gap list written: {gap_path}")

  # Ceiling breach halts the DOWNLOADS, not the run: the CIF handoff is a
  # separate, individually-named list, and the ledger is the whole point of
  # the exercise — both still execute, and the halted gap rows are attested
  # as held pending a decision rather than silently dropped.
  halted <- length(gap_idx) > max_fetch
  if (halted) {
    cli::cli_alert_danger(paste0(
      "fetch list of {length(gap_idx)} exceeds the {max_fetch} ceiling - ",
      "NOT downloading it. A gap this size means the relevance filter is ",
      "wrong, not that the corpus is missing that much. Continuing to the ",
      "CIF handoff and the ledger."))
  }
  fetch_idx <- if (halted) integer(0) else gap_idx

  ## 5. fetch
  outcomes <- list()
  for (i in fetch_idx) {
    o <- wb_fetch_one(afr[i, ], disk, dry_run = dry_run)
    outcomes[[length(outcomes) + 1]] <- o
    if (identical(o$disposition, "fetched") && !is.na(o$local_filename))
      disk <- bind_rows(disk, tibble(
        path = file.path(WB_TO_SCREEN, o$local_filename), base = o$local_filename,
        docid = as.character(afr$id[i]), type_token = afr$.tok[i],
        pcodes = list(wb_pcodes(afr$pcode[i]))))
  }
  fetched <- if (length(outcomes)) bind_rows(outcomes) else
    tibble(id = character(), disposition = character(),
           local_filename = character(), notes = character())
  if (nrow(fetched)) print(as.data.frame(table(fetched$disposition)))

  ## 6. CIF handoff
  handoff <- tibble()
  if (do_handoff) {
    handoff <- wb_cif_handoff(disk, fetch_live = !dry_run)
    if (nrow(handoff)) {
      disk <- attr(handoff, "disk")
      print(as.data.frame(handoff[, c("country", "mdb_project_id", "project_title",
                                      "wds_doc_type", "wds_year", "outcome")]),
            width = 220)
      cli::cli_alert_info("handoff outcomes: {paste(names(table(handoff$outcome)), table(handoff$outcome), sep='=', collapse='; ')}")
    }
  }

  ## 6b. fold the handoff's actions into the fetch-outcome table.
  # A CIF-handoff document is usually ALSO on the Africa country sweep, so
  # without this its ledger row reports what the sweep would have done with
  # it (out_by_type, or held pending the ceiling decision) instead of the
  # file we actually downloaded. An action taken wins over a rule not applied.
  if (nrow(handoff)) {
    hf <- handoff[!is.na(handoff$wds_id) &
                    handoff$outcome %in% c("fetched", "duplicate",
                                           "failed_download"), , drop = FALSE]
    if (nrow(hf)) {
      hf <- hf[!duplicated(hf$wds_id), ]
      fetched <- bind_rows(
        fetched[!fetched$id %in% hf$wds_id, , drop = FALSE],
        tibble(id = hf$wds_id, disposition = hf$outcome,
               local_filename = hf$local_filename,
               notes = paste0("fetched via the CIF ", hf$program, " handoff (",
                              hf$mdb, "), queried by ", hf$queried_by,
                              "; match confidence: ", hf$confidence)))
      cli::cli_alert_info("ledger: {nrow(hf)} handoff action{?s} folded into the fetch outcomes")
    }
  }

  ## 7. attestation ledger — one row per listed Africa document
  disp  <- character(nrow(afr))
  lfile <- rep(NA_character_, nrow(afr))
  notes <- character(nrow(afr))
  fi <- match(as.character(afr$id), fetched$id)
  excl <- grepl(WB_EXCLUDE_TITLE_RE,
                paste(coalesce(afr$title, ""), coalesce(afr$report_name, "")))
  # Order matters: what we DID this run is reported before what a rule would
  # have said. A document fetched through the CIF handoff is `fetched`, even
  # if the Africa sweep's relevance rule would have dropped it.
  for (i in seq_len(nrow(afr))) {
    if (!is.na(fi[i])) {
      disp[i]  <- fetched$disposition[fi[i]]
      lfile[i] <- fetched$local_filename[fi[i]]
      notes[i] <- fetched$notes[fi[i]]
    } else if (!is.na(afr$.held[i])) {
      disp[i]  <- "already_held"
      lfile[i] <- afr$.held[i]
      notes[i] <- "matched on disk by WDS doc id or P-code + type token"
    } else if (!in_window[i]) {
      disp[i]  <- "held_pending_window_decision"
      notes[i] <- paste0("document date ", afr$.yr[i], " is before the ",
                         WB_MIN_YEAR, "+ scope window; listed, not fetched")
    } else if (!afr$.kept[i]) {
      disp[i]  <- "out_by_type"
      notes[i] <- if (excl[i])
        "budget-support / policy-lending instrument (WB_EXCLUDE_TITLE_RE)"
      else
        "no agriculture/adaptation signal in WB topics, title or abstract (filter_relevant)"
    } else if (halted) {
      # In window, relevance-kept, not on disk, deliberately NOT fetched
      # because the fetch list blew the ceiling. Of the vocabulary this is
      # the only "catalogued, not fetched, decision pending" slot; the
      # decision pending is a relevance-tier one, not a date one, so the
      # note says exactly that. Recorded, never silently dropped.
      disp[i]  <- "held_pending_window_decision"
      notes[i] <- paste0("live-derived gap (", afr$screen_status_cached[i],
                         "); fetch halted - list of ", length(gap_idx),
                         " exceeded the ", max_fetch, " ceiling, pending a ",
                         "decision on the to_screen relevance tier")
    } else {
      stop("ledger: in-window, kept, unheld document ", afr$id[i],
           " has no fetch outcome - refusing to write a blank disposition",
           call. = FALSE)
    }
  }
  # Provenance, independent of disposition: a document the CIF handoff chased
  # says so in its note whether we fetched it now or already held it. On a
  # re-run the disposition correctly becomes already_held, and without this
  # the only record that CIF is why we have the file would be the download log.
  if (nrow(handoff)) {
    hp <- handoff[!is.na(handoff$wds_id), , drop = FALSE]
    hp <- hp[!duplicated(hp$wds_id), ]
    j  <- match(as.character(afr$id), hp$wds_id)
    notes <- ifelse(is.na(j), notes, paste0(
      notes, "; CIF ", hp$program[j], " handoff (", hp$mdb[j], ", ",
      hp$country[j], "), queried by ", hp$queried_by[j],
      "; match confidence: ", hp$confidence[j]))
  }

  ledger <- tibble(
    site_id        = as.character(afr$id),
    title          = coalesce(afr$title, afr$report_name),
    doc_type_site  = afr$doc_type,
    # URLencode() is NOT vectorised (it splits only its first element), so it
    # must be applied per row or every ledger line gets the first doc type.
    listing        = paste0(WB_API_BASE, "?docty_exact=", .wb_enc(afr$doc_type),
                            "&count_exact=", .wb_enc(coalesce(afr$country, ""))),
    disposition    = disp,
    local_filename = lfile,
    notes          = notes
  )
  # handoff documents found outside the Africa country sweep still belong in
  # the ledger: they are World Bank documents we acted on.
  if (nrow(handoff)) {
    extra <- handoff[!is.na(handoff$wds_id) & !handoff$wds_id %in% ledger$site_id, ]
    if (nrow(extra)) {
      extra <- extra[!duplicated(extra$wds_id), ]
      ledger <- bind_rows(ledger, tibble(
        site_id        = extra$wds_id,
        title          = extra$project_title,
        doc_type_site  = extra$wds_doc_type,
        listing        = paste0(WB_API_BASE, "?proid=", coalesce(extra$mdb_project_id, ""),
                                " (CIF handoff)"),
        disposition    = ifelse(extra$outcome == "gap_not_fetched",
                                "held_pending_window_decision", extra$outcome),
        local_filename = extra$local_filename,
        notes          = paste0("CIF ", extra$program, " handoff (", extra$mdb,
                                "), queried by ", extra$queried_by,
                                "; match confidence: ", extra$confidence)))
      cli::cli_alert_info("ledger: +{nrow(extra)} CIF-handoff document{?s} not on the Africa country sweep")
    }
  }
  if (any(is.na(ledger$disposition) | !nzchar(ledger$disposition)))
    stop("ledger has blank dispositions", call. = FALSE)
  write_attestation(SOURCE_NAME, ledger)
  cli::cli_h2("ledger dispositions")
  print(table(ledger$disposition))

  ## 8. reconciliation: disk files the API no longer lists
  cli::cli_h2("reconciliation (disk vs live API listing)")
  live_ids    <- unique(as.character(afr$id))
  live_pcodes <- unique(unlist(lapply(afr$pcode, wb_pcodes)))
  orphan <- vapply(seq_len(nrow(disk)), function(i) {
    d <- disk$docid[i]
    if (!is.na(d) && d %in% live_ids) return(FALSE)
    !any(disk$pcodes[[i]] %in% live_pcodes)
  }, logical(1))
  cli::cli_alert_info("disk PDFs: {nrow(disk)}; not matched by any currently listed Africa document: {sum(orphan)}")
  if (any(orphan)) print(utils::head(disk$base[orphan], 60))

  ## 9. cross-check the completeness-audit candidate list
  mp <- file.path(PROJECT_ROOT, "audit", "2026-10_completeness", "wb_missing_projects.csv")
  if (file.exists(mp)) {
    miss <- readr::read_csv(mp, col_types = readr::cols(.default = "c"), progress = FALSE)
    gap_pcodes <- unique(unlist(lapply(afr$pcode[gap_idx], wb_pcodes)))
    miss$in_live_gap  <- toupper(miss$pcode) %in% gap_pcodes
    miss$on_disk_now  <- toupper(miss$pcode) %in% unique(unlist(disk$pcodes))
    miss$in_live_list <- toupper(miss$pcode) %in% live_pcodes
    cli::cli_h2("wb_missing_projects.csv cross-check ({nrow(miss)} rows)")
    cli::cli_alert_info("also flagged by the live derivation: {sum(miss$in_live_gap)}")
    cli::cli_alert_info("already on disk: {sum(miss$on_disk_now)}")
    cli::cli_alert_info("not listed at all by the live ICR/PPAR Africa sweep: {sum(!miss$in_live_list)}")
    print(as.data.frame(miss[, c("pcode", "country", "yr", "types", "in_live_gap",
                                 "on_disk_now", "in_live_list")]), width = 200)
  }

  cli::cli_h2("Done (gap-fill)")
  invisible(list(africa = afr, fetched = fetched, ledger = ledger,
                 handoff = handoff, disk = disk))
}

# ── Main execution ────────────────────────────────────────────────────────
run_worldbank_scraper <- function(countries = unname(WB_AFRICA_NAMES),
                                  max_keyword_queries = length(WB_KEYWORD_QUERIES)) {
  cli::cli_h1("World Bank Grey Literature Scraper")
  cli::cli_alert_info("Download directory: {DOWNLOAD_DIR}")
  cli::cli_alert_info("Scope: {paste(WB_DOC_TYPES, collapse=' | ')}; topic {paste(WB_TOPICS, collapse='/')}; date >= {WB_MIN_YEAR}")

  # Canary first: good facet must pass, a known-nonsense facet must fail —
  # then every doc type facet must match >0 documents. No blind scraping.
  wb_canary()
  wb_assert_doc_types()

  # Collect results from both strategies
  results1 <- search_by_doctype_country(countries)
  results2 <- search_by_keywords(max_keyword_queries)

  # Combine and deduplicate
  all_results <- bind_rows(results1, results2)
  cli::cli_alert_info("Total raw results: {nrow(all_results)}")

  # Filter for relevance
  relevant <- filter_relevant(all_results)

  # Save metadata before downloading
  save_metadata(relevant)

  # Download PDFs
  download_results(relevant)

  # Print summary
  print_source_summary(SOURCE_NAME)

  cli::cli_h2("Done!")
  invisible(relevant)
}

# ── CLI ─────────────────────────────────────────────────────────────────────
# Run ONLY when this file is the Rscript target. source("worldbank.R") must
# never start a scrape: the gap-fill stage, the tests and any helper that
# wants build_wb_url()/filter_relevant() source this file for its functions.
# The previous guard `sys.nframe() == 0 || !interactive()` fired on EVERY
# non-interactive source() — under Rscript, interactive() is FALSE, so merely
# sourcing the file from another script launched a full scrape. Same fix as
# the GEF scraper (--file= basename test).
#
#   Rscript R/01_retrieve/worldbank.R          # WB_MODE: probe|capped|gapfill|load|full
.wb_is_main <- local({
  fa <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  length(fa) > 0 &&
    identical(tolower(basename(sub("^--file=", "", fa[1]))), "worldbank.r")
})
if (.wb_is_main) {
  switch(Sys.getenv("WB_MODE", "full"),
    probe   = wb_probe(),
    capped  = run_worldbank_scraper(countries = c("Kenya", "Mozambique"),
                                    max_keyword_queries = 1),
    gapfill = run_wb_gapfill(),  # live gap derivation + fetch + ledger
    load    = invisible(NULL),   # source functions only, no run
    run_worldbank_scraper()
  )
}
