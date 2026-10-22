##############################################################################
# cif.R — Climate Investment Funds (CIF) Evaluation Document Scraper
#
# Targets: EVALUATION documents (independent/program evaluations, learning
#          reviews, completion/performance reports) relevant to African
#          agriculture adaptation, 2015+.
#
# Why cif.org and not Climate Project Explorer: the CIF corpus on CPE is
# effectively empty (verified 2026-07-23 — one Bangladesh proposal), so CIF
# evaluations must come from the fund's own Drupal site.
#
# Retrieval mechanics (verified 2026-07-23):
#   - Enumeration via the sitemap index https://www.cif.org/sitemap.xml
#     (?page=1..N), which lists all node URLs; document pages live under
#     /knowledge-documents/{slug} and /documents/{slug}.
#     (The /knowledge listing page is a static "featured" view — its pager
#     does not advance; sitemap is the only complete enumeration.)
#   - Document detail pages link the file at
#     /sites/cif_enc/files/knowledge-documents/{slug}.pdf (plus variants).
#
# Register harvest (2026-10 completeness campaign): the sitemap also lists
# ~448 /projects/ register pages that the document harvest never touches.
# cif.org hosts NO project evaluations (all project pages verified by the
# 2026-10 audit: proposal/approval files only) — CIF is a trust fund, so
# project evaluations live at the implementing MDBs (World Bank ICRs, AfDB
# PCRs). CIF_MODE=register builds catalogues/cif/portfolio.csv,
# mdb_handoff.csv (closed Africa PPCR/FIP → chase at the MDB) and the
# attestation ledger. It downloads nothing.
#
# Run modes via env var CIF_MODE: probe | capped | load | register | full (default)
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

SOURCE_NAME  <- "cif"
DOWNLOAD_DIR <- file.path(PATHS$downloads, SOURCE_NAME)
dir.create(DOWNLOAD_DIR, recursive = TRUE, showWarnings = FALSE)

CIF_BASE <- "https://www.cif.org"
CIF_YEAR_MIN <- 2015L

# slug pre-filter: fetch detail pages only for evaluation-ish documents
CIF_SLUG_RE <- paste(
  "evaluat", "mid-?term", "completion", "performance-review",
  "learning-review", "lessons-learned", "impact-assessment",
  "results-report", "country-results", "case-stud", "stocktak",
  sep = "|")

# progress documents among the slug matches (annual / country results
# reports): catalogued and attested as parked_progress, never fetched or
# downloaded (they are progress reporting, not evaluations)
CIF_PROGRESS_RE <- "results-report|country-results"

# governance/admin noise around the E&L Initiative itself — excluded
CIF_EXCLUDE_RE <- paste(
  "annual-report", "work-?plan", "business-?plan", "presentation",
  "concept-note", "policy-and-guidance", "options-paper",
  "terms-of-reference", "\\btor\\b", "workshop", "webinar", "agenda",
  "meeting", "committee", "joint-mission", "session", sep = "|")

# CIF pilot countries outside Africa (public list): a country-specific
# document naming ONLY one of these is out of geographic scope
CIF_NONAF_RE <- paste(
  "mexico", "brazil", "\\blao\\b", "indonesia", "india", "turkey",
  "kazakhstan", "philippines", "viet ?nam", "nepal", "bangladesh",
  "cambodia", "tajikistan", "ukraine", "bolivia", "peru", "chile",
  "colombia", "honduras", "nicaragua", "haiti", "jamaica", "dominica",
  "saint lucia", "grenada", "samoa", "tonga", "vanuatu", "fiji",
  "papua new guinea", "solomon", "kiribati", "yemen", "thailand",
  sep = "|")

# evaluation-type classification from the page title
cif_doc_type <- function(title) {
  t <- tolower(coalesce(title, ""))
  if (grepl("independent evaluation", t))       return("Independent evaluation")
  if (grepl("mid-?term", t))                    return("Mid-term evaluation")
  if (grepl("final evaluation|terminal", t))    return("Final evaluation")
  if (grepl("learning review|lessons", t))      return("Learning review")
  if (grepl("completion", t))                   return("Completion report")
  if (grepl("performance", t))                  return("Performance review")
  if (grepl("impact assessment|impact evaluat", t)) return("Impact evaluation")
  if (grepl("evaluat", t))                      return("Evaluation")
  NA_character_
}

