# ifad_target_list.R - turn the IFAD catalogue into a list a person can act on.
#
# Why this exists. Every document URL IFAD publishes in its own IATI data
# points at operations.ifad.org, and that host terminates TLS with alert 40
# without presenting a certificate (verified 3 Oct 2026 on IPv4 and IPv6, and
# confirmed by a real Chromium: ERR_SSL_VERSION_OR_CIPHER_MISMATCH). It is an
# unprovisioned Cloudflare hostname, not a defence: no client can reach it.
# A plain headless Chromium is also refused by www.ifad.org and ioe.ifad.org
# with a Cloudflare challenge, so automated retrieval is off by decision.
#
# What remains is worth having on its own. This writes the list of documents
# we would want, with working project-page links, so a person or the
# consultants can fetch them, and so a request to IFAD has a concrete
# attachment.
#
# Three corrections to the catalogue, all made here rather than by re-fetching
# (the 413-record cache is complete):
#
#   1. The IATI category codes are unusable. 683 of 750 rows are coded A08
#      "final evaluation" because IFAD blanket-tags nearly every attachment
#      A02,A07,A08. By title the real split is 544 supervision reports, 80
#      mid-term reviews, 59 completion reports, 45 design documents, 22
#      unclassified. Type is therefore read from doc_title, never doc_category.
#
#   2. 250 of 750 stored project-page links are wrong. IFAD's 1100-series
#      projects use a short id on the web (1100001679 -> /w/projects/1679).
#      The published A12 link in the record is authoritative; the derivation
#      rule agrees with it in 413 of 413 records, so we read the link and keep
#      the rule only as a fallback.
#
#   3. Roughly 18% of document links are attached to the wrong activity in
#      IFAD's published data: the Eswatini record carries documents titled for
#      Zambia and Mexico. The title carries its own project id and country and
#      is authoritative. Both are emitted, with id_agrees so the disagreement
#      is visible and never silently resolved.
#
#   Rscript R/01_retrieve/ifad_target_list.R

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
suppressMessages({ library(jsonlite); library(dplyr); library(stringr) })
source(file.path(REPO, "R", "00_shared", "paths.R"))

CAT   <- file.path(REPO, "catalogues", "ifad")
CACHE <- file.path(CAT, "ifad_cache")
stopifnot(dir.exists(CACHE))

# ── the type rule: title only, supervision first so nothing steals it ───────
# All 80 mid-term reviews read "Interim (Mid-term) Review Report", so a
# "mid-?term review" pattern matches none of them. Match the words, not the
# phrase.
ifad_doc_type <- function(title) {
  t <- tolower(title %||% "")
  dplyr::case_when(
    str_detect(t, "supervision")                      ~ "supervision",
    str_detect(t, "mid-?term|midterm|mid term")       ~ "mid_term_review",
    str_detect(t, "completion")                       ~ "completion_report",
    str_detect(t, "design|appraisal|president")       ~ "design_appraisal",
    TRUE                                              ~ "unclassified")
}
`%||%` <- function(a, b) if (is.null(a) || !length(a)) b else a

# countries that appear in IFAD titles but are not African; the title is the
# authority for geography because the activity it hangs off may be wrong
NON_AFRICAN <- paste0("^(Ecuador|Paraguay|Brazil|Mexico|Republic of Moldova|Moldova|",
                      "Peru|Bolivia|Guatemala|Nicaragua|Honduras|Cuba|El Salvador|",
                      "Argentina|Uruguay|Venezuela|Colombia|India|Bangladesh|Nepal|",
                      "Pakistan|Sri Lanka|Viet Nam|Vietnam|Cambodia|Indonesia|",
                      "Philippines|China|Kyrgyzstan|Tajikistan|Uzbekistan|Georgia|",
                      "Armenia|Turkey|Egypt, Arab Republic)\\b")

## ---- read the cache ---------------------------------------------------------
files <- list.files(CACHE, pattern = "\\.json$", full.names = TRUE)
cat("cache records:", length(files), "\n")

one <- function(p) {
  d <- tryCatch(fromJSON(p, simplifyVector = FALSE), error = function(e) NULL)
  if (is.null(d) || !length(d$xson)) return(NULL)
  a <- d$xson[[1]][["/iati-activities/iati-activity"]]
  if (is.null(a)) return(NULL)
  if (is.null(names(a))) a <- a[[1]]
  pid <- str_extract(basename(p), "[0-9]{10}")

  # the project's own web page, as IFAD publishes it (A12)
  page <- NA_character_
  for (dl in (a[["/document-link"]] %||% list())) {
    cats <- vapply(dl[["/category"]] %||% list(), function(c) c[["@code"]] %||% "", character(1))
    u <- dl[["@url"]] %||% ""
    if ("A12" %in% cats && grepl("/w/projects/", u, fixed = TRUE)) { page <- u; break }
  }
  if (is.na(page) && !is.na(pid))   # fallback, verified to agree on all 413
    page <- paste0("/w/projects/", if (startsWith(pid, "1100")) as.integer(substr(pid, 5, 10)) else pid)

  ci <- (a[["/contact-info"]] %||% list())
  ci <- if (length(ci)) ci[[1]] else list()
  # jsonlite renames IATI's empty narrative key to "1", which is why the first
  # IFAD script read blank titles for everything (its [[""]] never resolved).
  nar <- function(x) {
    n <- x %||% list()
    if (!length(n)) return("")
    v <- n[[1]][["1"]] %||% n[[1]][[""]] %||% ""
    if (is.null(v)) "" else as.character(v)[1]
  }

  docs <- list()
  for (dl in (a[["/document-link"]] %||% list())) {
    cats <- vapply(dl[["/category"]] %||% list(), function(c) c[["@code"]] %||% "", character(1))
    if ("A12" %in% cats) next
    # the key is flattened: "/title/narrative", not "/title" -> "/narrative"
    title <- nar(dl[["/title/narrative"]])
    docs[[length(docs) + 1]] <- tibble::tibble(
      activity_project_id = pid %||% NA_character_,
      doc_title    = title,
      doc_url      = dl[["@url"]] %||% "",
      categories   = paste(cats, collapse = ","),
      project_page = paste0("https://www.ifad.org", page),
      contact_name  = nar(ci[["/person-name/narrative"]]),
      contact_email = nar(ci[["/email"]]),
      contact_job   = nar(ci[["/job-title/narrative"]]))
  }
  if (!length(docs)) NULL else bind_rows(docs)
}
docs <- bind_rows(lapply(files, one))
cat("document links read:", nrow(docs), "\n")

