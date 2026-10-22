##############################################################################
# audit_proposed_actors.R - check every proposed new actor before a human
# spends time on it, the way audit_proposed_locations.R does for places.
#
# The pipeline proposes an actor whenever the matcher cannot place a name in
# the registry. Three kinds of proposal are not worth a new code, and the
# team should not have to spot them by eye:
#
#   NEAR-DUPLICATE  the registry already holds it under a slightly different
#                   name ("Centre"/"Center", an inline acronym, a missing
#                   space). The matcher folds these now, so a survivor here
#                   is a spelling the folding does not cover yet.
#   NOT AN ORGANISATION  a project coordination unit, task force or steering
#                   committee is part of a project, not a body that outlives
#                   it. The registry is a list of organisations.
#   FINANCING ARM   IDA is the World Bank's concessional window, ADF is the
#                   African Development Fund. Whether those get their own
#                   code or fold into the parent is the team's call, but it
#                   is a different question from "is this a new organisation".
#
#   Rscript R/07_review/audit_proposed_actors.R
##############################################################################

suppressPackageStartupMessages({ library(openxlsx) })

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
source(file.path(REPO, "R", "00_shared", "actor_names.R"))

rd <- function(f) {
  d <- read.csv(f, stringsAsFactors = FALSE, colClasses = "character")
  d[is.na(d)] <- ""; d
}

# the harmoniser writes its proposals beside the run; the team's copy lives
# in review/. Audit whichever is newer, so this works either way round.
cands <- c(file.path(VOCAB_DIR, "proposed_new_actors.csv"),
           file.path(REPO, "outputs", "extraction", "proposed_new_actors.csv"))
cands <- cands[file.exists(cands)]
if (!length(cands)) { cat("no proposed_new_actors.csv - nothing to audit\n"); quit(save = "no") }
PROP <- cands[which.max(file.mtime(cands))]
cat("auditing:", PROP, "\n")
p <- rd(PROP)
if (!nrow(p)) { cat("proposal file is empty\n"); quit(save = "no") }

# same registry, same trimming and the same idea of "same name" as the
# matcher whose proposals this audits - it used to have its own, stricter
# copy, so it reported duplicates the matcher could never actually reach
A <- actor_registry(TEMPLATE_XLSX)

fold <- actor_fold
A$f <- fold(A$name); A$fa <- fold(A$acro)

UNIT_RX <- paste0("\\b(project|programme|program) (coordination|implementation|",
  "management) unit\\b|\\b(pcu|piu|pmu)\\b|\\btask ?force\\b|",
  "\\bsteering committee\\b|\\bworking group\\b|\\bfocal points?\\b")
# A credit number ("IDA-52030", "IDA H-828-A3") and a postal address
# ("LCBC P.O. Box 727 N'Djamena") both arrived as proposed organisations.
# They are references to a grant or a place, not bodies that can hold a code.
NOT_BODY_RX <- paste0("\\bp\\.? ?o\\.? box\\b|\\bpostal\\b|",
  "^[a-z]{2,5}[- ]?[a-z]?-?[0-9]{3,6}([- ][a-z0-9]+)?\\)?$|",
  "\\b(credit|grant|loan) (no|number)\\b")
ARM_RX <- paste0("\\b(fund|facility|window|association|trust)\\b")

