##############################################################################
# extract_verbatim.R — SESSION 1 of the two-session extraction design
# (protocol §5/§7: Session 1 = verbatim extraction, Session 2 = coding).
#
# This script extracts ONLY verbatim passages and literal facts from one or
# more evaluation PDFs — no controlled-vocabulary choices are made here.
# Controlled-value harmonisation happens afterwards in R/harmonize.R, which
# sees only the short verified extracts, never the documents.
#
# Why: (a) verbatim outputs can be FACT-CHECKED mechanically — this script
# string-matches every quote and literal value against the cited page and
# writes a verification report; (b) one job per prompt (BTR lesson);
# (c) vocabulary changes re-run only Session 2, no document is re-read.
#
# Method carried over from extract_general.R (BTR_Analysis lineage):
# separate prompt per field group, whole page-tagged document doc-first
# (provider prompt caching), structured output, per-group tryCatch,
# JSON audit per group, timestamped CSV per run, prompt_version stamping.
#
# evidence_depth is NOT asked of the model: it is derived in code from what
# Session 1 found (results present -> 2, else 1), deterministically.
#
# Usage:
#   Rscript R/extract_verbatim.R                    # gold-standard P001
#   Rscript R/extract_verbatim.R doc1.pdf doc2.pdf  # any documents
#   EXTRACT_MODE=probe  -> identity group only (plumbing test)
#   EXTRACT_MODEL=gpt-5-nano -> cheaper model
# Requires OPENAI_API_KEY (~/.Renviron).
##############################################################################

suppressPackageStartupMessages({
  library(ellmer); library(pdftools); library(jsonlite); library(readr)
})

MODE  <- Sys.getenv("EXTRACT_MODE", "pilot")
MODEL <- Sys.getenv("EXTRACT_MODEL", "gpt-5-mini")
PROMPT_VERSION <- "s1-v2.7"   # v2.7 (30 Sep 2026): evidence travels with every value, for the consultant QC workbooks. A page per field across identity, geography and finance (pg1()); start_year_evidence/closure_year_evidence renamed to _quote; the money fields carry the document's own wording (budget_total_stated and friends) so an expanded figure like 1710000 is checkable against "UA 1.71 million" on the page; GESI gets a quote and a page; the fact-check verdict rides on the row as <field>_check instead of only in verify_*.csv; catalogue and code-derived values carry a _provenance string so no QC hover is ever blank. v2.6 (29 Sep 2026): result values keep their decimals (3.6 stays 3.6, 12.5 stays 12.5); v2.5 (28 Sep 2026): headline results rule (reach, physical, effect; eligibility, category, beneficiary anchor); v2.4: money as plain digits, rationale is the reason not the achievement; v2.3: national bodies carry their country; v2.2 (Charity pilot): planned closing and template dates excluded, AfDB numbers and unit codes; v2.1: countries, explicit start; v2.0: one module per document
# family (R/05_extract/families/*.R). The shared prompt keeps only the rules
# that hold for every family; each module adds where its fields sit, what its
# results table's columns are called, its actor roles, its currency and its
# traps, and the World Bank wording that used to sit in the shared prompt
# lives in wb_icr.R. v1.2 (16 Sep 2026), from adjudicating the gold
# disagreements against the documents: title copied character for character;
# location_count never counts the evaluation's own focus groups or
# interviews; a publisher that delivers the
# work is also an implementor and partners named in running text count;
# financing read from the focus programme's row in a multi-programme table.
# v1.1: team field rules - no shouty titles, no codes in titles, numeric-only
# location_count, location_notes always filled, GESI stated when absent,
# whole-digit results, % for percentages
# v1.3 (28 Sep 2026), team decisions on the QC questions: location_count is
# the number of COUNTRIES (finer levels go to location_notes, which also
# notes multi-scale work); the start year is recorded only when stated
# explicitly, never taken from an implementation period.
MODEL_TAG <- gsub("[^a-z0-9]+", "-", tolower(MODEL))   # for output file names
# .Renviron lives in the OneDrive-redirected Documents folder; a shell that
# overrides HOME (e.g. Git Bash) makes R miss it, so load it explicitly
if (!nzchar(Sys.getenv("OPENAI_API_KEY")))
  for (p in c(file.path(Sys.getenv("OneDrive"), "Documents", ".Renviron"),
              file.path(Sys.getenv("USERPROFILE"), "Documents", ".Renviron")))
    if (file.exists(p)) { readRenviron(p); break }
stopifnot("OPENAI_API_KEY not set" = nzchar(Sys.getenv("OPENAI_API_KEY")))

GL <- "C:/Users/mlolita/OneDrive - CGIAR/WP2_Evidence Synthesis/Grey Literature"
GOLD_P001 <- file.path(GL, "03_Documents/pilot/gold_set_P001-P010/P001",
  "P001_World Bank_Implementation Completion and Results Report_2019_worldbank_3A-AFCC2_RI_-Support_to_NPCA_TerrAfrica_Secretariat_--_P149269_Implementation_Completion_and_Results_Report_2019.pdf")

# Input: PDF path(s), or a MANIFEST csv (columns: project_code, pdf, focus,
# and optionally family: the census family from 02_dedup, which skips the
# cover detection).
# `focus` handles multi-project documents: it is injected into every prompt
# so the model extracts only for the named program (e.g. the shared GEF
# Food Systems evaluation covering RFS + GGP + CFI).
args <- commandArgs(trailingOnly = TRUE)
if (length(args) == 1 && grepl("\\.csv$", args[1])) {
  mf <- read.csv(args[1], stringsAsFactors = FALSE)
  mf[is.na(mf)] <- ""
  PDFS <- mf$pdf; FOCUS <- mf$focus; PCODE <- mf$project_code
  FAMILY <- if ("family" %in% names(mf)) mf$family else rep("", nrow(mf))
} else {
  PDFS <- if (length(args)) args else GOLD_P001
  FOCUS <- rep("", length(PDFS)); PCODE <- rep("", length(PDFS))
  FAMILY <- rep("", length(PDFS))
}

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- if (length(full)) normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", "..")) else getwd()
OUT_DIR <- Sys.getenv("EXTRACT_OUT_DIR", file.path(REPO, "outputs", "extraction"))
source(file.path(REPO, "R", "00_shared", "paths.R"))          # safe_name(): project codes are not filename-safe
source(file.path(REPO, "R", "00_shared", "clean_fields.R"))
source(file.path(REPO, "R", "00_shared", "results_rank.R"))   # choose_headline(): the three headline results
source(file.path(REPO, "R", "00_shared", "rf_table.R"))
source(file.path(REPO, "R", "00_shared", "doc_families.R"))
RAW_DIR <- file.path(OUT_DIR, "raw")
dir.create(RAW_DIR, recursive = TRUE, showWarnings = FALSE)

MAX_CHARS <- 600000
digest_path <- function(x) sprintf("%08x", sum(utf8ToInt(x) * seq_along(utf8ToInt(x)) %% 97))

read_doc <- function(path) {
  if (nchar(path) > 250) {   # Windows long-path workaround (OneDrive depth)
    short <- file.path(tempdir(), paste0("x", substr(digest_path(path), 1, 8), ".pdf"))
    ok <- suppressWarnings(file.copy(paste0("\\\\?\\", gsub("/", "\\\\", path)),
                                     short, overwrite = TRUE))
    if (!ok) ok <- file.copy(path, short, overwrite = TRUE)
    stopifnot("could not copy long-path PDF" = ok)
    path <- short
  }
  pages <- pdf_text(path)
  list(pages = pages, n_pages = length(pages), local_path = path)
}

# -------------------------------------------- catalogue prefill (tier 1) ----
# catalogues/doc_index.csv maps every corpus FILENAME to its catalogue row
# (built by R/build_doc_index.R; 100% coverage over the 656 in-scope files).
# Precedence: catalogue > cover-vision > text extraction. Displaced extracted
# values are kept in *_extracted columns for QC.
DOC_INDEX <- local({
  p <- file.path(REPO, "catalogues", "doc_index.csv")
  if (file.exists(p)) {
    di <- read.csv(p, stringsAsFactors = FALSE, colClasses = "character")
    di[is.na(di)] <- ""
    di
  } else NULL
})

