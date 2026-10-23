##############################################################################
# extract_locations.R — SESSION 1 for the LOCATION-SPECIFIC template sheet
# (project_data_location-specific; protocol §5/§7 two-session design).
#
# Extracts, verbatim, one row per location x intervention (x result) from an
# evaluation PDF, plus an enumeration of every named intervention location.
# NO controlled-vocabulary choices here: subsector type, result_level,
# target_beneficiary category, location codes and the project_lead actor code
# are assigned afterwards in R/06_harmonise/harmonize_locations.R.
#
# Carried over from extract_verbatim.R (v1.0 robustness):
#   page-tagged whole document, doc-first prompts (provider caching),
#   section maps for known big-document families, focus injection for
#   multi-project documents, results-framework pages attached as images,
#   mechanical fact-check of values/names against cited pages, junk gates.
#
# Usage:
#   Rscript R/05_extract/extract_locations.R manifest.csv   # project_code,pdf,focus
#   Rscript R/05_extract/extract_locations.R doc.pdf
#   EXTRACT_MODE=probe    -> locations group only (plumbing test)
#   EXTRACT_MODEL=...     -> model override (default gpt-5-mini)
#   EXTRACT_OUT_DIR=...   -> output folder (default outputs/extraction/locations)
# Requires OPENAI_API_KEY (~/.Renviron).
##############################################################################

suppressPackageStartupMessages({
  library(ellmer); library(pdftools); library(jsonlite); library(readr)
})

MODE  <- Sys.getenv("EXTRACT_MODE", "pilot")
MODEL <- Sys.getenv("EXTRACT_MODEL", "gpt-5-mini")
PROMPT_VERSION <- "loc-v1.5"   # v1.5 (29 Sep 2026): decimals kept, value_type and category per row, every result listed (main ones chosen in code), AfDB three-decimal numbers, where sites are listed; v1.4: ultimate + evidenced beneficiary, document's own beneficiary statement captured, verbatim rationale, one shared result gate (coverage and ratings are not results)
MODEL_TAG <- gsub("[^a-z0-9]+", "-", tolower(MODEL))
# .Renviron lives in the OneDrive-redirected Documents folder; a shell that
# overrides HOME (e.g. Git Bash) makes R miss it — load it explicitly
if (!nzchar(Sys.getenv("OPENAI_API_KEY")))
  for (p in c(file.path(Sys.getenv("OneDrive"), "Documents", ".Renviron"),
              file.path(Sys.getenv("USERPROFILE"), "Documents", ".Renviron")))
    if (file.exists(p)) { readRenviron(p); break }
stopifnot("OPENAI_API_KEY not set" = nzchar(Sys.getenv("OPENAI_API_KEY")))

args <- commandArgs(trailingOnly = TRUE)
if (length(args) == 1 && grepl("\\.csv$", args[1])) {
  mf <- read.csv(args[1], stringsAsFactors = FALSE)
  mf[is.na(mf)] <- ""
  PDFS <- mf$pdf; FOCUS <- mf$focus; PCODE <- mf$project_code
} else {
  stopifnot("give a manifest CSV or PDF path(s)" = length(args) > 0)
  PDFS <- args; FOCUS <- rep("", length(PDFS)); PCODE <- rep("", length(PDFS))
}

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- if (length(full)) normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", "..")) else getwd()
OUT_DIR <- Sys.getenv("EXTRACT_OUT_DIR", file.path(REPO, "outputs", "extraction", "locations"))
source(file.path(REPO, "R", "00_shared", "paths.R"))          # safe_name(): project codes are not filename-safe
source(file.path(REPO, "R", "00_shared", "clean_fields.R"))
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

# ---- section maps: same families as extract_verbatim.R, but location and
# component detail lives in the body/annexes, so the wb_icr map additionally
# keeps component-description and annex pages (site lists sit there).
detect_doc_family <- function(pages) {
  head_txt <- tolower(paste(pages[seq_len(min(6, length(pages)))], collapse = " "))
  if (grepl("implementation completion and results report", head_txt)) return("wb_icr")
  if (grepl("independent evaluation office of the gef|evaluation of gef", head_txt)) return("gef_ieo")
  "generic"
}

