##############################################################################
# harmonize.R — SESSION 2 of the two-session extraction design.
#
# Takes the verbatim output of R/extract_verbatim.R (session1_*.csv) and
# harmonises it to the 27 Aug 2026 template's controlled values:
#   * actor names -> actor CODES from the actor_codes registry (semicolon-
#     joined, per template). Deterministic matching first (name, acronym,
#     substring, fuzzy); leftovers resolved by ONE small batched LLM call
#     against fuzzy candidate shortlists; still-unmatched actors are written
#     to proposed_new_actors.csv for human review — codes are NEVER invented.
#   * coded fields (scale, beneficiary, document type, metrics, units,
#     funding mechanism): deterministic synonym maps first, then ONE batched
#     LLM call per field type, carrying the template readme's definitions.
#     Values are validated in code; anything off-list becomes
#     'CANDIDATE: ...' and is appended to candidate_vocab_log.csv.
#
# The model never sees the documents here — only the short verified extracts.
# A vocabulary change re-runs this script only; no document is re-read.
#
# Usage:
#   Rscript R/harmonize.R                      # latest session1_*.csv
#   Rscript R/harmonize.R outputs/extraction/session1_20260908_1200.csv
##############################################################################

suppressPackageStartupMessages({
  library(ellmer); library(readxl); library(readr); library(dplyr); library(jsonlite)
})

MODEL <- Sys.getenv("HARMONIZE_MODEL", "gpt-5-mini")
PROMPT_VERSION <- "s2-v0.3"
# .Renviron lives in the OneDrive-redirected Documents folder; a shell that
# overrides HOME (e.g. Git Bash) makes R miss it, so load it explicitly
if (!nzchar(Sys.getenv("OPENAI_API_KEY")))
  for (.p in c(file.path(Sys.getenv("OneDrive"), "Documents", ".Renviron"),
               file.path(Sys.getenv("USERPROFILE"), "Documents", ".Renviron")))
    if (file.exists(.p)) { readRenviron(.p); break }

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- if (length(full)) normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", "..")) else getwd()
OUT_DIR <- Sys.getenv("EXTRACT_OUT_DIR", file.path(REPO, "outputs", "extraction"))
# paths live in one place; this script used to carry its own copy of the
# template location, which is how it drifted from the audits that check it
source(file.path(REPO, "R", "00_shared", "paths.R"))
source(file.path(REPO, "R", "00_shared", "vocab_cache.R"))

args <- commandArgs(trailingOnly = TRUE)
s1_csv <- if (length(args)) args[1] else {
  f <- list.files(OUT_DIR, pattern = "^session1_.*\\.csv$", full.names = TRUE)
  stopifnot("no session1_*.csv found — run extract_verbatim.R first" = length(f) > 0)
  f[which.max(file.mtime(f))]
}
cat("harmonizing:", s1_csv, "\n")
# every column as text: read.csv would turn money columns into doubles and
# as.character(33000000) is "3.3e+07", which then leaked into budget_total
# and made budget_notes read "lead 3.207" (Charity pilot, 28 Sep 2026)
s1 <- read.csv(s1_csv, check.names = FALSE, stringsAsFactors = FALSE, colClasses = "character")
s1[is.na(s1)] <- ""

# ------------------------------------------------------- controlled values --
# OPT (the option lists) and DEFS (their readme definitions) moved to
# R/00_shared/vocab_lists.R on 30 Sep 2026, so the QC workbook builder offers
# consultants the same lists harmonisation chose from. Two copies would drift.
source(file.path(REPO, "R", "00_shared", "vocab_lists.R"))