# ------------------------------------------------ family modules (routing) --
# A source is not a family. The shared detector (00_shared/doc_families.R)
# names the family from the cover; each family has a module under
# R/05_extract/families/ that says which pages to keep, where its results
# table is and what its columns are called, and what to add to each prompt.
FAMILIES_DIR <- file.path(REPO, "R", "05_extract", "families")
load_module <- function(id) {
  f <- file.path(FAMILIES_DIR, paste0(id, ".R"))
  if (!file.exists(f)) f <- file.path(FAMILIES_DIR, "generic.R")
  env <- new.env(parent = globalenv())
  sys.source(f, envir = env)
  get("MODULE", envir = env)
}
module_for <- function(pages, family_hint = "") {
  fam <- if (nzchar(family_hint) && family_hint %in% FAMILY_IDS) family_hint
         else detect_family(pages)$family
  mod_id <- family_info(fam)$module
  if (identical(mod_id, "none")) {
    cat("  note: family", fam, "is a progress document or worksheet; read generically\n")
    mod_id <- "generic"
  }
  m <- load_module(mod_id); m$family <- fam; m
}

# Long documents are cut to the pages the module names, keeping the original
# [page N] numbers so citations and the fact-check stay valid. Short documents
# and modules without a page map keep every page.
select_pages <- function(pages, module, focus = "") {
  n <- length(pages)
  limit <- if (is.null(module$long_doc_pages)) 100 else module$long_doc_pages
  if (is.null(module$keep_pages) || n <= limit) return(rep(TRUE, n))
  keep <- module$keep_pages(pages, focus)
  keep[seq_len(min(12, n))] <- TRUE            # cover, identification block, TOC
  keep
}

# ------------------------------------------ results-table pages (per family) --
# The pages handed to rf_table.R and attached as images. Where the table sits
# differs by family: an annex at the end (World Bank), the body once (AfDB),
# or wherever the most column roles are named together (evaluator-written).
RF_MAX_IMG <- 10
rf_role_count <- function(low) vapply(low, function(t) sum(c(
  grepl("baseline|r.f.rence|situation de", t),
  grepl("target|cible|objectif vis", t),
  grepl("actual|achiev|most recent|level at|midterm level|r.alis|atteint|total actual", t),
  grepl("indicator|indicateur", t))), integer(1), USE.NAMES = FALSE)
rf_pages <- function(pages, module) {
  low <- tolower(pages); rf <- module$rf
  hits <- grep(rf$patterns, low)
  if (!length(hits)) return(integer(0))
  roles <- rf_role_count(low)
  if (identical(rf$prefer, "first")) {
    start <- hits[1]
    win <- seq(start, min(length(pages), start + RF_MAX_IMG - 1))
    return(win[win == start | roles[win] >= 2 | win %in% hits])
  }
  if (identical(rf$prefer, "dense")) {
    cand <- hits[roles[hits] >= 3]
    if (!length(cand)) cand <- hits
    return(sort(head(cand[order(-roles[cand], cand)], RF_MAX_IMG)))
  }
  ann <- if (!is.null(rf$annex_start)) grep(rf$annex_start, low) else integer(0)
  start <- if (length(ann)) ann[length(ann)] else hits[length(hits)]
  win <- seq(start, min(length(pages), start + RF_MAX_IMG - 1))
  extra <- if (!is.null(rf$extra_pages)) {
    e <- grep(rf$extra_pages, low); head(e[e >= start], 3)
  } else integer(0)
  sort(unique(c(win, extra)))
}

build_doc_text <- function(pages, sel) {
  txt <- paste0("[page ", which(sel), "]\n", pages[sel], collapse = "\n\n")
  if (nchar(txt) > MAX_CHARS) {                # backstop clip, BTR-style
    txt <- paste0(substr(txt, 1, round(MAX_CHARS * 0.7)), "\n...[clipped]...\n",
                  substr(txt, nchar(txt) - round(MAX_CHARS * 0.3) + 1, nchar(txt)))
  }
  txt
}

SYSTEM <- paste(
  "You are a meticulous VERBATIM data-extraction assistant for grey-literature",
  "project evaluation documents (African agriculture climate adaptation).",
  "You extract passages and literal facts EXACTLY as the document states them.",
  "You never classify into external categories — that happens later, elsewhere.",
  "When a value or passage is not in the document, return an empty string.",
  "Report actual values, not planned/target ones. The text carries [page N]",
  "markers: always report the page number for everything you extract, and",
  "make quotes exact so they can be verified against the page by machine.",
  "HARD RULES: (1) Numbers describing the evaluation's own methodology",
  "(sample sizes, respondents, focus-group participants) are never project",
  "results. (2) In tables covering several projects, read only this",
  "project's row. (3) If two tables contradict each other, use the",
  "identification block (data sheet, basic data, project information table)",
  "and mention the contradiction in the nearest notes field.")

pg <- function() type_array(items = type_integer(),
  description = "Page numbers ([page N]) where this information was found.")

# A page for ONE field, so a checker lands on the line instead of a range.
# The group's source_pages still covers the whole answer; this says which of
# those pages carries this particular value. 0 when the value is not in the
# document (nothing stated, or it was derived rather than read).
pg1 <- function(what) type_integer(paste0(
  "Page number ([page N]) carrying ", what,
  ". A single page, not a range. 0 if the field is empty or not stated."))