select_pages <- function(pages, family, focus = "") {
  n <- length(pages)
  if (family == "generic" || n <= 100) return(rep(TRUE, n))
  low <- tolower(pages)
  keep <- rep(FALSE, n)
  keep[seq_len(min(12, n))] <- TRUE
  mark <- function(re, span = 0) {
    for (h in grep(re, low)) keep[h:min(n, h + span)] <<- TRUE
  }
  if (family == "wb_icr") {
    mark("data sheet")
    mark("context and development objectives|project context", 8)
    mark("\\boutcome\\b", 2)
    mark("results framework and key outputs", 28)
    mark("components?[:]|description of components|annex", 6)
  } else if (family == "gef_ieo") {
    keep[seq_len(min(30, n))] <- TRUE
    mark("annex 15|global environmental benefits", 8)
    if (nzchar(focus)) {
      acro <- regmatches(focus, regexpr("\\(([A-Z]{2,6})\\)", focus))
      acro <- tolower(gsub("[()]", "", acro))
      gid  <- regmatches(focus, regexpr("[0-9]{4}", focus))
      phrase <- tolower(trimws(sub("^the\\s+", "",
                sub("[(,].*$", "", tolower(focus)))))
      pats <- Filter(nzchar, c(
        if (length(acro)) paste0("\\b", acro, "\\b"),
        if (length(gid)) gid,
        if (nchar(phrase) > 8) phrase))
      if (length(pats)) {
        hit <- Reduce(`|`, lapply(pats, function(p) grepl(p, low)))
        keep[hit] <- TRUE
      }
    }
  }
  keep
}

RF_MAX_IMG <- 10
rf_pages <- function(pages) {
  low <- tolower(pages)
  hits <- grep(paste0("results framework|key outputs|logical framework|",
                      "logframe|cadre logique|matrice de r|cadre de r"), low)
  if (!length(hits)) return(integer(0))
  ann <- grep("annex\\s*[0-9ivx]*[.:]?\\s*(results framework|logical framework)", low)
  start <- if (length(ann)) ann[length(ann)] else hits[length(hits)]
  seq(start, min(length(pages), start + RF_MAX_IMG - 1))
}

build_doc_text <- function(pages, sel) {
  txt <- paste0("[page ", which(sel), "]\n", pages[sel], collapse = "\n\n")
  if (nchar(txt) > MAX_CHARS) {
    txt <- paste0(substr(txt, 1, round(MAX_CHARS * 0.7)), "\n...[clipped]...\n",
                  substr(txt, nchar(txt) - round(MAX_CHARS * 0.3) + 1, nchar(txt)))
  }
  txt
}

SYSTEM <- paste(
  "You are a meticulous VERBATIM data-extraction assistant for grey-literature",
  "project evaluation documents (African agriculture climate adaptation).",
  "Your subject is WHERE the project worked: the specific places where",
  "adaptation interventions were implemented, and what happened in each place.",
  "You extract passages and literal facts EXACTLY as the document states them.",
  "You never classify into external categories — that happens later, elsewhere.",
  "When a value or passage is not in the document, return an empty string.",
  "Report actual values, not planned/target ones. The text carries [page N]",
  "markers: always report the page number for everything you extract.",
  "HARD RULES: (1) Numbers describing the evaluation's own methodology",
  "(sample sizes, respondents, focus groups) are never project results —",
  "though the methodology itself belongs in evidence_methodology fields.",
  "(2) In documents covering several projects, read only this project's",
  "content. (3) Places named only as travel logistics, control/comparison",
  "sites, ministry office addresses or geographic context are NOT",
  "intervention locations.")

pg <- function() type_array(items = type_integer(),
  description = "Page numbers ([page N]) where this information was found.")