verdict <- character(nrow(p)); note <- character(nrow(p))
for (i in seq_len(nrow(p))) {
  nm <- p$actor_name[i]; f <- fold(nm)
  low <- tolower(nm)
  if (!nzchar(f)) { verdict[i] <- "EMPTY - drop"; next }

  hit <- which(A$f == f | (nzchar(A$fa) & A$fa == f) |
               gsub(" ", "", A$f, fixed = TRUE) == gsub(" ", "", f, fixed = TRUE))
  if (!length(hit)) {
    d <- adist(f, A$f, ignore.case = TRUE)[1, ]
    k <- which.min(d)
    if (1 - d[k] / max(nchar(f), nchar(A$f[k])) >= 0.90) hit <- k
  }
  if (length(hit)) {
    verdict[i] <- "NEAR-DUPLICATE - use the existing code"
    note[i] <- paste0(A$code[hit[1]], " = ", A$name[hit[1]])
    next
  }
  if (grepl(UNIT_RX, low)) { verdict[i] <- "NOT AN ORGANISATION - part of a project"; next }
  if (grepl(NOT_BODY_RX, low)) {
    verdict[i] <- "NOT AN ORGANISATION - an identifier or an address"; next }
  if (grepl(ARM_RX, low)) {
    d <- adist(f, A$f, ignore.case = TRUE)[1, ]
    k <- which.min(d)
    sim <- 1 - d[k] / max(nchar(f), nchar(A$f[k]))
    verdict[i] <- "FINANCING ARM - own code, or fold into the parent?"
    if (sim >= 0.70) note[i] <- paste0("closest parent: ", A$code[k], " = ", A$name[k])
    next
  }
  verdict[i] <- "NEW - needs a code"
}

# Two things the checks above still miss, both found by hand on the pilot:
#
#   the same body proposed twice under different names ("INRAN in Niger" and
#   "National Agronomic Research Institute of Niger (INRAN)"), which would
#   spend two codes on one organisation; and
#
#   a registry entry under a former or longer name ("Rwanda Agriculture
#   Board" is RWA1 "Rwanda Agriculture and Animal Resource Development
#   Board"), which exact and near-exact matching cannot see.
#
# Neither can be settled automatically, so both are surfaced for a person
# rather than decided here.
toks  <- actor_tokens      # the same distinctive-word set the matcher uses
acros <- actor_acronyms
overlap <- function(a, b)
  if (!length(a) || !length(b)) 0 else length(intersect(a, b)) / max(length(a), length(b))

pt <- lapply(p$actor_name, toks)
pa <- Map(acros, p$actor_name, p$actor_accronym)
A$t <- lapply(A$name, toks)

for (i in seq_len(nrow(p))) {
  if (verdict[i] != "NEW - needs a code") next
  # (a) another proposal for the same body
  dup <- 0L
  for (j in seq_len(nrow(p))) {
    if (j == i || verdict[j] == "EMPTY - drop") next
    if (tolower(p$actor_name[j]) == tolower(p$actor_name[i])) next
    if (length(intersect(pa[[i]], pa[[j]])) > 0 || overlap(pt[[i]], pt[[j]]) >= 0.8) { dup <- j; break }
  }
  if (dup) {
    verdict[i] <- "DUPLICATE OF ANOTHER PROPOSAL - one code, not two"
    note[i] <- paste0("also proposed as: ", p$actor_name[dup])
    next
  }
  # (b) a registry entry under a longer or former name
  ov <- vapply(A$t, function(x) overlap(x, pt[[i]]), numeric(1))
  k <- which.max(ov)
  if (length(k) && ov[k] >= 0.6) {
    verdict[i] <- "CHECK - a registry entry looks similar"
    note[i] <- sprintf("%s = %s (%.0f%% of the distinctive words)",
                       A$code[k], A$name[k], 100 * ov[k])
  }
}

out <- cbind(p, audit_verdict = verdict, audit_note = note)
out <- out[order(out$audit_verdict == "NEW - needs a code", out$actor_name), ]
cat("verdicts over", nrow(p), "proposals:\n")
print(table(verdict))

f_out <- file.path(VOCAB_DIR, "proposed_new_actors_AUDIT.xlsx")
wb <- createWorkbook(); addWorksheet(wb, "proposed_actors")
writeData(wb, "proposed_actors", out, withFilter = TRUE,
          headerStyle = createStyle(textDecoration = "bold", fgFill = "#EEEEEE"))
freezePane(wb, "proposed_actors", firstRow = TRUE)
setColWidths(wb, "proposed_actors", cols = seq_along(out),
             widths = pmin(52, pmax(12, nchar(names(out)) + 4)))
saveWorkbook(wb, f_out, overwrite = TRUE)
cat("\nwritten:", f_out, "\n")