# ── Sitemap enumeration ─────────────────────────────────────────────────────
cif_sitemap_urls <- function() {
  idx_url <- paste0(CIF_BASE, "/sitemap.xml")
  # fail LOUDLY if the sitemap index is not what we asked for — scraping
  # blind against a changed site silently empties the corpus
  idx <- assert_response(polite_get(idx_url), idx_url,
                         list(content_type = "application/xml",
                              contains = "sitemap\\.xml\\?page="),
                         source = SOURCE_NAME)
  itxt <- httr::content(idx, "text", encoding = "UTF-8")
  pages <- gsub("</?loc>", "",
                unlist(regmatches(itxt, gregexpr("<loc>[^<]+</loc>", itxt))))
  urls <- character(0)
  for (p in pages) {
    r <- assert_response(polite_get(p), p,
                         list(min_bytes = 500,
                              contains = c("<urlset", "<loc>")),
                         source = SOURCE_NAME)
    txt <- httr::content(r, "text", encoding = "UTF-8")
    ls <- gsub("</?loc>", "", unlist(regmatches(txt, gregexpr("<loc>[^<]+</loc>", txt))))
    urls <- c(urls, ls)
    cli::cli_alert_info("sitemap {basename(p)}: {length(ls)} urls (total {length(urls)})")
  }
  urls
}

# ── Detail page parse ───────────────────────────────────────────────────────
cif_parse_document_page <- function(url) {
  page <- safe_read_html(url)
  if (is.null(page)) return(NULL)
  title <- tryCatch(rvest::html_text2(rvest::html_element(page, "h1")),
                    error = function(e) NA_character_)
  pdfs <- rvest::html_attr(
    rvest::html_elements(page, "a[href*='/sites/'][href$='.pdf'], a[href$='.pdf']"),
    "href")
  pdfs <- pdfs[!is.na(pdfs)]
  pdf <- if (length(pdfs)) {
    h <- pdfs[1]
    if (startsWith(h, "http")) h else paste0(CIF_BASE, h)
  } else NA_character_
  # date: datetime attr or a year in the page header area
  dt <- tryCatch(rvest::html_attr(rvest::html_element(page, "time"), "datetime"),
                 error = function(e) NA_character_)
  yr <- if (!is.na(dt)) substr(dt, 1, 4) else {
    m <- regmatches(title, regexpr("(19|20)\\d{2}", coalesce(title, "")))
    if (length(m) && nchar(m)) m else NA_character_
  }
  # country tags if present
  tags <- tryCatch(rvest::html_text2(
    rvest::html_elements(page, "a[href*='country'], .field--name-field-country a")),
    error = function(e) character(0))
  list(title = title, pdf = pdf, year = yr,
       countries = paste(unique(tags), collapse = ";"))
}

# ── Probe ───────────────────────────────────────────────────────────────────
cif_probe <- function() {
  cli::cli_h2("cif.org probe")
  idx <- polite_get(paste0(CIF_BASE, "/sitemap.xml"))
  ok_sm <- !is.null(idx) && httr::status_code(idx) == 200
  cli::cli_alert_info("sitemap reachable: {ok_sm}")
  d <- cif_parse_document_page(paste0(CIF_BASE, "/knowledge-documents/cif-annual-report-2025"))
  ok_page <- !is.null(d) && !is.na(d$pdf)
  cli::cli_alert_info("detail page parse: {ok_page} (title: {substr(coalesce(d$title,''),1,50)}; pdf: {!is.na(d$pdf)})")
  verdict <- c(sitemap = ok_sm, page = ok_page)
  print(verdict)
  invisible(verdict)
}