GROUPS <- list(

locations = list(
  task = paste(
    "Enumerate EVERY distinct named location in Africa where this project",
    "actually implemented adaptation interventions or reached beneficiaries.",
    "Sweep the WHOLE document: component descriptions, results sections,",
    "annex site lists, maps' captions, tables. Count each place once, at",
    "every level the document names it (a named village AND its district",
    "are two entries — each level gets its own entry). Include countries",
    "when the document works at country level. Exclude places that are",
    "only: evaluation travel stops, control/comparison sites, capital",
    "cities mentioned as ministry seats, other projects' sites, or",
    "geographic context (rivers, borders, climate zones).",
    "WHERE SITES ARE LISTED: World Bank completion reports name them in the",
    "data sheet, the component descriptions and the results annex; AfDB",
    "completion reports in the project area paragraph and the beneficiaries",
    "table; GEF, GCF and Adaptation Fund evaluations in the methodology and",
    "site chapters and in annex site lists; portal forms rarely name sites."),
  type = type_object(
    locations = type_array(description = "One entry per distinct named intervention location.",
      items = type_object(
        name = type_string("The PLACE NAME ONLY, exactly as printed in the document: 'Kiboga', not 'Kiboga district', not 'Kiboga (Uganda)', not 'Kiboga and 4 other villages'. No administrative word, no country in brackets, no parentheses, no counts, no description. For a country entry, the country name alone. If a set of places is only ever named as a group ('20 pilot villages'), do NOT put that phrase here — enumerate the individual named places, and if none are named, skip it."),
        level_stated = type_string("The administrative level in the document's own words: village, town, city, commune, district, province, region, county, sub-county, watershed, country... Empty if the document never says."),
        country = type_string("Country this location is in."),
        page = type_integer("Page where this location is (first) named as an intervention site."))),
    enumeration_notes = type_string("One sentence: what kinds of lists were found where (e.g. '14 pilot villages listed in Annex 3 p.61; 4 districts named in component descriptions'). Empty if trivial."),
    project_beneficiary_stated = type_string(paste(
      "The document's OWN statement of who the project benefits, quoted",
      "exactly. Documents usually say this outright - look for a",
      "'direct project beneficiaries' indicator in the results framework, a",
      "beneficiary table or count (often disaggregated by sex or youth), a",
      "'the project targets/serves/reaches X' sentence, or the target-group",
      "description in the objectives. Quote the clearest such passage,",
      "naming the group, not the institution delivering the work.",
      "Empty only if the document never states who benefits.")),
    project_beneficiary_page = type_integer("Page of that beneficiary statement. 0 if none."),
    source_pages = pg())),

location_rows = list(
  task = paste(
    "Extract the location-specific interventions and their results, as ROWS.",
    "One row = one intervention at one location (or one group of locations",
    "treated jointly). Work location by location through the document.",
    "RULES FOR ROWS:",
    "(a) If the document breaks an intervention's results down by location,",
    "make one row per location. If several locations are only ever treated",
    "jointly, make ONE row naming all of them.",
    "(b) A row does not need a result: an intervention described for a",
    "location with no reported outcome is still a row (leave result fields",
    "empty). But prefer rows WITH results where the document reports them.",
    "(c) COUNTRIES ARE LOCATIONS TOO: in a multi-country project or program,",
    "make one row PER COUNTRY whenever the document describes that country's",
    "activities or results — check per-country sections, annex tables listing",
    "countries, and country case studies. Do this for EVERY participating",
    "country the document covers, even briefly; finer site-level rows come",
    "in addition where the document gives them.",
    "(d) Never invent location-specificity: a project-wide total that the",
    "document does not tie to any named country or place is NOT a location",
    "row — skip it (it belongs to the project-level extraction, not here).",
    "(e) ONLY LOCATIONS IN AFRICA: rows for sites or countries outside",
    "Africa are never extracted, even when the program also works there.",
    "(f) All *_stated fields quote or closely paraphrase the document in",
    "max 50 words, in the document's language.",
    "(g) LOCATION NAMES: place name only. No country in brackets, no",
    "parentheses, no administrative word, no descriptions or counts.",
    "'Sofala Bank', not 'Sofala bank (Mozambique)'. Several places are",
    "separated by '; ', each one a clean name.",
    "(h) WHO BENEFITS: fill target_beneficiary_stated whenever the row has a",
    "result. If the passage does not name the group, use the group the",
    "document names for that component or for the project as a whole.",
    "RESULTS: a result is a quantity the project delivered or changed at that",
    "location. result_unit is FREE TEXT in this sheet, so use the document's",
    "own wording: 'people trained', 'hectares restored', 'tons produced',",
    "'km built', 'groups formed', 'tCO2e avoided', 'percent adopting',",
    "'training workshops held', 'plans adopted'. Deliverables of activity",
    "(workshops held, plans adopted, systems installed, infrastructure",
    "completed) ARE results here — classify them by impact-pathway level",
    "(process or output) rather than leaving them out. Prefer the outcome",
    "the document reports over the activity that produced it when both are",
    "given for the same location.",
    "NEVER results, do not extract these as a result value:",
    "durations and calendar dates; the evaluation's own methodology numbers",
    "(sample sizes, people interviewed, focus groups); staffing and",
    "administrative counts (missions, supervision visits, audits,",
    "recommendations); disbursements, budgets or any money amount, except a",
    "stated income or price change for beneficiaries; targets with no actual;",
    "figures from a PREDECESSOR or earlier-phase programme (check the years:",
    "a figure from before this project started belongs to another project);",
    "figures an interviewee reports about their OWN organisation's business",
    "(sector evidence, not this project's result);",
    "people compensated or resettled under safeguards (a cost of the",
    "project, not an adaptation result);",
    "an evaluation RATING or score ('4 out of 5', 'moderately satisfactory')",
    "- that is a judgement about the project, not something it delivered;",
    "a COUNT OF PLACES that only says where the project worked - '20 pilot",
    "villages', '3 countries covered', 'sites targeted'. That is coverage.",
    "A result is what the implementation PRODUCED. A place count counts only",
    "when the document reports something achieved at those places (villages",
    "where tenure was clarified, communities that adopted a practice).",
    "List EVERY quantitative result the document ties to a location, one row",
    "per result; the main ones are chosen afterwards in code, so do not",
    "select. Say for each value whether it is achieved, a target, a baseline,",
    "a plan, an estimate or a context statistic. AfDB tables print numbers",
    "with three decimals: '7,520.000' is 7,520 and '3.600' is 3.6."),
  type = type_object(
    rows = type_array(description = "One entry per location x intervention (x result).",
      items = type_object(
        locations = type_string("Location NAME(S) this row applies to, exactly as the document names them, several joined by '; '. Use the finest level the row's evidence supports."),
        subsector_stated = type_string("The agricultural domain this intervention targets, quoted or closely paraphrased from the document, max 50 words (e.g. crop production, livestock, fisheries, land management, food distribution)."),
        intervention_stated = type_string("WHAT was implemented at this location, quoted or closely paraphrased, max 50 words (e.g. training, irrigation works, seed distribution, agroforestry, insurance product)."),
        rationale_stated = type_string("The stressor or perceived benefit this intervention responds to AT THIS LOCATION (drought, flooding, food insecurity, market access...), IN THE DOCUMENT'S OWN WORDS: copy the passage exactly, word for word, max 50 words. Do not rewrite it, summarise it or compose a sentence of your own to fit this field. Empty if the document states no rationale for this location - an empty cell is better than an invented one."),
        target_beneficiary_stated = type_string(paste(
          "WHO ULTIMATELY BENEFITS at this location, in the document's own",
          "words (e.g. 'smallholder farmers', \"200 women's groups\",",
          "'fishing communities').",
          "A ministry, an agency, a programme team, staff, inspectors,",
          "rangers or researchers are the CHANNEL, not the beneficiary: when",
          "the passage names only those, look for the group the project says",
          "it is ultimately for - the objective or goal statement ('to improve",
          "the livelihoods of the rural population'), the direct-beneficiary",
          "indicator, or the target group - and give that group here, naming",
          "the institution afterwards in brackets.",
          "Only when the document never names an end group should this field",
          "hold the institution alone.",
          "EVIDENCE, NOT INFERENCE: quote a passage that actually SHOWS this",
          "group benefiting - reached, trained, supported, served, targeted,",
          "received, or counted as beneficiaries. A group merely mentioned",
          "somewhere in the document is not enough. If no passage shows who",
          "benefited here, leave this EMPTY rather than assume.")),
        target_beneficiary_page = type_integer("Page of the passage that shows this group benefiting. 0 if none."),
        result_stated = type_string("The concrete result reported for this location, quoted or closely paraphrased, max 50 words. Empty if no result is reported."),
        result_value = type_string("EXACTLY ONE number as digits, KEEPING THE DECIMALS THE DOCUMENT GIVES: 2829, not '2,829'; 4700000, not '4.7 million'; 43, not '43 percent'; 3.6 stays 3.6 and 12.5 stays 12.5 (never round or truncate). No thousands separators, no qualifiers, no units, no ranges, no lists, never several numbers separated by semicolons. If this location has several reported results, emit SEVERAL ROWS for it, one per result, repeating the location and intervention. Empty if the result is qualitative or there is none."),
        result_unit_stated = type_string("Counting unit/what-is-counted for that value, in the document's words: 'farmers trained', 'hectares', 'training workshops held'. For a percentage use the symbol %, not the word. Empty if no value."),
        value_type = type_enum(values = c("achieved", "target", "baseline", "planned", "estimate", "context"),
          description = "achieved = an actual value at the latest date reported (the only kind that is a result); target = an end or revised target; baseline = the starting value; planned = a design figure; estimate = a projection or economic-analysis figure; context = a statistic about the place, not the project."),
        category = type_enum(values = c("reach_people", "physical_quantity", "effect_rate", "institutional", "other"),
          description = "reach_people = a count of people, households, farmers, jobs or trainees; physical_quantity = land, water, production, animals, length or structures; effect_rate = a percentage, rate, yield, income or other measure of change; institutional = plans, policies, agreements, committees, systems, events; other = anything else."),
        evidence_methodology_stated = type_string("HOW the result was assessed, per the document: survey, interviews, monitoring data, field visits..., quoted or closely paraphrased, max 50 words. Empty if unstated."),
        evidence_source_stated = type_string("The evidence SOURCE named for the result: progress reports, M&E system, workshop reports, use metrics... Empty if unstated."),
        page = type_integer("Page where this row's core statement is."))),
    row_notes = type_string("Caveats affecting the rows (double counting across locations, contradictory site lists, data-quality warnings), briefly. Empty if none."),
    source_pages = pg()))
)

