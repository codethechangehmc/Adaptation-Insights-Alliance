##############################################################################
# 01_utils.R — Shared utility functions for all scrapers
# HTTP helpers, PDF validation, relevance filtering, logging
##############################################################################

suppressPackageStartupMessages({
  library(httr)
  library(rvest)
  library(dplyr)
  library(stringr)
  library(readr)
  library(jsonlite)
  library(xml2)
  library(glue)
  library(fs)
  library(cli)
  library(lubridate)
  library(tibble)
  library(curl)
  library(purrr)
})

# Source config if not already loaded
if (!exists("PATHS")) {
  # Try multiple methods to find 00_config.R
  config_found <- FALSE

  # Method 1: relative to this script (works with source())
  tryCatch({
    config_path <- file.path(dirname(sys.frame(1)$ofile), "00_config.R")
    if (file.exists(config_path)) { source(config_path); config_found <- TRUE }
  }, error = function(e) NULL)

  # Method 2: from working directory
  if (!config_found) {
    candidates <- c(
      file.path(getwd(), "R", "00_config.R"),
      file.path(getwd(), "00_config.R"),
      file.path(getwd(), "..", "00_config.R")
    )
    for (p in candidates) {
      if (file.exists(p)) { source(p); config_found <- TRUE; break }
    }
  }

  if (!config_found) {
    stop("Cannot find 00_config.R. Please source it first or cd into the project root.")
  }
}

# ── Polite HTTP GET ────────────────────────────────────────────────────────
#' Make an HTTP GET request with polite delays, retries, and backoff.
#'
#' @param url Character. The URL to fetch.
#' @param max_retries Integer. Maximum number of retry attempts.
#' @param delay_range Numeric vector of length 2. Min and max delay in seconds.
#' @param ... Additional arguments passed to httr::GET.
#' @return An httr response object, or NULL on failure.
polite_get <- function(url,
                       max_retries = HTTP_CONFIG$max_retries,
                       delay_range = c(HTTP_CONFIG$delay_min, HTTP_CONFIG$delay_max),
                       ...) {
  # Random delay before request
  delay <- runif(1, delay_range[1], delay_range[2])
  Sys.sleep(delay)

  for (attempt in seq_len(max_retries)) {
    resp <- tryCatch(
      {
        # Several hosts (afdb.org since Oct 2026) answer 403 to requests with
        # no Accept headers at all, while accepting the same honest UA once
        # ordinary browser Accept headers are present. Identify truthfully,
        # but send a normal header set.
        httr::GET(
          url,
          httr::user_agent(HTTP_CONFIG$user_agent),
          httr::add_headers(
            Accept = "text/html,application/xhtml+xml,application/xml;q=0.9,application/json;q=0.8,*/*;q=0.7",
            `Accept-Language` = "en-US,en;q=0.9,fr;q=0.8"
          ),
          httr::timeout(HTTP_CONFIG$timeout_sec),
          ...
        )
      },
      error = function(e) {
        cli::cli_alert_warning("HTTP error on attempt {attempt}/{max_retries}: {e$message}")
        NULL
      }
    )

    if (is.null(resp)) {
      if (attempt < max_retries) {
        backoff <- delay * (2^(attempt - 1))
        cli::cli_alert_info("Retrying in {round(backoff, 1)}s...")
        Sys.sleep(backoff)
      }
      next
    }

    status <- httr::status_code(resp)

    # Success
    if (status >= 200 && status < 300) {
      return(resp)
    }

    # Rate limited — backoff and retry
    if (status == 429) {
      retry_after <- as.numeric(httr::headers(resp)[["retry-after"]])
      if (is.na(retry_after)) retry_after <- 30
      backoff <- max(retry_after, delay * (2^attempt))
      cli::cli_alert_warning("Rate limited (429). Waiting {round(backoff, 1)}s...")
      Sys.sleep(backoff)
      next
    }

    # Server error — retry
    if (status >= 500) {
      cli::cli_alert_warning("Server error ({status}) on attempt {attempt}/{max_retries}")
      if (attempt < max_retries) {
        backoff <- delay * (2^(attempt - 1))
        Sys.sleep(backoff)
      }
      next
    }

    # Burst throttling: edge caches (e.g. GEF's Varnish) answer 403 to rapid
    # sequences and recover after a pause. Back off long and retry; a genuine
    # permanent 403 just costs max_retries slow attempts. Callers must treat
    # a final NULL/403 as a hard stop, never as an empty listing.
    if (status == 403) {
      cli::cli_alert_warning("Throttled or refused (403) on attempt {attempt}/{max_retries}: {url}")
      if (attempt < max_retries) {
        backoff <- max(20, delay * (2^attempt)) + runif(1, 0, 10)
        cli::cli_alert_info("Backing off {round(backoff)}s before retrying...")
        Sys.sleep(backoff)
        next
      }
      return(resp)
    }

    # Client error (4xx other than 429/403) — don't retry
    cli::cli_alert_danger("HTTP {status} for: {url}")
    return(resp)
  }

  cli::cli_alert_danger("All {max_retries} attempts failed for: {url}")
  return(NULL)
}