# ── Main ────────────────────────────────────────────────────────────────────
run_cif_scraper <- function(max_docs = Inf) {
  cli::cli_h1("CIF Evaluation Document Scraper")
  urls <- cif_sitemap_urls()
  doc_urls <- urls[grepl("/(knowledge-documents|documents)/", urls)]
  cli::cli_alert_info("document pages in sitemap: {length(doc_urls)}")

  cand <- doc_urls[grepl(CIF_SLUG_RE, doc_urls, ignore.case = TRUE) &
                   !grepl(CIF_EXCLUDE_RE, doc_urls, ignore.case = TRUE)]
  cli::cli_alert_info("evaluation-ish slugs after admin-noise exclusion: {length(cand)}")
  # progress documents (annual / country results reports) are parked without
  # fetching their detail pages and never reach the download loop
  prog <- cand[grepl(CIF_PROGRESS_RE, cand, ignore.case = TRUE)]
  cand <- setdiff(cand, prog)
  cli::cli_alert_info("parked as progress documents (not fetched): {length(prog)}")
  if (length(cand) > max_docs) cand <- cand[seq_len(max_docs)]

  rows <- list()
  for (i in seq_along(cand)) {
    u <- cand[i]
    d <- cif_parse_document_page(u)
    if (is.null(d)) next
    dtype <- cif_doc_type(coalesce(d$title, basename(u)))
    if (!is.na(dtype) && grepl(CIF_EXCLUDE_RE, tolower(coalesce(d$title, "")))) dtype <- NA_character_
    if (is.na(d$year) || !nzchar(coalesce(d$year, ""))) {
      m <- regmatches(coalesce(d$pdf, ""), regexpr("(19|20)\\d{2}", coalesce(d$pdf, "")))
      if (length(m) && nchar(m)) d$year <- m
    }
    # Africa relevance: country tags or country/region names in title/slug
    txt <- tolower(paste(d$title, basename(u), d$countries))
    africa_named <- any(vapply(tolower(AFRICA_COUNTRIES_EN),
                               function(cn) grepl(cn, txt, fixed = TRUE), logical(1)))
    regional <- grepl("africa|sahel", txt)
    nonaf_named <- grepl(CIF_NONAF_RE, txt)
    status <- if (is.na(dtype)) "parked"
              else if (africa_named || regional) "kept"
              else if (nonaf_named) "out_of_scope_geo"  # names a non-African pilot country only
              else "kept_global"   # program/portfolio evaluations cover Africa within global scope
    rows[[length(rows) + 1]] <- tibble(
      id         = basename(u),
      title      = coalesce(d$title, basename(u)),
      pdf_url    = coalesce(d$pdf, ""),
      doc_date   = coalesce(d$year, ""),
      doc_type   = coalesce(dtype, "other"),
      country    = d$countries,
      project_id = "",
      web_url    = u,
      status     = status
    )
    if (i %% 20 == 0) cli::cli_alert_info("pages: {i}/{length(cand)}")
  }
  results <- bind_rows(rows)
  if (length(prog)) {
    results <- bind_rows(results, tibble(
      id         = basename(prog),
      title      = gsub("-", " ", basename(prog)),
      pdf_url    = "",
      doc_date   = "",
      doc_type   = "results report (progress)",
      country    = "",
      project_id = "",
      web_url    = prog,
      status     = "parked_progress"
    ))
  }
  cli::cli_alert_info("catalogued: {nrow(results)}")
  print(table(results$status))

  # year floor (kept docs with a known pre-2015 year are parked)
  results <- results %>%
    mutate(.yr = suppressWarnings(as.integer(doc_date)),
           status = ifelse(status %in% c("kept", "kept_global") &
                             !is.na(.yr) & .yr < CIF_YEAR_MIN,
                           "parked_old", status)) %>%
    select(-.yr)

  meta_path <- file.path(PATHS$data, "cif_metadata.csv")
  readr::write_csv(results, meta_path)
  cli::cli_alert_success("metadata: {meta_path}")

  kept <- results %>% filter(status %in% c("kept", "kept_global"), nzchar(pdf_url))
  cli::cli_h2("Downloading {nrow(kept)} kept documents")
  n_ok <- 0; n_fail <- 0; n_skip <- 0
  for (i in seq_len(nrow(kept))) {
    r <- kept[i, ]
    fname <- paste0(substr(glue("cif_{safe_filename(r$id)}_{coalesce(r$doc_date,'XXXX')}"), 1, 100), ".pdf")
    dest <- file.path(DOWNLOAD_DIR, fname)
    if (file.exists(dest)) {
      log_download(SOURCE_NAME, r$id, r$doc_type, r$title, r$pdf_url, dest,
                   "skipped", "Already exists")
      n_skip <- n_skip + 1; next
    }
    ok <- download_pdf(r$pdf_url, dest)
    if (identical(ok, TRUE)) {
      log_download(SOURCE_NAME, r$id, r$doc_type, r$title, r$pdf_url, dest, "success")
      n_ok <- n_ok + 1
    } else if (identical(ok, "skipped")) { n_skip <- n_skip + 1 }
    else {
      log_download(SOURCE_NAME, r$id, r$doc_type, r$title, r$pdf_url, dest,
                   "failed", "Download or validation failed")
      n_fail <- n_fail + 1
    }
  }
  cli::cli_h3("Summary")
  cli::cli_alert_success("downloaded: {n_ok} | failed: {n_fail} | skipped: {n_skip}")
  print_source_summary(SOURCE_NAME)
  invisible(results)
}