# ------------------------------------------------------- junk gates (code) --
word_count <- function(x) lengths(gregexpr("\\S+", x)) * nzchar(trimws(x))

# ---- location-name hygiene (v1.2) -------------------------------------------
# "Sofala bank (Mozambique)" -> "Sofala bank"; "20 pilot villages (5 each)" is
# a description, not a place, and is dropped. Composite strings defeated both
# the registry matcher and the fact-check in v1.1.
clean_one_loc <- function(x) {
  x <- trimws(gsub("\\s+", " ", x))
  x <- sub("\\s*\\([^)]*\\)\\s*$", "", x)            # trailing parenthetical
  x <- gsub("\\s*\\([^)]*\\)", " ", x)               # any other parenthetical
  x <- sub("^(the)\\s+", "", x, ignore.case = TRUE)
  x <- trimws(gsub("\\s+", " ", x))
  # a leading count means this is a description of a group, not a place name
  if (grepl("^[0-9]+\\s", x) && grepl("village|site|district|communit|school|group",
                                      x, ignore.case = TRUE)) return("")
  x
}
clean_loc_names <- function(s) {
  if (!nzchar(s)) return(s)
  parts <- vapply(trimws(strsplit(s, ";")[[1]]), clean_one_loc, character(1), USE.NAMES = FALSE)
  parts <- parts[nzchar(parts)]
  if (!length(parts)) return("")
  paste(unique(parts), collapse = "; ")
}