# ── Safe HTML reader ───────────────────────────────────────────────────────
#' Read an HTML page safely, returning NULL on failure.
#'
#' @param url Character. URL to read.
#' @return An xml_document or NULL.
safe_read_html <- function(url) {
  resp <- polite_get(url)
  if (is.null(resp)) return(NULL)
  if (httr::status_code(resp) != 200) return(NULL)

  tryCatch(
    {
      content_text <- httr::content(resp, as = "text", encoding = "UTF-8")
      # Check for JS-only pages (empty or very short body)
      if (nchar(content_text) < 500 || !grepl("<body", content_text, ignore.case = TRUE)) {
        cli::cli_alert_warning("Page appears to be JS-only (empty body): {url}")
        return(NULL)
      }
      xml2::read_html(content_text)
    },
    error = function(e) {
      cli::cli_alert_warning("HTML parse error: {e$message}")
      NULL
    }
  )
}

# ── Safe JSON fetch ────────────────────────────────────────────────────────
#' Fetch a URL and parse the response as JSON. Returns NULL on failure.
#'
#' @param url Character. URL returning JSON.
#' @return A list (parsed JSON) or NULL.
safe_get_json <- function(url) {
  resp <- polite_get(url)
  if (is.null(resp)) return(NULL)
  if (httr::status_code(resp) != 200) {
    cli::cli_alert_danger("JSON request returned HTTP {httr::status_code(resp)}: {url}")
    return(NULL)
  }

  tryCatch(
    {
      txt <- httr::content(resp, as = "text", encoding = "UTF-8")
      jsonlite::fromJSON(txt, simplifyDataFrame = FALSE)
    },
    error = function(e) {
      cli::cli_alert_warning("JSON parse error: {e$message}")
      NULL
    }
  )
}