## ---- enrich -----------------------------------------------------------------
proj <- read.csv(file.path(CAT, "ifad_projects.csv"), stringsAsFactors = FALSE,
                 colClasses = "character")
docs <- docs %>%
  mutate(
    doc_type_title    = ifad_doc_type(doc_title),
    title_project_id  = str_extract(doc_title, "[0-9]{10}"),
    title_country     = str_trim(str_replace(str_extract(doc_title, "^[^0-9]+"), ":$", "")),
    id_agrees         = !is.na(title_project_id) & title_project_id == activity_project_id,
    project_id        = coalesce(title_project_id, activity_project_id),
    doc_uuid          = str_extract(doc_url, "[0-9a-f]{8}-[0-9a-f-]{27,}"),
    doc_date          = str_extract(doc_title, "[A-Z][a-z]+ 20[0-9]{2}$"),
    doc_year          = str_extract(doc_date, "20[0-9]{2}"),
    non_african       = str_detect(coalesce(title_country, ""), NON_AFRICAN),
    url_alive         = FALSE,
    url_dead_reason   = "operations.ifad.org terminates TLS with alert 40 and presents no certificate (verified 2026-10-03, IPv4 and IPv6, and by a real Chromium)") %>%
  left_join(proj %>% select(project_id, end_year, title_catalogue = title),
            by = "project_id")

cat("\ntype counts (must reproduce 544 / 80 / 59 / 45 / 22):\n")
print(table(docs$doc_type_title))
cat("\nproject-page links corrected vs the old catalogue: ")
old <- read.csv(file.path(CAT, "ifad_documents.csv"), stringsAsFactors = FALSE, colClasses = "character")
cat(sum(!old$project_page %in% docs$project_page), "of", nrow(old), "\n")
cat("document links attached to the wrong activity:",
    sum(!docs$id_agrees, na.rm = TRUE), "of", nrow(docs), "\n")

## ---- the target list --------------------------------------------------------
TARGET_TYPES <- c("completion_report", "mid_term_review")
tgt <- docs %>%
  filter(doc_type_title %in% TARGET_TYPES, !non_african) %>%
  mutate(end_year_n = suppressWarnings(as.integer(end_year))) %>%
  filter(is.na(end_year_n) | end_year_n >= 2015) %>%
  distinct(doc_url, .keep_all = TRUE) %>%
  mutate(
    type_label = ifelse(doc_type_title == "completion_report",
                        "Project_Completion_Report", "Mid-term_Review"),
    year_for_name = coalesce(doc_year, end_year),
    suggested_filename = paste0("ifad_", project_id, "_", type_label,
                                ifelse(is.na(year_for_name), "", paste0("_", year_for_name)),
                                ".pdf")) %>%
  arrange(title_country, project_id, doc_type_title)

out_cols <- c("project_id", "title_country", "title_catalogue", "doc_type_title",
              "doc_date", "doc_title", "project_page", "doc_url", "url_alive",
              "url_dead_reason", "suggested_filename", "contact_name",
              "contact_email", "contact_job", "end_year", "id_agrees", "doc_uuid")
write.csv(tgt[, intersect(out_cols, names(tgt))],
          file.path(CAT, "ifad_target_documents.csv"), row.names = FALSE, fileEncoding = "UTF-8")

excl <- docs %>%
  filter(doc_type_title %in% TARGET_TYPES, non_african) %>%
  distinct(doc_url, .keep_all = TRUE)
write.csv(excl[, intersect(out_cols, names(excl))],
          file.path(CAT, "ifad_target_documents_excluded.csv"), row.names = FALSE, fileEncoding = "UTF-8")

write.csv(docs, file.path(CAT, "ifad_documents_v2.csv"), row.names = FALSE, fileEncoding = "UTF-8")

cat("\n=== target list ===\n")
cat("documents:", nrow(tgt), "| projects:", length(unique(tgt$project_id)), "\n")
print(table(tgt$doc_type_title))
cat("non-African, excluded:", nrow(excl), "\n")
cat("rows whose document is attached to the wrong activity:",
    sum(!tgt$id_agrees, na.rm = TRUE), "\n")
cat("rows with a named IFAD contact:", sum(nzchar(tgt$contact_email)), "\n")
cat("\nwritten:\n  ifad_target_documents.csv\n  ifad_target_documents_excluded.csv\n  ifad_documents_v2.csv\n")