fold_rows <- function(res, meta) {
  rl <- res$rows
  if (is.null(rl)) rl <- list()
  if (is.data.frame(rl)) rl <- lapply(seq_len(nrow(rl)), function(i) as.list(rl[i, ]))
  g <- function(r, f) { v <- r[[f]]; if (is.null(v) || !length(v) || is.na(v[1])) "" else as.character(v[1]) }
  # A row survives on its location + intervention alone. A result that breaks
  # the typology rules is scrubbed and flagged, NOT used to drop the row —
  # dropping cost us location coverage in v1.1.
  # one shared gate (R/00_shared/clean_fields.R) so both sheets reject the same
  # things: money, durations, compensation, admin counts, ratings, and place
  # counts that say where the project worked rather than what changed
  bad_result <- function(r)
    result_reject_reason(g(r, "result_value"), g(r, "result_unit_stated"),
                         g(r, "result_stated"))
  keep <- vapply(rl, function(r)
    nzchar(g(r, "locations")) && nzchar(g(r, "intervention_stated")), logical(1))
  rl <- rl[keep]
  if (!length(rl)) return(NULL)
  df <- do.call(rbind, lapply(rl, function(r) {
    rs <- g(r, "result_stated"); rv <- g(r, "result_value")
    bad <- bad_result(r); ru <- g(r, "result_unit_stated")
    vt <- g(r, "value_type")
    if (!nzchar(bad) && nzchar(vt) && vt != "achieved") bad <- paste0("NOT AN ACHIEVED VALUE (", vt, ")")
    if (nzchar(bad)) { rs <- ""; rv <- ""; ru <- "" }
    flags <- c(bad,
      if (any(word_count(c(g(r, "subsector_stated"), g(r, "intervention_stated"),
                           g(r, "rationale_stated"), rs)) > 60)) "OVER 50 WORDS",
      if (nzchar(rv) && !grepl("[0-9]", rv)) "VALUE NOT NUMERIC",
      if ((nzchar(rs) || nzchar(rv)) && !nzchar(g(r, "target_beneficiary_stated")))
        "BENEFICIARY MISSING")
    flags <- flags[nzchar(flags)]
    data.frame(
      locations_stated  = clean_loc_names(g(r, "locations")),
      subsector_stated  = g(r, "subsector_stated"),
      intervention_stated = g(r, "intervention_stated"),
      rationale_stated  = g(r, "rationale_stated"),
      target_beneficiary_stated = g(r, "target_beneficiary_stated"),
      result_stated     = rs,
      result_value      = rv,
      result_unit_stated = ru,
      value_type = vt,
      category = g(r, "category"),
      evidence_methodology_stated = g(r, "evidence_methodology_stated"),
      evidence_source_stated = g(r, "evidence_source_stated"),
      page = g(r, "page"),
      evidence_depth = if (nzchar(rs) || nzchar(rv)) "2" else "1",
      row_flags = paste(flags, collapse = "; "),
      stringsAsFactors = FALSE)
  }))
  for (m in names(meta)) df[[m]] <- meta[[m]]
  df$row_notes <- if (is.null(res$row_notes)) "" else as.character(res$row_notes)
  df
}