# ── PDF Download & Validation ──────────────────────────────────────────────
#' Download a PDF file with validation.
#'
#' Checks: file size > min_pdf_bytes and first 5 bytes are %PDF-.
#' Deletes invalid files and returns FALSE.
#'
#' @param url Character. PDF URL.
#' @param dest Character. Destination file path.
#' @param min_bytes Integer. Minimum file size in bytes.
#' @return TRUE if download succeeded and PDF is valid, FALSE otherwise.
download_pdf <- function(url, dest,
                         min_bytes = HTTP_CONFIG$min_pdf_bytes) {
  # Skip only if the existing file is VALID. Returning "skipped" for a
  # truncated or non-PDF leftover would make every re-download pass no-op on
  # exactly the files it exists to replace.
  if (file.exists(dest)) {
    if (valid_local_file(dest, "pdf", min_bytes)) {
      cli::cli_alert_info("Already exists and valid, skipping: {basename(dest)}")
      return("skipped")
    }
    cli::cli_alert_warning("Existing file invalid, re-downloading: {basename(dest)}")
    file.remove(dest)
  }

  # Ensure directory exists
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)

  # Download with polite delay
  resp <- polite_get(url)
  if (is.null(resp)) return(FALSE)
  if (httr::status_code(resp) != 200) {
    cli::cli_alert_danger("Download failed (HTTP {httr::status_code(resp)}): {basename(dest)}")
    return(FALSE)
  }

  # Write content
  tryCatch(
    {
      content_raw <- httr::content(resp, as = "raw")
      writeBin(content_raw, dest)
    },
    error = function(e) {
      cli::cli_alert_danger("Write error: {e$message}")
      if (file.exists(dest)) file.remove(dest)
      return(FALSE)
    }
  )

  # Validate: file size
  fsize <- file.info(dest)$size
  if (is.na(fsize) || fsize < min_bytes) {
    cli::cli_alert_warning("PDF too small ({fsize} bytes): {basename(dest)}")
    file.remove(dest)
    return(FALSE)
  }

  # Validate: magic bytes (%PDF-)
  tryCatch(
    {
      con <- file(dest, "rb")
      magic <- readBin(con, "raw", n = 5)
      close(con)
      magic_str <- rawToChar(magic)
      if (magic_str != "%PDF-") {
        cli::cli_alert_warning("Not a valid PDF (magic: {magic_str}): {basename(dest)}")
        file.remove(dest)
        return(FALSE)
      }
    },
    error = function(e) {
      cli::cli_alert_warning("Magic byte check error: {e$message}")
      if (file.exists(dest)) file.remove(dest)
      return(FALSE)
    }
  )

  cli::cli_alert_success("Downloaded: {basename(dest)} ({round(fsize/1024)}KB)")
  return(TRUE)
}

# ── File validation and non-PDF downloads ──────────────────────────────────
# Magic bytes and floors per kind. zip covers docx/xlsx (OOXML packages);
# doc/xls are OLE2 compound files.
FILE_KINDS <- list(
  pdf  = list(magic = charToRaw("%PDF-"),                  min_bytes = 10240L),
  zip  = list(magic = as.raw(c(0x50, 0x4B, 0x03, 0x04)),   min_bytes = 2048L),
  docx = list(magic = as.raw(c(0x50, 0x4B, 0x03, 0x04)),   min_bytes = 2048L),
  xlsx = list(magic = as.raw(c(0x50, 0x4B, 0x03, 0x04)),   min_bytes = 2048L),
  doc  = list(magic = as.raw(c(0xD0, 0xCF, 0x11, 0xE0)),   min_bytes = 4096L),
  xls  = list(magic = as.raw(c(0xD0, 0xCF, 0x11, 0xE0)),   min_bytes = 4096L)
)

#' Is a local file plausibly intact: present, above the size floor for its
#' kind, and starting with the right magic bytes?
valid_local_file <- function(path, kind = NULL, min_bytes = NULL) {
  if (!file.exists(path)) return(FALSE)
  if (is.null(kind)) kind <- tolower(tools::file_ext(path))
  spec <- FILE_KINDS[[kind]]
  if (is.null(spec)) return(file.info(path)$size > 0)   # unknown kind: exist + non-empty
  if (is.null(min_bytes)) min_bytes <- spec$min_bytes
  fsize <- file.info(path)$size
  if (is.na(fsize) || fsize < min_bytes) return(FALSE)
  magic <- tryCatch({
    con <- file(path, "rb"); on.exit(close(con))
    readBin(con, "raw", n = length(spec$magic))
  }, error = function(e) raw(0))
  identical(magic, spec$magic)
}