GROUPS <- list(

identity = list(
  task = "Extract the project identity and timeline, verbatim from the document.",
  type = type_object(
    project_title  = type_string("The PROJECT's name, word by word as stated - from the cover, from the identification block the family note names (data sheet, basic data, project information table), or from the 'evaluation of the project X' phrasing (extract X). Never the REPORT's own name (e.g. 'PPCR Evaluation Report' is a report title, not a project title). WRITE IT IN NORMAL SENTENCE CASE even when the cover shouts it in capitals. Keep abbreviations as they are (APPSA, RFS, AFCC2/RI) but NEVER include a project or document code (no P-number, no GEF ID, no report number, no trailing code). Copy the remaining words CHARACTER FOR CHARACTER from the identification block, including spacing around hyphens and slashes: if it reads 'X/Y -Support', do not tidy it to 'X/Y - Support'."),
    project_id     = type_string("The publisher's project identifier exactly as printed IN THIS DOCUMENT, in the form the family note gives. Empty if none printed."),
    project_lead_name = type_string("NAME of the ORGANISATION leading the project, as the document names it (often the implementing agency or publisher; the family note names the role). Never an internal department, global practice, division or regional unit of an organisation — name the organisation itself. An organisation that both commissions and delivers the work is the lead AND an implementor: record it in both places. A NATIONAL body (ministry, department, directorate, agency, authority, government, national institute or fund) is written WITH ITS COUNTRY after a comma, the way the registry writes it: 'Ministry of Agriculture and Food Security, Malawi', 'Environment Protection Agency, Sierra Leone', 'Government of Mozambique'. Take the country the project is implemented in; never leave a national body without its country, and never invent one for an international organisation."),
    publication_year = type_string("Year the source document was published (front page, 'Date of report', submission date). NEVER a template or form version date printed in a header or footer, such as 'GEF 7 Core Indicators, March 2019 (revised)' or 'Version 2.1, 2018'. Empty if the document carries no date of its own."),
    start_year     = type_string("Year the project ACTUALLY started per the document. Look in the dates block the family note names (Key Dates, Project data, Project Information Table, Relevant Dates): 'Approval', 'Effectiveness', 'entry into force', 'signature', 'officially launched', French 'mise en vigueur'. Never design/concept/endorsement years, and NEVER an extension approval or revised-closing decision date. If no formal date is stated but the document gives an explicit implementation period ('implemented between 2017 and 2022'), use its first year. A prose statement of when work began also counts: 'under implementation since 2018', 'running since 2018', 'operational since 2018'. Empty only if none of these is stated."),
    start_year_quote = type_string("Short exact quote stating the start (e.g. 'Approval 29-Apr-2014', 'Effectiveness date: 12 March 2017'), with its wording unchanged. An implementation period alone ('implemented between 2017 and 2022') is NOT a start statement: leave start_year and this field empty and put the period in implementation_period."),
    start_year_page = pg1("the start statement quoted above"),
    closure_year   = type_string("Year the project ACTUALLY closed ('actual closing', 'completed in'; the last year of an explicit implementation period counts if the project is described as finished). NEVER a planned, expected, original or revised closing date of a project still under implementation (interim and mid-term evaluations, progress reports): leave empty then. Empty if still running ('to date') or not stated."),
    closure_year_quote = type_string("Short exact quote stating the closing."),
    closure_year_page = pg1("the closing statement quoted above"),
    implementation_period = type_string("The implementation period exactly as the document states it, e.g. '2017-2022' or 'implemented between 2017 and 2022', if any such statement exists. Empty otherwise."),
    document_type_stated = type_string("The document's OWN designation of itself, verbatim (e.g. 'Implementation Completion and Results Report', 'Project Performance Evaluation Report', 'Mid-term evaluation of the project ...')."),
    resource_id    = type_string("The DOCUMENT's own report/document number as printed, in the form the family note gives. NEVER a grant, loan or trust-fund account number (TF-..., IDA-..., 2100155...), never internal department/routing codes (RDGW/AHAI), never bare date codes. Empty if none."),
    # one page per field, so a checker lands on the line rather than on the
    # group's page range
    project_title_page    = pg1("the project title as printed"),
    project_id_page       = pg1("the project identifier"),
    project_lead_page     = pg1("the naming of the lead organisation"),
    publication_year_page = pg1("the document's own date"),
    implementation_period_page = pg1("the implementation period statement"),
    document_type_page    = pg1("the document's designation of itself"),
    resource_id_page      = pg1("the report/document number"),
    source_pages   = pg())),

geography = list(
  task = paste(
    "Extract the geographic scope verbatim. Review the whole document and",
    "aggregate location lists that appear in different sections."),
  type = type_object(
    scope_stated   = type_string("Exact quote of the document's own statement of geographic scope/coverage (e.g. 'The study's geographical scope was nationwide' or the countries list)."),
    location_count = type_string("A BARE NUMBER and nothing else - digits only, no words, no '~', no 'N/A', no unit. It is the number of DISTINCT AFRICAN COUNTRIES in which the project implemented activities, as the document names them. A project in one country is 1. Count a country once. Countries outside Africa are NOT counted here: name them in location_notes (the template keeps the scope beyond Africa there). Do NOT count districts, villages, sites or provinces here: they belong in location_notes. Do NOT count countries that only appear as context, comparison, mission destinations, event venues or partner headquarters. NEVER count the evaluation's own fieldwork: focus groups, interviews, survey rounds and respondent groups are not places. Leave empty only when the document truly never names where the project worked."),
    location_count_basis = type_string("One sentence naming the countries counted and where the list is (pages), so the count can be checked."),
    location_notes = type_string(paste(
      "ALWAYS fill this, and it MUST account for the number in location_count.",
      "Give a VERBATIM sentence, phrase or list from the document naming where",
      "the project worked - quote it exactly, do not paraphrase.",
      "Then add the finer level when the document enumerates it: how many",
      "districts, villages or sites, with a short quote. If the project works",
      "at several scales (regional or national policy work plus local sites),",
      "say so in a few words.",
      "Name any countries outside Africa here, with their number, since",
      "location_count leaves them out.",
      "The two fields must tell one story. If the passage you quote covers only",
      "PART of what you counted, say so first and then quote, for example:",
      "'26 countries are named as receiving support; 15 of them received CSIF",
      "support: \"Uganda, Madagascar, Ghana...\"'. Never leave a number here",
      "that contradicts location_count without explaining the difference.",
      "If the project also worked outside Africa, add",
      "'total of X international locations, of which Y African' after the quote.")),
    scope_page          = pg1("the scope statement quoted in scope_stated"),
    location_notes_page = pg1("the verbatim passage quoted in location_notes"),
    source_pages   = pg())),

rationale = list(
  task = "Extract why the project was implemented and who it targets, verbatim.",
  type = type_object(
    rationale_project = type_string(paste(
      "WHY the project was needed, IN THE DOCUMENT'S OWN WORDS.",
      "This is the REASON the project was designed: the problem, hazard or",
      "need that existed BEFORE the project. It is never what the project",
      "achieved, delivered or exceeded.",
      "Copy the sentence or sentences that state the problem, EXACTLY as",
      "printed, word for word. Do NOT rewrite, summarise, translate, tidy or",
      "recombine them into a sentence of your own, and do not add words to",
      "make them fit this field. This text is machine-checked against the page.",
      "Choose the passage that gives the context-specific hazards, stressors",
      "and pain points, and the perceived benefits, up to 100 words.",
      "If two separate passages are needed to cover the climatic and the",
      "non-climatic drivers, quote both and join them with ' ... ', each part",
      "still word for word.",
      "If a passage is longer than 100 words, quote its most relevant part",
      "exactly and mark the cut with '...'.",
      "CLIMATIC drivers to look for: drought, rainfall variability, flooding,",
      "temperature, cyclones, sea-level rise, climate-linked pests and disease.",
      "NON-CLIMATIC: land degradation, soil fertility loss, overexploitation,",
      "food and nutrition insecurity, poverty, weak market access, insecure",
      "tenure, weak institutions or extension, gender gaps.",
      "NEVER put here: the project's objectives or components, the activities",
      "it carried out, who funded or implemented it, or its results. A",
      "sentence starting 'To improve...', 'The project supported...' or 'The",
      "project has achieved its objectives in...' is the wrong content unless",
      "the document itself uses those words to describe the problem. If the",
      "document states no reason at all, leave the field EMPTY rather than",
      "quoting an achievement or an objective.")),
    rationale_project_page = type_integer("Page number where the quoted rationale passage appears."),
    target_beneficiary_stated = type_string(paste(
      "EXACT quote (verbatim, machine-checkable) of the passage naming who the",
      "project ULTIMATELY benefits. Ministries, agencies, programme teams,",
      "staff and researchers are the channel, not the beneficiary: when the",
      "project works through institutions, quote the passage that says who",
      "that is for - the objective or goal statement ('to improve the",
      "livelihoods of the rural population of SSA'), the direct-beneficiary",
      "indicator, or the stated target group. Quote the institution instead",
      "only when the document never names an end group.",
      "EVIDENCE, NOT INFERENCE: the passage must SHOW this group benefiting -",
      "reached, trained, supported, served, targeted, received, or counted as",
      "beneficiaries. A group merely mentioned in the document is not enough.",
      "Documents usually say this outright, so look for it: a 'direct project",
      "beneficiaries' indicator in the results framework, a beneficiary table",
      "or count (often disaggregated by sex or youth), a 'the project",
      "targets/serves/reaches X' sentence, or the target group named in the",
      "objectives. Quote the clearest of those.",
      "If no passage shows who benefited, leave this EMPTY rather than assume.")),
    target_beneficiary_page = type_integer("Page of that quote."),
    GESI_project = type_string("Summary of gender-equality and social-inclusion content as presented (management, design, results, disaggregation, indigenous communities, local knowledge). If the document says nothing about gender or social inclusion, write exactly: The document does not address gender equality or social inclusion. Never leave this empty."),
    GESI_project_quote = type_string("Short exact quote from the document's own gender or social-inclusion text, so the summary above can be checked against a page. Empty when the document says nothing on the subject."),
    GESI_project_page = pg1("the gender or social-inclusion passage quoted above"),
    source_pages = pg())),

results = list(
  task = paste(
    "Extract ALL quantitative project-level ACTUAL results, exhaustively.",
    "Check the results table first; the family note says where it is and what",
    "its columns are called.",
    "SHORTFALLS AND NON-DELIVERY COUNT AS RESULTS AND ARE OFTEN MISSED.",
    "Include every indicator that fell short, delivered nothing, or was",
    "dropped, with its actual figure - including zero. An output reported as",
    "'0 of 2 collection centres built', '10 of 17 warehouses (59%)' or",
    "'0.00' against a target is a FINDING, not an empty cell: give the actual",
    "(0, 10) and set status 'not achieved' or 'partially achieved'. Read the",
    "effectiveness/achievement narrative as well as the annex - completion",
    "rates per output are usually stated there and not in the table.",
    "Report metric and unit AS THE DOCUMENT WORDS THEM — do",
    "not translate into any external category.",
    "A RESULT IS A QUANTITY OF SOMETHING THE PROJECT CHANGED OR DELIVERED:",
    "people (beneficiaries reached, farmers/women/youth trained, households",
    "served, jobs created), land and water (hectares restored, irrigated,",
    "under improved management), production and yields (tons, kg/ha, crop",
    "yield increase, income increase), infrastructure and assets (km of",
    "roads, wells, markets, storage built), animals, organizations/groups",
    "formed or strengthened, emissions avoided (tCO2e), policies or plans",
    "adopted, and adoption/achievement percentages OF SUCH QUANTITIES.",
    "NOT results, never extract as results: durations and time periods",
    "(months, years of implementation, extensions), calendar dates,",
    "counts of reports/meetings/missions/recommendations/contracts,",
    "staffing or administrative numbers, disbursement rates or amounts,",
    "targets without actuals, the evaluation's own methodology numbers,",
    "survey-questionnaire rows, PREDECESSOR/historical program figures,",
    "or other projects' results.",
    "NOT A RESULT EITHER: an evaluation RATING or score ('4 out of 5',",
    "'moderately satisfactory') is a judgement about the project, not",
    "something it delivered. And a COUNT OF PLACES that only says where",
    "the project worked - '20 pilot villages', '3 countries covered',",
    "'sites targeted' - is coverage, not a result: a result is what the",
    "implementation PRODUCED. A place count counts only when the document",
    "reports something achieved there (villages where tenure was",
    "clarified, communities that adopted a practice).",
    "ALWAYS INCLUDE THE PROJECT'S TOTAL NUMBER OF DIRECT BENEFICIARIES (people;",
    "or households or farmers when people are not counted) WHEREVER IT SITS:",
    "an objective-level row, an intermediate row, a beneficiaries table, a",
    "'key outputs' box or the narrative. It anchors the results of almost",
    "every document. Give the whole-project total; country shares, components",
    "and gender or age sub-groups are separate entries with project_total 'no'.",
    "Percentages of a target achieved ('% realized', 'progress towards target')",
    "are never results. Economic-analysis figures (net present value, rate of",
    "return, carbon over 20 years, cost per beneficiary) and context statistics",
    "(national population, potential area, national herd) are never results.",
    "When a table cell holds an index or a percentage and the narrative cell",
    "beside it gives the real count ('409,089 people and 1,352,522 livestock'),",
    "report the real count. When the executive summary and the table disagree",
    "on a figure, report the table's figure and put the other in result_notes.",
    "In a mid-term review report the latest progress values and write",
    "'mid-term value' in scope."),
  type = type_object(
    results = type_array(description = "One entry per distinct quantitative actual result.",
      items = type_object(
        value  = type_string("The NUMBER as digits, nothing else, KEEPING THE DECIMALS THE DOCUMENT GIVES: 14325, not '14,325'; 4700000, not '4.7 million'; 47, not '47 percent'; 3.6 stays 3.6 and 12.5 stays 12.5 (never round or truncate); 15, not '15.00'. No thousands separators, no qualifiers ('over', 'approximately'), no units, no ranges, no sentences - put those in metric_stated or scope. 'N' or 'Y' for a yes/no indicator."),
        metric_stated = type_string("What is counted, in the document's own words (the indicator name or phrase, verbatim) — e.g. wording like 'direct project beneficiaries', 'land area under sustainable management', 'women trained'."),
        unit_stated   = type_string("Counting unit in the document's own words (e.g. 'farmers', 'ha', 'households'). For a percentage write the symbol %, not the word. Empty if none stated."),
        indicator_level = type_enum(values = c("outcome", "output", "narrative"),
          description = "outcome = an indicator at the level of the project's objective (PDO indicators, outcome indicators, core indicators, fund-level indicators); output = a component, output or intermediate indicator; narrative = a figure in running text only. The family note names these levels as this document calls them."),
        status = type_enum(values = c("achieved", "partially achieved", "not achieved", "no target stated"),
          description = "Achievement vs target, as the document rates it."),
        value_type = type_enum(values = c("achieved", "target", "baseline", "planned", "estimate", "context"),
          description = "achieved = an actual value at the latest date reported (the only kind that is a result); target = an end or revised target; baseline = the starting value; planned = a design or appraisal figure; estimate = an economic-analysis or projection figure; context = a statistic about the country or area, not the project."),
        category = type_enum(values = c("reach_people", "physical_quantity", "effect_rate", "institutional", "other"),
          description = "reach_people = a count of people, households, farmers, jobs or trainees; physical_quantity = a quantity of land, water, production, animals, length or structures (ha, tonnes, m3, km, heads, units built); effect_rate = a percentage, rate, yield, income or other measure of change; institutional = plans, policies, agreements, committees, systems, events, products; other = anything else."),
        project_total = type_enum(values = c("yes", "no", "unknown"),
          description = "yes = the figure is the whole-project total; no = a country share, a component, a site or a gender or age sub-group; unknown = the document does not say."),
        in_summary = type_enum(values = c("yes", "no"),
          description = "yes = the figure is also quoted in the executive summary, the achievement or efficacy narrative or the justification of the outcome rating; no = it appears only in a table or annex."),
        scope  = type_string("Denominator/coverage: which component, geography, whole program or one country, unique or aggregated counts; 'mid-term value' in a mid-term review. One short phrase."),
        page   = type_integer("Page where the actual value is stated.")
      )),
    result_notes = type_string("Caveats changing how the numbers read (double counting, data quality, contradictions) plus notable failed indicators, briefly. Empty if none."),
    source_pages = pg())),

finance = list(
  task = paste(
    "Extract the project financing verbatim. Read the TITLE PAGE wording and",
    "the financing table in the identification block first; the family note",
    "says where it is and in which currency."),
  type = type_object(
    budget_total = type_string("Total PLANNED budget: the financing-plan or identification-block TOTAL across ALL sources (lead fund grant/credit + co-financing + government counterpart + beneficiary in-kind). Typical table rows: the lead fund's grant or credit, 'Government', 'Co-financing', 'TOTAL'. NEVER the amount spent/executed - that is disbursed, a different field. Digits only, EXPANDED to full units: 'UA 1.71 million' -> 1710000. Write the number as PLAIN DIGITS: 33000000, never '33,000,000', never '33 million', never scientific notation such as 3.3e+07."),
    budget_lead_share = type_string("The lead funder's / main envelope alone (the lead funder the family note names), digits only, expanded to full units, plain digits (30000000, never 3e+07 or '30 million'). Empty if same as budget_total."),
    disbursed    = type_string("Total actually SPENT/disbursed: look for 'actual disbursed', 'actual at closing', 'total spent', 'expenditure', execution tables, French 'decaisse'. Sum ALL sources actually spent when several are stated. Not commitments, not the plan. The identification block wins on contradictions (flag them in finance_notes). Digits only, expanded to full units (1.39 million -> 1390000), plain digits, never scientific notation."),
    # The three figures above are EXPANDED to full units, so the number written
    # ("1710000") appears nowhere in the document ("UA 1.71 million") and the
    # fact-check cannot match it. These carry the document's own wording so the
    # value stays checkable by machine and by a human reading the page.
    budget_total_stated      = type_string("The total budget EXACTLY as the document prints it, wording and separators unchanged: 'UA 1.71 million', 'US$ 33,000,000', '33 millions de dollars'. This is the string a reader would find on the page; budget_total is the same figure expanded to digits. Empty if budget_total is empty."),
    budget_lead_share_stated = type_string("The lead funder's envelope EXACTLY as printed, wording and separators unchanged. Empty if budget_lead_share is empty."),
    disbursed_stated         = type_string("The amount spent/disbursed EXACTLY as printed, wording and separators unchanged. Empty if disbursed is empty."),
    budget_total_page        = pg1("the total budget figure"),
    budget_lead_share_page   = pg1("the lead funder's envelope"),
    disbursed_page           = pg1("the disbursed figure"),
    currency_page            = pg1("the currency as printed"),
    instrument_page          = pg1("the financing instrument wording"),
    currency     = type_string("ISO currency code, e.g. 'USD', 'EUR', 'UA'."),
    instrument_stated = type_string("EXACT wording of the financing instrument(s) from the title page or financing table, verbatim (the family note says where it is printed)."),
    funding_mechanism_portion = type_string("INSTRUMENT-TYPE mix (grant/loan/investment/other — never fund or account names) WITH PERCENTAGES in parentheses joined by ' + ', per the template format: 'grant (40%) + loan (40%) + other-in-kind contribution (20%)'. Compute percentages from stated amounts when the document gives amounts but no percentages. Empty if the split cannot be established."),
    funder_names      = type_array(items = type_string(), description = "NAMES of all funding ORGANISATIONS incl. named trust funds and co-financiers, as the document names them. Never account/grant numbers like 'TF-17015' or 'IDA-52030', and never financing-table row labels or generic categories in any language ('Borrower/Recipient', 'Local Beneficiaries', 'Bilateral Agencies', 'GOUVERNEMENT/BENEFICIAIRE', 'CONTREPARTIE') - only actual named organisations (a named government like 'Government of Benin' counts). A NATIONAL body (ministry, department, directorate, agency, authority, government, national institute or fund) is written WITH ITS COUNTRY after a comma, the way the registry writes it: 'Ministry of Agriculture and Food Security, Malawi', 'Environment Protection Agency, Sierra Leone', 'Government of Mozambique'. Take the country the project is implemented in; never leave a national body without its country, and never invent one for an international organisation."),
    implementor_names = type_array(items = type_string(), description = "NAMES of the implementing agencies: those designated in the identification block PLUS any co-implementing national agencies named in the document body (multi-country projects often have one agency per country while the block names only one). Not private partners, borrowers or buyers. Include delivery partners named only in running text, not just those in a table: 'their partner, UCASN, delivered' names an implementor. When the publisher delivers the work itself, name the publisher here too. A NATIONAL body (ministry, department, directorate, agency, authority, government, national institute or fund) is written WITH ITS COUNTRY after a comma, the way the registry writes it: 'Ministry of Agriculture and Food Security, Malawi', 'Environment Protection Agency, Sierra Leone', 'Government of Mozambique'. Take the country the project is implemented in; never leave a national body without its country, and never invent one for an international organisation."),
    finance_notes = type_string("Contradictions between financing tables, counterpart funding that never materialized, or similar. Empty if none."),
    source_pages = pg()))
)

