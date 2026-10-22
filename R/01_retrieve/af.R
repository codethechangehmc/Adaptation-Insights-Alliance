##############################################################################
# af.R — Adaptation Fund Document Scraper
#
# Targets: EVALUATION documents (mid-term/final/terminal evaluations,
#          project completion reports) of Adaptation Fund projects in
#          Africa. PPRs (annual Project Performance Reports) are PROGRESS
#          documents: catalogued as parked_progress, never downloaded
#          (parked question for the team). Proposals / project documents /
#          inception reports / management responses: out_by_type.
#
# PRIMARY channel (switched 2026-10-02): the fund's OWN site.
#   1. ONE GET of /projects-programmes/project-information/projects-table-view/
#      which embeds the whole portfolio as a JS array `var projects = [...]`
#      (196 rows: name/country/sector/status/region/link).
#   2. For each African project, GET its project page and collect every
#      document anchor on https://fifspubprd.azureedge.net/... where the
#      ANCHOR TEXT is the clean document type ("Mid-term evaluation report",
#      "Final evaluation report", "Project completion report", "PPR1 (for
#      web)"). CAUTION (verified 2026-10-02): the pages sometimes reuse an
#      evaluation anchor text for a management response (e.g. anchor
#      "Mid-term evaluation report" -> ".../IFAD Management Response
#      ACREGIR MTR.pdf"), so classification checks the decoded href
#      filename for management-response markers FIRST.
#
# FALLBACK channel (CPR, kept below clearly marked): the Climate Policy
# Radar public API. Measured recall is 57% (39 of 69 African AF projects):
# page_size caps at 100 with no pagination, the country query templates all
# converge on the same global top-100, and CPR lags the fund's own store.
# The cpr_* client is still shared with the GCF gap-fill (gcf_gapfill.R
# sources this file with AF_MODE=load and calls run_mcf_scraper("GCF.")).
#
# Run modes via env var AF_MODE: full (default, site scraper) | probe (CPR
# probe) | cpr (legacy CPR scraper) | load (define functions only)
##############################################################################