#' download_pdf for any FILE_KINDS kind: same politeness, same validation
#' discipline (size floor + magic bytes), same TRUE / FALSE / "skipped"
#' contract. kind defaults to the destination's extension.
download_file <- function(url, dest, kind = NULL, min_bytes = NULL) {
  if (is.null(kind)) kind <- tolower(tools::file_ext(dest))
  if (!kind %in% names(FILE_KINDS)) {
    cli::cli_alert_danger("download_file: unknown kind {kind} for {basename(dest)}")
    return(FALSE)
  }
  if (identical(kind, "pdf")) return(download_pdf(url, dest,
    min_bytes = if (is.null(min_bytes)) HTTP_CONFIG$min_pdf_bytes else min_bytes))
  if (is.null(min_bytes)) min_bytes <- FILE_KINDS[[kind]]$min_bytes

  if (file.exists(dest)) {
    if (valid_local_file(dest, kind, min_bytes)) {
      cli::cli_alert_info("Already exists and valid, skipping: {basename(dest)}")
      return("skipped")
    }
    cli::cli_alert_warning("Existing file invalid, re-downloading: {basename(dest)}")
    file.remove(dest)
  }
  dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
  resp <- polite_get(url)
  if (is.null(resp) || httr::status_code(resp) != 200) {
    cli::cli_alert_danger("Download failed: {basename(dest)}")
    return(FALSE)
  }
  ok <- tryCatch({ writeBin(httr::content(resp, as = "raw"), dest); TRUE },
                 error = function(e) {
                   cli::cli_alert_danger("Write error: {e$message}")
                   if (file.exists(dest)) file.remove(dest)
                   FALSE
                 })
  if (!ok) return(FALSE)
  if (!valid_local_file(dest, kind, min_bytes)) {
    cli::cli_alert_warning("Invalid {kind} (size or magic bytes): {basename(dest)}")
    file.remove(dest)
    return(FALSE)
  }
  cli::cli_alert_success("Downloaded: {basename(dest)} ({round(file.info(dest)$size/1024)}KB)")
  TRUE
}

# ── Response assertions ─────────────────────────────────────────────────────
# Every scraper failure found in the Oct 2026 audit was a source answering
# HTTP 200 with the wrong content: GCF returned an empty AJAX shell, the
# World Bank API returned total=0 for misspelled document types, AfDB served
# the same wildcard parent view for any path under /evaluation-reports/.
# assert_response makes a listing/API fetch fail LOUDLY unless the response
# demonstrably matches the request.