fold_locations <- function(res, meta) {
  ll <- res$locations
  if (is.null(ll)) ll <- list()
  if (is.data.frame(ll)) ll <- lapply(seq_len(nrow(ll)), function(i) as.list(ll[i, ]))
  if (!length(ll)) return(NULL)
  g <- function(r, f) { v <- r[[f]]; if (is.null(v) || !length(v) || is.na(v[1])) "" else as.character(v[1]) }
  df <- do.call(rbind, lapply(ll, function(r) data.frame(
    location_name = clean_one_loc(g(r, "name")), level_stated = g(r, "level_stated"),
    country = g(r, "country"), page = g(r, "page"), stringsAsFactors = FALSE)))
  df <- df[nzchar(df$location_name), , drop = FALSE]
  df <- df[!duplicated(tolower(paste(df$location_name, df$country))), , drop = FALSE]
  for (m in names(meta)) df[[m]] <- meta[[m]]
  df$enumeration_notes <- if (is.null(res$enumeration_notes)) "" else as.character(res$enumeration_notes)
  # the document's own beneficiary statement travels with the enumeration so
  # Session 2 can fill a row from real evidence instead of from sibling rows
  df$project_beneficiary_stated <- if (is.null(res$project_beneficiary_stated)) "" else
    as.character(res$project_beneficiary_stated)
  df$project_beneficiary_page <- if (is.null(res$project_beneficiary_page)) "" else
    as.character(res$project_beneficiary_page)
  df
}

# ------------------------------------------------ verbatim fact-check (code) --
norm_txt <- function(x) {
  # \u escapes, not literal characters: the source file is read in the system
  # locale, so literal smart quotes here silently failed to match and iconv
  # then turned the apostrophe into digits ("Cote d209Ivoire")
  x <- gsub("[\u2018\u2019\u201c\u201d]", " ", x)
  x <- gsub("[\u2013\u2014]", "-", x)
  # fold accents before lowering: "Cote d'Ivoire" must match either spelling
  x <- iconv(x, "UTF-8", "ASCII//TRANSLIT", sub = " ")
  x <- tolower(x)
  x <- gsub("[^a-z0-9]+", " ", x)
  trimws(x)
}
norm_num <- function(x) gsub("[^0-9]", "", x)

check_value <- function(value, page_cited, pages_txt) {
  # a cell may still hold several numbers; check each part separately
  parts <- trimws(strsplit(as.character(value), ";")[[1]])
  parts <- parts[nzchar(parts)]
  if (length(parts) > 1) {
    st <- vapply(parts, check_value, character(1), page_cited, pages_txt,
                 USE.NAMES = FALSE)
    st <- st[st != "skipped"]
    if (!length(st)) return("skipped")
    if (all(st == "verified")) return("verified")
    if (any(st == "NOT FOUND")) return("NOT FOUND (part)")
    return("found_other_page")
  }
  v <- norm_num(value)
  if (!nzchar(v) || nchar(v) < 2) return("skipped")
  p <- suppressWarnings(as.integer(page_cited))
  cited <- if (!is.na(p)) max(1, p - 1):min(length(pages_txt), p + 1) else integer(0)
  hay <- norm_num(paste(pages_txt[cited], collapse = " "))
  if (nzchar(hay) && grepl(v, hay, fixed = TRUE)) return("verified")
  if (grepl(v, norm_num(paste(pages_txt, collapse = " ")), fixed = TRUE))
    return("found_other_page")
  "NOT FOUND"
}
check_name <- function(name, pages_txt) {
  hay <- norm_txt(paste(pages_txt, collapse = " "))
  n <- norm_txt(name)
  if (!nzchar(n) || nchar(n) < 3) return("skipped")
  if (grepl(n, hay, fixed = TRUE)) return("verified")
  # a composite string ("Sofala Bank (Mozambique)", "A and B") is verified when
  # each of its named parts is in the document; v1.1 reported these as misses
  parts <- unlist(strsplit(name, "\\(|\\)|;|,| and | et "))
  parts <- trimws(parts); parts <- parts[nchar(parts) >= 4]
  parts <- vapply(parts, norm_txt, character(1), USE.NAMES = FALSE)
  parts <- parts[nchar(parts) >= 4]
  if (length(parts) >= 1 &&
      all(vapply(parts, function(p) grepl(p, hay, fixed = TRUE), logical(1))))
    return("verified (composite)")
  "NOT FOUND"
}
# rationale_stated must be the document's own words: exact string match on the
# cited page, not the looser token coverage used for the paraphrase fields
check_quote <- function(txt, page_cited, pages_txt) {
  q <- norm_txt(txt)
  if (!nzchar(q) || nchar(q) < 12) return("skipped")
  p <- suppressWarnings(as.integer(page_cited))
  cited <- if (!is.na(p)) max(1, p - 1):min(length(pages_txt), p + 1) else integer(0)
  hay <- norm_txt(paste(pages_txt[cited], collapse = " "))
  if (nzchar(hay) && grepl(q, hay, fixed = TRUE)) return("verified")
  if (grepl(q, norm_txt(paste(pages_txt, collapse = " ")), fixed = TRUE))
    return("found_other_page")
  # a quote joined from two passages with ' ... ' is checked part by part
  parts <- trimws(strsplit(as.character(txt), "\\s*\\.{3}\\s*")[[1]])
  parts <- parts[nchar(parts) >= 12]
  if (length(parts) > 1) {
    hay_all <- norm_txt(paste(pages_txt, collapse = " "))
    if (all(vapply(parts, function(p2) grepl(norm_txt(p2), hay_all, fixed = TRUE),
                   logical(1)))) return("verified (joined quotes)")
  }
  "NOT VERBATIM"
}
# *_stated fields are quote-or-paraphrase: check token coverage on cited page
check_paraphrase <- function(txt, page_cited, pages_txt) {
  q <- norm_txt(txt)
  if (!nzchar(q) || nchar(q) < 12) return("skipped")
  p <- suppressWarnings(as.integer(page_cited))
  cited <- if (!is.na(p)) max(1, p - 1):min(length(pages_txt), p + 1) else integer(0)
  hay <- norm_txt(paste(pages_txt[cited], collapse = " "))
  tok <- strsplit(q, " ")[[1]]; tok <- tok[nchar(tok) > 3]
  if (length(tok) < 3) return("skipped")
  cov <- mean(vapply(tok, function(t) grepl(t, hay, fixed = TRUE), logical(1)))
  if (cov >= 0.85) "verified"
  else {
    hay_all <- norm_txt(paste(pages_txt, collapse = " "))
    cov_all <- mean(vapply(tok, function(t) grepl(t, hay_all, fixed = TRUE), logical(1)))
    if (cov_all >= 0.85) "found_other_page"
    else if (cov_all >= 0.55) "paraphrase (partial tokens)"
    else "NOT FOUND"
  }
}

