##############################################################################
# screen_scope.R — decide whether a document belongs in the corpus at all,
# by READING IT, and record why against each protocol criterion.
#
# WHY THIS IS A SECOND SCRIPT, NOT AN EDIT TO screen_corpus.R.
# screen_corpus.R asks "does this document's cover agree with the folder we
# filed it in". It answers that from 3 pages, 8 documents per call, and that
# batching is exactly what makes it cheap. This script asks a different
# question — "should it be in the corpus" — and that cannot be answered from a
# cover page: on a World Bank ICR the first pages are a cover and a data
# sheet, while the climate risk the project responds to appears in the
# development objective or the context section. Reading whole documents means
# one document per call, so the two cannot share a loop. Both still have a
# job: this one is the gate, the older one stays useful as a periodic sweep
# for filing mistakes among documents already in scope.
#
# WHAT IT COSTS. Measured over 48 corpus documents: mean 55 pages, 136k
# characters. Whole corpus, whole documents, gpt-5-nano: about 21 M input
# tokens, USD 1.06. Reading only the first 3 pages would cost 6 cents. The
# difference is not worth optimising, so it reads everything.
#
# HOW IT DECIDES. The model weighs the protocol's criteria and returns ONE
# verdict and ONE sentence. When a document is out of scope that sentence must
# NAME the criteria that failed, so a reviewer can see the ground without
# opening the file. The year rule is applied afterwards in code, because it is
# still unsettled: the WP3 protocol says 2000-2025 and the workstream operates
# 2015-2025 (open question 12). Changing YEAR_MIN and YEAR_MAX below and
# re-running apply_verdict over the saved rows re-decides on dates with no
# document read again.
#
# Criteria, from WP3 protocol Tables 1-3:
#   scope       an African country is named as an implementation location
#   sector      crops, livestock, fisheries, agroforestry, food systems or
#               value chains are the PRIMARY subject, not incidental
#   intervention the project responds to an observed or anticipated CLIMATE
#               risk, and the response is adaptation rather than mitigation
#   source      the document reports IMPLEMENTED action (delivered outputs,
#               disbursement, monitoring indicators, evaluation findings),
#               not a plan, a proposal or an administrative note
#   timeframe   the document's own year falls in the accepted window
#
# Nothing is moved. Output is a review list, as screen_corpus.R is, so a
# person can correct it before anything acts on it.
#
#   Rscript R/03_screen/screen_scope.R              all sources
#   Rscript R/03_screen/screen_scope.R --source=cif --limit=20
#   -> 04_Screening/scope_screen.csv   (resumable; appends)
##############################################################################

suppressPackageStartupMessages({ library(ellmer); library(pdftools) })

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."),
                      mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
source(file.path(REPO, "R", "00_shared", "doc_families.R"))
source(file.path(REPO, "R", "03_screen", "screen_text.R"))   # extraction + deterministic pre-pass

if (!nzchar(Sys.getenv("OPENAI_API_KEY")))
  for (.p in c(file.path(Sys.getenv("OneDrive"), "Documents", ".Renviron"),
               file.path(Sys.getenv("USERPROFILE"), "Documents", ".Renviron")))
    if (file.exists(.p)) { readRenviron(.p); break }
stopifnot("OPENAI_API_KEY not set" = nzchar(Sys.getenv("OPENAI_API_KEY")))

MODEL     <- Sys.getenv("SCREEN_MODEL", "gpt-5-nano")
MAX_CHARS <- 320000        # ~80k tokens; longer documents keep head and tail
args   <- commandArgs(trailingOnly = TRUE)
opt    <- function(n, d = "") {
  h <- grep(paste0("^--", n, "="), args, value = TRUE)
  if (length(h)) sub(paste0("^--", n, "="), "", h[1]) else d
}
SRC    <- opt("source")
LIMIT  <- suppressWarnings(as.integer(opt("limit", "0")))
OUT    <- file.path(SCREEN_DIR, opt("out", "scope_screen.csv"))   # --out=working/scope_screen_parts/x.csv for shards
SHARD  <- opt("shard", "")            # --shard=2/4 : take every 4th document starting at the 2nd
REASK  <- opt("reask", "")            # --reask=04_Screening/inputs/decisions/scope_screen_reask.csv : judge these again
dir.create(dirname(OUT), recursive = TRUE, showWarnings = FALSE)

