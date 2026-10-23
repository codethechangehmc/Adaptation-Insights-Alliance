# evidence_scan.R - a recall net for excluded documents that does not depend
# on the screener's judgement.
#
# Why this exists. The Phase 4c re-read re-judged the Cameroon agriculture
# ICR (P143417) and reproduced the original error word for word: "does not
# name a climate risk it responds to". The ICR's own component (iii) is
# "strengthening the resilience of production systems ... to climate change".
# Re-reading with the same prompt reproduces the same blind spot, so a
# verification built only on re-reading has a recall ceiling, and the
# documents it keeps missing never reach a human or an adjudicator.
#
# This scan is the independent second signal. It reads the full text of every
# excluded document and measures the evidence the protocol's criteria ask
# for, deterministically:
#
#   agriculture   is farming/livestock/fisheries/food systems the subject?
#   climate risk  is a named hazard present (drought, flood, erratic rainfall,
#                 temperature rise, salinity, climate variability)?
#   adaptation    is there an action framed as a response to that hazard?
#   co-occurrence do a climate term and an agriculture term appear in the SAME
#                 sentence? This is the strongest cheap signal that the
#                 project acts on a climate risk in agriculture, and it is
#                 what the audits used when they found these by hand.
#
# A document ruled out while scoring high is not thereby in scope: it is a
# disagreement between the model's verdict and the document's own words, and
# every disagreement goes to adjudication. Boilerplate is stripped first
# (pretreat_text), so the AfDB template label cannot manufacture a hit.
#
#   Rscript R/03_screen/evidence_scan.R                 # all excluded docs
#   Rscript R/03_screen/evidence_scan.R --source=worldbank --limit=50
#   -> review/evidence_scan.csv            every scanned document, scored
#      review/adjudication_candidates.csv  the disagreements, ranked

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
source(file.path(REPO, "R", "03_screen", "screen_text.R"))
suppressMessages(library(pdftools))

args <- commandArgs(trailingOnly = TRUE)
opt <- function(k, d = NULL) {
  hit <- grep(paste0("^--", k, "="), args, value = TRUE)
  if (length(hit)) sub(paste0("^--", k, "="), "", hit[1]) else d
}
ONLY  <- opt("source")
LIMIT <- suppressWarnings(as.integer(opt("limit", NA)))
OUT   <- file.path(SCREEN_DIR, "inputs", "reports", "evidence_scan.csv")
CAND  <- file.path(SCREEN_DIR, "inputs", "decisions", "adjudication_candidates.csv")

SCREEN <- file.path(SCREEN_DIR, "scope_screen.csv")
sc <- read.csv(SCREEN, stringsAsFactors = FALSE, colClasses = "character")
sc[is.na(sc)] <- ""

# ── the evidence vocabularies ───────────────────────────────────────────────
# Deliberately narrow. Recall comes from reading every document in full, not
# from loose terms; a loose list would flag everything and tell us nothing.
AGRI <- c("agricultur", "farmer", "farming", "smallholder", "crop", "cropping",
          "livestock", "pastoral", "rangeland", "fisher", "fishing",
          "aquaculture", "agroforestr", "irrigation", "food security",
          "food system", "value chain", "harvest", "seed", "soil fertility",
          "extension service", "cassava", "maize", "sorghum", "millet",
          "rice", "cocoa", "coffee", "horticultur", "market garden")

RISK <- c("climate change", "climate variab", "climate risk", "climate shock",
          "climate hazard", "drought", "flood", "erratic rainfall",
          "rainfall variab", "irregular rainfall", "dry spell", "heat stress",
          "rising temperature", "sea level rise", "salinit", "saltwater intrusion",
          "coastal erosion", "desertification", "changement climatique",
          "secheresse", "sécheresse", "inondation")

ADAPT <- c("adaptation", "adapt to", "resilien", "climate-smart", "climate smart",
           "drought-tolerant", "drought tolerant", "heat-tolerant",
           "water harvest", "soil and water conservation", "early warning",
           "agro-ecolog", "agroecolog", "conservation agriculture",
           "flood control", "anti-erosion", "erosion control",
           "climate information", "agro-climatic", "resistant variet",
           "résilience", "adaptative")