verify_doc <- function(rows_df, locs_df, pages_txt, doc) {
  v <- list()
  add <- function(item, status) v[[length(v) + 1]] <<- data.frame(
    document = doc, item = item, status = status, stringsAsFactors = FALSE)
  if (!is.null(locs_df)) for (i in seq_len(nrow(locs_df)))
    add(paste0("location: ", substr(locs_df$location_name[i], 1, 40)),
        check_name(locs_df$location_name[i], pages_txt))
  if (!is.null(rows_df)) for (i in seq_len(nrow(rows_df))) {
    for (nm in strsplit(rows_df$locations_stated[i], ";\\s*")[[1]])
      if (tolower(nm) != "unspecified")
        add(paste0("row_", i, " loc: ", substr(nm, 1, 30)), check_name(nm, pages_txt))
    if (nzchar(rows_df$result_value[i]))
      add(paste0("row_", i, " value: ", rows_df$result_value[i]),
          check_value(rows_df$result_value[i], rows_df$page[i], pages_txt))
    add(paste0("row_", i, " intervention"),
        check_paraphrase(rows_df$intervention_stated[i], rows_df$page[i], pages_txt))
    # the rationale must be the document's own words, so it is held to the
    # stricter quote check rather than the paraphrase one
    if (nzchar(rows_df$rationale_stated[i]))
      add(paste0("row_", i, " rationale"),
          check_quote(rows_df$rationale_stated[i], rows_df$page[i], pages_txt))
  }
  do.call(rbind, v)
}

