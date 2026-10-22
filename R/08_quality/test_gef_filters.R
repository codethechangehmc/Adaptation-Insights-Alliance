# test_gef_filters.R - offline regression tests for the GEF doc-type filter
# fixes (Oct 2026 corpus-completion campaign).
#
# The pre-fix failure modes these tests pin down:
#   * bare "TE"/"MTR" patterns matched as SUBSTRINGS of doc_url, so nearly
#     every URL passed the filter (615 proposals were downloaded);
#   * infer_gef_doc_type returned NA for a TE whose link text was "3302 TE",
#     and NA (priority 99) then LOST to a PIF (priority 11) in
#     select_best_gef_document.
#
#   Rscript R/08_quality/test_gef_filters.R    -> PASS/FAIL per test
#
# Sourcing gef.R here is itself a regression test: the run guard must NOT
# start a scrape when the file is sourced.

.find_r_dir <- function() {
  full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  normalizePath(file.path(dirname(sub("^--file=", "", full[1])), ".."), mustWork = TRUE)
}
R_DIR <- .find_r_dir()
suppressMessages({
  source(file.path(R_DIR, "00_shared", "00_config.R"))
  source(file.path(R_DIR, "00_shared", "01_utils.R"))
  source(file.path(R_DIR, "01_retrieve", "gef.R"))   # guard: must not execute
})
PATHS$log_file <- file.path(tempdir(), "download_log_test.csv")   # never the real log

n_pass <- 0L; n_fail <- 0L
check <- function(name, cond) {
  if (isTRUE(cond)) { n_pass <<- n_pass + 1L; cat("PASS", name, "\n") }
  else              { n_fail <<- n_fail + 1L; cat("FAIL", name, "\n") }
}

## ---- infer_gef_doc_type: tokens type real evaluations -----------------------
check("'3302 TE' link text -> Terminal Evaluation",
      identical(infer_gef_doc_type(
        "https://publicpartnershipdata.azureedge.net/gef/GEFDocuments/17aef3b7/TE/_3302%20TE.pdf",
        "3302 TE"), "Terminal Evaluation"))

check("GUID_TE.pdf (underscore boundary) -> Terminal Evaluation",
      identical(infer_gef_doc_type(
        "https://publicpartnershipdata.azureedge.net/gef/GEFProjectVersions/cab7f34b_TE.pdf",
        "TE"), "Terminal Evaluation"))

check("double-encoded %2520 TE title -> Terminal Evaluation",
      identical(infer_gef_doc_type(
        "https://undpgefpims.org/attachments/x/y.docx",
        "Terminal%2520Evaluation%2520Report_REMECC"), "Terminal Evaluation"))

check("'3669 ICR' -> Terminal Evaluation (ICR token)",
      identical(infer_gef_doc_type("https://example.org/doc.pdf", "3669 ICR"),
                "Terminal Evaluation"))

check("MTR token in encoded title -> Mid-Term Review",
      identical(infer_gef_doc_type(
        "https://undpgefpims.org/attachments/5270/x.docx",
        "PIMS%205270%20MTR%20Review%20Report%20%20final%20version"), "Mid-Term Review"))

check("spelled-out Midterm Review in url -> Mid-Term Review",
      identical(infer_gef_doc_type(
        "https://x.net/gef/GEFDocuments/a/MTR/MidtermReviewMTR_4141_2019.pdf", NA),
        "Mid-Term Review"))

## ---- infer_gef_doc_type: substrings must NOT type -----------------------------
check("'water' title does not match TE",
      !identical(infer_gef_doc_type("https://example.org/report.pdf", "water"),
                 "Terminal Evaluation"))

check("'te' inside url words does not match TE",
      is.na(infer_gef_doc_type(
        "https://example.org/integrated-water-system/latest/notes.pdf",
        "Annual notes")))

check("COTE_D_IVOIRE / Côte never matches TE (accents are word chars)",
      is.na(infer_gef_doc_type(
        paste0("https://publicpartnershipdata.azureedge.net/gef/PMISGEFDocuments/",
               "Climate%20Change/Cote%20d%27Ivoire%20-%20%285618%29%20-%20Preparation%20of%20",
               "C%C3%B4te%20d%E2%80%99Ivoire%E2%80%99s%20Initial%20Biennial%20Up/",
               "ID5618__EA__Initial_BUR_COTE_D_IVOIRE__05.11.2013.pdf"),
        "Enabling Activity Request")))

check("evaluation beats proposal words in the same name",
      identical(infer_gef_doc_type(
        "https://x.net/gef/GEFDocuments/a/TE/TerminalEvaluationTE_project-document.pdf", NA),
        "Terminal Evaluation"))

check("PIR still types as progress report",
      identical(infer_gef_doc_type(
        "https://x.net/gef/GEFDocuments/a/PIR/ProjectImplementationReportPIR_2021.pdf", NA),
        "Project Implementation Report"))