# ---------------------------------------------------- result ranking (code) --
# A headcount tells you how big a project was; an outcome tells you whether it
# worked. The synthesis exists to answer the second, so reach must not outrank
# the project's own objective indicator. The old +10 for "beneficiar" did
# exactly that: on holdout H002 it recorded 313,981 beneficiaries and dropped
# the project's two PDO indicators, coffee productivity (1.20) and quality
# share (65.93%), which are what the project was for.
is_reach <- function(r) grepl(
  paste0("beneficiar|people reached|persons reached|farmers reached|",
         "households reached|reached with|participants"),
  tolower(paste(r$metric_stated, r$unit_stated)))

# Two slots must not describe one indicator. H009 spent all three on 438,291
# total / 214,763 male / 223,528 female; P010 on the programme total plus
# Malawi's share of it. That is one result with a breakdown, not three results.
metric_key <- function(r) {
  k <- tolower(paste(r$metric_stated, collapse = " "))
  k <- gsub("[(][^)]*[)]", " ", k)
  k <- gsub(paste0("- *(of which|male|female|men|women|total|regional|national|",
                   "overall|cumulative|disaggregated).*$"), " ", k)
  k <- gsub("[^a-z ]", " ", k)
  k <- trimws(gsub(" +", " ", k))
  substr(k, 1, 42)
}