# ── Setup ──────────────────────────────────────────────────────────────────
.find_r_dir <- function() {
  tryCatch({
    d <- dirname(sys.frame(2)$ofile)
    if (!is.null(d) && nzchar(d)) return(normalizePath(d, mustWork = FALSE))
  }, error = function(e) NULL)
  tryCatch({
    args <- commandArgs(trailingOnly = FALSE)
    fa <- grep("^--file=", args, value = TRUE)
    if (length(fa)) return(normalizePath(dirname(sub("^--file=", "", fa[1])), mustWork = FALSE))
  }, error = function(e) NULL)
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
# paths.R gives DOCS_ROOT (the corpus lives in the sibling 03_Documents)
if (!exists("DOCS_ROOT")) {
  .r_dir2 <- .find_r_dir()
  for (.p in file.path(.r_dir2, c(".", "..", "../00_shared", "00_shared", "R/00_shared"), "paths.R")) if (file.exists(.p)) { source(.p); break }
}
if (!exists("DOCS_ROOT") && exists("PROJECT_ROOT"))
  DOCS_ROOT <- normalizePath(file.path(PROJECT_ROOT, "..", "03_Documents"),
                             mustWork = FALSE)

SOURCE_NAME  <- "af"
DOWNLOAD_DIR <- file.path(PATHS$downloads, SOURCE_NAME)   # CPR fallback only
dir.create(DOWNLOAD_DIR, recursive = TRUE, showWarnings = FALSE)

AF_DOCS_DIR      <- file.path(DOCS_ROOT, "af")
AF_LIST_DIR      <- file.path(AF_DOCS_DIR, "List")
AF_TO_SCREEN_DIR <- file.path(AF_DOCS_DIR, "Docs", "to_screen")

# ── Configuration: fund site (primary) ──────────────────────────────────────
AF_BASE         <- "https://www.adaptation-fund.org"
AF_TABLE_URL    <- paste0(AF_BASE, "/projects-programmes/project-information/projects-table-view/")
AF_TABLE_CANARY <- paste0(AF_BASE, "/projects-programmes/project-information/projects-table-view-zzz-canary/")
AF_DOC_HOST_RE  <- "fifspubprd"           # the fund's document store CDN
AF_PORTFOLIO_EXPECTED <- 196L             # verified 2026-10-02; report divergence
AF_PORTFOLIO_MIN      <- 150L             # hard assertion floor

# ── Configuration: CPR fallback ─────────────────────────────────────────────
CPR_API <- "https://api.climatepolicyradar.org"
CPE_WEB <- "https://climateprojectexplorer.org"
MCF_QUERY_TEMPLATES <- c(
  "{country} final evaluation report",
  "{country} mid-term evaluation",
  "{country} project completion evaluation"
)
MCF_PAGE_SIZE <- 100
AF_YEAR_MIN <- 2015L

# ── Document-type classification ────────────────────────────────────────────
# Canonical type labels. Order of checks is FIXED: management response /
# matrix of responses FIRST (never an evaluation), then the evaluation
# types, then progress/other. The two on-disk mislabels
# (af_AF00000109_Mid-term_evaluation_2019.pdf and
#  af_AFRDG00001_Completion_report_2016.pdf, both management responses)
# came from matching "mid-term evaluation" / "completion report" anywhere
# in a title without this precedence.
AF_EVAL_TYPES <- c("Mid-term evaluation", "Final evaluation",
                   "Terminal evaluation", "Performance evaluation",
                   "Completion report", "Evaluation report")
AF_PROGRESS_TYPES <- c("Performance report (PPR)", "Monitoring report")

# PPR detection. Some pages use the FILE NAME as the anchor text
# ("AF00000177_PPR3_Web.pdf") or a language label ("English" -> a PPR href),
# so the href is consulted too. "[^a-z]ppr" (not "\\bppr") because "_" is a
# word character: "\\bppr" misses "AF00000177_PPR3". The leading
# non-letter also keeps "approval" from matching.
AF_PPR_RE <- paste0(
  "(^|[^a-z])ppr[ _-]?[0-9]|(^|[^a-z])ppr([^a-z]|$)|",
  "project performance report|(annual )?performance report"
)

# Files on disk whose NAME says one type and whose CONTENT is another (see
# audit/2026-10_completeness/af_retype.csv). They are never renamed — the
# screening rows are keyed by filename — but they must NEVER satisfy an
# already_held match, or the real evaluation they are named after is
# silently treated as held and never fetched. That is exactly what happened
# to the UN-Habitat mid-term evaluation (project 5199) on the first run.
AF_MISTYPED_ON_DISK <- c(
  "af_AF00000109_Mid-term_evaluation_2019.pdf",   # UN-Habitat management response
  "af_AFRDG00001_Completion_report_2016.pdf"      # SANBI ESP management response
)

AF_MGMT_RE <- paste0(
  "management'?s? response|matrix of response|response matrix|",
  "mgmn?t\\.? ?response|management reponse|",
  "response to (the )?(draft )?(mid-?term|terminal|final|project) ?(project )?(evaluation|review)"
)

url_decode_safe <- function(x) {
  vapply(as.character(x), function(s) {
    if (is.na(s)) return("")
    tryCatch(utils::URLdecode(s), error = function(e) s)
  }, character(1), USE.NAMES = FALSE)
}

#' Classify a document from its title/anchor text (and, for the
#' management-response rule only, the decoded href filename — the fund's
#' pages reuse evaluation anchor texts for management responses).
mcf_doc_type <- function(title, href = "") {
  t <- tolower(coalesce(as.character(title), ""))
  h <- tolower(basename(url_decode_safe(coalesce(as.character(href), ""))))
  # 1. management response / matrix of responses — NEVER an evaluation
  if (grepl(AF_MGMT_RE, t) || grepl(AF_MGMT_RE, h)) return("Management response")
  # 2. mid-term evaluation / review
  if (grepl("mid[ _-]*term[ _-]*(project[ _-]*)?(evaluation|review|eval\\b)", t)) return("Mid-term evaluation")
  # 3. final / terminal evaluation
  if (grepl("terminal evaluation", t))   return("Terminal evaluation")
  if (grepl("final evaluation", t))      return("Final evaluation")
  if (grepl("performance evaluation", t)) return("Performance evaluation")
  # 4. project completion report
  if (grepl("completion report|project completion", t)) return("Completion report")
  if (grepl("^evaluation( report)?$|^evaluation report", t)) return("Evaluation report")
  # 5. PPR — annual Project Performance Report: PROGRESS, never fetched.
  #    Checked in the href too (filename-as-anchor-text, language labels).
  if (grepl(AF_PPR_RE, t) || grepl(AF_PPR_RE, h)) return("Performance report (PPR)")
  # 6. monitoring report — also a progress document
  if (grepl("monitoring report", t)) return("Monitoring report")
  # 7. inception report
  if (grepl("inception", t)) return("Inception report")
  # 8. proposal / project document / concept
  if (grepl("project document|proposal|concept|project formulation", t)) return("Project document")
  # 9. other
  "Other"
}

#' Best-effort document year: 4-digit year in the anchor text, else in the
#' decoded href filename (latest plausible year wins — evaluation filenames
#' often carry both the project-era and the report year). NA when nothing
#' is visible: the file then stays WITHOUT a year suffix rather than a
#' wrong one.
af_doc_year <- function(text, href = "") {
  pick <- function(s) {
    ys <- regmatches(s, gregexpr("(?<![0-9])(19|20)[0-9]{2}(?![0-9])", s, perl = TRUE))[[1]]
    ys <- suppressWarnings(as.integer(ys))
    ys <- ys[!is.na(ys) & ys >= 1990 & ys <= 2035]
    if (length(ys)) max(ys) else NA_integer_
  }
  y <- pick(coalesce(as.character(text), ""))
  if (is.na(y)) y <- pick(basename(url_decode_safe(coalesce(as.character(href), ""))))
  y
}

af_type_label <- function(type) gsub(" ", "_", type, fixed = TRUE)

# ── Site enumeration: the projects-table-view JS array ──────────────────────
#' Extract the JSON text of `var <varname> = [...]` from a page body,
#' robustly (bracket matching that respects JSON strings and escapes).
af_extract_js_array <- function(body, varname = "projects") {
  m <- regexpr(paste0("var\\s+", varname, "\\s*="), body)
  if (m < 0) return(NULL)
  rest <- substr(body, m + attr(m, "match.length"), nchar(body))
  off <- regexpr("[", rest, fixed = TRUE)
  if (off < 0) return(NULL)
  chars <- strsplit(substr(rest, off, nchar(rest)), "", fixed = TRUE)[[1]]
  depth <- 0L; in_str <- FALSE; esc <- FALSE
  for (i in seq_along(chars)) {
    ch <- chars[i]
    if (in_str) {
      if (esc) esc <- FALSE
      else if (ch == "\\") esc <- TRUE
      else if (ch == "\"") in_str <- FALSE
    } else {
      if (ch == "\"") in_str <- TRUE
      else if (ch == "[") depth <- depth + 1L
      else if (ch == "]") {
        depth <- depth - 1L
        if (depth == 0L) return(paste(chars[1:i], collapse = ""))
      }
    }
  }
  NULL
}

.af_html_unescape <- function(x) {
  vapply(as.character(x), function(s) {
    if (is.na(s) || !nzchar(s) || !grepl("&", s, fixed = TRUE)) return(coalesce(s, ""))
    tryCatch(xml2::xml_text(xml2::read_html(paste0("<x>", s, "</x>"))),
             error = function(e) s)
  }, character(1), USE.NAMES = FALSE)
}

#' Parse the portfolio table page body into a tibble
#' (name, country, sector, status, region, link). NULL on failure.
af_parse_projects <- function(body) {
  arr <- af_extract_js_array(body, "projects")
  if (is.null(arr)) return(NULL)
  js <- tryCatch(jsonlite::fromJSON(arr, simplifyDataFrame = TRUE),
                 error = function(e) {
                   # JS-not-quite-JSON cleanup: trailing commas
                   arr2 <- gsub(",\\s*([\\]}])", "\\1", arr)
                   tryCatch(jsonlite::fromJSON(arr2, simplifyDataFrame = TRUE),
                            error = function(e2) NULL)
                 })
  if (is.null(js) || !is.data.frame(js) || !nrow(js)) return(NULL)
  need <- c("name", "d_country", "sectors", "status_dis", "region", "link")
  if (!all(need %in% names(js))) return(NULL)
  tibble(
    name    = .af_html_unescape(js$name),
    country = coalesce(js$d_country, ""),
    sector  = coalesce(js$sectors, ""),
    status  = coalesce(js$status_dis, ""),
    region  = coalesce(js$region, ""),
    link    = coalesce(js$link, "")
  )
}

#' Canary + fetch + assert + parse the whole portfolio in ONE request
#' (plus the two canary requests).
af_fetch_portfolio <- function() {
  expect <- list(
    content_type = "text/html",
    min_bytes    = 50000,
    contains     = c("var\\s+projects"),
    check        = function(body) {
      df <- af_parse_projects(body)
      if (is.null(df)) return("`var projects` present but the array did not parse")
      if (nrow(df) < AF_PORTFOLIO_MIN)
        return(paste0("only ", nrow(df), " portfolio rows parsed (need >= ", AF_PORTFOLIO_MIN, ")"))
      TRUE
    }
  )
  canary_check(SOURCE_NAME, AF_TABLE_URL, expect, AF_TABLE_CANARY)
  resp <- polite_get(AF_TABLE_URL)
  assert_response(resp, AF_TABLE_URL, expect, source = SOURCE_NAME)
  body <- httr::content(resp, as = "text", encoding = "UTF-8")
  df <- af_parse_projects(body)
  if (nrow(df) != AF_PORTFOLIO_EXPECTED)
    cli::cli_alert_warning("portfolio rows = {nrow(df)} (expected {AF_PORTFOLIO_EXPECTED}) - DIVERGENCE, report it")
  df
}

# ── Harvest: one project page -> its fifspubprd document anchors ────────────
af_harvest_page <- function(url) {
  resp <- polite_get(url)
  st <- if (is.null(resp)) NA_integer_ else httr::status_code(resp)
  if (is.null(resp) || st != 200) {
    return(list(ok = FALSE, status = st, anchors = NULL, africa = NA))
  }
  body <- httr::content(resp, as = "text", encoding = "UTF-8")
  html <- tryCatch(xml2::read_html(body), error = function(e) NULL)
  if (is.null(html)) return(list(ok = FALSE, status = st, anchors = NULL, africa = NA))
  a    <- rvest::html_elements(html, "a")
  href <- rvest::html_attr(a, "href")
  keep <- !is.na(href) & grepl(AF_DOC_HOST_RE, href)
  anchors <- tibble(
    anchor_text = stringr::str_squish(rvest::html_text2(a[keep])),
    href        = href[keep]
  ) %>% distinct(href, .keep_all = TRUE)
  list(ok = TRUE, status = st, anchors = anchors,
       africa = grepl(AFRICA_REGEX, tolower(body), perl = TRUE))
}

# ── Matching fresh site documents against what is already on disk ───────────
# Matching rule (two tiers, then a basename identity check at download):
#  A. url-tail: the anchor's decoded, lowercased basename equals the decoded
#     basename of a source_url in List/af_metadata.csv -> that row's
#     project_id; a disk file af_{pid}_{Type_label}_* (year ignored: existing
#     suffixes are FAMILY years, not document years) of the SAME classified
#     type = already_held.
#  B. site project number: href path /afdocuments/project/N/ -> project_id
#     via any metadata row sharing that N, then the same disk check.
#  C. at download time: an identical target basename anywhere under
#     03_Documents/af/ = already_held (never overwrite).
af_disk_index <- function() {
  files <- list.files(AF_DOCS_DIR, recursive = TRUE, full.names = TRUE)
  files <- files[grepl("\\.(pdf|docx?|xlsx?)$", files, ignore.case = TRUE)]
  tibble(path = files, base = basename(files), lower = tolower(basename(files)))
}

af_meta_index <- function() {
  p <- file.path(AF_LIST_DIR, "af_metadata.csv")
  if (!file.exists(p)) return(NULL)
  m <- suppressWarnings(readr::read_csv(p, col_types = readr::cols(.default = "c"),
                                        progress = FALSE))
  if (!all(c("project_id", "source_url") %in% names(m))) return(NULL)
  m$src_base  <- tolower(basename(url_decode_safe(coalesce(m$source_url, ""))))
  m$site_num  <- stringr::str_match(coalesce(m$source_url, ""),
                                    "/afdocuments/project/(\\d+)/")[, 2]
  m
}

af_site_num <- function(href) stringr::str_match(href, "/afdocuments/project/(\\d+)/")[, 2]

#' Returns list(pid, held_file): pid = project_id when identifiable (else
#' NA), held_file = matching on-disk basename of the same type (else NA).
af_match_disk <- function(href, type, disk, meta) {
  pid <- NA_character_; held <- NA_character_
  if (!is.null(meta)) {
    base <- tolower(basename(url_decode_safe(href)))
    pids <- unique(meta$project_id[meta$src_base == base & nzchar(meta$src_base)])
    if (!length(pids)) {
      num <- af_site_num(href)
      if (!is.na(num))
        pids <- unique(meta$project_id[!is.na(meta$site_num) & meta$site_num == num])
    }
    if (length(pids)) {
      pid <- pids[1]
      lab <- af_type_label(type)
      for (p in pids) {
        pat <- paste0("^af_", tolower(p), "_", tolower(lab), "(_|\\.)")
        hit <- disk$base[grepl(pat, disk$lower)]
        # a known-mistyped file never counts as holding this type
        hit <- hit[!tolower(hit) %in% tolower(AF_MISTYPED_ON_DISK)]
        if (length(hit)) { pid <- p; held <- hit[1]; break }
      }
    }
  }
  list(pid = pid, held = held)
}

# ── Main scraper (site channel) ─────────────────────────────────────────────
run_af_scraper <- function(max_pages = Inf) {
  cli::cli_h1("Adaptation Fund scraper - fund site channel")
  dir.create(AF_TO_SCREEN_DIR, recursive = TRUE, showWarnings = FALSE)
  dir.create(AF_LIST_DIR, recursive = TRUE, showWarnings = FALSE)

  ## 1. portfolio (one request + canary)
  portfolio <- af_fetch_portfolio()
  readr::write_csv(portfolio, file.path(AF_LIST_DIR, "af_portfolio.csv"))
  cli::cli_alert_success("portfolio: {nrow(portfolio)} rows -> af_portfolio.csv")
  reg <- table(portfolio$region)
  cli::cli_alert_info("regions: {paste(names(reg), as.integer(reg), sep='=', collapse=' | ')}")

  ## 2. Africa selection: region == Africa, plus region == Other rows whose
  ##    project page confirms African countries (the regional Kunene
  ##    Angola/Namibia project sits under Other with country "Regional").
  africa <- portfolio %>%
    filter(region %in% c("Africa", "Other")) %>%
    distinct(link, .keep_all = TRUE)
  cli::cli_alert_info("Africa rows: {sum(africa$region == 'Africa')} + {sum(africa$region == 'Other')} under Other to verify on-page")

  ## 3. harvest project pages
  rows <- list(); page_fail <- list(); n_hard <- 0L
  n_do <- min(nrow(africa), max_pages)
  for (i in seq_len(n_do)) {
    pr <- africa[i, ]
    h <- af_harvest_page(pr$link)
    if (!h$ok) {
      page_fail[[length(page_fail) + 1]] <- tibble(link = pr$link, status = h$status)
      if (!is.na(h$status) && h$status %in% c(403L, 429L)) {
        n_hard <- n_hard + 1L
        if (n_hard >= 2L) stop("persistent 403/429 from adaptation-fund.org after backoff - stopping (politeness)", call. = FALSE)
      }
      next
    }
    n_hard <- 0L
    if (pr$region == "Other" && !isTRUE(h$africa)) {
      cli::cli_alert_info("skipping non-African 'Other' project: {pr$name}")
      next
    }
    if (nrow(h$anchors)) {
      rows[[length(rows) + 1]] <- h$anchors %>%
        mutate(project = pr$name, country = pr$country, status_dis = pr$status,
               region = pr$region, page = pr$link)
    }
    if (i %% 10 == 0) cli::cli_alert_info("pages: {i}/{n_do} | anchors so far: {sum(vapply(rows, nrow, 1L))}")
  }
  anchors <- bind_rows(rows)
  if (length(page_fail)) {
    pf <- bind_rows(page_fail)
    cli::cli_alert_warning("{nrow(pf)} project page(s) failed: {paste(pf$link, '(HTTP', pf$status, ')', collapse='; ')}")
  } else pf <- tibble(link = character(), status = integer())
  cli::cli_alert_success("harvest: {nrow(anchors)} fifspubprd anchors across {n_do - nrow(pf)} pages")

  ## 4. classify (anchor text, href consulted for the mgmt-response rule)
  anchors <- anchors %>%
    mutate(
      doc_type = mapply(mcf_doc_type, anchor_text, href, USE.NAMES = FALSE),
      doc_year = mapply(af_doc_year, anchor_text, href, USE.NAMES = FALSE),
      site_id  = sub("^https?://[^/]+", "", href)
    )
  # dedup by site_id across pages: prefer a classified (non-Other) row
  anchors <- anchors %>%
    group_by(site_id) %>%
    arrange(doc_type == "Other", .by_group = TRUE) %>%
    mutate(n_listings = dplyr::n(), other_pages = paste(setdiff(page, first(page)), collapse = "; ")) %>%
    slice(1) %>% ungroup()
  cli::cli_h2("anchors by classified type")
  print(table(anchors$doc_type))

  ## 5. dispositions + downloads
  disk <- af_disk_index()
  meta <- af_meta_index()
  assigned <- character(0)   # target basenames assigned this run (collision guard)

  n <- nrow(anchors)
  disposition <- character(n); local_filename <- rep(NA_character_, n)
  notes <- character(n)

  for (i in seq_len(n)) {
    r <- anchors[i, ]
    typ <- r$doc_type
    note <- paste0("classified: ", typ)
    if (nzchar(r$other_pages)) note <- paste0(note, "; also listed on: ", r$other_pages)

    if (typ %in% AF_PROGRESS_TYPES) {
      disposition[i] <- "parked_progress"
      notes[i] <- paste0(note, "; PPR = progress document, parked question for the team")
      next
    }
    if (!typ %in% AF_EVAL_TYPES) {
      disposition[i] <- "out_by_type"
      notes[i] <- note
      next
    }

    ## evaluation-type: held / fetch / failed
    m <- af_match_disk(r$href, typ, disk, meta)
    if (!is.na(m$held)) {
      disposition[i] <- "already_held"
      local_filename[i] <- m$held
      notes[i] <- paste0(note, "; matched by ",
                         if (tolower(basename(url_decode_safe(r$href))) %in% meta$src_base)
                           "url-tail" else "site project number", " -> ", m$pid)
      next
    }
    id_part <- if (!is.na(m$pid)) m$pid else {
      slug <- sub("/$", "", r$page)
      slug <- sub(".*/", "", slug)
      slug <- substr(slug, 1, 60); slug <- sub("-+$", "", slug)
      num <- af_site_num(r$href)
      if (!is.na(num)) paste0(slug, "-p", num) else slug
    }
    ext <- tolower(tools::file_ext(basename(url_decode_safe(r$href))))
    if (!ext %in% names(FILE_KINDS)) ext <- "pdf"
    fname <- paste0("af_", id_part, "_", af_type_label(typ),
                    ifelse(is.na(r$doc_year), "", paste0("_", r$doc_year)), ".", ext)
    if (tolower(fname) %in% assigned) {    # two docs would share a name: disambiguate
      fname <- sub(paste0("\\.", ext, "$"), paste0("_", i, ".", ext), fname)
    }
    assigned <- c(assigned, tolower(fname))

    hit <- disk$path[disk$lower == tolower(fname)]
    if (length(hit)) {                      # identical basename anywhere under af/: never overwrite
      disposition[i] <- "already_held"
      local_filename[i] <- basename(hit[1])
      notes[i] <- paste0(note, "; identical basename already on disk: ",
                         sub(".*/af/", "af/", hit[1]))
      next
    }

    dest <- file.path(AF_TO_SCREEN_DIR, fname)
    ok <- download_file(r$href, dest)
    if (identical(ok, TRUE) || identical(ok, "skipped")) {
      disposition[i] <- "fetched"
      local_filename[i] <- fname
      notes[i] <- note
      disk <- bind_rows(disk, tibble(path = dest, base = fname, lower = tolower(fname)))
      log_download(SOURCE_NAME, project_code = id_part, doc_type = typ,
                   title = paste0(r$project, " - ", r$anchor_text),
                   url = r$href, filepath = dest, status = "success")
    } else {
      probe <- polite_get(r$href)
      code <- if (is.null(probe)) "no response" else paste0("HTTP ", httr::status_code(probe))
      if (identical(code, "HTTP 200")) code <- "HTTP 200 but size/magic-byte validation failed"
      disposition[i] <- "failed_download"
      notes[i] <- paste0(note, "; ", code)
      log_download(SOURCE_NAME, project_code = id_part, doc_type = typ,
                   title = paste0(r$project, " - ", r$anchor_text),
                   url = r$href, filepath = dest, status = "failed", notes = code)
    }
  }

  anchors$disposition <- disposition
  anchors$local_filename <- local_filename
  anchors$notes <- notes

  ## 6. the two known mislabels (see audit/2026-10_completeness/af_retype.csv):
  ##    both are management responses held on disk under evaluation names.
  ##    Files are NOT renamed (screening rows are keyed by filename).
  i109 <- grepl("UN-?Habitat ?Mgmn?t ?response", url_decode_safe(anchors$href), ignore.case = TRUE)
  if (any(i109)) {
    anchors$local_filename[i109] <- "af_AF00000109_Mid-term_evaluation_2019.pdf"
    anchors$notes[i109] <- paste0(anchors$notes[i109],
      "; held on disk under an evaluation name (6-page UN-Habitat management response) - re-judge, see af_retype.csv")
  }
  ledger <- anchors %>%
    transmute(source = SOURCE_NAME, site_id,
              title = paste0(project, " - ", anchor_text),
              doc_type_site = anchor_text, listing = page,
              discovered_at = NA_character_, disposition, local_filename, notes)
  # AFRDG00001 (readiness grant, page not in the projects-table-view): the
  # on-disk "completion report" is a 3-page management response (md5 matches
  # the CPR cdn object). Ledgered manually so the retype is on the record.
  if (!any(grepl("6551_SANBI AF TA Grant_ESP_Completion Report_20180328",
                 url_decode_safe(ledger$site_id), fixed = TRUE))) {
    ledger <- bind_rows(ledger, tibble(
      source = SOURCE_NAME,
      site_id = "/afdocuments/project/6551/6551_SANBI AF TA Grant_ESP_Completion Report_20180328.pdf",
      title = "Technical Assistance Grant for ESP (AFRDG00001) - Management response misfiled as Project completion report",
      doc_type_site = "Project completion report (CPR title)",
      listing = "CPR family AF.family.AFRDG00001.0 (readiness grant; not in projects-table-view)",
      discovered_at = NA_character_,
      disposition = "out_by_type",
      local_filename = "af_AFRDG00001_Completion_report_2016.pdf",
      notes = "management response (3 pages) held on disk under a completion-report name; md5 994a3bd34b6568f27a69008516be3686 matches CPR cdn object - re-judge, see af_retype.csv"
    ))
  }
  write_attestation(SOURCE_NAME, ledger)

  ## 7. cross-check the completeness-audit candidate list
  miss_p <- file.path(PROJECT_ROOT, "audit", "2026-10_completeness", "af_missing_files.csv")
  if (file.exists(miss_p)) {
    miss <- readr::read_csv(miss_p, col_types = readr::cols(.default = "c"), progress = FALSE)
    miss$site_id <- sub("^https?://[^/]+", "", miss$url)
    key <- function(x) tolower(url_decode_safe(x))
    idx <- match(key(miss$site_id), key(ledger$site_id))
    miss$fresh_disposition <- ifelse(is.na(idx), "NOT-ON-SITE-ANYMORE", ledger$disposition[idx])
    miss$fresh_local_file  <- ifelse(is.na(idx), NA, ledger$local_filename[idx])
    cli::cli_h2("af_missing_files.csv cross-check ({nrow(miss)} rows)")
    print(as.data.frame(miss[, c("doc_text", "fresh_disposition", "fresh_local_file")]), width = 200)
    if (any(is.na(idx)))
      cli::cli_alert_warning("{sum(is.na(idx))} audit row(s) not found in the fresh harvest - investigate")
  }

  ## 8. reconciliation: disk vs ledger
  disk2 <- af_disk_index()
  in_ledger <- tolower(disk2$base) %in% tolower(coalesce(ledger$local_filename, ""))
  cli::cli_h2("reconciliation")
  cli::cli_alert_info("disk files under 03_Documents/af: {nrow(disk2)}; referenced by a ledger row: {sum(in_ledger)}")
  if (any(!in_ledger))
    cli::cli_alert_info("not referenced (CPR-era names / readiness grants / progress): {paste(disk2$base[!in_ledger], collapse=', ')}")
  cli::cli_h2("ledger dispositions")
  print(table(ledger$disposition))

  invisible(list(portfolio = portfolio, anchors = anchors, ledger = ledger,
                 page_failures = pf))
}

##############################################################################
# ═══ FALLBACK ONLY: Climate Policy Radar API client ═══
# Measured recall 57% (39/69 African AF projects): the country query
# templates do NOT actually filter by country (page_size caps at 100, no
# pagination, every query converges on the same global top-100), and CPR
# lags the fund's own document store. Kept because gcf_gapfill.R reuses
# the cpr_* client and run_mcf_scraper with prefix "GCF.".
##############################################################################

# Africa ISO3 (54 AU member states)
AFRICA_ISO3 <- c(
  "DZA","AGO","BEN","BWA","BFA","BDI","CPV","CMR","CAF","TCD","COM","COD",
  "COG","CIV","DJI","EGY","GNQ","ERI","SWZ","ETH","GAB","GMB","GHA","GIN",
  "GNB","KEN","LSO","LBR","LBY","MDG","MWI","MLI","MRT","MUS","MAR","MOZ",
  "NAM","NER","NGA","RWA","STP","SEN","SYC","SLE","SOM","ZAF","SSD","SDN",
  "TZA","TGO","TUN","UGA","ZMB","ZWE"
)

cpr_get_json <- function(url) {
  Sys.sleep(runif(1, HTTP_CONFIG$delay_min, HTTP_CONFIG$delay_max))
  safe_get_json(url)
}

#' Search /search/documents (top-100 by relevance; no deeper pagination)
cpr_search_top <- function(query) {
  url <- paste0(CPR_API, "/search/documents?query=",
                utils::URLencode(query, reserved = TRUE),
                "&page_size=", MCF_PAGE_SIZE)
  js <- cpr_get_json(url)
  if (is.null(js)) return(NULL)
  js$results
}

#' Sweep country-targeted queries; collect family import_ids per prefix
#' (e.g. c("AF.", "GCF.")). Results cached to data/mcf_family_ids.csv so
#' the GCF gap-fill reuses the same sweep.
cpr_collect_family_ids <- function(prefixes = c("AF.", "GCF."),
                                   countries = AFRICA_COUNTRIES_EN,
                                   use_cache = TRUE) {
  cache <- file.path(PATHS$data, "mcf_family_ids.csv")
  if (use_cache && file.exists(cache)) {
    df <- readr::read_csv(cache, show_col_types = FALSE)
    cli::cli_alert_info("family ids loaded from cache: {nrow(df)}")
    return(df)
  }
  fam <- list()
  n_q <- 0
  for (co in countries) {
    for (tpl in MCF_QUERY_TEMPLATES) {
      n_q <- n_q + 1
      res <- cpr_search_top(sub("\\{country\\}", co, tpl))
      if (is.null(res)) next
      for (r in res) {
        id <- r$id
        for (pref in prefixes) {
          if (startsWith(id, pref)) {
            # authoritative family id from the member_of relation
            # (r$documents is sometimes a single relation object, sometimes
            # an array of them); fall back to deriving from the document id
            fid <- NULL
            rels <- r$documents
            if (!is.null(rels)) {
              if (!is.null(rels$type)) rels <- list(rels)
              for (rel in rels) {
                if (identical(rel$type, "member_of") && !is.null(rel$value$id)) {
                  fid <- rel$value$id; break
                }
              }
            }
            if (is.null(fid)) {
              code <- sub("^[A-Z]+\\.document\\.([A-Za-z0-9_]+)\\..*$", "\\1", id)
              if (!identical(code, id)) {
                fid <- paste0(sub("\\.$", "", pref), ".family.", code, ".0")
              }
            }
            if (!is.null(fid)) fam[[fid]] <- pref
          }
        }
      }
    }
    if (n_q %% 30 == 0) cli::cli_alert_info("queries: {n_q} | families: {length(fam)}")
  }
  df <- tibble(family_id = names(fam), prefix = unlist(fam))
  if (use_cache) {  # only persist full sweeps (partial runs must not poison the cache)
    readr::write_csv(df, cache)
    cli::cli_alert_success("family sweep done: {nrow(df)} families ({n_q} queries); cached")
  } else {
    cli::cli_alert_success("family sweep done: {nrow(df)} families ({n_q} queries); not cached (partial)")
  }
  df
}

#' Fetch one family; returns NULL or a list(family, docs tibble)
cpr_get_family <- function(fid) {
  js <- cpr_get_json(paste0(CPR_API, "/families/", fid))
  if (is.null(js) || is.null(js$data)) return(NULL)
  d <- js$data
  docs <- purrr::map(d$documents, function(doc) {
    tibble(
      id           = coalesce(doc$import_id, ""),
      doc_title    = coalesce(doc$title, ""),
      cdn_url      = coalesce(doc$cdn_object, ""),
      source_url   = coalesce(doc$source_url, ""),
      content_type = coalesce(doc$content_type, ""),
      md5          = coalesce(doc$md5_sum, ""),
      doc_slug     = coalesce(doc$slug, "")
    )
  }) %>% bind_rows()
  list(
    import_id   = d$import_id,
    title       = coalesce(d$title, ""),
    slug        = coalesce(d$slug, ""),
    geographies = unlist(d$geographies),
    published   = coalesce(d$published_date, ""),
    corpus_id   = coalesce(d$corpus_id, ""),
    docs        = docs
  )
}

# ── CPR probe ───────────────────────────────────────────────────────────────
af_probe <- function() {
  cli::cli_h2("CPR API probe")
  p0 <- cpr_search_top("Senegal final evaluation report")
  ok_search <- !is.null(p0) && length(p0) > 0
  n_af <- if (ok_search) sum(vapply(p0, function(r) startsWith(r$id, "AF."), logical(1))) else 0
  cli::cli_alert_info("country query: {if (ok_search) length(p0) else 'FAIL'} results, {n_af} AF hits")

  fam <- cpr_get_family("AF.family.007NSNCR.0")
  ok_family <- !is.null(fam) && nrow(fam$docs) > 0
  cli::cli_alert_info("family fetch (Senegal 007NSNCR): {if (ok_family) paste(nrow(fam$docs), 'documents') else 'FAIL'}")

  ok_pdf <- FALSE
  if (ok_family) {
    u <- fam$docs$cdn_url[nzchar(fam$docs$cdn_url)][1]
    resp <- tryCatch(httr::GET(u, httr::user_agent(HTTP_CONFIG$user_agent),
                               httr::timeout(HTTP_CONFIG$timeout_sec)),
                     error = function(e) NULL)
    if (!is.null(resp) && httr::status_code(resp) == 200) {
      raw5 <- httr::content(resp, as = "raw")[1:5]
      ok_pdf <- identical(rawToChar(raw5), "%PDF-")
    }
    cli::cli_alert_info("CDN PDF valid: {ok_pdf}")
  }
  verdict <- c(search = ok_search, family = ok_family, pdf = ok_pdf)
  print(verdict)
  invisible(verdict)
}

# ── CPR fallback: build catalogue + download for one fund prefix ────────────
run_mcf_scraper <- function(prefix = "AF.", source_name = "af",
                            countries = AFRICA_COUNTRIES_EN,
                            year_min = AF_YEAR_MIN) {
  cli::cli_h1("MCF scraper via CPR API — prefix {prefix} (FALLBACK channel)")
  dl_dir <- file.path(PATHS$downloads, source_name)
  dir.create(dl_dir, recursive = TRUE, showWarnings = FALSE)

  # only trust/write the sweep cache on a full-country sweep
  fam_df <- cpr_collect_family_ids(prefixes = c("AF.", "GCF."),
                                   countries = countries,
                                   use_cache = length(countries) >= 50)
  fam_ids <- fam_df$family_id[fam_df$prefix == prefix]
  cli::cli_alert_success("{length(fam_ids)} candidate families for {prefix}")

  rows <- list()
  n_f <- 0; n_guidance <- 0
  project_corpus <- paste0("MCF.corpus.", sub("\\.$", "", prefix), ".n0000")
  for (fid in fam_ids) {
    n_f <- n_f + 1
    fam <- cpr_get_family(fid)
    if (is.null(fam)) next
    if (!identical(fam$corpus_id, project_corpus)) { n_guidance <- n_guidance + 1; next }
    in_africa <- length(intersect(fam$geographies, AFRICA_ISO3)) > 0
    fam_year <- suppressWarnings(as.integer(substr(fam$published, 1, 4)))
    proj_code <- sub("^[A-Z]+\\.family\\.([A-Za-z0-9]+)\\..*$", "\\1", fam$import_id)

    for (i in seq_len(nrow(fam$docs))) {
      doc <- fam$docs[i, ]
      # classify from the CPR title AND the fund-store source_url: CPR titles
      # a management response after the evaluation it responds to
      dtype <- mcf_doc_type(doc$doc_title, doc$source_url)
      status <- if (!in_africa) "out_of_scope_geo"
                else if (dtype %in% AF_EVAL_TYPES) "kept"
                else "parked"
      rows[[length(rows) + 1]] <- tibble(
        id          = doc$id,
        title       = paste0(fam$title, " — ", doc$doc_title),
        pdf_url     = ifelse(nzchar(doc$cdn_url), doc$cdn_url, doc$source_url),
        doc_date    = fam$published,
        doc_type    = ifelse(dtype == "Other", doc$doc_title, dtype),
        country     = paste(fam$geographies, collapse = ";"),
        project_id  = proj_code,
        web_url     = paste0(CPE_WEB, "/document/", fam$slug),
        source_url  = doc$source_url,
        content_type = doc$content_type,
        md5         = doc$md5,
        family_id   = fam$import_id,
        family_year = fam_year,
        status      = status
      )
    }
    if (n_f %% 20 == 0) cli::cli_alert_info("families processed: {n_f}/{length(fam_ids)}")
  }
  results <- bind_rows(rows)
  cli::cli_alert_info("guidance/non-project families skipped: {n_guidance}")
  cli::cli_alert_info("documents catalogued: {nrow(results)}")
  cli::cli_alert_info("status: {paste(capture.output(print(table(results$status))), collapse=' / ')}")

  # date floor on kept docs (family year is approval-era; evaluations come
  # later, so a family year >= year_min - 10 with unknown doc year is kept
  # flagged; strict floor only when family clearly predates scope era)
  results <- results %>%
    mutate(status = ifelse(
      status == "kept" & !is.na(family_year) & family_year < (year_min - 10),
      "parked_old", status))

  meta_path <- file.path(PATHS$data, paste0(source_name, "_metadata.csv"))
  readr::write_csv(results, meta_path)
  cli::cli_alert_success("metadata: {meta_path}")

  # downloads
  kept <- results %>% filter(status == "kept", nzchar(pdf_url))
  cli::cli_h2("Downloading {nrow(kept)} kept documents")
  n_ok <- 0; n_fail <- 0; n_skip <- 0
  for (i in seq_len(nrow(kept))) {
    r <- kept[i, ]
    ext <- tolower(tools::file_ext(sub("\\?.*$", "", r$pdf_url)))
    if (!nzchar(ext) || nchar(ext) > 4) ext <- "pdf"
    ftype <- safe_filename(r$doc_type)
    fname <- glue("{source_name}_{r$project_id}_{ftype}_{coalesce(as.character(r$family_year),'XXXX')}.{ext}")
    dest <- file.path(dl_dir, fname)
    if (file.exists(dest)) {
      log_download(source_name, r$project_id, r$doc_type, r$title, r$pdf_url,
                   dest, "skipped", "Already exists")
      n_skip <- n_skip + 1; next
    }
    ok <- download_pdf(r$pdf_url, dest)
    if (identical(ok, FALSE) && nzchar(r$source_url) && r$source_url != r$pdf_url) {
      ok <- download_pdf(r$source_url, dest)
    }
    # non-PDF types (docx evals): download_pdf rejects them — fetch raw
    if (identical(ok, FALSE) && ext != "pdf") {
      resp <- tryCatch(httr::GET(r$pdf_url, httr::user_agent(HTTP_CONFIG$user_agent),
                                 httr::timeout(HTTP_CONFIG$timeout_sec)),
                       error = function(e) NULL)
      if (!is.null(resp) && httr::status_code(resp) == 200) {
        writeBin(httr::content(resp, as = "raw"), dest)
        ok <- file.size(dest) > 10240
      }
    }
    if (identical(ok, TRUE)) {
      log_download(source_name, r$project_id, r$doc_type, r$title, r$pdf_url,
                   dest, "success")
      n_ok <- n_ok + 1
    } else if (identical(ok, "skipped")) {
      n_skip <- n_skip + 1
    } else {
      log_download(source_name, r$project_id, r$doc_type, r$title, r$pdf_url,
                   dest, "failed", "Download or validation failed")
      n_fail <- n_fail + 1
    }
    if (i %% 10 == 0) cli::cli_alert_info("downloads: {i}/{nrow(kept)} (ok {n_ok}, fail {n_fail}, skip {n_skip})")
  }
  cli::cli_h3("Summary")
  cli::cli_alert_success("downloaded: {n_ok} | failed: {n_fail} | skipped: {n_skip}")
  print_source_summary(source_name)
  invisible(results)
}

run_af_cpr_fallback <- function(countries = AFRICA_COUNTRIES_EN) {
  run_mcf_scraper(prefix = "AF.", source_name = "af", countries = countries)
}

# Run if called directly. AF_MODE: full (site, default) | probe | cpr | load
if (sys.nframe() == 0 || !interactive()) {
  switch(Sys.getenv("AF_MODE", "full"),
    probe  = af_probe(),
    cpr    = run_af_cpr_fallback(),
    capped = run_af_cpr_fallback(countries = c("Senegal", "Kenya", "Madagascar")),
    load   = invisible(NULL),
    run_af_scraper()
  )
}