## ---- the accepted year window ---------------------------------------------
# The WP3 protocol says 2000-2025; the workstream has been operating 2015-2025
# (open question 12). Change these two numbers and re-run apply_verdict over
# the saved rows - no document needs reading again.
YEAR_MIN <- 2015
YEAR_MAX <- 2025

## ---- which folders to look in ---------------------------------------------
# Parked folders are included deliberately: a gate that only looks at what was
# already kept can find things wrongly kept but never things wrongly parked,
# and the GEF and AfDB "undated" piles are where an in-scope document hides.
SCAN <- SCAN_DIRS            # every folder a document can sit in; see 00_shared/paths.R

TYPES <- c("implementation completion report", "terminal evaluation",
  "mid-term evaluation", "impact evaluation report",
  "implementation status / progress report", "management response",
  "funding proposal / project document", "monitoring & evaluation report",
  "portfolio performance review / program evaluation",
  "policy brief / learning brief / factsheet",
  "administrative / meeting document", "other")

YN <- c("yes", "no", "unclear")

## ---- read a whole document, long-path safe --------------------------------
# Extraction (pdf / docx / legacy doc) and the deterministic pre-pass live in
# screen_text.R. The pre-pass strips the GEF portal machine footer (the
# "M/D/YYYY   Page N of M" lines that put publication_year 2026 on 12
# documents) and the AfDB PCR boilerplate label that manufactured sham
# climate_risk_quotes, BEFORE the model reads anything.
read_all <- function(path) {
  p <- path
  if (nchar(p) > 250) {
    ext <- tolower(tools::file_ext(p)); if (!nzchar(ext)) ext <- "pdf"
    short <- file.path(tempdir(), paste0("s", abs(sum(utf8ToInt(p))) %% 1e8, ".", ext))
    ok <- suppressWarnings(file.copy(paste0("\\\\?\\", gsub("/", "\\\\", p)),
                                     short, overwrite = TRUE))
    if (!ok) ok <- suppressWarnings(file.copy(p, short, overwrite = TRUE))
    if (!ok) return("")
    p <- short
  }
  txt <- pretreat_text(extract_document_text(p))
  if (nchar(txt) > MAX_CHARS)
    txt <- paste0(substr(txt, 1, round(MAX_CHARS * 0.75)), "\n...[middle omitted]...\n",
                  substr(txt, nchar(txt) - round(MAX_CHARS * 0.25) + 1, nchar(txt)))
  txt
}

SYSTEM <- paste(
  "You decide whether a grey-literature document belongs in a review of",
  "IMPLEMENTED climate change adaptation in Africa's food and agriculture",
  "sector. Weigh four criteria: SCOPE (an African country is named as a place",
  "the work was implemented), SECTOR (crops, livestock, fisheries, agroforestry,",
  "food systems or agricultural value chains are the PRIMARY subject, not",
  "incidental), INTERVENTION (the project responds to an observed or anticipated",
  "CLIMATE risk, and the response is adaptation), SOURCE TYPE (the document",
  "reports action actually carried out - delivered outputs, disbursement,",
  "monitoring indicators, evaluation findings - not a plan, proposal, concept",
  "note or administrative request).",
  "Then give ONE verdict and ONE sentence. If the verdict is out of scope, that",
  "sentence must NAME the criteria that failed and say what the document is",
  "instead. Name only the criteria that genuinely fail and prefer the smallest",
  "set that is enough to exclude it: padding the list with criteria that did",
  "not really fail makes the reason useless to a reviewer. Saying 'unsure' is",
  "a real answer and is better than a guess.",
  "Three rules the review found broken: (a) a regional or multi-country",
  "project implemented in African countries MEETS scope; being multi-country",
  "is never a reason to exclude. (b) A project spanning several agricultural",
  "sub-sectors (crops and livestock and irrigation) is STILL the agriculture",
  "sector. (c) Irrigation, value chains, productivity, food security or",
  "market access on their own are NOT adaptation: the intervention criterion",
  "is met only when the document names a climate risk the project responds",
  "to. If you cannot quote such a risk, the verdict cannot be 'in scope'.",
  "Emergency relief after a flood or drought responds to a hazard but is not",
  "adaptation. A safety net or a planning grant is not agriculture delivery.",
  "A climate risk means a hazard or stressor the project responds to: drought,",
  "flood, erratic or declining rainfall, rising temperature, heat, cyclone,",
  "sea-level rise, salinisation, desertification, water scarcity, or climate",
  "variability described as a problem. Abundant rainfall described as an asset",
  "is NOT a climate risk. Many African agriculture projects build climate",
  "resilience without ever using the word climate: judge the substance, not the",
  "vocabulary. Mitigation - reducing emissions, decarbonisation, carbon",
  "sequestration as the objective - is NOT adaptation.",
  "Quote the document exactly where you are asked to quote, so the quote can be",
  "found in the text again. Leave a quote empty rather than inventing support.",
  "DOCUMENT FAMILIES - the template the document is written in, which decides",
  "how it will be read later. Choose exactly one id from this list:",
  family_choices_text())

