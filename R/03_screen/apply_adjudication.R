# apply_adjudication.R - record the adjudicators' verdicts as rulings.
#
# Six adjudicators read 120 flagged documents in full, each without sight of
# the screener's verdict or of the held-out reference, and wrote a verdict
# with verbatim quotes for the climate risk and the adaptation action. Their
# judgements are better evidenced than the screener's: a full read against the
# four criteria rather than one pass over truncated text.
#
# They are still MODEL judgements, so they are recorded the same way the
# earlier session rulings were, in scope_screen_overrides.csv with a `by`
# beginning "Claude". That has three consequences, all intended:
#   - screen_rules applies them last, so they take effect
#   - build_reverify_list treats anything by Claude as challengeable, so a
#     later pass can re-ask them; only a person's decision is exempt
#   - the provenance says plainly who decided and on what basis
#
# Documents the adjudicator could not settle become "unsure", which is the
# queue a person works from. That is the honest destination for a genuine
# 50/50 on sector primacy, and for a multi-project evaluation with no focus
# project.
#
#   Rscript R/03_screen/apply_adjudication.R [--dry]

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
DRY <- "--dry" %in% commandArgs(trailingOnly = TRUE)

ADJ <- file.path(SCREEN_DIR, "inputs", "decisions", "scope_reverify_adjudication.csv")
OVR <- file.path(SCREEN_DIR, "inputs", "decisions", "scope_screen_overrides.csv")
SC  <- file.path(SCREEN_DIR, "scope_screen.csv")
stopifnot(file.exists(ADJ), file.exists(OVR))

a  <- read.csv(ADJ, stringsAsFactors = FALSE, colClasses = "character")
ov <- read.csv(OVR, stringsAsFactors = FALSE, colClasses = "character")
sc <- read.csv(SC,  stringsAsFactors = FALSE, colClasses = "character")
sc[is.na(sc)] <- ""
a[is.na(a)] <- ""

key_sc <- paste(sc$source, sc$filename)
now <- sc$verdict_ruled[match(paste(a$source, a$filename), key_sc)]
a$was <- ifelse(is.na(now), "(not screened)", now)

cat("adjudicated:", nrow(a), "\n")
print(table(adjudicator = a$verdict, screener = a$was))

# Only disagreements need recording. Where the adjudicator agrees with the
# standing verdict, a ruling would add noise and a future re-ask cost.
change <- a$verdict != a$was & a$was != "(not screened)"
cat("\ndisagreements to record:", sum(change), "\n")
for (i in which(change))
  cat(sprintf("  %-9s %-52s %-13s -> %s\n", a$source[i], substr(a$filename[i], 1, 52),
              a$was[i], a$verdict[i]))

if (!sum(change)) { cat("\nnothing to record\n"); quit(save = "no") }

mk_note <- function(r) {
  bits <- c(sprintf("adjudicated on a full read (%s confidence)", r[["confidence"]]))
  if (nzchar(r[["project_subject"]])) bits <- c(bits, sprintf("subject: %s", r[["project_subject"]]))
  if (nzchar(r[["climate_risk_quote"]]))
    bits <- c(bits, sprintf("risk: \"%s\"", substr(r[["climate_risk_quote"]], 1, 160)))
  if (nzchar(r[["adaptation_action_quote"]]))
    bits <- c(bits, sprintf("action: \"%s\"", substr(r[["adaptation_action_quote"]], 1, 160)))
  if (nzchar(r[["note"]])) bits <- c(bits, r[["note"]])
  paste(bits, collapse = "; ")
}

new <- data.frame(
  source   = a$source[change],
  filename = a$filename[change],
  verdict  = a$verdict[change],
  note     = vapply(which(change), function(i) mk_note(a[i, ]), character(1)),
  by       = "Claude adjudication, Oct 2026",
  stringsAsFactors = FALSE)

at  <- match(paste(new$source, new$filename), paste(ov$source, ov$filename))
upd <- which(!is.na(at))
if (length(upd)) {
  ov$verdict[at[upd]] <- new$verdict[upd]
  ov$note[at[upd]]    <- paste("superseded by adjudication;", new$note[upd])
  ov$by[at[upd]]      <- new$by[upd]
  cat("\nupdated in place:", length(upd), "\n")
}
add <- new[is.na(at), ]
out <- rbind(ov[, names(new)], add)
cat("appended:", nrow(add), "| overrides total:", nrow(out), "\n")

if (DRY) { cat("\n(dry run: nothing written)\n"); quit(save = "no") }
write.csv(out, OVR, row.names = FALSE, fileEncoding = "UTF-8")
cat("\nwritten:", OVR, "\nnow run: Rscript R/03_screen/screen_rules.R\n")