# -------------------------------------------------------------- extraction --
extract_doc <- function(pdf_path, focus = "", pcode = "", groups = GROUPS) {
  doc_name <- tools::file_path_sans_ext(basename(pdf_path))
  cat("\n==", if (nzchar(pcode)) paste0(pcode, " · "), doc_name, "==\n")
  doc <- read_doc(pdf_path)
  fam <- detect_doc_family(doc$pages)
  sel <- select_pages(doc$pages, fam, focus)
  doc$text <- build_doc_text(doc$pages, sel)
  cat("  pages:", doc$n_pages, "| family:", fam, "| pages used:", sum(sel),
      "| chars:", nchar(doc$text),
      if (nzchar(focus)) paste0("| focus: ", focus), "\n")

  meta <- list(project_code_hint = pcode, document = basename(pdf_path),
               model = MODEL, prompt_version = PROMPT_VERSION,
               run_date = format(Sys.Date()))
  focus_line <- if (nzchar(focus)) paste0(
    "IMPORTANT — this document covers SEVERAL programs/projects. Extract ",
    "ONLY for ", focus, ". Ignore every other program's sites, rows and ",
    "results, and double-check each row: a location that belongs to another ",
    "program in this document must not appear. ") else ""
  raw <- list()
  for (gname in names(groups)) {
    g <- groups[[gname]]
    prompt <- paste0("DOCUMENT (page-tagged):\n\n", doc$text,
                     "\n\n---\nTASK: ", focus_line, g$task)
    # ---- coverage injection (v1.2): the enumeration pass already found the
    # places; without this the row pass silently covered only a third of them.
    if (gname == "location_rows" && !is.null(raw$locations)) {
      enum <- raw$locations$locations
      if (is.data.frame(enum)) enum <- lapply(seq_len(nrow(enum)), function(i) as.list(enum[i, ]))
      nm <- vapply(enum, function(e) {
        v <- e$name; if (is.null(v) || !length(v) || is.na(v[1])) "" else trimws(as.character(v[1]))
      }, character(1))
      ct <- vapply(enum, function(e) {
        v <- e$country; if (is.null(v) || !length(v) || is.na(v[1])) "" else trimws(as.character(v[1]))
      }, character(1))
      keepn <- nzchar(nm) & !duplicated(tolower(paste(nm, ct)))
      if (any(keepn)) {
        lst <- paste0("- ", nm[keepn], ifelse(nzchar(ct[keepn]), paste0("  [", ct[keepn], "]"), ""))
        cat("  coverage   ", sum(keepn), "enumerated location(s) injected\n")
        prompt <- paste0(prompt,
          "\n\nLOCATIONS ALREADY IDENTIFIED IN THIS DOCUMENT (", sum(keepn), "):\n",
          paste(lst, collapse = "\n"),
          "\n\nCOVERAGE REQUIREMENT: work through this list and produce at least",
          " one row for EVERY location on it for which the document says",
          " anything about what was done or achieved there. Use exactly these",
          " place names. Only skip a location if the document names it but says",
          " nothing about activities or results there; a location you skip must",
          " be listed in row_notes with the reason. You may add rows for",
          " locations missing from the list.")
      }
    }
    t0 <- Sys.time()
    res <- tryCatch({
      chat <- chat_openai(model = MODEL, system_prompt = SYSTEM)
      imgs <- list()
      if (gname == "location_rows") {
        rfp <- rf_pages(doc$pages)
        for (p in rfp) {
          png <- file.path(tempdir(), paste0("rfl_", substr(digest_path(pdf_path), 1, 8),
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
            "location-disaggregated values from the images wherever the text ",
            "is unclear.")
        }
      }
      if (length(imgs)) do.call(chat$chat_structured,
                                c(list(prompt), imgs, list(type = g$type)))
      else chat$chat_structured(prompt, type = g$type)
    }, error = function(e) e)
    secs <- round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1)
    if (inherits(res, "error")) {
      warning(gname, " failed: ", conditionMessage(res))
      cat(sprintf("  %-14s FAILED (%ss): %s\n", gname, secs,
                  substr(conditionMessage(res), 1, 80)))
      next
    }
    cat(sprintf("  %-14s ok (%ss)\n", gname, secs))
    raw[[gname]] <- res
    write_json(res, file.path(RAW_DIR, paste0("s1loc_", if (nzchar(pcode)) paste0(safe_name(pcode), "_") else "", substr(doc_name, 1, 55),
               "_", gname, ".json")), auto_unbox = TRUE, pretty = TRUE)   # safe_name(): a corpus project code carries a "source:" prefix and a colon cannot go in a Windows path
  }
  rows_df <- if (!is.null(raw$location_rows)) fold_rows(raw$location_rows, meta) else NULL
  locs_df <- if (!is.null(raw$locations)) fold_locations(raw$locations, meta) else NULL
  cat("  rows:", if (is.null(rows_df)) 0 else nrow(rows_df),
      "| locations enumerated:", if (is.null(locs_df)) 0 else nrow(locs_df), "\n")
  ver <- tryCatch(verify_doc(rows_df, locs_df, doc$pages, basename(pdf_path)),
                  error = function(e) { warning("verify failed: ", conditionMessage(e)); NULL })
  list(rows = rows_df, locations = locs_df, verify = ver)
}

if (MODE == "probe") GROUPS <- GROUPS["locations"]

out  <- Map(extract_doc, PDFS, FOCUS, PCODE)
rows <- dplyr::bind_rows(Filter(Negate(is.null), lapply(out, `[[`, "rows")))
locs <- dplyr::bind_rows(Filter(Negate(is.null), lapply(out, `[[`, "locations")))
vers <- do.call(rbind, Filter(Negate(is.null), lapply(out, `[[`, "verify")))

stamp <- paste0(MODEL_TAG, "_", format(Sys.time(), "%Y%m%d_%H%M"))
if (nrow(rows)) {
  f <- file.path(OUT_DIR, paste0("s1loc_rows_", stamp, ".csv"))
  write_csv(rows, f); cat("\nwritten:", f, "(", nrow(rows), "rows )\n")
}
if (nrow(locs)) {
  f <- file.path(OUT_DIR, paste0("s1loc_locations_", stamp, ".csv"))
  write_csv(locs, f); cat("written:", f, "(", nrow(locs), "locations )\n")
}
if (!is.null(vers)) {
  f <- file.path(OUT_DIR, paste0("verify_loc_", stamp, ".csv"))
  write_csv(vers, f)
  cat("verification report:", f, "\nverification summary:\n")
  print(table(vers$status))
}
