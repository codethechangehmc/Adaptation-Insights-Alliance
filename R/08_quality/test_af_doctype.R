# test_af_doctype.R - offline regression tests for the Adaptation Fund
# document-type classifier (mcf_doc_type / af_doc_year in R/01_retrieve/af.R).
#
# Root cause under test: a management response must NEVER classify as the
# evaluation it responds to. Two on-disk mislabels came from matching
# "mid-term evaluation" / "completion report" anywhere in a title, and the
# fund's own project pages reuse evaluation ANCHOR TEXTS for management
# responses (the type is then only visible in the href filename).
#
#   Rscript R/08_quality/test_af_doctype.R    -> PASS/FAIL per test

.find_r_dir <- function() {
  full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  normalizePath(file.path(dirname(sub("^--file=", "", full[1])), ".."), mustWork = TRUE)
}
R_DIR <- .find_r_dir()
Sys.setenv(AF_MODE = "load")               # define functions only, never scrape
suppressMessages({
  source(file.path(R_DIR, "00_shared", "00_config.R"))
  source(file.path(R_DIR, "00_shared", "01_utils.R"))
  source(file.path(R_DIR, "01_retrieve", "af.R"))
})
PATHS$log_file <- file.path(tempdir(), "download_log_test.csv")   # never the real log

n_pass <- 0L; n_fail <- 0L
check <- function(name, cond) {
  if (isTRUE(cond)) { n_pass <<- n_pass + 1L; cat("PASS", name, "\n") }
  else              { n_fail <<- n_fail + 1L; cat("FAIL", name, "\n") }
}

## ---- management responses are NEVER evaluations (checked FIRST) ------------
check("mgmt response to mid-term evaluation is NOT a mid-term evaluation",
      mcf_doc_type("Management Response to the Mid-Term Project Evaluation Report") == "Management response")
check("mgmt response to terminal evaluation is NOT a terminal evaluation",
      mcf_doc_type("Management response to Terminal Evaluation") == "Management response")
check("matrix of responses is a management response",
      mcf_doc_type("Matrix of responses to IEES MTR Recommendations 28-08-2025") == "Management response")
# live cases (2026-10-02): evaluation anchor text, management response href
check("eval anchor text + mgmt-response href (IFAD/ACREGIR) -> Management response",
      mcf_doc_type("Mid-term evaluation report",
                   "https://fifspubprd.azureedge.net/afdocuments/project/7759/IFAD%20Management%20Response%20ACREGIR%20MTR.pdf") == "Management response")
check("PCR anchor text + mgmt-response href (Lake Victoria) -> Management response",
      mcf_doc_type("Project completion report",
                   "https://fifspubprd.azureedge.net/afdocuments/project/1434/Management%20response%20to%20Terminal%20Evaluation.pdf") == "Management response")
check("UN-Habitat 'Mgmnt response' href variant -> Management response",
      mcf_doc_type("Mid-term evaluation report",
                   "https://fifspubprd.azureedge.net/afdocuments/project/5199/UN-HabitatMgmnt%20response-finalCorrect.pdf") == "Management response")
check("management response is not an eval type",
      !"Management response" %in% AF_EVAL_TYPES)

## ---- positive cases: the clean anchor texts ---------------------------------
check("mid-term evaluation report",
      mcf_doc_type("Mid-term evaluation report",
                   "https://fifspubprd.azureedge.net/afdocuments/project/12155/WFP_AF_The%20Gambia_MTR%20report_final.pdf") == "Mid-term evaluation")
check("mid-term review",
      mcf_doc_type("Mid-term review") == "Mid-term evaluation")
check("final evaluation report",
      mcf_doc_type("Final evaluation report") == "Final evaluation")
check("terminal evaluation",
      mcf_doc_type("Terminal evaluation report") == "Terminal evaluation")
check("project completion report",
      mcf_doc_type("Project completion report") == "Completion report")
check("completion report (docx href)",
      mcf_doc_type("Project completion report",
                   "https://fifspubprd.azureedge.net/afdocuments/project/24/SANBI%20URP_Project%20Completion%20Summary_2024.09.30.docx") == "Completion report")
check("all eval anchor types are eval types",
      all(c("Mid-term evaluation", "Final evaluation", "Terminal evaluation",
            "Completion report") %in% AF_EVAL_TYPES))

## ---- progress and out-of-scope types ----------------------------------------
check("PPR1 (for web) is a progress document",
      mcf_doc_type("PPR1 (for web)") == "Performance report (PPR)")
check("PPR type is progress, not eval",
      "Performance report (PPR)" %in% AF_PROGRESS_TYPES &&
        !"Performance report (PPR)" %in% AF_EVAL_TYPES)