SPEC <- type_object(
  doc_kind_stated = type_string("The document's own designation of itself, verbatim (e.g. 'Implementation Completion and Results Report', 'Rapport d'achevement'). Empty if none visible."),
  doc_type = type_enum(values = TYPES, description = "What this document IS."),
  family = type_enum(values = FAMILY_IDS, description = paste(
    "Which document TEMPLATE this is written in, one id from the DOCUMENT FAMILIES",
    "list in the instructions. A rule-based guess from the cover is given with the",
    "document; confirm it, or correct it when the document plainly is something else.")),
  publication_year = type_string("Year this document was issued, 4 digits. Empty if not stated."),
  project_name = type_string("Project or programme name. Empty if none."),
  language = type_string("Main language: en/fr/pt/other."),
  countries = type_string("African countries where the work was implemented, semicolon separated. Empty if none named."),
  covers_several_projects = type_enum(values = YN,
    description = "Does the document report on more than one distinct project or programme?"),
  adaptation_or_mitigation = type_enum(values = c("adaptation", "mitigation", "both", "neither"),
    description = "Which the project mainly is."),
  climate_risk_quote = type_string("Verbatim quote naming the climate hazard or stressor the project responds to. Empty if the document names none."),
  adaptation_quote = type_string("Verbatim quote describing what was done in response to that risk. Empty if none."),

  verdict = type_enum(values = c("in scope", "out of scope", "unsure"),
    description = "In scope only when ALL of scope, sector, intervention and source type are met. Out of scope when any one clearly fails. Unsure when the document does not let you tell."),
  reason = type_string(paste(
    "ONE short sentence, for a reviewer who has not read the document.",
    "When the verdict is OUT OF SCOPE you MUST name the criteria that failed,",
    "using these names: scope, sector, intervention, source type. Name ONLY the",
    "ones that genuinely fail, and prefer the SMALLEST set that is enough to",
    "exclude the document. Do not list every criterion. A governance paper that",
    "names African countries has NOT failed scope, it has failed source type. A",
    "mitigation project in African agriculture has NOT failed sector, it has",
    "failed intervention. Then say in a few words what the document is instead.",
    "For example: 'Out on source type: a one-page request to launch an",
    "evaluation, not a report of implemented action.' Or: 'Out on sector and",
    "intervention: a fiscal consolidation budget support operation, with no",
    "agriculture and no climate risk.' When the verdict is in scope or unsure,",
    "one plain sentence is enough. A bare word such as 'sector' is not a",
    "reason and will be sent back.")))

chat_one <- function(txt, guess = "") {
  ch <- chat_openai(model = MODEL, system_prompt = SYSTEM)
  hint <- if (nzchar(guess)) paste0(" A rule-based check of the cover suggests the",
    " document family '", guess, "' (", family_info(guess)$label, "); keep it unless the",
    " document plainly is something else. A title that merely contains another family's",
    " abbreviation (an ICR headed '(ICRR)') does not change the family.")
    else " No rule matched the cover; choose the document family from the list."
  ch$chat_structured(paste0("DOCUMENT:\n\n", txt,
    "\n\n---\nJudge the five criteria and quote the document for each.", hint),
    type = SPEC)
}