# --------------------------------------------------------- LLM batch helper --
llm_map <- function(field, texts, options, definitions = "", na_rule = "") {
  idx <- which(nzchar(texts) & !texts %in% options)   # skip already-valid/empty
  if (!length(idx)) return(texts)
  # reuse the decision this extract already got, so a rerun is comparable
  cache <- vocab_cache_load(REPO, field, options)
  out0 <- texts
  hit <- vapply(texts[idx], function(t) {
    k <- vocab_key(t); if (k %in% names(cache)) unname(cache[k]) else ""
  }, character(1), USE.NAMES = FALSE)
  if (any(nzchar(hit))) {
    # a remembered NOT STATED means the cell stays empty, not that the
    # question is unanswered
    hit[toupper(hit) == "NOT STATED"] <- ""
    out0[idx[nzchar(hit)]] <- hit[nzchar(hit)]
    cat(sprintf("  %-22s %d of %d from the decision cache\n", field,
                sum(nzchar(hit)), length(idx)))
    idx <- idx[!nzchar(hit)]
    if (!length(idx)) return(out0)
  }
  texts <- out0
  chat <- chat_openai(model = MODEL, system_prompt = paste(
    "You harmonise verbatim extracts from project evaluations into a fixed",
    "controlled vocabulary. You see only the extract, never the document.",
    "Choose the single best option.",
    if (nzchar(na_rule)) na_rule else paste(
      "If the extract does not actually state this field - it is a counting",
      "line, a page heading, a figure with no subject, or simply about",
      "something else - answer exactly 'NOT STATED'. An empty cell is correct",
      "and useful; a plausible-looking value the extract does not support is",
      "not. If the extract DOES state the field but no option fits, answer",
      "'CANDIDATE: ' followed by a 2-6 word label."),
    "Never invent options; never force a bad fit."))
  prompt <- paste0(
    "FIELD: ", field, "\nOPTIONS: ", paste(options, collapse = "; "),
    if (nzchar(definitions)) paste0("\nDEFINITIONS: ", definitions) else "",
    "\n\nINPUT EXTRACTS (numbered):\n",
    paste0(sprintf("%d) %s", seq_along(idx), substr(texts[idx], 1, 400)),
           collapse = "\n"))
  spec <- type_object(mapping = type_array(
    items = type_object(
      i = type_integer("Input number."),
      choice = type_string("One option verbatim, or 'CANDIDATE: ...'."))))
  res <- tryCatch(chat$chat_structured(prompt, type = spec),
                  error = function(e) { warning(field, ": ", conditionMessage(e)); NULL })
  if (is.null(res)) return(texts)
  n_unstated <- 0L
  # what gets written to the sheet, and what gets remembered, differ for a
  # NOT STATED: the cell is empty, but the decision itself must be recorded
  # or every rerun pays to ask the same question again
  remembered <- texts
  m <- res$mapping
  if (is.data.frame(m)) m <- lapply(seq_len(nrow(m)), function(i) as.list(m[i, ]))
  out <- texts
  for (mm in m) {
    j <- suppressWarnings(as.integer(mm$i))
    if (is.na(j) || j < 1 || j > length(idx)) next
    ch <- as.character(mm$choice)
    if (identical(toupper(trimws(ch)), "NOT STATED")) {
      n_unstated <- n_unstated + 1L
      out[idx[j]] <- ""                            # the document did not say
      remembered[idx[j]] <- "NOT STATED"
      next
    }
    if (!(ch %in% options) && !startsWith(ch, "CANDIDATE:"))
      ch <- paste0("CANDIDATE: ", texts[idx[j]])   # validation: never off-list
    out[idx[j]] <- ch
    remembered[idx[j]] <- ch
  }
  if (n_unstated)
    cat(sprintf("  %-22s %d left empty - the extract did not state it\n",
                field, n_unstated))
  vocab_cache_save(REPO, field, options, texts[idx], remembered[idx])
  out
}

log_candidates <- function(df_doc, field, stated, chosen) {
  k <- which(startsWith(chosen, "CANDIDATE:"))
  if (!length(k)) return(invisible())
  log <- data.frame(date = format(Sys.Date()), document = df_doc[k],
                    field = field, stated = stated[k], chosen = chosen[k],
                    stringsAsFactors = FALSE)
  path <- file.path(OUT_DIR, "candidate_vocab_log.csv")
  write.table(log, path, sep = ",", row.names = FALSE, append = file.exists(path),
              col.names = !file.exists(path))
}