check("CEO endorsement still types",
      identical(infer_gef_doc_type(
        "https://x.net/gef/GEFProjectVersions/guid_CEOEndorsement.pdf", "CEO Approval"),
        "CEO Endorsement"))

## ---- filter_target_documents: tokens never fire on raw URLs -------------------
mk <- function(title, url, type = NA_character_) {
  tibble::tibble(gef_id = "1", project_title = "p", project_url = "pu",
                 doc_title = title, doc_url = url, doc_type = type,
                 country = "Kenya")
}
suppressMessages({
  # url full of te/pif substrings, nothing else: must be filtered OUT
  out1 <- filter_target_documents(mk(
    "Annual notes", "https://example.org/integrated-updates/latest/notes.pdf"))
  # bare TE as link TEXT token: must be kept
  out2 <- filter_target_documents(mk(
    "3302 TE", "https://example.org/a.pdf", "Terminal Evaluation"))
  # 'water' title: out
  out3 <- filter_target_documents(mk("water", "https://example.org/water.pdf"))
})
check("url 'te' substrings alone do not pass the filter", nrow(out1) == 0)
check("doc typed/texted TE passes the filter", nrow(out2) == 1)
check("'water' does not pass the filter", nrow(out3) == 0)

## ---- select_best_gef_document: NA never outranks a typed evaluation ----------
suppressMessages({
  docs <- tibble::tibble(
    gef_id    = c("42", "42", "42"),
    doc_title = c("mystery attachment", "proposal", "3302 TE"),
    doc_url   = c("u1", "u2", "u3"),
    doc_type  = c(NA_character_, "Project Identification Form", "Terminal Evaluation")
  )
  best <- select_best_gef_document(docs)
})
check("typed TE beats PIF and NA", identical(best$doc_type, "Terminal Evaluation"))

suppressMessages({
  docs2 <- tibble::tibble(
    gef_id    = c("7", "7"),
    doc_title = c("mystery attachment", "endorsement"),
    doc_url   = c("u1", "u2"),
    doc_type  = c(NA_character_, "CEO Endorsement")
  )
  best2 <- select_best_gef_document(docs2)
})
check("NA never outranks ANY typed document", identical(best2$doc_type, "CEO Endorsement"))

suppressMessages({
  docs3 <- tibble::tibble(gef_id = "9", doc_title = "mystery",
                          doc_url = "u1", doc_type = NA_character_)
  best3 <- select_best_gef_document(docs3)
})
check("a project with only NA docs still keeps one row", nrow(best3) == 1)

## ---- the historical regression end-to-end ------------------------------------
# A project page listing a PIF and a "3302 TE"-style evaluation: after
# re-typing with the fixed infer, the TE must win the one-per-project pick.
suppressMessages({
  raw <- tibble::tibble(
    gef_id    = c("3302", "3302"),
    doc_title = c("Project Identification Form", "3302 TE"),
    doc_url   = c("https://x.net/gef/GEFProjectVersions/guid_PIF.pdf",
                  "https://x.net/gef/GEFDocuments/guid/TE/_3302%20TE.pdf"),
    doc_type  = c(infer_gef_doc_type("https://x.net/gef/GEFProjectVersions/guid_PIF.pdf",
                                     "Project Identification Form"),
                  infer_gef_doc_type("https://x.net/gef/GEFDocuments/guid/TE/_3302%20TE.pdf",
                                     "3302 TE"))
  )
  best4 <- select_best_gef_document(raw)
})
check("regression: '3302 TE' project yields the TE, not the PIF",
      identical(best4$doc_type, "Terminal Evaluation") &&
      identical(best4$doc_title, "3302 TE"))

## ---- gef_has_next_page: xml_missing is not NULL ------------------------------
# rvest::html_node() returns an xml_missing node, never NULL, so the old
# `if (is.null(next_link)) break` never fired and every listing loop ran one
# page PAST the end. On the funding-source facet the past-the-end page is
# HTTP 200 with a stale "Displaying 391 - 395 of 395" and no results table,
# which tripped assert_response and killed the sweep (LDCF page 14, 2026-10-02).
last_page <- xml2::read_html(paste0(
  "<html><body><table class='views-view-table'><tbody><tr><td>x</td></tr>",
  "</tbody></table><nav><a href='?page=12' rel='prev'>Prev</a></nav>",
  "</body></html>"))
mid_page <- xml2::read_html(paste0(
  "<html><body><table class='views-view-table'><tbody><tr><td>x</td></tr>",
  "</tbody></table><nav><a href='?f%5B0%5D=funding_source%3A479&amp;page=13' ",
  "rel='next'>Next</a></nav></body></html>"))

check("last page (no rel=next) -> no next page",
      identical(gef_has_next_page(last_page), FALSE))
check("mid page (rel=next present) -> next page",
      identical(gef_has_next_page(mid_page), TRUE))
check("the old is.null() test would have been wrong on the last page",
      !is.null(rvest::html_node(last_page, "a[rel='next']")))

cat(sprintf("\n%d passed, %d failed\n", n_pass, n_fail))
if (n_fail > 0) quit(status = 1)