count_terms <- function(txt, terms) {
  sum(vapply(terms, function(t) {
    g <- gregexpr(t, txt, fixed = TRUE)[[1]]
    if (g[1] == -1L) 0L else length(g)
  }, integer(1)))
}

# Sentence-level evidence. Two things are measured, and the second is the one
# that matters most: the documents the audits found wrongly excluded are
# agriculture-DOMINANT with SPARSE climate language. The Cameroon ICR counts
# 930 agriculture terms against 2 climate terms, and its single adaptation
# component sits in one sentence. A density threshold cannot see that; it is
# a needle, so the scan must surface the needle itself rather than score the
# haystack.
sentence_evidence <- function(txt) {
  sent <- unlist(strsplit(txt, "(?<=[.!?])\\s+", perl = TRUE))
  sent <- sent[nchar(sent) > 25 & nchar(sent) < 600]
  if (!length(sent)) return(list(n = 0L, quote = "", risk_quotes = ""))
  risk_re  <- paste(RISK,  collapse = "|")
  agri_re  <- paste(AGRI,  collapse = "|")
  adapt_re <- paste(ADAPT, collapse = "|")
  both <- grepl(risk_re, sent) & grepl(agri_re, sent)
  # every sentence naming a climate hazard, action-bearing ones first: this is
  # what an adjudicator reads to decide the intervention criterion
  risky <- sent[grepl(risk_re, sent)]
  risky <- c(risky[grepl(adapt_re, risky)], risky[!grepl(adapt_re, risky)])
  q <- if (any(both)) {
    b <- sent[both]
    wa <- b[grepl(adapt_re, b)]
    if (length(wa)) wa[1] else b[1]
  } else if (length(risky)) risky[1] else ""
  clean <- function(x) gsub("\\s+", " ", trimws(substr(x, 1, 350)))
  list(n = sum(both), quote = clean(q),
       risk_quotes = paste(vapply(head(risky, 3), clean, character(1)),
                           collapse = " || "))
}

## ---- pick the documents to scan --------------------------------------------
# Only documents excluded on a JUDGEMENT. A document out on its date or its
# geography is not a judgement this scan can second-guess: the year is a team
# decision and the country is a fact. Scanning them would bury the real
# candidates under correct exclusions (an Ethiopian pastoral project from
# 2009 scores high on every term and is still out, on the window).
pick <- sc$verdict_ruled %in% c("out of scope", "unsure")
# Trust the DATE, and only the corrected date. Two mistakes to avoid, both
# found by the holdout:
#   - the reason text is stale. gef_5580's reason still reads "dated 2026"
#     although year_overrides.csv corrected it to 2019 from the pipeline's own
#     date file, so a regex on the reason text excluded a document that is
#     inside the window. Read publication_year, which the rules have already
#     corrected, never the sentence.
#   - geography is NOT a fact here, it is a claim. The CIF development-impacts
#     case studies were excluded for naming "no African country", yet page 239
#     is a Niger agriculture case study. Excluding documents because the model
#     said they are not African would make the check circular, so geography
#     exclusions are scanned like any other judgement.
yr <- suppressWarnings(as.integer(sc$publication_year))
out_of_window <- !is.na(yr) & (yr < 2015 | yr > 2025)
timeframe <- rep(FALSE, nrow(sc))
geography <- rep(FALSE, nrow(sc))
# Parked progress documents are not a judgement either: whether the family
# counts at all is an open question for the template owner, so their exclusion
# is a recorded decision awaiting a person, not a mistake to detect. Leaving
# them in buried the real candidates under GCF annual performance reports,
# which score high on every term by their nature.
parked <- grepl("progress_reports|proposal_stage|tracking_tools",
                sc$folder, fixed = FALSE)
pick <- pick & !timeframe & !geography & !out_of_window & !parked
cat("excluded from the scan: timeframe", sum(timeframe), "| geography",
    sum(geography), "| dated outside the window", sum(out_of_window),
    "| parked", sum(parked), "\n")
if (!is.null(ONLY)) pick <- pick & sc$source %in% strsplit(ONLY, ",")[[1]]
rows <- sc[pick, ]
if (!is.na(LIMIT)) rows <- head(rows, LIMIT)
cat("documents to scan:", nrow(rows), "\n")

find_path <- function(source, folder, filename) {
  p <- file.path(DOCS_ROOT, folder, filename)
  if (file.exists(p)) return(p)
  for (d in SCAN_DIRS[[source]]) {
    p <- file.path(DOCS_ROOT, d, filename)
    if (file.exists(p)) return(p)
  }
  NA_character_
}