# ══ Register harvest (/projects/) — portfolio, MDB handoff, attestation ═════
#
# cif.org hosts no project evaluations (2026-10 audit: all 448 project
# register pages carry proposal/approval files only); CIF is a trust fund and
# project evaluations (WB ICRs, AfDB PCRs) live at the implementing MDBs.
# This harvest therefore DOWNLOADS NOTHING. It writes, under catalogues/cif/:
#   portfolio.csv   — one row per unique /projects/ page in the sitemap
#   mdb_handoff.csv — closed Africa PPCR/FIP projects to chase at the MDB
#   attestation.csv — ledger: evaluation-like document slugs + register pages

CATALOGUE_DIR  <- file.path(PROJECT_ROOT, "catalogues", SOURCE_NAME)
CIF_CORPUS_DIR <- file.path(dirname(PROJECT_ROOT), "03_Documents", SOURCE_NAME,
                            "Docs", "evaluation_docs")

# World Bank ICRs already in the corpus (via the worldbank scraper; screened
# in 04_Screening/scope_screen.csv) for closed PPCR projects on the CIF register
CIF_KNOWN_ICRS <- tibble::tribble(
  ~mdb_project_id, ~country_re,  ~title_re,
  "P127254",       "Zambia",     "strengthening climate resilience",
  "P158816",       "Madagascar", "climate resilien|ppcr",
  "P160268",       "Rwanda",     "climate resilien|ppcr"
)

# canary: a known project page must pass a page-specific assertion, and a
# nonsense slug must FAIL that same assertion (detects wildcard soft-200s)
cif_canary <- function() {
  canary_check(
    SOURCE_NAME,
    good_url = paste0(CIF_BASE, "/projects/niger-irrigation-program"),
    expect   = list(title    = "Niger Irrigation Program",
                    contains = c("PPCRNE033B",
                                 "views-field-field-project-status")),
    nonsense_url = paste0(CIF_BASE, "/projects/zzz-canary-nonexistent")
  )
}

# unique project page URLs from the sitemap (/index.php/ twins collapsed)
cif_project_urls <- function(urls) {
  p <- urls[grepl("/projects/", urls, fixed = TRUE)]
  p <- sub("/index\\.php/", "/", p)
  p <- sub("[?#].*$", "", p)
  p <- sub("/+$", "", p)
  unique(p)
}

cif_slug_title <- function(s) gsub("-", " ", s)

# program acronym from the taxonomy name, e.g.
# "Pilot Program for Climate Resilience (PPCR)" -> "PPCR"
cif_program_acronym <- function(program_name) {
  if (is.na(program_name) || !nzchar(program_name)) return(NA_character_)
  m <- regmatches(program_name, regexpr("\\(([^)]+)\\)\\s*$", program_name))
  if (length(m) && nzchar(m)) return(gsub("[()\\s]", "", m, perl = TRUE))
  trimws(program_name)
}

# Africa = region Sub-Saharan Africa, or any named country is African (covers
# the MENA-region African pilots: Morocco, Egypt, Tunisia, ...)
cif_is_africa <- function(countries, region) {
  if (!is.na(region) && grepl("sub-?saharan", region, ignore.case = TRUE))
    return(TRUE)
  if (is.na(countries) || !nzchar(countries)) return(FALSE)
  cn <- tolower(iconv(trimws(strsplit(countries, ";")[[1]]),
                      to = "ASCII//TRANSLIT", sub = ""))
  # "Papua New Guinea" must not fire the "Guinea" containment test
  cn <- cn[!grepl("papua new guinea", cn)]
  if (!length(cn)) return(FALSE)
  af <- tolower(AFRICA_COUNTRIES_EN)
  any(cn %in% af) ||
    any(vapply(af, function(a) any(grepl(a, cn, fixed = TRUE)), logical(1)))
}