rank_results <- function(rl) {
  if (!length(rl)) return(rl)
  score <- vapply(rl, function(r) {
    s <- 0
    if (identical(r$indicator_level, "outcome")) s <- s + 100
    if (identical(r$indicator_level, "output")) s <- s + 50
    if (is_reach(r)) s <- s - 5
    s
  }, numeric(1))
  rl[order(-score, seq_along(rl))]
}

# Fill the three slots: best first, never the same indicator twice, and at
# least one outcome that is not a headcount whenever the document offers one.
choose_three <- function(top) {
  pick <- list(); seen <- character(0); spare <- list()
  for (r in top) {
    k <- metric_key(r)
    if (nzchar(k) && k %in% seen) { spare[[length(spare) + 1L]] <- r; next }
    pick[[length(pick) + 1L]] <- r; seen <- c(seen, k)
    if (length(pick) == 3L) break
  }
  if (length(pick) && all(vapply(pick, is_reach, logical(1)))) {
    alt <- Filter(function(r) !is_reach(r), c(top, spare))
    if (length(alt)) pick[[length(pick)]] <- alt[[1]]
  }
  while (length(pick) < 3L && length(spare)) {
    pick[[length(pick) + 1L]] <- spare[[1]]; spare <- spare[-1]
  }
  pick
}

fold_results <- function(res, row, pages_txt = NULL) {
  rl <- res$results
  if (is.null(rl)) rl <- list()
  if (is.data.frame(rl)) rl <- lapply(seq_len(nrow(rl)), function(i) as.list(rl[i, ]))
  # what is not a result (money, durations, dates, admin counts, ratings, place
  # counts, AfDB dot-thousands misreads) is decided in R/00_shared/results_rank.R
  # so that refold_results.R applies exactly the same gate to a finished run
  fm <- row$family_module; fm <- if (is.null(fm) || !length(fm) || is.na(fm[1])) "" else as.character(fm[1])
  rl <- results_gate(rl, fm, pages_txt)
  # headline rule (survey of 50 documents, 28 Sep 2026; R/00_shared/results_rank.R):
  # eligibility, then reach, main physical achievement, main measured effect,
  # then fill from the framework. A small achieved value of a failed indicator
  # is still the achieved value (18 ha of a 4,000 ha target); zeros stay out.
  failed   <- Filter(function(r) identical(r$status, "not achieved"), rl)
  chosen <- choose_headline(rl)
  top    <- chosen$top
  ranked <- c(top, chosen$rest)
  for (i in 1:3) {
    r <- if (length(top) >= i) top[[i]] else NULL
    row[[paste0("result", i)]] <- if (is.null(r)) "" else as.character(r$value)
    row[[paste0("result", i, "_metric_stated")]] <- if (is.null(r)) "" else as.character(r$metric_stated)
    row[[paste0("result", i, "_unit_stated")]]   <- if (is.null(r)) "" else as.character(r$unit_stated)
    row[[paste0("result", i, "_scope")]] <- if (is.null(r)) "" else as.character(r$scope)
    row[[paste0("result", i, "_page")]]  <- if (is.null(r)) "" else as.character(r$page)
  }
  # everything the three slots could not hold - including an indicator dropped
  # because another slot already describes it - still belongs in the notes
  rest <- Filter(function(r) !any(vapply(top, identical, logical(1), r)), ranked)
  extra <- if (length(rest))
    paste0("further results: ", paste(vapply(rest, function(r)
      paste0(r$value, " ", r$metric_stated, " (", r$scope, ", p", r$page, ")"),
      character(1)), collapse = "; ")) else ""
  fails <- if (length(failed))
    paste0("NOT achieved: ", paste(vapply(failed, function(r)
      paste0(r$metric_stated, " (", r$value, ", p", r$page, ")"), character(1)),
      collapse = "; ")) else ""
  notes <- if (is.null(res$result_notes)) "" else as.character(res$result_notes)
  row$result_notes <- paste(Filter(nzchar, c(notes, fails, extra)), collapse = " | ")
  row$results_all_n <- as.character(length(rl))
  # evidence_depth derived deterministically (protocol: 2 = results evidence)
  row$evidence_depth <- if (length(rl)) "2" else "1"
  # derived in code, so there is no page: say so rather than leave the QC
  # hover empty
  row$evidence_depth_provenance <- if (length(rl))
    paste0("derived in code: ", length(rl), " result(s) found in the document, so depth 2")
    else "derived in code: no results found in the document, so depth 1"
  row
}

# ------------------------------------------------ verbatim fact-check (code) --
norm_txt <- function(x) {
  x <- tolower(x)
  x <- gsub("[\u2018\u2019\u201c\u201d]", "'", x)
  x <- gsub("[\u2013\u2014]", "-", x)
  x <- gsub("[^a-z0-9]+", " ", x)
  trimws(x)
}
norm_num <- function(x) gsub("[^0-9]", "", x)