## ---- combine the judgements into a verdict, in code -----------------------
apply_verdict <- function(r) {
  fi <- family_info(if (nzchar(r$family)) r$family else "generic")
  if (isTRUE(fi$progress) && r$verdict == "in scope") {
    r$verdict <- "unsure"
    r$reason  <- paste0("Progress document (", fi$label, "), not an evaluation; whether",
                        " progress reports count is an open protocol question. ", r$reason)
  }
  if (r$verdict == "in scope" && r$adaptation_or_mitigation %in% c("mitigation", "neither")) {
    r$verdict <- "out of scope"
    r$reason  <- paste("Out on intervention: the project is", r$adaptation_or_mitigation,
                       "by the document's own account, not adaptation.", r$reason)
  }
  if (r$verdict == "in scope" && nchar(trimws(r$climate_risk_quote)) < 12) {
    r$verdict <- "unsure"
    r$reason  <- paste("No climate risk quoted, so the intervention criterion is not evidenced.", r$reason)
  }
  y <- suppressWarnings(as.integer(r$publication_year))
  if (is.na(y)) {
    if (r$verdict == "in scope") {
      r$verdict <- "unsure"
      r$reason <- paste("No year stated, so timeframe cannot be checked.", r$reason)
    }
  } else if (y < YEAR_MIN || y > YEAR_MAX) {
    r$verdict <- "out of scope"
    r$reason <- sprintf("Out on timeframe: dated %d, outside %d-%d. %s",
                        y, YEAR_MIN, YEAR_MAX, r$reason)
  }
  r
}

## ---- collect, skipping what is already judged -----------------------------
docs <- list()
for (s in names(SCAN)) {
  if (nzchar(SRC) && s != SRC) next
  for (rel in SCAN[[s]]) {
    d <- file.path(DOCS_ROOT, rel)
    if (!dir.exists(d)) next
    # pdf, docx and legacy doc are all read; xlsx and zip stay out (zips are
    # unpacked at retrieval, xlsx are indicator workbooks). The PDF-only glob
    # left 53 files - 27 of them narrative Word TEs/MTRs - never screened.
    for (f in list.files(d, pattern = "\\.(pdf|docx|doc)$", ignore.case = TRUE))
      docs[[length(docs) + 1]] <- list(source = s, folder = rel, file = f,
                                       path = file.path(d, f))
  }
}
# one document, one record: aliases found by 02_dedup are not screened
ALIASES <- file.path(SCREEN_DIR, "inputs", "decisions", "duplicates.csv")
skip <- if (file.exists(ALIASES)) {
  a <- read.csv(ALIASES, stringsAsFactors = FALSE, colClasses = "character")
  paste(a$drop_source, a$drop_file)
} else character(0)
docs <- Filter(function(d) !(paste(d$source, d$file) %in% skip), docs)
if (length(skip)) cat("skipping", length(skip), "duplicate aliases from", basename(ALIASES), "\n")

# the rule-based family from the census (02_dedup/doc_census.R), if it has run
CENSUS <- file.path(SCREEN_DIR, "inputs", "decisions", "family_census.csv")
guess_of <- if (file.exists(CENSUS)) {
  cen <- read.csv(CENSUS, stringsAsFactors = FALSE, colClasses = "character")
  setNames(cen$family, paste(cen$source, cen$filename))
} else character(0)