cif_parse_project_page <- function(url) {
  page <- safe_read_html(url)
  if (is.null(page)) return(NULL)
  one <- function(sel) {
    x <- tryCatch(rvest::html_text2(rvest::html_elements(page, sel)),
                  error = function(e) character(0))
    x <- trimws(x)
    x <- x[nzchar(x)]
    if (length(x)) x[1] else NA_character_
  }
  joined <- function(sel) {
    x <- tryCatch(rvest::html_text2(rvest::html_elements(page, sel)),
                  error = function(e) character(0))
    x <- unique(trimws(x))
    x <- x[nzchar(x)]
    if (length(x)) paste(x, collapse = "; ") else NA_character_
  }
  title <- one(".views-field-title .field-content")
  if (is.na(title)) {
    t <- one("title")
    if (!is.na(t)) title <- sub("\\s*\\|\\s*CIF\\s*$", "", t)
  }
  countries <- joined(".views-field-field-country .field-content a")
  if (is.na(countries))
    countries <- joined(".views-field-field-country .field-content")
  program_name <- one(".cch-programs-name a")
  if (is.na(program_name))
    program_name <- one(".views-field-field-cch-programs .field-content a")
  list(
    title          = title,
    cif_project_id = one(".views-field-field-project-id .field-content"),
    countries      = countries,
    region         = one(".views-field-field-region .field-content"),
    program_name   = program_name,
    status         = one(".views-field-field-project-status .field-content"),
    mdb            = joined(".views-field-field-implementing-partners .field-content"),
    funding_usd_m  = one(".views-field-field-funding .field-content")
  )
}

# fetch + parse every project page; checkpoint each row so an interrupted
# ~450-page run resumes instead of refetching (portfolio_partial.csv)
cif_harvest_register <- function(project_urls) {
  part_path <- file.path(CATALOGUE_DIR, "portfolio_partial.csv")
  done <- if (file.exists(part_path))
    readr::read_csv(part_path, col_types = readr::cols(.default = "c"))
  else NULL
  todo <- if (!is.null(done)) setdiff(project_urls, done$url) else project_urls
  cli::cli_alert_info(paste0(
    "register: {length(project_urls)} project pages ",
    "({length(todo)} to fetch, {length(project_urls) - length(todo)} from checkpoint)"))
  rows <- list()
  fail_streak <- 0
  for (i in seq_along(todo)) {
    u <- todo[i]
    d <- cif_parse_project_page(u)
    if (is.null(d)) {
      fail_streak <- fail_streak + 1
      row <- tibble(
        slug = basename(u), url = u, title = NA_character_,
        cif_project_id = NA_character_, program = NA_character_,
        program_name = NA_character_, countries = NA_character_,
        region = NA_character_, status = NA_character_,
        mdb = NA_character_, cif_funding_usd_m = NA_character_,
        is_africa = NA_character_, parse_ok = "FALSE")
      log_download(SOURCE_NAME, basename(u), "project_register_page",
                   url = u, status = "failed",
                   notes = "project page fetch/parse failed")
    } else {
      fail_streak <- 0
      row <- tibble(
        slug = basename(u), url = u, title = d$title,
        cif_project_id = d$cif_project_id,
        program = cif_program_acronym(d$program_name),
        program_name = d$program_name, countries = d$countries,
        region = d$region, status = d$status, mdb = d$mdb,
        cif_funding_usd_m = d$funding_usd_m,
        is_africa = as.character(cif_is_africa(d$countries, d$region)),
        parse_ok = "TRUE")
    }
    rows[[length(rows) + 1]] <- row
    readr::write_csv(row, part_path, append = file.exists(part_path))
    if (fail_streak >= 5)
      stop("cif register: 5 consecutive page failures - the site is ",
           "refusing or down; stopping rather than hammering", call. = FALSE)
    if (i %% 25 == 0)
      cli::cli_alert_info("register pages: {i}/{length(todo)}")
  }
  out <- bind_rows(done, bind_rows(rows))
  out[match(project_urls, out$url), ]
}