res <- vector("list", nrow(rows))
t0 <- Sys.time()
for (i in seq_len(nrow(rows))) {
  r <- rows[i, ]
  p <- find_path(r$source, r$folder, r$filename)
  if (is.na(p)) {
    res[[i]] <- data.frame(source = r$source, filename = r$filename,
      verdict_ruled = r$verdict_ruled, chars = 0L, agri = 0L, risk = 0L,
      adapt = 0L, cooccur = 0L, agri_per10k = 0, risk_per10k = 0,
      quote = "", risk_quotes = "", note = "file not found", stringsAsFactors = FALSE)
    next
  }
  txt <- tryCatch(extract_document_text(p), error = function(e) "")
  txt <- tryCatch(pretreat_text(txt), error = function(e) txt)
  txt <- tolower(gsub("[\r\n]+", " ", txt))
  n <- nchar(txt)
  if (n < 500) {
    res[[i]] <- data.frame(source = r$source, filename = r$filename,
      verdict_ruled = r$verdict_ruled, chars = n, agri = 0L, risk = 0L,
      adapt = 0L, cooccur = 0L, agri_per10k = 0, risk_per10k = 0,
      quote = "", risk_quotes = "", note = "no usable text", stringsAsFactors = FALSE)
    next
  }
  a <- count_terms(txt, AGRI); k <- count_terms(txt, RISK); d <- count_terms(txt, ADAPT)
  co <- sentence_evidence(txt)
  res[[i]] <- data.frame(source = r$source, filename = r$filename,
    verdict_ruled = r$verdict_ruled, chars = n, agri = a, risk = k, adapt = d,
    cooccur = co$n, agri_per10k = round(a / n * 10000, 2),
    risk_per10k = round(k / n * 10000, 2), quote = co$quote, risk_quotes = co$risk_quotes, note = "",
    stringsAsFactors = FALSE)
  if (i %% 25 == 0)
    cat(sprintf("  %d/%d  (%.1f min elapsed)\n", i, nrow(rows),
                as.numeric(difftime(Sys.time(), t0, units = "mins"))))
}
out <- do.call(rbind, res)
write.csv(out, OUT, row.names = FALSE, fileEncoding = "UTF-8")
cat("\nwritten:", OUT, "-", nrow(out), "rows\n")

## ---- the candidates --------------------------------------------------------
# A candidate is an excluded document whose own text carries all three
# ingredients in quantity: agriculture as a recurring subject, a named climate
# hazard, and at least one sentence binding the two together. The thresholds
# are deliberately generous: this list is read by an adjudicator, so a false
# positive costs one reading and a false negative costs a document.
# Two tiers, because the errors have two shapes.
#   A  the text binds climate and agriculture repeatedly: a strong candidate
#   B  agriculture is plainly the subject and a climate hazard is named even
#      once. This is the shape of every World Bank error the audit found, and
#      a density rule cannot see it. One true sentence satisfies the
#      protocol's intervention criterion, so one is enough to deserve a read.
# A short document can be saturated with agriculture and still have a low raw
# count: gef_5280 is a 15k-character portal sheet with 26 agriculture terms,
# which is 17 per 10k, denser than most full evaluations. Raw count alone
# missed it, so density counts too.
cand <- out[out$note == "" & out$risk >= 1 &
            (out$agri >= 40 | out$agri_per10k >= 8), ]
cand$tier <- ifelse(cand$cooccur >= 2, "A", "B")
cand <- cand[order(cand$tier, -cand$cooccur, -cand$agri), ]
write.csv(cand, CAND, row.names = FALSE, fileEncoding = "UTF-8")

cat("\n=== adjudication candidates:", nrow(cand), "of", nrow(out), "scanned ===\n")
print(table(cand$source, cand$tier))
cat("\ntop 15 by co-occurring sentences:\n")
for (i in head(seq_len(nrow(cand)), 15))
  cat(sprintf("  [%s] %-56s co=%3d agri=%4d risk=%3d\n", cand$source[i],
              substr(cand$filename[i], 1, 56), cand$cooccur[i],
              cand$agri[i], cand$risk[i]))
cat("\nwritten:", CAND, "\n")