check_quote <- function(quote, pages_cited, pages_txt) {
  if (is.null(quote) || !length(quote) || is.na(quote[1])) return("skipped")
  q <- norm_txt(quote[1])
  if (!nzchar(q) || nchar(q) < 8) return("skipped")
  cited <- unique(unlist(lapply(pages_cited, function(p)
    max(1, p - 1):min(length(pages_txt), p + 1))))
  cited <- cited[cited >= 1 & cited <= length(pages_txt)]
  hay_cited <- norm_txt(paste(pages_txt[cited], collapse = " "))
  if (grepl(q, hay_cited, fixed = TRUE)) return("verified")
  if (grepl(q, norm_txt(paste(pages_txt, collapse = " ")), fixed = TRUE))
    return("found_other_page")
  # table cells are not contiguous in extracted text: if ~all tokens of the
  # quote sit on the cited page(s), it is a table reconstruction, not invented
  tok <- strsplit(q, " ")[[1]]; tok <- tok[nchar(tok) > 2]
  if (length(tok) >= 2 &&
      mean(vapply(tok, function(t) grepl(t, hay_cited, fixed = TRUE), logical(1))) >= 0.9)
    return("verified_tokens (table)")
  "NOT FOUND"
}
check_value <- function(value, pages_cited, pages_txt) {
  if (is.null(value) || !length(value) || is.na(value[1])) return("skipped")
  v <- norm_num(value[1])
  if (!nzchar(v) || nchar(v) < 2) return("skipped")
  cited <- unique(unlist(lapply(pages_cited, function(p)
    max(1, p - 1):min(length(pages_txt), p + 1))))
  hay <- norm_num(paste(pages_txt[cited], collapse = " "))
  if (grepl(v, hay, fixed = TRUE)) return("verified")
  if (grepl(v, norm_num(paste(pages_txt, collapse = " ")), fixed = TRUE))
    return("found_other_page")
  "NOT FOUND"
}

check_name <- function(name, pages_txt) {   # actor names: anywhere in the doc
  if (is.null(name) || !length(name) || is.na(name[1])) return("skipped")
  name <- name[1]
  n <- norm_txt(name)
  if (!nzchar(n) || nchar(n) < 3) return("skipped")
  hay <- norm_txt(paste(pages_txt, collapse = " "))
  if (grepl(n, hay, fixed = TRUE)) return("verified")
  acr <- regmatches(name, regexpr("\\(([^)]+)\\)", name))   # '(TLF)' style
  if (length(acr) && grepl(norm_txt(gsub("[()]", "", acr)), hay, fixed = TRUE))
    return("verified")
  "NOT FOUND"
}

# Returns BOTH the long audit frame (document/item/status, written to
# verify_*.csv as before) and a named list of <field>_check values folded onto
# the extraction row. The row is what the QC workbooks read, so a verdict has
# to travel with its value instead of sitting in a second file joined on a
# free-text label.
verify_doc <- function(row, raw, pages_txt, doc) {
  as_pages <- function(x) { p <- suppressWarnings(as.integer(unlist(x))); p[!is.na(p)] }
  v <- list()
  chk <- list()
  # `field` names the row column this verdict belongs to; NULL means the item
  # is one of many for a field (an array name) and is folded in below.
  add <- function(item, status, field = NULL) {
    v[[length(v) + 1]] <<- data.frame(
      document = doc, item = item, status = status, stringsAsFactors = FALSE)
    if (!is.null(field)) chk[[paste0(field, "_check")]] <<- status
  }
  # one verdict for a whole array: the worst wins, plus how many names failed
  fold_arr <- function(field, statuses) {
    statuses <- statuses[nzchar(statuses) & statuses != "skipped"]
    chk[[paste0(field, "_check")]] <<-
      if (!length(statuses)) "skipped"
      else if (any(statuses == "NOT FOUND")) "NOT FOUND"
      else if (any(statuses == "found_other_page")) "found_other_page"
      else "verified"
    chk[[paste0(field, "_check_failed")]] <<- sum(statuses == "NOT FOUND")
  }
  add("project_lead_name", check_name(raw$identity$project_lead_name, pages_txt),
      "project_lead_name")
  fst <- character(0)
  for (nm in unlist(raw$finance$funder_names)) {
    s <- check_name(nm, pages_txt); fst <- c(fst, s)
    add(paste0("funder: ", substr(nm, 1, 40)), s)
  }
  fold_arr("funder_names", fst)
  ist <- character(0)
  for (nm in unlist(raw$finance$implementor_names)) {
    s <- check_name(nm, pages_txt); ist <- c(ist, s)
    add(paste0("implementor: ", substr(nm, 1, 40)), s)
  }
  fold_arr("implementor_names", ist)
  idp <- as_pages(raw$identity$source_pages)
  pg_or <- function(x, fallback) { p <- as_pages(x); if (length(p) && p[1] > 0) p else fallback }
  add("project_id",  check_value(raw$identity$project_id,
      pg_or(raw$identity$project_id_page, idp), pages_txt), "project_id")
  add("resource_id", check_quote(raw$identity$resource_id,
      pg_or(raw$identity$resource_id_page, idp), pages_txt), "resource_id")
  add("start_year_quote",   check_quote(raw$identity$start_year_quote,
      pg_or(raw$identity$start_year_page, idp), pages_txt), "start_year")
  add("closure_year_quote", check_quote(raw$identity$closure_year_quote,
      pg_or(raw$identity$closure_year_page, idp), pages_txt), "closure_year")
  add("document_type_stated",  check_quote(raw$identity$document_type_stated,
      pg_or(raw$identity$document_type_page, idp), pages_txt), "document_type_stated")
  add("project_title", check_quote(raw$identity$project_title,
      pg_or(raw$identity$project_title_page, idp), pages_txt), "project_title")
  add("scope_stated", check_quote(raw$geography$scope_stated,
      pg_or(raw$geography$scope_page, as_pages(raw$geography$source_pages)), pages_txt),
      "scope_stated")
  tbp <- as_pages(raw$rationale$target_beneficiary_page)
  if (!length(tbp)) tbp <- as_pages(raw$rationale$source_pages)
  add("target_beneficiary_stated",
      check_quote(raw$rationale$target_beneficiary_stated, tbp, pages_txt),
      "target_beneficiary_stated")
  # GESI is a summary, not a quote, so the quote beside it is what gets checked
  gq <- as.character(raw$rationale$GESI_project_quote %||% "")
  if (nzchar(gq))
    add("GESI_project_quote", check_quote(gq,
        pg_or(raw$rationale$GESI_project_page, as_pages(raw$rationale$source_pages)),
        pages_txt), "GESI_project")
  # the rationale must be the document's own words, so it is checked like any
  # other quote; each ' ... '-joined part is checked separately
  rp <- as_pages(raw$rationale$rationale_project_page)
  if (!length(rp)) rp <- as_pages(raw$rationale$source_pages)
  rq <- as.character(raw$rationale$rationale_project %||% "")
  if (nzchar(rq)) {
    parts <- trimws(strsplit(rq, "\\s*\\.{3}\\s*")[[1]])
    parts <- parts[nchar(parts) >= 12]
    if (!length(parts)) parts <- rq
    st <- vapply(parts, check_quote, character(1), rp, pages_txt, USE.NAMES = FALSE)
    add("rationale_project",
        if (all(st %in% c("verified", "verified_tokens (table)"))) "verified"
        else if (any(st == "NOT FOUND")) "NOT FOUND"
        else st[1], "rationale_project")
  }
  fnp <- as_pages(raw$finance$source_pages)
  # The money fields are expanded to full units, so the digits on the row are
  # not the string on the page. Check the document's own wording instead, and
  # fall back to the digits when no wording came back.
  money <- function(field, stated_field, page_field) {
    stated <- as.character(raw$finance[[stated_field]] %||% "")
    pgs <- pg_or(raw$finance[[page_field]], fnp)
    st <- if (nzchar(stated)) check_quote(stated, pgs, pages_txt)
          else check_value(raw$finance[[field]], pgs, pages_txt)
    add(field, st, field)
  }
  money("budget_total",      "budget_total_stated",      "budget_total_page")
  money("budget_lead_share", "budget_lead_share_stated", "budget_lead_share_page")
  money("disbursed",         "disbursed_stated",         "disbursed_page")
  add("currency", check_quote(raw$finance$currency,
      pg_or(raw$finance$currency_page, fnp), pages_txt), "currency")
  add("instrument_stated", check_quote(raw$finance$instrument_stated,
      pg_or(raw$finance$instrument_page, fnp), pages_txt), "instrument_stated")
  rl <- raw$results$results
  if (is.data.frame(rl)) rl <- lapply(seq_len(nrow(rl)), function(i) as.list(rl[i, ]))
  for (i in seq_along(rl)) {
    r <- rl[[i]]
    add(paste0("result_", i, ": ", substr(r$metric_stated, 1, 40)),
        check_value(r$value, as_pages(r$page), pages_txt))
  }
  # Results are checked again against the THREE FOLDED SLOTS. The loop above
  # walks the document's own order, while choose_headline() decides which three
  # reach the row, so result_2 in the audit frame is not result2 on the row.
  for (i in 1:3) {
    val <- row[[paste0("result", i)]]
    if (is.null(val) || !nzchar(as.character(val)[1])) next
    chk[[paste0("result", i, "_check")]] <-
      check_value(val, as_pages(row[[paste0("result", i, "_page")]]), pages_txt)
  }
  list(long = do.call(rbind, v), checks = chk)
}