# closed Africa PPCR/FIP projects: their evaluations (ICRs/PCRs) must be
# retrieved from the implementing MDB — one handoff row per project
cif_write_mdb_handoff <- function(portfolio) {
  af <- portfolio %>%
    filter(parse_ok == "TRUE", is_africa == "TRUE",
           program %in% c("PPCR", "FIP"),
           grepl("^closed$", trimws(coalesce(status, "")), ignore.case = TRUE))
  handoff <- af %>%
    transmute(program,
              country        = countries,
              project_title  = title,
              mdb            = coalesce(mdb, ""),
              mdb_project_id = "",
              status         = trimws(status),
              cif_url        = url,
              already_held   = FALSE)
  for (k in seq_len(nrow(CIF_KNOWN_ICRS))) {
    cand <- which(handoff$program == "PPCR" &
                  grepl(CIF_KNOWN_ICRS$country_re[k], handoff$country,
                        ignore.case = TRUE))
    if (length(cand) > 1) {
      tm <- cand[grepl(CIF_KNOWN_ICRS$title_re[k],
                       handoff$project_title[cand], ignore.case = TRUE)]
      if (length(tm)) cand <- tm
    }
    if (!length(cand)) {
      cli::cli_alert_warning(paste0(
        "handoff: no closed PPCR register row matches ",
        "{CIF_KNOWN_ICRS$mdb_project_id[k]} ({CIF_KNOWN_ICRS$country_re[k]})"))
      next
    }
    if (length(cand) > 1)
      cli::cli_alert_warning(paste0(
        "handoff: {length(cand)} rows match {CIF_KNOWN_ICRS$mdb_project_id[k]} ",
        "({CIF_KNOWN_ICRS$country_re[k]}) - marking the first"))
    handoff$already_held[cand[1]]   <- TRUE
    handoff$mdb_project_id[cand[1]] <- CIF_KNOWN_ICRS$mdb_project_id[k]
  }
  if (nrow(handoff) < 25 || nrow(handoff) > 40)
    stop("mdb_handoff: ", nrow(handoff), " rows is outside the sanity band ",
         "25-40 (audit expects ~33 = 18 closed PPCR + 15 closed FIP)",
         call. = FALSE)
  ok <- nzchar(coalesce(handoff$program, "")) &
    nzchar(coalesce(handoff$country, "")) &
    nzchar(coalesce(handoff$project_title, "")) &
    nzchar(coalesce(handoff$status, ""))
  if (!all(ok))
    stop("mdb_handoff: ", sum(!ok),
         " rows missing program/country/title/status", call. = FALSE)
  p <- file.path(CATALOGUE_DIR, "mdb_handoff.csv")
  readr::write_csv(handoff, p)
  cli::cli_alert_success(
    "mdb_handoff: {nrow(handoff)} rows ({sum(handoff$program == 'PPCR')} PPCR / {sum(handoff$program == 'FIP')} FIP; {sum(handoff$already_held)} already held) -> {p}")
  handoff
}