# First run ledgered 7 PPRs as out_by_type: the pages sometimes use the FILE
# NAME as the anchor text, or a language label, and "\\bppr" does not match
# "AF00000177_PPR3" because "_" is a word character.
check("PPR filename as anchor text is a progress document",
      mcf_doc_type("AF00000177_PPR3_Web.pdf") == "Performance report (PPR)")
check("language-label anchor + PPR href is a progress document",
      mcf_doc_type("English",
                   "https://fifspubprd.azureedge.net/afdocuments/project/9/AF00000230_PPR1_Web.pdf") == "Performance report (PPR)")
check("'Approval' in a filename is NOT a PPR",
      mcf_doc_type("Other project order",
                   "https://x/10_AFB-Decision-B.30-31.18-Approval_of_extension_project_completion_date.pdf") == "Other")
check("monitoring report is a progress document",
      mcf_doc_type("Monitoring Report 1") == "Monitoring report")
check("monitoring report is progress, not eval",
      "Monitoring report" %in% AF_PROGRESS_TYPES &&
        !"Monitoring report" %in% AF_EVAL_TYPES)
check("inception report", mcf_doc_type("Inception Report") == "Inception report")
check("inception workshop report filename as anchor text",
      mcf_doc_type("12038_2020-05-08-SierraLeone_AF-Inception Workshop Report.pdf") == "Inception report")
check("project document",  mcf_doc_type("Project document") == "Project document")
check("project pre-concept", mcf_doc_type("Project pre-concept") == "Project document")
check("unknown anchor -> Other", mcf_doc_type("Procurement plan") == "Other")

## ---- year extraction ---------------------------------------------------------
check("year from href (dotted date)",
      identical(af_doc_year("Final evaluation report",
        "https://x/afdocuments/project/24/SANBI%20URP%20Terminal%20Evaluation_Draft_2024.09.20.pdf"), 2024L))
check("year from href takes the LATEST plausible year",
      identical(af_doc_year("Final evaluation report",
        "https://x/afdocuments/project/1434/afr-mie-water-2015-1_2025_te_unep.pdf"), 2025L))
check("no visible year -> NA (file stays without year suffix)",
      is.na(af_doc_year("Mid-term evaluation report",
        "https://x/afdocuments/project/12101/ADSWAC%20Mid%20Term%20Evalution%20Report-OSS%5B79%5D.pdf")))
check("digits that are not years are ignored",
      is.na(af_doc_year("Mid-term evaluation report",
        "https://x/afdocuments/project/8/8_KCCAP%20MID-TERM%20EVALUATION%20REPORT.pdf")))

## ---- a mistyped on-disk file must not absorb the real evaluation -----------
# First run of the site scraper marked the REAL UN-Habitat mid-term
# evaluation (/afdocuments/project/5199/Final MTE Report-...pdf) as
# already_held against af_AF00000109_Mid-term_evaluation_2019.pdf - a
# management response. The real evaluation was then never fetched.
disk <- tibble::tibble(
  path  = c("x/af_AF00000109_Mid-term_evaluation_2019.pdf",
            "x/af_065NKENMR_Mid-term_evaluation_2014.pdf"),
  base  = c("af_AF00000109_Mid-term_evaluation_2019.pdf",
            "af_065NKENMR_Mid-term_evaluation_2014.pdf"),
  lower = c("af_af00000109_mid-term_evaluation_2019.pdf",
            "af_065nkenmr_mid-term_evaluation_2014.pdf"))
meta <- tibble::tibble(
  project_id = c("AF00000109", "065NKENMR"),
  source_url = c("https://fifspubprd.azureedge.net/afdocuments/project/5199/x.pdf",
                 "https://fifspubprd.azureedge.net/afdocuments/project/8/y.pdf"),
  src_base   = c("x.pdf", "y.pdf"),
  site_num   = c("5199", "8"))

check("both retype filenames are registered as mistyped",
      all(c("af_AF00000109_Mid-term_evaluation_2019.pdf",
            "af_AFRDG00001_Completion_report_2016.pdf") %in% AF_MISTYPED_ON_DISK))
m_bad <- af_match_disk(
  "https://fifspubprd.azureedge.net/afdocuments/project/5199/Final%20MTE%20Report-UN-Habitat.pdf",
  "Mid-term evaluation", disk, meta)
check("real MTE is NOT already_held against the mistyped file", is.na(m_bad$held))
check("project id still resolves for the real MTE", identical(m_bad$pid, "AF00000109"))
m_ok <- af_match_disk(
  "https://fifspubprd.azureedge.net/afdocuments/project/8/8_KCCAP%20MID-TERM%20EVALUATION%20REPORT.pdf",
  "Mid-term evaluation", disk, meta)
check("a genuinely held evaluation still matches already_held",
      identical(m_ok$held, "af_065NKENMR_Mid-term_evaluation_2014.pdf"))

cat(sprintf("\n%d passed, %d failed\n", n_pass, n_fail))
if (n_fail > 0) quit(status = 1)
