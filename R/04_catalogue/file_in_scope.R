# file_in_scope.R - move documents the screener ruled in scope into the
# in-scope folder for their source.
#
# Screening and filing are separate steps on purpose: a document is fetched
# into to_screen, judged, and only then promoted. Nothing downstream sees a
# document until it is filed, because build_doc_index.R and the extraction
# driver both read CORPUS_DIRS, not the screening verdicts. So a verdict that
# is never filed is a document the pipeline cannot use.
#
# Rules this obeys:
#   - it moves ONLY files whose ruled verdict is "in scope"
#   - it never moves a file out of an in-scope folder: a verdict that changed
#     the other way is reported, not acted on, because demoting a file would
#     break paths that other records already point at. Those are listed for a
#     person.
#   - it never overwrites. A name collision in the destination stops that
#     file and is reported.
#   - the screening record is keyed by (source, filename), not by path, so
#     moving a file does not invalidate its judgement. The `folder` column is
#     refreshed afterwards so the record matches the disk.
#
#   Rscript R/04_catalogue/file_in_scope.R --dry
#   Rscript R/04_catalogue/file_in_scope.R

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
DRY <- "--dry" %in% commandArgs(trailingOnly = TRUE)

SCREEN <- file.path(SCREEN_DIR, "scope_screen.csv")
sc <- read.csv(SCREEN, stringsAsFactors = FALSE, colClasses = "character")
sc[is.na(sc)] <- ""

ins <- which(sc$verdict_ruled == "in scope")
cat("in scope:", length(ins), "\n")

moved <- 0L; skipped <- list(); demote <- list()
for (i in ins) {
  src <- sc$source[i]
  dest_rel <- CORPUS_DIRS[[src]]
  if (is.null(dest_rel) || identical(sc$folder[i], dest_rel)) next
  from <- file.path(DOCS_ROOT, sc$folder[i], sc$filename[i])
  to   <- file.path(DOCS_ROOT, dest_rel, sc$filename[i])
  if (!file.exists(from)) {
    skipped[[length(skipped) + 1]] <- c(sc$filename[i], "source file missing")
    next
  }
  if (file.exists(to)) {
    skipped[[length(skipped) + 1]] <- c(sc$filename[i], "a file of that name is already filed")
    next
  }
  if (DRY) { moved <- moved + 1L; next }
  dir.create(dirname(to), recursive = TRUE, showWarnings = FALSE)
  if (file.rename(from, to)) {
    sc$folder[i] <- dest_rel
    moved <- moved + 1L
  } else {
    skipped[[length(skipped) + 1]] <- c(sc$filename[i], "move failed")
  }
}

# the other direction: filed documents whose verdict is no longer in scope
for (i in seq_len(nrow(sc))) {
  src <- sc$source[i]
  if (is.null(CORPUS_DIRS[[src]])) next
  if (identical(sc$folder[i], CORPUS_DIRS[[src]]) && sc$verdict_ruled[i] != "in scope")
    demote[[length(demote) + 1]] <- c(src, sc$filename[i], sc$verdict_ruled[i])
}

cat(if (DRY) "would move:" else "moved:", moved, "files\n")
if (length(skipped)) {
  cat("\nnot moved (", length(skipped), "):\n", sep = "")
  for (s in head(skipped, 15)) cat(sprintf("  %-62s %s\n", substr(s[1], 1, 62), s[2]))
}
if (length(demote)) {
  cat("\nfiled but no longer in scope (", length(demote), ") - reported, NOT moved:\n", sep = "")
  for (d in head(demote, 20)) cat(sprintf("  %-9s %-56s %s\n", d[1], substr(d[2], 1, 56), d[3]))
  out <- file.path(SCREEN_DIR, "inputs", "reports", "filed_but_not_in_scope.csv")
  write.csv(do.call(rbind.data.frame, c(demote, stringsAsFactors = FALSE)) |>
              setNames(c("source", "filename", "verdict_ruled")),
            out, row.names = FALSE, fileEncoding = "UTF-8")
  cat("  listed in:", basename(out), "\n")
}

if (!DRY && moved > 0) {
  write.csv(sc, SCREEN, row.names = FALSE, na = "", fileEncoding = "UTF-8")
  cat("\nscreening record refreshed so its folder column matches the disk\n")
  cat("now rebuild: build_doc_index.R, corpus_inventory.R\n")
}