# ── Attestation ledger ──────────────────────────────────────────────────────
# One row per evaluation-like document slug the (widened) harvest identifies,
# plus one per project register page. Nothing is downloaded here: dispositions
# record what we already hold, what is parked, and what is out by type.
cif_build_attestation <- function(doc_urls, portfolio, handoff) {
  cand <- doc_urls[grepl(CIF_SLUG_RE, doc_urls, ignore.case = TRUE)]
  slugs <- basename(cand)
  first <- !duplicated(slugs)
  twins <- unique(slugs[duplicated(slugs)])
  cand  <- cand[first]
  slugs <- slugs[first]

  # on-disk corpus: filenames are cif_{safe_filename(slug)}_{year|}.pdf,
  # basenames capped at 100 chars by the downloader
  files <- list.files(CIF_CORPUS_DIR, pattern = "\\.pdf$", ignore.case = TRUE)
  fslug <- sub("_((19|20)\\d{2})?\\.pdf$", "", sub("^cif_", "", files))
  match_file <- function(s) {
    hit <- which(fslug == s)
    if (length(hit)) return(files[hit[1]])
    hit <- which(nchar(files) >= 100 & startsWith(s, fslug))
    if (length(hit) == 1) return(files[hit])
    NA_character_
  }
  local_file <- vapply(slugs, match_file, character(1), USE.NAMES = FALSE)

  # prior desk decisions from the July 2026 document harvest
  meta_path <- file.path(CATALOGUE_DIR, "cif_metadata.csv")
  pstat <- character(0); ptitle <- character(0); pdtype <- character(0)
  if (file.exists(meta_path)) {
    meta   <- readr::read_csv(meta_path,
                              col_types = readr::cols(.default = "c"))
    pstat  <- setNames(meta$status, meta$id)
    ptitle <- setNames(meta$title, meta$id)
    pdtype <- setNames(meta$doc_type, meta$id)
  }

  n <- length(slugs)
  disposition <- character(n)
  notes <- character(n)
  for (i in seq_len(n)) {
    s <- slugs[i]
    st <- unname(pstat[s])
    if (!is.na(local_file[i])) {
      disposition[i] <- "already_held"
      notes[i] <- "in corpus (03_Documents/cif/Docs/evaluation_docs)"
    } else if (grepl(CIF_EXCLUDE_RE, s, ignore.case = TRUE)) {
      disposition[i] <- "out_by_type"
      notes[i] <- "admin/governance document (CIF_EXCLUDE_RE)"
    } else if (grepl(CIF_PROGRESS_RE, s, ignore.case = TRUE)) {
      disposition[i] <- "parked_progress"
      notes[i] <- "results / country results report: progress document, not downloaded"
    } else if (!is.na(st) && st %in% c("kept", "kept_global")) {
      disposition[i] <- "failed_download"
      notes[i] <- paste0("kept by the 2026-07 harvest (", st,
                         ") but no valid file on disk")
    } else if (!is.na(st) && st == "out_of_scope_geo") {
      disposition[i] <- "excluded_desk_review"
      notes[i] <- "names only non-African pilot countries (out_of_scope_geo, 2026-07)"
    } else if (!is.na(st) && st == "parked_old") {
      disposition[i] <- "held_pending_window_decision"
      notes[i] <- "pre-2015 (outside window; parked_old in cif_metadata)"
    } else if (!is.na(st) && st == "parked") {
      disposition[i] <- "out_by_type"
      notes[i] <- "no evaluation type in page title (parked in cif_metadata)"
    } else {
      disposition[i] <- "held_pending_window_decision"
      notes[i] <- paste0("new candidate from the widened slug filter (2026-10); ",
                         "not downloaded - nothing on cif.org qualifies per the ",
                         "completeness audit")
    }
    if (s %in% twins)
      notes[i] <- paste0(notes[i],
                         "; listed under both /documents/ and /knowledge-documents/")
  }
  doc_df <- tibble(
    site_id        = slugs,
    title          = coalesce(unname(ptitle[slugs]), cif_slug_title(slugs)),
    doc_type_site  = coalesce(unname(pdtype[slugs]),
                              ifelse(grepl(CIF_PROGRESS_RE, slugs,
                                           ignore.case = TRUE),
                                     "results report (progress)", "document")),
    listing        = cand,
    disposition    = disposition,
    local_filename = local_file,
    notes          = notes
  )

  # every file on disk must be accounted for exactly once
  dup_used <- local_file[!is.na(local_file)][duplicated(local_file[!is.na(local_file)])]
  if (length(dup_used))
    stop("attestation: files matched by more than one slug: ",
         paste(unique(dup_used), collapse = ", "), call. = FALSE)
  orphans <- setdiff(files, local_file[!is.na(local_file)])
  if (length(orphans)) {
    oslug <- sub("_((19|20)\\d{2})?\\.pdf$", "", sub("^cif_", "", orphans))
    cli::cli_alert_warning(
      "attestation: {length(orphans)} file{?s} on disk not in the current sitemap document listing - attested from the held file")
    doc_df <- bind_rows(doc_df, tibble(
      site_id        = oslug,
      title          = coalesce(unname(ptitle[oslug]), cif_slug_title(oslug)),
      doc_type_site  = coalesce(unname(pdtype[oslug]), "document"),
      listing        = NA_character_,
      disposition    = "already_held",
      local_filename = orphans,
      notes          = "held on disk; slug absent from the current sitemap document listing"
    ))
  }

  # register findings: project pages host proposal/approval files only —
  # evaluations live at the implementing MDBs, so the page is out by type
  reg_notes <- paste0(
    "CIF project register page (",
    coalesce(portfolio$program, "?"), ", ",
    coalesce(portfolio$status, "?"),
    "): proposal/approval files only; project evaluations live at the ",
    "implementing MDB(s): ", coalesce(portfolio$mdb, "unknown"))
  in_handoff <- portfolio$url %in% handoff$cif_url
  reg_notes[in_handoff] <- paste0(reg_notes[in_handoff],
                                  "; queued in mdb_handoff.csv")
  held <- handoff[handoff$already_held, ]
  m <- match(held$cif_url, portfolio$url)
  reg_notes[m] <- paste0(reg_notes[m], "; WB ICR ", held$mdb_project_id,
                         " already in corpus via the worldbank scraper")
  reg_df <- tibble(
    site_id        = portfolio$slug,
    title          = coalesce(portfolio$title, portfolio$slug),
    doc_type_site  = "project register page",
    listing        = portfolio$url,
    disposition    = "out_by_type",
    local_filename = NA_character_,
    notes          = reg_notes
  )

  collisions <- intersect(doc_df$site_id, reg_df$site_id)
  if (length(collisions))
    cli::cli_alert_warning(
      "attestation: {length(collisions)} site_id{?s} shared between document and project slugs: {paste(collisions, collapse = ', ')}")

  df <- bind_rows(doc_df, reg_df)
  write_attestation(SOURCE_NAME, df)
  cli::cli_alert_info(paste0(
    "attestation dispositions: ",
    paste(names(table(df$disposition)), table(df$disposition),
          sep = "=", collapse = ", ")))
  n_held <- sum(df$disposition == "already_held")
  if (n_held != length(files))
    stop("attestation: ", n_held, " already_held rows but ", length(files),
         " files on disk - reconciliation failed", call. = FALSE)
  invisible(df)
}

