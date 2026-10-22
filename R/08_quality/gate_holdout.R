# gate_holdout.R - scores a screening re-verification pass against the
# held-out reference, and is the ONLY thing that may read that reference.
#
# Reference-by-reading: before any re-screen ran, full-text audits of the six
# sources recorded every exclusion they could show to be wrong, with the
# quoted evidence, in audit/2026-10_completeness/holdout/wrong_exclusions.csv.
# That file is the expected answer written before the output existed. It must
# never be given to a screener, a re-ask list builder or an adjudicating
# agent, or the measurement becomes circular. This script is run by the
# orchestrator after the re-verification pass has written its verdicts.
#
# Scoring:
#   expected "in scope"              -> pass if the new verdict_ruled is
#                                       "in scope", or "unsure" (a hand-off to
#                                       a person is a catch, not a miss)
#   expected "covers several
#   projects" / "multi-project
#   route" / "flag"                  -> pass if the row is no longer a plain
#                                       "out of scope": unsure, in scope, or
#                                       flagged for re-ask / contradiction /
#                                       superseded in rule_applied
#
# Gate: every row marked confidence = clear MUST pass. Rows marked probable
# are reported but do not fail the gate on their own.
#
#   Rscript R/08_quality/gate_holdout.R
#   Rscript R/08_quality/gate_holdout.R --before   # score the CURRENT file as
#                                                  # a baseline, before re-run

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))

HOLD <- file.path(REPO, "audit", "2026-10_completeness", "holdout", "wrong_exclusions.csv")
SCREEN <- file.path(SCREEN_DIR, "scope_screen.csv")
stopifnot(file.exists(HOLD), file.exists(SCREEN))

h  <- read.csv(HOLD,   stringsAsFactors = FALSE, colClasses = "character")
sc <- read.csv(SCREEN, stringsAsFactors = FALSE, colClasses = "character")
sc[is.na(sc)] <- ""

key  <- paste(sc$source, sc$filename)
hit  <- match(paste(h$source, h$filename), key)

h$found         <- !is.na(hit)
h$verdict_now   <- ifelse(h$found, sc$verdict_ruled[hit], NA_character_)
h$rule_now      <- ifelse(h$found, sc$rule_applied[hit], NA_character_)
h$reason_now    <- ifelse(h$found, substr(sc$reason[hit], 1, 90), NA_character_)

FLAGGED <- "re-ask|contradicts verdict|superseded|boilerplate|human \\("
h$flagged <- !is.na(h$rule_now) & grepl(FLAGGED, h$rule_now)

h$pass <- mapply(function(found, expected, now, flagged) {
  if (!isTRUE(found)) return(NA)                       # file not screened (yet)
  if (expected == "in scope") return(now %in% c("in scope", "unsure"))
  now %in% c("in scope", "unsure") || isTRUE(flagged)  # anything but a plain out
}, h$found, h$expected, h$verdict_now, h$flagged)

cat("\n=== holdout gate ===\n")
cat("reference rows:", nrow(h), " (", sum(h$confidence == "clear"), "clear,",
    sum(h$confidence != "clear"), "probable )\n\n")

for (i in order(h$confidence, h$source)) {
  mark <- if (is.na(h$pass[i])) "  ??" else if (h$pass[i]) "  ok" else "FAIL"
  cat(sprintf("%s  [%-9s] %-8s %-62s now: %-13s %s\n", mark,
              h$confidence[i], h$source[i], substr(h$filename[i], 1, 62),
              ifelse(is.na(h$verdict_now[i]), "NOT SCREENED", h$verdict_now[i]),
              ifelse(isTRUE(h$flagged[i]), "[flagged]", "")))
}

clear <- h[h$confidence == "clear", ]
prob  <- h[h$confidence != "clear", ]
n_clear_pass <- sum(clear$pass %in% TRUE)
n_prob_pass  <- sum(prob$pass %in% TRUE)

cat("\nclear    :", n_clear_pass, "/", nrow(clear), "caught\n")
cat("probable :", n_prob_pass,  "/", nrow(prob),  "caught\n")
if (any(is.na(h$pass))) cat("not yet screened:", sum(is.na(h$pass)), "\n")

missed <- clear[!(clear$pass %in% TRUE), ]
if (nrow(missed)) {
  cat("\nMISSED (each is a defect in the re-verification, not in the reference):\n")
  for (i in seq_len(nrow(missed)))
    cat(" -", missed$source[i], missed$filename[i], "\n   expected:",
        missed$expected[i], "| basis:", substr(missed$basis[i], 1, 110), "\n")
}

out <- file.path(REPO, "outputs", "extraction", "holdout_score.csv")
write.csv(h[, c("source", "filename", "confidence", "expected", "verdict_now",
                "flagged", "pass", "basis")], out, row.names = FALSE, fileEncoding = "UTF-8")
cat("\nwritten:", out, "\n")

pass_gate <- nrow(missed) == 0 && !any(is.na(clear$pass))
cat("\nGATE:", if (pass_gate) "PASS" else "FAIL", "\n")
if (!pass_gate) quit(status = 1)