#' Assert that a response matches what was requested.
#'
#' @param resp httr response (or NULL) as returned by polite_get().
#' @param url  The requested URL, for messages and the log.
#' @param expect list with any of:
#'   status       allowed status codes (default 200:299)
#'   content_type prefix the Content-Type must start with (e.g. "text/html")
#'   min_bytes    minimum body size
#'   title        regex the HTML <title> must match
#'   contains     character vector of regexes that must ALL match the body —
#'                include something ECHOING THE REQUEST (the queried facet
#'                label, the searched term), or a wildcard view will pass
#'   not_contains regexes that must match NOWHERE (e.g. the known signature
#'                of a generic parent view)
#'   check        function(body_text) returning TRUE, or a message string
#' @param on_fail "stop" (default), "warn" (log + return NULL), or "quiet"
#'                (return NULL silently — for canaries that EXPECT failure).
#' @param source  source name for the download log.
#' @return resp invisibly on pass; NULL on fail when not stopping.
assert_response <- function(resp, url, expect = list(),
                            on_fail = c("stop", "warn", "quiet"), source = NA) {
  on_fail <- match.arg(on_fail)
  fail <- function(why) {
    if (on_fail != "quiet") {
      cli::cli_alert_danger("response assertion failed: {why}")
      cli::cli_alert_danger("  for: {url}")
      log_download(source = ifelse(is.na(source), "assert", source), url = url,
                   status = "assertion_failed", notes = why)
      if (on_fail == "stop") stop("assert_response: ", why, "\n  url: ", url, call. = FALSE)
    }
    NULL
  }
  if (is.null(resp)) return(fail("no response (transport failure or retries exhausted)"))
  status <- httr::status_code(resp)
  allowed <- if (is.null(expect$status)) 200:299 else expect$status
  if (!status %in% allowed) return(fail(paste0("HTTP ", status)))
  if (!is.null(expect$content_type)) {
    ct <- httr::headers(resp)[["content-type"]]
    if (is.null(ct) || !startsWith(tolower(ct), tolower(expect$content_type)))
      return(fail(paste0("content-type ", ct %||% "<none>", " != ", expect$content_type)))
  }
  body <- tryCatch(httr::content(resp, as = "text", encoding = "UTF-8"),
                   error = function(e) "")
  if (!is.null(expect$min_bytes) && nchar(body, type = "bytes") < expect$min_bytes)
    return(fail(paste0("body under ", expect$min_bytes, " bytes")))
  if (!is.null(expect$title)) {
    title <- sub(".*<title[^>]*>\\s*(.*?)\\s*</title>.*", "\\1",
                 gsub("[\r\n]", " ", body))
    if (!grepl(expect$title, title, ignore.case = TRUE))
      return(fail(paste0("page title ", substr(title, 1, 60), " !~ /", expect$title, "/")))
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
  invisible(resp)
}

`%||%` <- function(a, b) if (is.null(a)) b else a

#' Run at a scraper's start: the known-good listing must PASS its assertion
#' and a nonsense URL must FAIL it. Catches wildcard soft-200 servers (the
#' AfDB failure class) and assertions too weak to tell views apart.
canary_check <- function(source, good_url, expect, nonsense_url,
                         nonsense_expect = expect) {
  g <- assert_response(polite_get(good_url), good_url, expect,
                       on_fail = "warn", source = source)
  if (is.null(g))
    stop("canary (", source, "): the known-good listing failed its own assertion; ",
         "the site changed or the expectation is wrong - do not scrape blind", call. = FALSE)
  b <- assert_response(polite_get(nonsense_url), nonsense_url, nonsense_expect,
                       on_fail = "quiet", source = source)
  if (!is.null(b))
    stop("canary (", source, "): a NONSENSE url passed the assertion - the server ",
         "serves a wildcard view this expectation cannot tell apart; tighten `expect`",
         call. = FALSE)
  cli::cli_alert_success("canary ok ({source}): good listing passes, nonsense fails")
  invisible(TRUE)
}

# ── Attestation ledger ──────────────────────────────────────────────────────
# One row per document the source's website lists, with what we did about it.
# The ledger is the completeness guarantee: rerun the scraper, rebuild the
# site inventory, diff against the ledger, and only new or changed rows need
# action. Every row must carry a disposition; a gate fails on blanks.
ATTEST_DISPOSITIONS <- c("fetched", "already_held", "failed_download",
                         "out_by_type", "duplicate", "parked_progress",
                         "excluded_desk_review", "held_pending_window_decision")
ATTEST_COLS <- c("source", "site_id", "title", "doc_type_site", "listing",
                 "discovered_at", "disposition", "local_filename", "notes")

attestation_path <- function(source)
  file.path(PROJECT_ROOT, "catalogues", source, "attestation.csv")

read_attestation <- function(source) {
  p <- attestation_path(source)
  if (!file.exists(p)) return(NULL)
  readr::read_csv(p, col_types = readr::cols(.default = "c"))
}

#' Validate and write a source's ledger (full overwrite: the ledger always
#' mirrors the latest site inventory). Carries discovered_at forward for rows
#' already known.
write_attestation <- function(source, df) {
  stopifnot(all(c("site_id", "disposition") %in% names(df)))
  for (col in ATTEST_COLS) if (!col %in% names(df)) df[[col]] <- NA_character_
  df$source <- source
  bad <- !df$disposition %in% ATTEST_DISPOSITIONS
  if (any(bad))
    stop("write_attestation(", source, "): ", sum(bad), " rows with dispositions outside the vocabulary: ",
         paste(unique(df$disposition[bad]), collapse = ", "), call. = FALSE)
  old <- read_attestation(source)
  if (!is.null(old)) {
    keep <- setNames(old$discovered_at, old$site_id)
    known <- df$site_id %in% names(keep)
    df$discovered_at[known] <- keep[df$site_id[known]]
  }
  df$discovered_at[is.na(df$discovered_at)] <- format(Sys.Date())
  p <- attestation_path(source)
  dir.create(dirname(p), recursive = TRUE, showWarnings = FALSE)
  readr::write_csv(df[, ATTEST_COLS], p)
  cli::cli_alert_success("attestation ({source}): {nrow(df)} rows, all dispositioned")
  invisible(df)
}

# ── Safe Filename ──────────────────────────────────────────────────────────
#' Sanitize a string for use as a filename.
#'
#' @param x Character. Input string.
#' @param max_len Integer. Maximum filename length.
#' @return A safe filename string.
safe_filename <- function(x, max_len = 120) {
  x <- as.character(x)
  x <- iconv(x, to = "ASCII//TRANSLIT", sub = "")
  x <- str_replace_all(x, "[^A-Za-z0-9_\\-]", "_")
  x <- str_replace_all(x, "_+", "_")
  x <- str_replace_all(x, "^_|_$", "")
  x <- str_sub(x, 1, max_len)
  if (nchar(x) == 0) x <- "unnamed"
  x
}

# ── Relevance Filter ──────────────────────────────────────────────────────
#' Check if text matches Africa AND (agriculture OR adaptation) keywords.
#'
#' @param text Character. Text to check (title, abstract, description, etc.)
#' @param require_africa Logical. Whether to require an Africa match.
#' @param require_sector Logical. Whether to require agriculture OR adaptation match.
#' @return TRUE if the text passes the filter.
passes_relevance_filter <- function(text,
                                    require_africa = TRUE,
                                    require_sector = TRUE) {
  if (is.null(text) || is.na(text) || nchar(text) == 0) return(FALSE)
  text_lower <- tolower(text)

  has_africa <- !require_africa
  has_sector <- !require_sector

  if (require_africa) {
    has_africa <- any(sapply(AFRICA_ALL, function(kw) {
      grepl(kw, text_lower, fixed = TRUE)
    }))
  }

  if (require_sector) {
    has_agri <- any(sapply(AGRICULTURE_ALL, function(kw) {
      grepl(kw, text_lower, fixed = TRUE)
    }))
    has_adapt <- any(sapply(ADAPTATION_ALL, function(kw) {
      grepl(kw, text_lower, fixed = TRUE)
    }))
    has_sector <- has_agri || has_adapt
  }

  has_africa && has_sector
}

# ── Faster relevance filter using single regex ─────────────────────────────
#' Build a single regex from a keyword vector for fast matching.
build_regex <- function(keywords) {
  # Escape special regex chars and join with |
  escaped <- str_replace_all(keywords, "([\\[\\](){}\\\\.*+?^$|])", "\\\\\\1")
  paste0("(?:", paste(escaped, collapse = "|"), ")")
}

# Pre-build regex patterns for speed
AFRICA_REGEX    <- build_regex(AFRICA_ALL)
AGRI_REGEX      <- build_regex(AGRICULTURE_ALL)
ADAPT_REGEX     <- build_regex(ADAPTATION_ALL)

#' Fast relevance filter using pre-compiled regex.
passes_relevance_fast <- function(text, require_africa = TRUE, require_sector = TRUE) {
  if (is.null(text) || is.na(text) || nchar(text) == 0) return(FALSE)
  text_lower <- tolower(text)

  if (require_africa && !grepl(AFRICA_REGEX, text_lower, perl = TRUE)) return(FALSE)
  if (require_sector) {
    has_agri  <- grepl(AGRI_REGEX, text_lower, perl = TRUE)
    has_adapt <- grepl(ADAPT_REGEX, text_lower, perl = TRUE)
    if (!has_agri && !has_adapt) return(FALSE)
  }
  TRUE
}

# ── Download Logger ────────────────────────────────────────────────────────
#' Append a log entry to the download log CSV.
#'
#' @param source Character. Source name (e.g., "worldbank", "gcf").
#' @param project_code Character. Project identifier.
#' @param doc_type Character. Document type.
#' @param title Character. Document title.
#' @param url Character. Download URL.
#' @param filepath Character. Local file path (or NA).
#' @param status Character. One of: success, failed, skipped, filtered, blocked, requires_browser.
#' @param notes Character. Additional notes.
log_download <- function(source, project_code = NA, doc_type = NA,
                         title = NA, url = NA, filepath = NA,
                         status = "success", notes = NA) {
  entry <- tibble(
    timestamp    = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
    source       = source,
    project_code = as.character(project_code),
    doc_type     = as.character(doc_type),
    title        = as.character(title),
    url          = as.character(url),
    filepath     = as.character(filepath),
    status       = status,
    notes        = as.character(notes)
  )

  # GL_LOG_SUFFIX shards the log per source (download_log_<suffix>.csv) so
  # concurrently running scrapers never append to the same file; merge with
  # merge_download_logs() afterwards.
  log_path <- PATHS$log_file
  suffix <- Sys.getenv("GL_LOG_SUFFIX", "")
  if (nzchar(suffix)) log_path <- sub("\\.csv$", paste0("_", suffix, ".csv"), log_path)

  if (file.exists(log_path)) {
    readr::write_csv(entry, log_path, append = TRUE)
  } else {
    readr::write_csv(entry, log_path)
  }
}

#' Fold sharded download logs (download_log_<suffix>.csv) back into the main
#' log, ordered by timestamp, and remove the shards.
merge_download_logs <- function() {
  main <- PATHS$log_file
  shards <- Sys.glob(sub("\\.csv$", "_*.csv", main))
  if (!length(shards)) return(invisible(0L))
  all <- lapply(c(if (file.exists(main)) main, shards),
                readr::read_csv, col_types = readr::cols(.default = "c"))
  out <- dplyr::arrange(dplyr::bind_rows(all), timestamp)
  readr::write_csv(out, main)
  file.remove(shards)
  cli::cli_alert_success("merged {length(shards)} log shard{?s} into {basename(main)}")
  invisible(length(shards))
}

# ── Summary Reporter ───────────────────────────────────────────────────────
#' Print a summary of the download log for a given source.
print_source_summary <- function(source_name) {
  log_path <- PATHS$log_file
  if (!file.exists(log_path)) {
    cli::cli_alert_warning("No log file found.")
    return(invisible(NULL))
  }

  log <- readr::read_csv(log_path, show_col_types = FALSE) %>%
    filter(source == source_name)

  if (nrow(log) == 0) {
    cli::cli_alert_warning("No entries for source: {source_name}")
    return(invisible(NULL))
  }

  counts <- log %>% count(status) %>% arrange(desc(n))

  cli::cli_h2("Summary for: {source_name}")
  cli::cli_text("Total entries: {nrow(log)}")
  for (i in seq_len(nrow(counts))) {
    cli::cli_text("  {counts$status[i]}: {counts$n[i]}")
  }

  return(invisible(log))
}

# ── Check required packages ────────────────────────────────────────────────
check_packages <- function() {
  required <- c("httr", "rvest", "dplyr", "stringr", "readr", "jsonlite",
                 "xml2", "glue", "fs", "cli", "lubridate", "tibble",
                 "curl", "purrr")
  missing <- required[!sapply(required, requireNamespace, quietly = TRUE)]
  if (length(missing) > 0) {
    cli::cli_alert_danger("Missing packages: {paste(missing, collapse = ', ')}")
    cli::cli_alert_info("Install with: install.packages(c({paste0('\"', missing, '\"', collapse = ', ')}))")
    return(FALSE)
  }
  cli::cli_alert_success("All required packages are installed.")
  return(TRUE)
}

cat("✓ Utils loaded.\n")