run_cif_register <- function() {
  cli::cli_h1("CIF register harvest (portfolio + MDB handoff + attestation)")
  dir.create(CATALOGUE_DIR, recursive = TRUE, showWarnings = FALSE)
  cif_canary()
  cache <- file.path(PATHS$data, "cif_sitemap_urls_cache.txt")
  reuse <- identical(Sys.getenv("CIF_REUSE"), "1")
  urls <- if (reuse && file.exists(cache)) {
    cli::cli_alert_info("reusing cached sitemap url list: {cache}")
    readLines(cache)
  } else {
    u <- cif_sitemap_urls()
    writeLines(u, cache)
    u
  }
  proj <- cif_project_urls(urls)
  doc_urls <- unique(sub("/index\\.php/", "/",
                         urls[grepl("/(knowledge-documents|documents)/", urls)]))
  cli::cli_alert_info(paste0(
    "sitemap: {length(urls)} urls | {length(proj)} unique project pages | ",
    "{length(doc_urls)} document pages"))

  pf_path <- file.path(CATALOGUE_DIR, "portfolio.csv")
  portfolio <- if (reuse && file.exists(pf_path)) {
    cli::cli_alert_info("reusing existing portfolio.csv")
    readr::read_csv(pf_path, col_types = readr::cols(.default = "c"))
  } else {
    cif_harvest_register(proj)
  }
  # GATE: one portfolio row per unique /projects/ URL in the sitemap
  stopifnot(nrow(portfolio) == length(proj))
  readr::write_csv(portfolio, pf_path)
  part_path <- file.path(CATALOGUE_DIR, "portfolio_partial.csv")
  if (file.exists(part_path)) file.remove(part_path)
  cli::cli_alert_success("portfolio: {nrow(portfolio)} rows -> {pf_path}")

  af <- portfolio %>% filter(is_africa == "TRUE")
  cli::cli_h2("Audit reconciliation")
  cli::cli_alert_info("Africa projects: {nrow(af)} (audit: 113)")
  print(table(af$program, useNA = "ifany"))
  closed <- af %>%
    filter(grepl("^closed$", trimws(coalesce(status, "")), ignore.case = TRUE))
  cli::cli_alert_info(paste0(
    "closed Africa PPCR: {sum(closed$program == 'PPCR', na.rm = TRUE)} (audit: 18) | ",
    "closed Africa FIP: {sum(closed$program == 'FIP', na.rm = TRUE)} (audit: 15)"))

  handoff <- cif_write_mdb_handoff(portfolio)
  cif_build_attestation(doc_urls, portfolio, handoff)
  invisible(portfolio)
}

# Run if called directly (not when sourced).
# CIF_MODE: probe | capped | load | register | full (default)
if (sys.nframe() == 0 && !interactive()) {
  switch(Sys.getenv("CIF_MODE", "full"),
    probe    = cif_probe(),
    capped   = run_cif_scraper(max_docs = 15),
    load     = invisible(NULL),
    register = run_cif_register(),
    run_cif_scraper()
  )
}