# Already-judged keys come from the part file being written AND from the main
# judgement list: a --out= shard that only knew its own rows would re-pay for
# every document already in scope_screen.csv, and the newest-wins merge would
# then overwrite settled rows. (A --reask run still resets this below: a
# re-ask replaces the earlier judgement by design.)
done <- character(0)
MAIN <- file.path(SCREEN_DIR, "scope_screen.csv")
for (.f in unique(c(OUT, MAIN))) {
  if (!file.exists(.f)) next
  prev <- tryCatch(read.csv(.f, stringsAsFactors = FALSE, colClasses = "character"),
                   error = function(e) NULL)
  if (!is.null(prev) && nrow(prev)) done <- c(done, paste(prev$source, prev$filename))
}
if (nzchar(REASK) && file.exists(REASK)) {
  ra <- read.csv(REASK, stringsAsFactors = FALSE, colClasses = "character")
  want <- paste(ra$source, ra$filename)
  docs <- Filter(function(d) paste(d$source, d$file) %in% want, docs)
  done <- character(0)                 # a re-ask replaces the earlier judgement
  cat("re-ask list:", length(docs), "documents\n")
}
docs <- Filter(function(d) !(paste(d$source, d$file) %in% done), docs)
if (nzchar(SHARD)) {                   # parallel runs: disjoint slices of the same ordered list
  k <- as.integer(sub("/.*", "", SHARD)); n <- as.integer(sub(".*/", "", SHARD))
  docs <- docs[seq_along(docs) %% n == (k %% n)]
  cat("shard", SHARD, "->", length(docs), "documents
")
}
if (LIMIT > 0 && length(docs) > LIMIT) docs <- docs[seq_len(LIMIT)]
cat("to judge:", length(docs), "documents |", length(done), "already done |", MODEL, "\n")
if (!length(docs)) quit(save = "no")

dir.create(VOCAB_DIR, recursive = TRUE, showWarnings = FALSE)
FIELDS <- c("source", "folder", "filename", "verdict", "verdict_model", "reason",
            "family", "family_rule", "family_agrees",
            "doc_type", "doc_kind_stated", "publication_year", "project_name",
            "language", "countries", "covers_several_projects",
            "adaptation_or_mitigation", "climate_risk_quote",
            "adaptation_quote", "chars", "note")

for (i in seq_along(docs)) {
  d <- docs[[i]]
  txt <- read_all(d$path)
  row <- as.list(setNames(rep("", length(FIELDS)), FIELDS))
  row$source <- d$source; row$folder <- d$folder; row$filename <- d$file
  row$chars <- nchar(txt)
  if (nchar(txt) < 500) {
    row$verdict <- "unsure"
    row$note <- if (grepl("\\.doc$", d$file, ignore.case = TRUE) && nchar(txt) == 0)
      "needs conversion: legacy .doc" else "no usable text layer; needs a person or OCR"
  } else {
    guess <- unname(guess_of[paste(d$source, d$file)])
    guess <- if (length(guess) && !is.na(guess) && guess %in% FAMILY_IDS && guess != "generic") guess else ""
    row$family_rule <- guess
    res <- tryCatch(chat_one(txt, guess), error = function(e) { row$note <<- conditionMessage(e); NULL })
    if (!is.null(res) && nchar(trimws(as.character(res$reason))) < 25) {
      cat("           bare reason, asking once more\n")
      res2 <- tryCatch(chat_one(txt, guess), error = function(e) NULL)
      if (!is.null(res2) && nchar(trimws(as.character(res2$reason))) >= 25) res <- res2
    }
    if (is.null(res)) {
      # an API or parsing failure is not a judgement: write nothing, so the
      # next run picks the document up again
      cat(sprintf("  %3d/%-3d %-10s SKIPPED (will retry): %s | %s
", i, length(docs), d$source,
                  substr(d$file, 1, 40), substr(row$note, 1, 80)))
      next
    } else {
      for (k in names(res)) if (k %in% FIELDS) row[[k]] <- as.character(res[[k]])
      row$verdict_model <- as.character(res$verdict)   # before any rule touches it
      row$family_agrees <- if (nzchar(guess)) as.character(identical(row$family, guess)) else "no rule"
      row <- apply_verdict(row)
      if (!nzchar(row$reason)) row$reason <- res$reason
    }
  }
  line <- as.data.frame(row[FIELDS], stringsAsFactors = FALSE)
  write.table(line, OUT, sep = ",", row.names = FALSE, na = "",
              col.names = !file.exists(OUT), append = file.exists(OUT), qmethod = "double")
  cat(sprintf("  %3d/%-3d %-10s %-12s %-22s %s\n", i, length(docs), d$source,
              row$verdict, row$family, substr(d$file, 1, 46)))
}
cat("\nwritten:", OUT, "\n")
