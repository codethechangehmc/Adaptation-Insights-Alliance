# build_adjudication_batches.R - split the evidence-scan candidates into
# batches an adjudicator can work through, WITHOUT showing the verdict.
#
# Reference-by-reading. An adjudicator that can see the screener's verdict
# tends to rationalise it; the whole point of this pass is an independent
# second opinion on documents where the model's judgement and the document's
# own words disagree. So the batch files carry the file path, the criteria
# and the sentences that caused the flag, and never the verdict, the reason,
# or whether the audits already know about this document.
#
# The adjudicator writes its verdict and its supporting quote first. The
# orchestrator compares afterwards.
#
#   Rscript R/03_screen/build_adjudication_batches.R [--batches=6]

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
args <- commandArgs(trailingOnly = TRUE)
nb <- suppressWarnings(as.integer(sub("^--batches=", "",
        grep("^--batches=", args, value = TRUE)[1])))
if (is.na(nb)) nb <- 6

CAND <- file.path(SCREEN_DIR, "inputs", "decisions", "adjudication_candidates.csv")
SC   <- file.path(SCREEN_DIR, "scope_screen.csv")
OUTD <- file.path(VOCAB_DIR, "adjudication_batches")
dir.create(OUTD, recursive = TRUE, showWarnings = FALSE)

cand <- read.csv(CAND, stringsAsFactors = FALSE, colClasses = "character")
sc   <- read.csv(SC,   stringsAsFactors = FALSE, colClasses = "character")
sc[is.na(sc)] <- ""

# resolve each candidate to a path on disk
key <- paste(sc$source, sc$filename)
hit <- match(paste(cand$source, cand$filename), key)
folder <- sc$folder[hit]
path <- file.path(DOCS_ROOT, folder, cand$filename)
missing <- !file.exists(path)
for (i in which(missing)) {
  for (d in SCAN_DIRS[[cand$source[i]]]) {
    p <- file.path(DOCS_ROOT, d, cand$filename[i])
    if (file.exists(p)) { path[i] <- p; missing[i] <- FALSE; break }
  }
}
cat("candidates:", nrow(cand), "| resolved on disk:", sum(!missing), "\n")

out <- data.frame(
  id        = seq_len(nrow(cand)),
  source    = cand$source,
  filename  = cand$filename,
  path      = path,
  tier      = cand$tier,
  agri_terms = cand$agri,
  climate_terms = cand$risk,
  linked_sentences = cand$cooccur,
  flagged_because = cand$risk_quotes,     # the sentences, never the verdict
  stringsAsFactors = FALSE)
out <- out[!missing, ]

# interleave sources so every batch sees a mix rather than one source's quirks
out <- out[order(seq_len(nrow(out)) %% nb, out$source), ]
split_idx <- rep(seq_len(nb), length.out = nrow(out))
for (b in seq_len(nb)) {
  part <- out[split_idx == b, ]
  f <- file.path(OUTD, sprintf("batch_%02d.csv", b))
  write.csv(part, f, row.names = FALSE, fileEncoding = "UTF-8")
  cat(sprintf("  batch %02d: %3d documents -> %s\n", b, nrow(part), basename(f)))
}
cat("\nNote: these files deliberately contain no verdict, reason or audit flag.\n")