# -------------------------------------------------------------- extraction --
extract_doc <- function(pdf_path, focus = "", pcode = "", family = "", groups = GROUPS) {
  doc_name <- tools::file_path_sans_ext(basename(pdf_path))
  cat("\n==", if (nzchar(pcode)) paste0(pcode, " · "), doc_name, "==\n")
  doc <- read_doc(pdf_path)
  module <- module_for(doc$pages, family)
  sel <- select_pages(doc$pages, module, focus)
  doc$text <- build_doc_text(doc$pages, sel)
  cat("  pages:", doc$n_pages, "| family:", module$family, "->", module$id,
      "| pages used:", sum(sel),
      "| chars:", nchar(doc$text),
      if (nzchar(focus)) paste0("| focus: ", focus), "\n")

  row <- list(project_code_hint = pcode, document = basename(pdf_path),
              family = module$family, family_module = module$id,
              model = MODEL, prompt_version = PROMPT_VERSION,
              run_date = format(Sys.Date()))
  # the family's own rules ride on the shared system prompt, and each group's
  # task gets the family note saying where its fields sit in this template
  sys_fam <- paste(SYSTEM, "DOCUMENT FAMILY:", paste0(module$label, "."), module$traps)
  fam_note <- function(g) {
    nt <- module$notes[[g]]
    if (is.null(nt) || !nzchar(nt)) "" else
      paste0("\n\nTHIS DOCUMENT FAMILY (", module$label, "): ", nt)
  }
  focus_line <- if (nzchar(focus)) paste0(
    "IMPORTANT — this document covers SEVERAL programs/projects. Extract ",
    "ONLY for ", focus, ". Ignore every other program's rows, results and ",
    "financing. ") else ""
  raw <- list()
  for (gname in names(groups)) {
    g <- groups[[gname]]
    prompt <- paste0("DOCUMENT (page-tagged):\n\n", doc$text,
                     "\n\n---\nTASK: ", focus_line, g$task, fam_note(gname))
    t0 <- Sys.time()
    res <- tryCatch({
      chat <- chat_openai(model = MODEL, system_prompt = sys_fam)
      imgs <- list()
      if (gname == "results") {
        rfp <- rf_pages(doc$pages, module)
        # Read the indicator tables AS TABLES first and hand the model rows
        # whose columns are already named. This is what stops it taking the
        # baseline for the achievement: in the flattened text a row is a bare
        # run of figures, and the count of figures changes from row to row.
        tbl <- if (is.null(module$rf$anchors)) character(0) else
          tryCatch(rf_tables(doc$local_path, rfp, anchors = module$rf$anchors),
                   error = function(e) character(0))
        if (length(tbl)) {
          cat("  rf-table   ", length(tbl), "indicator row(s) with named columns\n")
          prompt <- paste0(prompt,
            "\n\nINDICATOR TABLE, COLUMNS ALREADY RESOLVED (authoritative for these ",
            "rows - the page text flattens these tables and loses which figure is ",
            "which):\n", paste(tbl, collapse = "\n"),
            "\n\nUse the value marked ACTUAL ACHIEVED as the result. Never use a ",
            "baseline or a target as a result. An ACTUAL ACHIEVED of 0 IS a result ",
            "- report it with status 'not achieved'.")
        }
        for (p in if (isTRUE(module$rf$vision)) rfp else integer(0)) {
          png <- file.path(tempdir(), paste0("rf_", substr(digest_path(pdf_path), 1, 8),
                                             "_", p, ".png"))
          okp <- tryCatch({ pdftools::pdf_convert(doc$local_path, format = "png",
                            pages = p, filenames = png, dpi = 110, verbose = FALSE); TRUE },
                          error = function(e) FALSE)
          if (okp) imgs[[length(imgs) + 1]] <- content_image_file(png, resize = "none")
        }
        if (length(imgs)) {
          cat("  rf-vision  ", length(imgs), "table page(s) attached [page",
              rfp[1], "onward]\n")
          prompt <- paste0(prompt,
            "\n\nATTACHED IMAGES: the results-framework/table pages [page ",
            paste(rfp[seq_along(imgs)], collapse = ", "), "] rendered as ",
            "images, because table layouts scramble in the text layer. Read ",
            "the actual values from the images wherever the text is unclear.")
        }
      }
      if (length(imgs)) do.call(chat$chat_structured,
                                c(list(prompt), imgs, list(type = g$type)))
      else chat$chat_structured(prompt, type = g$type)
    }, error = function(e) e)
    secs <- round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1)
    if (inherits(res, "error")) {
      warning(gname, " failed: ", conditionMessage(res))
      cat(sprintf("  %-10s FAILED (%ss): %s\n", gname, secs,
                  substr(conditionMessage(res), 1, 80)))
      next
    }
    cat(sprintf("  %-10s ok (%ss)\n", gname, secs))
    raw[[gname]] <- res
    write_json(res, file.path(RAW_DIR, paste0("s1_", if (nzchar(pcode)) paste0(safe_name(pcode), "_") else "", substr(doc_name, 1, 55),
               "_", gname, ".json")), auto_unbox = TRUE, pretty = TRUE)   # project code first: focus projects sharing one document no longer overwrite each other; safe_name() because a corpus code carries a "source:" prefix and a colon cannot go in a Windows path
    if (gname == "results") { row <- fold_results(res, row, doc$pages); next }
    for (f in names(res)) {
      vv <- res[[f]]
      row[[if (f == "source_pages") paste0(gname, "_pages") else f]] <-
        if (length(vv) > 1) paste(unlist(vv), collapse = "; ") else
        if (length(vv) == 0) "" else as.character(vv)
    }
  }
  # derive missing years from an explicit implementation period, IN CODE —
  # deterministic, immune to the model's (correct) caution about whether a
  # period statement "counts" as an official start (v0.7, QC pattern fix)
  gv <- function(x) if (is.null(x) || !length(x) || is.na(x)) "" else as.character(x)

  # ------ tier 2: image-cover fallback (glossy reports whose cover is an
  # image: the text layer sees only running headers - detect via a near-empty
  # first page, read the cover with ONE small vision call)
  if (nchar(trimws(doc$pages[1])) < 150) {
    png <- file.path(tempdir(), paste0("cover_", substr(digest_path(pdf_path), 1, 8), ".png"))
    okc <- tryCatch({ pdftools::pdf_convert(doc$local_path, format = "png", pages = 1,
                      filenames = png, dpi = 150, verbose = FALSE); TRUE },
                    error = function(e) FALSE)
    if (okc) {
      cov <- tryCatch({
        ch <- chat_openai(model = MODEL, system_prompt = SYSTEM)
        ch$chat_structured(
          paste("This image is the COVER PAGE of a project evaluation document",
                "whose text layer is empty. Read from the image:"),
          content_image_file(png, resize = "none"),
          type = type_object(
            cover_title = type_string("The report/project title as printed on the cover, verbatim."),
            cover_year  = type_string("Publication year printed on the cover (copyright line, date). Empty if none visible."),
            cover_publisher = type_string("Publisher/lead organisation shown on the cover. Empty if none.")))
      }, error = function(e) { warning("cover vision failed: ", conditionMessage(e)); NULL })
      if (!is.null(cov)) {
        if (nzchar(gv(cov$cover_title))) {
          row$project_title_extracted <- gv(row$project_title)
          row$project_title <- trimws(gsub("\\s+", " ", gv(cov$cover_title)))
          row$title_source <- "cover_vision"
        }
        cyr <- regmatches(gv(cov$cover_year), regexpr("(19|20)[0-9]{2}", gv(cov$cover_year)))
        if (!nzchar(gv(row$publication_year)) && length(cyr))
          row$publication_year <- cyr
        if (!nzchar(gv(row$project_lead_name)) && nzchar(gv(cov$cover_publisher)))
          row$project_lead_name <- gv(cov$cover_publisher)
        cat("  cover      read by vision fallback\n")
      }
    }
  }

  # ------ tier 1: catalogue prefill (corpus documents) - catalogue wins
  if (!is.null(DOC_INDEX)) {
    ixr <- DOC_INDEX[DOC_INDEX$filename == basename(pdf_path), ]
    if (nrow(ixr) == 1 && ixr$match_method != "unmatched") {
      # A catalogue value did not come off a page, so there is no quote and no
      # page to cite. Record where it DID come from, so the QC workbook can
      # show provenance instead of an empty hover, and nothing is invented.
      prov <- paste0("from the ", ixr$source, " catalogue (match: ",
                     ixr$match_method, ")")
      stash <- function(field, val) {
        if (nzchar(val)) {
          row[[paste0(field, "_extracted")]] <<- gv(row[[field]])
          row[[field]] <<- val
          row[[paste0(field, "_provenance")]] <<- prov
        }
      }
      # The World Bank and GEF catalogues name the PROJECT; the Adaptation
      # Fund, GCF, AfDB and CIF lists name the DOCUMENT ("... - Final
      # evaluation report", and for a GCF code shared by several documents
      # possibly another document's title). Only a project name may replace
      # the extracted title (Charity pilot, 28 Sep 2026).
      if (ixr$source %in% c("worldbank", "gef")) stash("project_title", ixr$title)
      else if (nzchar(ixr$title)) row$project_title_catalogue <- ixr$title
      stash("project_id", ixr$project_id)
      stash("resource_id", ixr$report_no)
      if (!nzchar(gv(row$publication_year)) && nzchar(ixr$year) && ixr$year != "NA") {
        row$publication_year <- ixr$year
        row$publication_year_provenance <- prov
      }
      row$reference_link_1 <- ixr$url
      row$reference_link_1_provenance <- prov
      row$prefill <- ixr$match_method
      cat("  prefill    from catalogue (", ixr$match_method, ")\n")
    }
  }

  # Decision of 28 Sep 2026 (QC question 3): the start year is recorded only
  # when the document states it explicitly. The first year of an implementation
  # period is NOT a start; the cell stays empty and is flagged so QC decides.
  # The closure year may still take the last year of a period the document
  # describes as finished (the template asks for the actual closing).
  per <- gv(row$implementation_period)
  if (nzchar(per)) {
    yrs <- as.integer(unlist(regmatches(per, gregexpr("(19|20)[0-9]{2}", per))))
    yrs <- yrs[!is.na(yrs) & yrs >= 1990 & yrs <= 2035]
    if (length(yrs)) {
      if (!nzchar(gv(row$start_year)))
        row$start_year_flag <- paste0("start year not stated explicitly; implementation period only (", per, "): QC to decide")
      if (length(yrs) >= 2 && !nzchar(gv(row$closure_year))) {
        row$closure_year <- as.character(max(yrs))
        row$closure_year_quote <- paste0("derived from implementation period: ", per)
      }
    }
  }
  # a GEF core indicator worksheet carries no date of its own: the only year
  # printed is the template version in the footer (Charity pilot, 28 Sep 2026)
  if (identical(as.character(row$family %||% ""), "gef_indicator_sheet") && nzchar(gv(row$publication_year))) {
    row$publication_year_flag <- paste0("worksheet: ", gv(row$publication_year), " is the form template's version date, not the document's; left empty")
    row$publication_year <- ""
  }
  # ...and the worksheet's own name is not a project title
  if (identical(as.character(row$family %||% ""), "gef_indicator_sheet") && grepl("core indicator", tolower(gv(row$project_title)))) {
    row$project_title_flag <- paste0("worksheet: '", gv(row$project_title), "' is the form's name, not the project's; left empty")
    row$project_title <- ""
  }
  # a closing later than the report itself is a plan, not a closure
  py <- suppressWarnings(as.integer(gv(row$publication_year)))
  cy <- suppressWarnings(as.integer(gv(row$closure_year)))
  if (!is.na(py) && !is.na(cy) && cy > py) {
    row$closure_year_flag <- paste0("closing ", cy, " is later than the report (", py, "): a planned date, not the actual closing; left empty")
    row$closure_year <- ""; row$closure_year_quote <- ""
  }
  # year sanity check (template: only 2000-2025 accepted)
  for (yf in c("publication_year", "start_year", "closure_year")) {
    y <- suppressWarnings(as.integer(row[[yf]]))
    if (!is.na(y) && (y < 2000 || y > 2025))
      row[[paste0(yf, "_flag")]] <- "OUT OF 2000-2025 RANGE"
  }
  # ---- team field rules (9 Sep 2026), applied in code AFTER the catalogue
  # prefill, because catalogue titles are often shouty and carry the P-code
  row$project_title_raw <- gv(row$project_title)
  row$project_title <- clean_title(row$project_title)
  if (!identical(row$project_title, row$project_title_raw) &&
      nzchar(row$project_title_raw)) row$title_cleaned <- "yes"
  lc_raw <- gv(row$location_count)
  row$location_count <- clean_count(lc_raw)
  if (nzchar(lc_raw) && !identical(lc_raw, row$location_count))
    row$location_count_raw <- lc_raw
  row$location_notes <- clean_location_notes(gv(row$location_notes), gv(row$scope_stated))
  cflag <- check_count_vs_notes(row$location_count, row$location_notes)
  if (nzchar(cflag)) row$location_count_flag <- cflag
  row$GESI_project <- clean_gesi(gv(row$GESI_project))
  for (tf in c("rationale_project", "GESI_project", "location_notes",
               "target_beneficiary_stated", "scope_stated", "result_notes",
               "finance_notes", "project_title")) {
    if (!is.null(row[[tf]])) {
      ct <- clean_text(gv(row[[tf]]))
      row[[tf]] <- ct$value
      if (nzchar(ct$note)) row$text_artifact_flag <- ct$note
    }
  }
  for (i in 1:3) {
    vf <- paste0("result", i); uf <- paste0(vf, "_unit_stated")
    cn <- clean_number(gv(row[[vf]]))
    if (nzchar(gv(row[[vf]]))) {
      row[[vf]] <- cn$value
      row[[uf]] <- clean_unit(gv(row[[uf]]), gv(row[[vf]]))
      if (nzchar(cn$note))
        row$result_notes <- trimws(paste(gv(row$result_notes),
                                         paste0(vf, ": ", cn$note), sep = " | "))
    }
  }
  ver <- tryCatch(verify_doc(row, raw, doc$pages, basename(pdf_path)),
                  error = function(e) { warning("verify failed: ", conditionMessage(e)); NULL })
  # the verdicts ride on the row, so nothing downstream has to rejoin
  # verify_*.csv on a free-text label
  for (k in names(ver$checks)) row[[k]] <- as.character(ver$checks[[k]])
  list(row = as.data.frame(row, stringsAsFactors = FALSE, check.names = FALSE),
       verify = ver$long)
}

if (MODE == "probe") GROUPS <- GROUPS["identity"]

out <- Map(extract_doc, PDFS, FOCUS, PCODE, FAMILY)
rows <- dplyr::bind_rows(lapply(out, `[[`, "row"))
vers <- do.call(rbind, Filter(Negate(is.null), lapply(out, `[[`, "verify")))

stamp <- paste0(MODEL_TAG, "_", format(Sys.time(), "%Y%m%d_%H%M"))
row_csv <- file.path(OUT_DIR, paste0("session1_", stamp, ".csv"))
write_csv(rows, row_csv)
cat("\nwritten:", row_csv, "\n")
if (!is.null(vers)) {
  ver_csv <- file.path(OUT_DIR, paste0("verify_", stamp, ".csv"))
  write_csv(vers, ver_csv)
  cat("verification report:", ver_csv, "\n")
  cat("verification summary:\n"); print(table(vers$status))
}