# -------------------------------------------------------- actor registry -----
# The registry, the name comparison and the matching tiers all live in
# R/00_shared/actor_names.R now, so that the audit which checks this script's
# proposals uses the same definition of "same organisation" as the matcher
# that made them, and so that the checks can run without an API key.
source(file.path(REPO, "R", "00_shared", "actor_names.R"))
source(file.path(REPO, "R", "00_shared", "clean_fields.R"))   # money_num, format_money, budget_notes_for are used before the field rules below
areg <- actor_registry(TEMPLATE_XLSX)
ASYN <- local({
  f <- file.path(REPO, "catalogues", "actor_synonyms.csv")
  if (!file.exists(f)) return(NULL)
  d <- read_csv_utf8(f)
  if (!nrow(d)) NULL else d
})
AIDX <- actor_index(areg, ASYN)
cat("  actors                 registry", nrow(areg), "| synonyms",
    if (is.null(ASYN)) 0 else nrow(ASYN), "
")
# nrm() is still used by map_unit_det() and country_prefix() below; it is the
# same function, kept under its old name so those two do not change.
nrm <- actor_nrm

# country helpers live in R/00_shared/actor_names.R; the index is built once
CIDX <- actor_country_index(areg)
in_context <- function(country, ctx) actor_in_context(country, ctx)
match_actor_country_h <- function(name, ctx) match_actor_country(name, ctx, CIDX)
drop_foreign <- function(rows, ctx) actor_drop_foreign(rows, ctx, CIDX)

resolve_actors <- function(all_names, context = NULL) {
  uniq <- unique(trimws(unlist(strsplit(all_names[nzchar(all_names)], ";\\s*"))))
  uniq <- uniq[nzchar(uniq)]
  ctx_of <- function(u) if (!is.null(context) && u %in% names(context)) context[[u]] else ""
  map <- setNames(vapply(uniq, function(u) {
    cd <- match_actor_det(u, AIDX)$code
    if (is.na(cd)) cd <- match_actor_country_h(u, ctx_of(u))
    cd
  }, character(1)), uniq)
  n_country <- sum(!is.na(map) & vapply(uniq, function(u) is.na(match_actor_det(u, AIDX)$code), logical(1)))
  if (n_country) cat("  actors                ", n_country, "matched through the document's country\n")
  pending <- names(map)[is.na(map)]
  # An organisation the model already recognised stays recognised: without
  # this, two harmonise runs of the same extraction matched 25 actors and
  # then 18, so the proposal list churned for no reason. Only positive
  # matches are remembered, and only while the code is still in the registry.
  # Comparing a matcher change against the run before it is meaningless
  # while the cache is answering: it already holds the codes and would
  # reproduce them whatever the matcher now does. ACTOR_CACHE=off turns
  # it off for an A/B run.
  acache <- if (identical(tolower(Sys.getenv("ACTOR_CACHE")), "off"))
    setNames(character(0), character(0)) else
    vocab_cache_load(REPO, "actor_match", "registry")
  if (length(pending) && length(acache)) {
    hit <- vapply(pending, function(p) {
      k <- vocab_key(p)
      if (k %in% names(acache) && acache[[k]] %in% areg$code) unname(acache[k]) else ""
    }, character(1), USE.NAMES = FALSE)
    if (any(nzchar(hit))) {
      map[pending[nzchar(hit)]] <- hit[nzchar(hit)]
      cat("  actors                ", sum(nzchar(hit)),
          "matched from the decision cache\n")
      pending <- pending[!nzchar(hit)]
    }
  }
  if (length(pending)) {                     # one batched LLM disambiguation
    cand_rows  <- lapply(pending, function(p) {
      cc <- actor_candidates(p, AIDX)
      keep <- cc$rows %in% drop_foreign(cc$rows, ctx_of(p))
      list(rows = cc$rows[keep], via = cc$via[keep])
    })
    cand_codes <- lapply(cand_rows, function(cc) areg$code[cc$rows])
    lines <- vapply(seq_along(pending), function(i) {
      cand <- cand_rows[[i]]$rows
      ctx <- ctx_of(pending[i])
      paste0(i, ") '", pending[i], "'", if (nzchar(ctx)) paste0(" [document covers: ", substr(ctx, 1, 120), "]") else "", " -> candidates: ",
             if (length(cand)) paste0(areg$code[cand], "=", areg$name[cand],
                                      ifelse(nzchar(areg$acro[cand]),
                                             paste0(" [", areg$acro[cand], "]"), ""),
                                      collapse = "; ") else "(none)")
    }, character(1))
    chat <- chat_openai(model = MODEL, system_prompt = paste(
      "You match organisation names from evaluation documents to a registry.",
      "Pick the candidate code ONLY if it is CLEARLY the same organisation",
      "(renames/acronyms count, e.g. a former name of the same body).",
      "An acronym matches only the candidate's actual acronym or name",
      "initials — letters merely CONTAINED in a candidate's name (e.g. 'TAF'",
      "inside 'Taflalet') are NOT a match. A department, global practice,",
      "division or regional unit is not an organisation — answer 'NEW' for",
      "those. A national ministry, agency or government belongs to the country",
      "the document covers (given in brackets): the same ministry of ANOTHER",
      "country is NOT a match, answer 'NEW' with that country.",
      "When in ANY doubt, answer 'NEW' and describe the organisation",
      "so a registry entry can be prepared. Never guess codes."))
    spec <- type_object(mapping = type_array(items = type_object(
      i = type_integer(), code = type_string("Registry code or 'NEW'."),
      scale = type_enum(values = c("global", "continental", "national", "unknown"),
        description = "For NEW actors: the organisation's scale per the registry convention (global; continental = Africa-wide; national)."),
      country = type_string("For NEW national actors: the country, e.g. 'Rwanda'. Empty otherwise."),
      acronym = type_string("The organisation's acronym if commonly used, else empty."),
      actor_type = type_string("For NEW actors, one of: academic institution; advocacy organization/group; banks and microfinance institutions; bilateral development agency; civil society organization; development organization; farmer/pastoralist organization/cooperative; foundation/ philanthropic organization; government agency; intergovernmental organization; international finance institution; media; non-governmental organization; other; private company; producer/farmer group; project/programme; research institution; think tank; trade organization; training/capacity building centre."))))
    res <- tryCatch(chat$chat_structured(
      paste0("ORGANISATIONS AND CANDIDATES:\n", paste(lines, collapse = "\n")),
      type = spec), error = function(e) NULL)
    newinfo <- list()
    if (!is.null(res)) {
      m <- res$mapping
      if (is.data.frame(m)) m <- lapply(seq_len(nrow(m)), function(i) as.list(m[i, ]))
      for (mm in m) {
        j <- suppressWarnings(as.integer(mm$i))
        if (is.na(j) || j < 1 || j > length(pending)) next
        cd <- as.character(mm$code)
        # accept ONLY a code from this item's own candidate shortlist — a
        # valid-but-unshown registry code would be an unverifiable guess
        if (cd %in% cand_codes[[j]]) map[pending[j]] <- cd
        else newinfo[[pending[j]]] <- mm     # NEW: keep scale/acronym/type
      }
      settled <- pending[!is.na(map[pending])]
      if (length(settled))
        vocab_cache_save(REPO, "actor_match", "registry", settled,
                         unname(map[settled]))
    }
  } else newinfo <- list()
  new <- names(map)[is.na(map)]
  if (length(new)) {
    # Intake form for the team: suggested code = registry-convention prefix
    # (GLO / CON / country prefix) + next free number in that section.
    # These are PROPOSALS — the code becomes real only once a human adds the
    # row to the actor_codes sheet; the next harmonize run then matches it
    # automatically (no re-extraction needed).
    prefix_of <- function(code) gsub("[0-9]+$", "", code)
    next_code <- local({
      # Codes handed out in earlier runs must be counted too, or every run
      # restarts at registry-max + 1 and issues the same code to a different
      # organisation. The location side already does this; this side did not.
      prev <- unlist(lapply(
        c(file.path(OUT_DIR, "proposed_new_actors.csv"),
          file.path(VOCAB_DIR, "proposed_new_actors.csv")), function(f) {
          if (!file.exists(f)) return(character(0))
          d <- tryCatch(read.csv(f, stringsAsFactors = FALSE), error = function(e) NULL)
          if (is.null(d) || !"suggested_code" %in% names(d)) character(0)
          else as.character(d$suggested_code)
        }))
      prev <- prev[nzchar(prev) & !is.na(prev)]
      known <- c(areg$code, prev)
      taken <- table(prefix_of(known))
      maxn  <- vapply(names(taken), function(p) {
        suppressWarnings(max(as.integer(gsub("^[A-Za-z]+", "",
          known[prefix_of(known) == p])), na.rm = TRUE))
      }, numeric(1))
      maxn[!is.finite(maxn)] <- 0
      counter <- as.list(maxn)
      function(prefix) {
        n <- if (!is.null(counter[[prefix]])) counter[[prefix]] + 1 else 1
        counter[[prefix]] <<- n
        paste0(prefix, n)
      }
    })
    # The old version promised to reuse the registry's prefix and then just
    # uppercased the first three letters, so Malawi got MAL where the registry
    # uses MWI. Ask the registry instead. For each prefix, which country do its
    # own actor names mention most? BF says Burkina Faso 54 times, GHA says
    # Ghana 35, ZAM says Zambia 25. Invert that, and a country whose name two
    # prefixes claim (NIG and NER are both Niger, CG and COG both Congo, ZA and
    # ZAF both South Africa) gets no code rather than a guessed one.
    PREFIX_COUNTRY <- local({
      pad <- paste0(" ", nrm(areg$name), " ")
      pre <- prefix_of(areg$code)
      words <- unlist(strsplit(pad, " ", fixed = TRUE))
      words <- unique(words[nchar(words) >= 4])
      out <- character(0)
      for (p in setdiff(unique(pre), c("GLO", "CON", "REG"))) {
        k <- which(pre == p)
        if (length(k) < 2) next
        n <- vapply(words, function(w)
          sum(grepl(paste0(" ", w, " "), pad[k], fixed = TRUE)), integer(1))
        # a country name is mentioned by many of a prefix's own actors and
        # hardly at all by the rest of the registry
        share_out <- vapply(words, function(w)
          sum(grepl(paste0(" ", w, " "), pad[-k], fixed = TRUE)), integer(1))
        score <- n / pmax(1, n + share_out)
        cand <- which(n >= 2 & score >= 0.8)
        if (!length(cand)) next
        out[p] <- names(sort(n[cand], decreasing = TRUE))[1]
      }
      out
    })
    country_prefix <- function(country) {
      k <- nrm(country)
      if (!nzchar(k)) return("")
      # the inferred table is keyed on single words, so "Burkina Faso" is
      # looked up whole and then by its first distinctive word
      keys <- unique(c(k, Filter(function(w) nchar(w) >= 4,
                                 strsplit(k, " ", fixed = TRUE)[[1]])))
      for (kk in keys) {
        owners <- names(PREFIX_COUNTRY)[PREFIX_COUNTRY == kk]
        if (length(owners) == 1) return(owners)
        if (length(owners) > 1) return("")      # two prefixes claim it
      }
      ""
    }

    rows <- lapply(new, function(nm) {
      inf <- newinfo[[nm]]
      scale <- if (!is.null(inf)) as.character(inf$scale) else "unknown"
      pre <- switch(scale, global = "GLO", continental = "CON",
                    national = country_prefix(as.character(inf$country)), "")
      data.frame(date = format(Sys.Date()), actor_name = actor_tidy_proposal(nm),
        actor_accronym = if (!is.null(inf)) as.character(inf$acronym) else "",
        suggested_scale = scale,
        suggested_country = if (!is.null(inf)) as.character(inf$country) else "",
        suggested_code = if (nzchar(pre)) next_code(pre) else "",
        suggested_actor_type = if (!is.null(inf)) as.character(inf$actor_type) else "",
        status = if (nzchar(pre))
          "REVIEW: confirm/edit, add row to actor_codes, then re-run harmonize"
        else "REVIEW: no code suggested - the country prefix is ambiguous or unknown; pick one, add the row, re-run harmonize",
        stringsAsFactors = FALSE)
    })
    nn <- do.call(rbind, rows)
    # one proposal per body: "Ministry of Environment and Sustainable Development,
    # Mauritania" and "Ministry of the Environment and Sustainable Development,
    # Mauritania" are the same row (vocabulary review, 28 Sep 2026)
    nn <- nn[!duplicated(actor_fold(nn$actor_name)), , drop = FALSE]
    path <- file.path(OUT_DIR, "proposed_new_actors.csv")
    if (file.exists(path)) {                       # don't re-propose known names
      seen <- tryCatch(read.csv(path, stringsAsFactors = FALSE)$actor_name,
                       error = function(e) character(0))
      nn <- nn[!actor_fold(nn$actor_name) %in% actor_fold(seen), , drop = FALSE]
    }
    if (nrow(nn))
      write.table(nn, path, sep = ",", row.names = FALSE,
                  append = file.exists(path), col.names = !file.exists(path))
  }
  map[is.na(map)] <- paste0("NEW: ", names(map)[is.na(map)])
  map
}
codes_for <- function(x, map) {
  if (!nzchar(x)) return("")
  parts <- trimws(unlist(strsplit(x, ";\\s*")))
  paste(unique(map[parts]), collapse = "; ")
}

# ------------------------------------------------- deterministic first maps --
# unit_syn / map_unit_det live in R/00_shared/clean_fields.R (29 Sep 2026)
map_doctype_det <- function(d) {
  k <- tolower(d)
  if (grepl("implementation completion", k)) return("implementation completion report")
  if (grepl("performance evaluation report|icr review", k)) return("terminal evaluation")
  if (grepl("terminal evaluation|final evaluation|final report", k)) return("terminal evaluation")
  if (grepl("mid.?term", k)) return("mid-term evaluation")
  if (grepl("implementation status", k)) return("implementation status report")
  if (grepl("impact (assessment|evaluation)", k)) return("impact evaluation report")
  # independent multi-program / fund-level evaluations
  if (grepl("independent evaluation office|evaluation of .*programs|independent evaluation of the|evaluation of the pilot program", k))
    return("portfolio performance review")
  if (grepl("^\\s*evaluation of ", k)) return("terminal evaluation")
  d
}
map_funding_det <- function(instr) {
  k <- tolower(instr)
  # known funds whose instrument is always a grant, even when the wording is
  # only 'funded by ...' (GEF Trust Fund, Adaptation Fund, LDCF/SCCF windows)
  if (grepl("gef trust fund|\\bget\\b|adaptation fund|ldcf|sccf|green climate fund|\\bgcf\\b|gafsp", k) &&
      !grepl("credit|loan", k)) return("grant")
  k <- gsub("investment project financing", "", k)   # WB modality label, not an instrument
  has <- c(loan = grepl("credit|loan", k), grant = grepl("grant", k),
           investment = grepl("equity|bond|investment", k))
  found <- names(has)[has]
  if (!length(found)) return("")
  paste(found, collapse = "+")
}

# ------------------------------------------------------------ harmonise -----
h <- s1
gc_chr <- function(col) if (col %in% names(h)) as.character(h[[col]]) else rep("", nrow(h))

# actors -> codes
# each actor name carries the text that says where its document's project
# is, so a ministry without a country can be placed
actor_ctx <- local({
  ctx <- list()
  doc_txt <- actor_nrm(paste(gc_chr("project_title"), gc_chr("scope_stated"),
                             gc_chr("location_notes"), gc_chr("location_count_basis")))
  for (i in seq_len(nrow(h))) {
    nm <- trimws(unlist(strsplit(paste(gc_chr("project_lead_name")[i], gc_chr("funder_names")[i],
                                       gc_chr("implementor_names")[i], sep = ";"), ";\\s*")))
    for (u in nm[nzchar(nm)]) ctx[[u]] <- paste(ctx[[u]], doc_txt[i])
  }
  ctx
})
amap <- resolve_actors(c(gc_chr("project_lead_name"), gc_chr("funder_names"),
                         gc_chr("implementor_names")), context = actor_ctx)
h$project_lead <- vapply(gc_chr("project_lead_name"), codes_for, character(1), map = amap)
h$funder       <- vapply(gc_chr("funder_names"), codes_for, character(1), map = amap)
h$implementors <- vapply(gc_chr("implementor_names"), codes_for, character(1), map = amap)   # template column renamed 28 Sep 2026

# budget_notes (decision of 28 Sep 2026, QC question 7): budget_total stays the
# standardised total across all sources; the split goes here in very short
# words and amounts, e.g. "lead 44700000; cofinancing 263500000". Empty when
# the document gives no lead share or the share equals the total.
# money columns as plain digits (money_num / format_money in clean_fields.R);
# text that is not a number is left as it is
for (m in c("budget_total", "budget_lead_share", "disbursed")) if (m %in% names(h)) {
  v <- money_num(h[[m]]); h[[m]] <- ifelse(is.na(v), h[[m]], format_money(v))
}
h$budget_notes <- budget_notes_for(gc_chr("budget_total"), gc_chr("budget_lead_share"))

# scale + beneficiary + document type (deterministic, then batched LLM)
h$project_scale <- llm_map("project_scale (geographic level of the project)",
  paste0("scope: ", gc_chr("scope_stated"), " | locations: ",
         gc_chr("location_count"), " ", gc_chr("location_notes")),
  OPT$scale, DEFS$scale)
h$target_beneficiary_project <- llm_map(
  "target_beneficiary_project (who the project targets)",
  gc_chr("target_beneficiary_stated"), OPT$beneficiary, DEFS$beneficiary)
dt <- vapply(gc_chr("document_type_stated"), map_doctype_det, character(1))
h$document_type <- llm_map("document_type", dt, OPT$doc_type, DEFS$doc_type)

# result metrics + units
for (i in 1:3) {
  ms <- gc_chr(paste0("result", i, "_metric_stated"))
  us <- vapply(gc_chr(paste0("result", i, "_unit_stated")), map_unit_det, character(1))
  # The metric names the SUBJECT of the number, so the two escapes collapse
  # into one another unless they are told apart: "New knowledge and advocacy
  # products disseminated" plainly states what was counted, it simply is not
  # one of the 27 options. Judged under the generic rule the model answered
  # CANDIDATE once and NOT STATED the next time, and NOT STATED blanks the
  # cell - which is how a value ended up with a unit and no metric.
  h[[paste0("result", i, "_metric")]] <- llm_map(
    paste0("result_metric (what a project result counts)"), ms, OPT$metric,
    na_rule = paste(
      "Answer 'NOT STATED' ONLY when the extract names no countable subject at",
      "all - a bare figure, a date, a duration, an administrative count, or a",
      "pure unit word such as 'Percent' or 'Number'. In every other case the",
      "extract DOES state the field: if no option fits, answer 'CANDIDATE: '",
      "followed by a 2-6 word NOUN label naming what was counted, never a",
      "copied phrase and never digits or percent signs ('loss ratio', not 'as",
      "low as 39% for Maize'). Not being in the",
      "list is never a reason to answer NOT STATED."))
  # beneficiary wording is mapped by rule first (clean_fields.R), the way the
  # references word it; the model decides only where the rule is silent
  det <- vapply(paste(ms, gc_chr(paste0("result", i, "_unit_stated"))), map_people_metric_det, character(1), USE.NAMES = FALSE)
  det[!det %in% OPT$metric] <- ""
  det[stated_is_measure(gc_chr(paste0("result", i, "_unit_stated")))] <- ""   # a land or index row is not a people count
  cur <- h[[paste0("result", i, "_metric")]]
  ust <- gc_chr(paste0("result", i, "_unit_stated"))
  # the wording decides the option where it can (land by unit, yield by rate,
  # head nouns for people and organisations); the model's choice is dropped
  # when it contradicts the thing counted; what is left without an option
  # carries the document's exact wording (29 Sep 2026)
  det2 <- mapply(map_metric_det, ms, ust, USE.NAMES = FALSE); det2[!det2 %in% OPT$metric] <- ""
  metric <- ifelse(nzchar(det) & nzchar(ms), det, ifelse(nzchar(det2), det2, cur))
  conflict <- metric_option_conflict(metric, ms, "")
  metric[conflict] <- ""
  metric <- candidate_verbatim(metric, ms)
  h[[paste0("result", i, "_metric")]] <- metric
  unit <- llm_map("result_unit", us, OPT$unit)
  unit <- mapply(unit_count_fallback, ust, unit, USE.NAMES = FALSE)
  # a yield stated per hectare in kg is kg/hectare
  unit[metric == "crop yield increase" & unit %in% c("kg", "") & grepl("per hectare|/ha|par hectare", tolower(ms))] <- "kg/hectare"
  unit <- candidate_verbatim(unit, ifelse(startsWith(unit, "CANDIDATE:"), ust, ""))
  h[[paste0("result", i, "_unit")]] <- unit
  h[[paste0("result", i, "_metric")]] <- metric_unit_consistent(h[[paste0("result", i, "_metric")]],
                                                                h[[paste0("result", i, "_unit")]], ms)
}
# A metric that counts people is counted in individuals. "Number" as the
# stated unit maps to quantity, which is right for profiles or sub-projects
# and wrong for advisory agents trained (Charity pilot, 28 Sep 2026).
PEOPLE_METRICS <- c("direct beneficiaries", "total beneficiaries", "women beneficiaries",
  "youth beneficiaries", "smallholder farmers reached", "extension agents trained",
  "crop producers", "livestock producers", "fishers", "processors", "wholesalers",
  "association members")
for (i in 1:3) {
  mcol <- paste0("result", i, "_metric"); ucol <- paste0("result", i, "_unit")
  fix <- h[[mcol]] %in% PEOPLE_METRICS & h[[ucol]] %in% c("quantity", "")
  h[[ucol]][fix] <- "individuals"
  h[[ucol]][h[[mcol]] == "vulnerable households" & h[[ucol]] %in% c("quantity", "", "individuals")] <- "households"
}
# "women" alone is the template's "women (female-headed households)": the
# template has no plain women option, and the reference readings used this one
# (vocabulary review, 28 Sep 2026)
h$target_beneficiary_project[tolower(h$target_beneficiary_project) %in%
  c("candidate: women", "candidate: women farmers", "candidate: rural women", "women")] <- "women (female-headed households)"

# funding mechanism: deterministic from instrument wording first ('funded
# by <known grant fund>' rules included); anything a keyword can't settle
# goes to the LLM with the template definitions instead of defaulting to
# 'other' blindly
fm <- vapply(gc_chr("instrument_stated"), map_funding_det, character(1))
# the instrument mix names the instruments even when the instrument wording
# is a financing table ("loan (90.91%) + counterpart (9.09%)")
portion <- tolower(gc_chr("funding_mechanism_portion"))
has_loan <- grepl("\\bloans?\\b|\\bcredits?\\b", portion)
has_grant <- grepl("\\bgrants?\\b", portion)
from_portion <- ifelse(has_loan & has_grant, "loan+grant", ifelse(has_loan, "loan", ifelse(has_grant, "grant", "")))
fm[!nzchar(fm) & nzchar(from_portion)] <- from_portion[!nzchar(fm) & nzchar(from_portion)]
# no instrument wording, but the funder itself settles it (grant-only funds)
grantfunder <- grepl("gef|global environment facility|trust fund|adaptation fund",
                     tolower(gc_chr("funder_names")))
fm[!nzchar(fm) & grantfunder] <- "grant"
pendfm <- !nzchar(fm) & nzchar(gc_chr("instrument_stated"))
if (any(pendfm)) {
  fm2 <- llm_map("funding_mechanism (financing instrument type)",
    ifelse(pendfm, paste0("instrument wording: ", gc_chr("instrument_stated"),
                          " | portion: ", gc_chr("funding_mechanism_portion")), ""),
    c("grant", "loan", "investment", "blended", "other", "loan+grant"),
    "blended: intentional mix of concessional/public and private capital; grant: non-repayable funds; investment: capital expecting financial return; loan: borrowed money requiring repayment; other: alternative mechanisms (carbon credits, in-kind, insurance, domestic budget); loan+grant: mixed credits and grants. If genuinely unclassifiable, choose other.")
  fm[pendfm] <- fm2[pendfm]
}
fm[startsWith(fm, "CANDIDATE:")] <- "other"   # readme: unclassifiable -> other
h$funding_mechanism <- fm

# candidate logging
log_candidates(h$document, "target_beneficiary_project",
               gc_chr("target_beneficiary_stated"), h$target_beneficiary_project)
for (i in 1:3) {
  log_candidates(h$document, paste0("result", i, "_metric"),
                 gc_chr(paste0("result", i, "_metric_stated")),
                 h[[paste0("result", i, "_metric")]])
  log_candidates(h$document, paste0("result", i, "_unit"),
                 gc_chr(paste0("result", i, "_unit_stated")),
                 h[[paste0("result", i, "_unit")]])
}

# ------------------------------------------- field rules, applied again -----
# Session 1 already applies these, but a harmonise of an older run must not
# publish rows that predate a rule, and the location sheet joins on
# project_code, which only exists here as the session's code hint.
source(file.path(REPO, "R", "00_shared", "clean_fields.R"))
h$project_code <- gc_chr("project_code_hint")

# A beneficiary must be a group of people. When the passage the extraction
# quoted names none - P006's document says "7. Beneficiary : 4 LCBC
# countries: Cameroon, Niger, Nigeria and Chad", a geography - the model
# maps it to the nearest option anyway and invents an answer. Re-read the
# project's own title, rationale and results instead; P006's title is
# "... Integrated Pest Management for Subsistence Farming".
# Second source when the project's own words settle nothing: the location
# pass read every passage in the document row by row, so the group it found
# most often is evidenced where the general sheet's quote is not.
loc_ben <- function(pcode) {
  fs <- list.files(file.path(OUT_DIR, "locations"),
                   pattern = "^locations_harmonized_.*\\.csv$", full.names = TRUE)
  if (!length(fs)) return("")
  d <- tryCatch(read.csv(fs[which.max(file.mtime(fs))], stringsAsFactors = FALSE,
                         colClasses = "character"), error = function(e) NULL)
  if (is.null(d) || !all(c("project_code", "target_beneficiary") %in% names(d))) return("")
  v <- d$target_beneficiary[d$project_code == pcode]
  v <- v[!is.na(v) & nzchar(v)]
  if (!length(v)) return("")
  names(sort(table(v), decreasing = TRUE))[1]
}

ben_stated <- gc_chr("target_beneficiary_stated")
for (i in seq_len(nrow(h))) {
  if (!names_no_people(ben_stated[i])) next
  from <- paste(h$project_title[i], gc_chr("rationale_project")[i],
                gc_chr("result1_metric_stated")[i], gc_chr("result2_metric_stated")[i],
                gc_chr("result3_metric_stated")[i])
  tb <- detect_beneficiary(from); why <- "the project's own words"
  if (!nzchar(tb)) { tb <- loc_ben(h$project_code[i])
                     why <- "the group the location rows evidence most often" }
  was <- h$target_beneficiary_project[i]
  if (!nzchar(tb)) {
    cat(sprintf("  beneficiary            %s: quoted passage named no people and nothing else evidences a group; kept %s for review\n",
                h$project_code[i], if (nzchar(was)) was else "(empty)"))
  } else if (!identical(tb, was)) {
    h$target_beneficiary_project[i] <- tb
    cat(sprintf("  beneficiary            %s: quoted passage named no people (\"%s\"); read %s from %s\n",
                h$project_code[i], substr(ben_stated[i], 1, 55), tb, why))
  } else {
    cat(sprintf("  beneficiary            %s: quoted passage named no people, but %s is confirmed by %s\n",
                h$project_code[i], was, why))
  }
}
h$project_title <- vapply(gc_chr("project_title"), clean_title, character(1),
                          USE.NAMES = FALSE)
h$location_count <- vapply(gc_chr("location_count"), clean_count, character(1),
                           USE.NAMES = FALSE)
h$GESI_project <- vapply(gc_chr("GESI_project"), clean_gesi, character(1),
                         USE.NAMES = FALSE)
for (fld in c("rationale_project", "location_notes", "result_notes",
              paste0("result", 1:3), paste0("result", 1:3, "_metric"),
              paste0("result", 1:3, "_unit"), paste0("result", 1:3, "_metric_stated"),
              paste0("result", 1:3, "_unit_stated"))) {
  v <- gc_chr(fld); v[is.na(v)] <- ""; h[[fld]] <- v
}
# columns that travel with a result when the slots are closed up
RESULT_SIDECARS <- c("_metric_stated", "_unit_stated", "_scope", "_page")
rule_notes <- rep("", nrow(h))
add_note <- function(i, msg) if (nzchar(msg))
  rule_notes[i] <<- trimws(paste(rule_notes[i], msg, sep = if (nzchar(rule_notes[i])) "; " else ""))
for (i in seq_len(nrow(h))) {
  for (fld in c("rationale_project", "location_notes", "result_notes")) {
    ct <- clean_text(h[[fld]][i]); h[[fld]][i] <- ct$value
    if (nzchar(ct$note)) add_note(i, paste0(fld, ": ", ct$note))
  }
  add_note(i, check_count_vs_notes(h$location_count[i], h$location_notes[i]))
  # decision 21 (15 Sep 2026): portions use only the template's five
  # instrument types; anything else keeps its wording behind "other-".
  # Entries are not merged, so two grants stay listed separately.
  if ("funding_mechanism_portion" %in% names(h)) {
    fp <- clean_funding_portion(h$funding_mechanism_portion[i])
    h$funding_mechanism_portion[i] <- fp$value
    add_note(i, fp$note)
  }
  # drop anything the shared gate says is not a result, then close the gap so
  # result1 is always the first real one
  keep <- list()
  for (k in 1:3) {
    v <- h[[paste0("result", k)]][i]
    u <- h[[paste0("result", k, "_unit")]][i]
    s <- paste(h[[paste0("result", k, "_metric_stated")]][i],
               h[[paste0("result", k, "_unit_stated")]][i])
    if (!nzchar(trimws(v)) && !nzchar(trimws(h[[paste0("result", k, "_metric")]][i]))) next
    why <- result_reject_reason(v, u, s, h[[paste0("result", k, "_metric")]][i])
    if (nzchar(why)) { add_note(i, paste0("result", k, " dropped: ", why)); next }
    cn <- clean_number(v)
    if (nzchar(cn$note)) add_note(i, paste0("result", k, ": ", cn$note))
    # Carry the WHOLE result, not three of its columns. Dropping a result
    # shifts the survivors up, and moving only value/metric/unit left
    # metric_stated, unit_stated, scope and page describing a different
    # indicator: P001 ended up with the value 15 beside the wording "An SLWM
    # Knowledge Platform...", and a page number pointing at the wrong place,
    # which silently breaks the fact-check trail.
    got <- list(v = if (nzchar(cn$value)) cn$value else v,
                m = h[[paste0("result", k, "_metric")]][i], u = u)
    for (sfx in RESULT_SIDECARS) {
      cn2 <- paste0("result", k, sfx)
      got[[sfx]] <- if (cn2 %in% names(h)) h[[cn2]][i] else ""
    }
    keep[[length(keep) + 1L]] <- got
  }
  for (k in 1:3) {
    got <- if (k <= length(keep)) keep[[k]] else
           c(list(v = "", m = "", u = ""), setNames(as.list(rep("", length(RESULT_SIDECARS))), RESULT_SIDECARS))
    h[[paste0("result", k)]][i] <- got$v
    h[[paste0("result", k, "_unit")]][i] <- got$u
    for (sfx in RESULT_SIDECARS) {
      cn2 <- paste0("result", k, sfx)
      if (cn2 %in% names(h)) h[[cn2]][i] <- got[[sfx]]
    }
    # a value must always say what it counts; an empty metric is not a finding
    h[[paste0("result", k, "_metric")]][i] <- if (!nzchar(trimws(got$v))) got$m else
      metric_floor(got$m, got[["_metric_stated"]], got[["_scope"]])
  }
}
h$result_notes <- trimws(ifelse(nzchar(rule_notes),
  paste(h$result_notes, rule_notes, sep = ifelse(nzchar(h$result_notes), " | ", "")),
  h$result_notes))
cat("field rules: ", sum(nzchar(rule_notes)), " row(s) picked up a note\n", sep = "")

# ------------------------------------------------ template-shaped output ----
TEMPLATE_COLS <- c("project_code", "project_title", "project_id", "project_lead",
  "publication_year", "start_year", "closure_year", "project_scale",
  "location_count", "location_notes", "rationale_project",
  "target_beneficiary_project", "GESI_project",
  "result1", "result1_metric", "result1_unit",
  "result2", "result2_metric", "result2_unit",
  "result3", "result3_metric", "result3_unit", "result_notes",
  "budget_total", "disbursed", "currency", "funding_mechanism",
  "funding_mechanism_portion", "budget_notes", "funder", "implementors", "document_type",
  "resource_id", "evidence_depth",
  "reference_link_1", "reference_link_2", "reference_link_3")
for (cc in TEMPLATE_COLS) if (!cc %in% names(h)) h[[cc]] <- ""

s1_model <- if ("model" %in% names(s1) && nzchar(s1$model[1]))
  gsub("[^a-z0-9]+", "-", tolower(s1$model[1])) else "unknown"
stamp <- paste0(s1_model, "_", format(Sys.time(), "%Y%m%d_%H%M"))
h$harmonize_version <- PROMPT_VERSION; h$session1_file <- basename(s1_csv)

# ONE output, not two. Until 30 Sep 2026 this wrote a clean template-shaped
# file and a diagnostics twin, and the clean one is what reached people: every
# quote, page and fact-check verdict was dropped on the way out, so a reviewer
# got values with no trail back to the document. TEMPLATE_COLS now defines the
# delivery VIEW rather than destroying the rest. The template columns come
# first so the file still reads as the sheet; export_results.R subsets to them
# for the workbook, and the QC builder and the scorer read what follows.
h <- h[, c(TEMPLATE_COLS, setdiff(names(h), TEMPLATE_COLS))]
out1 <- file.path(OUT_DIR, paste0("harmonized_", stamp, ".csv"))
write_csv(h, out1)
cat("harmonised:", out1, "\n  ", length(TEMPLATE_COLS), "template columns +",
    ncol(h) - length(TEMPLATE_COLS), "evidence/diagnostic columns\n")
cat("actors: ", sum(!startsWith(unlist(amap), "NEW:")), "matched,",
    sum(startsWith(unlist(amap), "NEW:")), "proposed new\n")
