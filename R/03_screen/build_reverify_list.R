# build_reverify_list.R - builds the Phase 4c re-ask list deterministically.
#
# The campaign re-reads every screened-out and unsure document in full, to
# retrieve the ones wrongly excluded. The list is derived from the screening
# record alone, so it is reproducible and carries no knowledge of which
# documents the audits believe are wrong (that reference is held out and only
# the gate may read it).
#
# Included:  every row whose ruled verdict is "out of scope" or "unsure"
# Excluded:  - keys decided by a PERSON (a team decision is not re-asked;
#              screen_rules re-applies it last anyway, so re-asking would spend
#              money to produce a verdict that is then discarded).
#              Rulings written by a Claude session are NOT team decisions: they
#              are model judgements recorded in the same file, and they are
#              exactly what this campaign exists to re-check, so they ARE
#              re-asked. The ruling still wins in verdict_ruled; where the
#              fresh read disagrees, the conflict goes to the team queue.
#            - parked progress documents (the family is an open team question)
#            - rows superseded by a fuller document (judge the replacement)
#            - files that are no longer on disk
#            - legacy .doc files with no converter installed (they would come
#              back "unsure: needs conversion" for free)
# Added:     the CIF documents the audit flagged for re-screening under the
#            covers-several-projects rule, even where already unsure.
#
#   Rscript R/03_screen/build_reverify_list.R
#   Rscript R/03_screen/build_reverify_list.R --exclude-done   # resume: drop
#       keys already judged in 04_Screening/inputs/working/scope_screen_parts/reverify_*.csv
#
# Writes 04_Screening/inputs/reports/scope_screen_reask_full.csv (source, filename) and prints the
# shard command to run.

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
args <- commandArgs(trailingOnly = TRUE)

SCREEN <- file.path(SCREEN_DIR, "scope_screen.csv")
OVR    <- file.path(SCREEN_DIR, "inputs", "decisions", "scope_screen_overrides.csv")
SUP    <- file.path(SCREEN_DIR, "inputs", "decisions", "supersedes.csv")
EXTRA  <- file.path(REPO, "audit", "2026-10_completeness", "cif_rescreen.csv")
OUT    <- file.path(SCREEN_DIR, "inputs", "reports", "scope_screen_reask_full.csv")

sc <- read.csv(SCREEN, stringsAsFactors = FALSE, colClasses = "character")
sc[is.na(sc)] <- ""
key <- paste(sc$source, sc$filename)

cat("screened rows:", nrow(sc), "\n")
pick <- sc$verdict_ruled %in% c("out of scope", "unsure")
cat("  out of scope or unsure:", sum(pick), "\n")

drop_reason <- rep(NA_character_, nrow(sc))

if (file.exists(OVR)) {
  ov <- read.csv(OVR, stringsAsFactors = FALSE, colClasses = "character")
  by_person <- !grepl("^claude", trimws(ov$by), ignore.case = TRUE)
  hit <- key %in% paste(ov$source[by_person], ov$filename[by_person])
  drop_reason[pick & hit] <- "decided by a person"
  n_session <- sum(key %in% paste(ov$source[!by_person], ov$filename[!by_person]) & pick)
  cat("  session rulings kept IN the re-ask (challengeable):", n_session, "\n")
}
parked <- grepl("progress_reports", sc$folder, fixed = TRUE)
drop_reason[pick & parked & is.na(drop_reason)] <- "parked progress document"

if (file.exists(SUP)) {
  sp <- read.csv(SUP, stringsAsFactors = FALSE, colClasses = "character")
  if (nrow(sp)) {
    hit <- key %in% paste(sp$source, sp$filename)
    drop_reason[pick & hit & is.na(drop_reason)] <- "superseded by a fuller document"
  }
}

on_disk <- rep(FALSE, nrow(sc))
for (src in names(SCAN_DIRS)) {
  files <- unlist(lapply(SCAN_DIRS[[src]], function(d) {
    p <- file.path(DOCS_ROOT, d)
    if (dir.exists(p)) list.files(p) else character(0)
  }))
  on_disk[sc$source == src] <- sc$filename[sc$source == src] %in% files
}
drop_reason[pick & !on_disk & is.na(drop_reason)] <- "file not on disk"

legacy_doc <- grepl("\\.doc$", sc$filename, ignore.case = TRUE)
has_soffice <- nzchar(Sys.which("soffice.com")) || nzchar(Sys.which("soffice"))
if (!has_soffice)
  drop_reason[pick & legacy_doc & is.na(drop_reason)] <- "legacy .doc, no converter installed"

take <- pick & is.na(drop_reason)
cat("  excluded from the re-ask:\n")
tb <- table(drop_reason[pick])
for (n in names(tb)) cat(sprintf("     %-36s %4d\n", n, tb[[n]]))

out <- data.frame(source = sc$source[take], filename = sc$filename[take],
                  stringsAsFactors = FALSE)

# the audit's CIF re-screen list, even where the row is already unsure
if (file.exists(EXTRA)) {
  ex <- read.csv(EXTRA, stringsAsFactors = FALSE, colClasses = "character")
  ex <- ex[paste(ex$source, ex$filename) %in% key, c("source", "filename")]
  add <- ex[!paste(ex$source, ex$filename) %in% paste(out$source, out$filename), ]
  if (nrow(add)) {
    out <- rbind(out, add)
    cat("  added from cif_rescreen.csv:", nrow(add), "\n")
  }
}

if ("--exclude-done" %in% args) {
  parts <- Sys.glob(file.path(SCREEN_DIR, "inputs", "working", "scope_screen_parts", "reverify_*.csv"))
  done <- unlist(lapply(parts, function(p) {
    d <- tryCatch(read.csv(p, stringsAsFactors = FALSE, colClasses = "character"),
                  error = function(e) NULL)
    if (is.null(d) || !nrow(d)) character(0) else paste(d$source, d$filename)
  }))
  n0 <- nrow(out)
  out <- out[!paste(out$source, out$filename) %in% done, ]
  cat("  resume: dropped", n0 - nrow(out), "keys already judged in", length(parts), "part file(s)\n")
}

write.csv(out, OUT, row.names = FALSE, fileEncoding = "UTF-8")
cat("\nre-ask list:", nrow(out), "documents ->", OUT, "\n")
print(table(out$source))
cat("\nrun as shards, e.g. 4 ways:\n")
cat("  Rscript R/03_screen/screen_scope.R --reask=", OUT,
    " --out=working/scope_screen_parts/reverify_1.csv --shard=1/4\n", sep = "")
cat("then: Rscript R/03_screen/merge_screen_parts.R && Rscript R/03_screen/screen_rules.R\n")
