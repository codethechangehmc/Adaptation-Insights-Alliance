# dedup_corpus.R - one document, one record.
#
# Reads the census (doc_census.R) and finds three things:
#   level 1  identical files (same content hash) in two places
#   level 2  the same document filed in two folders: same family, same moment
#            in the project cycle, and a shared project or report identifier
#            (the GEF folder holds World Bank ICRs and AfDB PCRs that the
#            funder's own folder also holds)
#   level 3  several documents about ONE project: same identifier, different
#            kind (a mid-term review and a terminal evaluation, a PCR and its
#            review). Not duplicates. But the template holds one row per
#            project, so which document is authoritative is a protocol
#            decision; the clusters are reported for that decision.
#
# Levels 1 and 2 are duplicates: one copy is kept (the funder's own folder
# first, then an in-scope folder over a parked one, then the longer file) and
# the others are written as aliases. The screener and the extraction runner
# skip aliases, so nothing is screened or extracted twice and the alias's
# identifiers still travel with the kept record (a GEF ID on a World Bank
# ICR says GEF co-financed it). Report only: nothing is moved or deleted.
#
#   Rscript R/02_dedup/dedup_corpus.R
#   -> 04_Screening/inputs/decisions/duplicates.csv        aliases to skip
#      04_Screening/inputs/reports/project_clusters.csv  for the protocol call

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."),
                      mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
source(file.path(REPO, "R", "00_shared", "doc_families.R"))

CENSUS <- file.path(SCREEN_DIR, "inputs", "decisions", "family_census.csv")
OUT_D  <- file.path(SCREEN_DIR, "inputs", "decisions", "duplicates.csv")
OUT_P  <- file.path(SCREEN_DIR, "inputs", "reports", "project_clusters.csv")
stopifnot(file.exists(CENSUS))

cen <- read.csv(CENSUS, stringsAsFactors = FALSE, colClasses = "character")
cen$pages    <- suppressWarnings(as.integer(cen$pages))
cen$progress <- cen$progress == "TRUE"
cen <- cen[cen$family != "unreadable", ]
n   <- nrow(cen)
cat("census rows:", n, "\n")

IDCOLS <- c("wb_project", "wb_report", "afdb_code", "gef_id", "gcf_fp", "af_id")
ids_of <- function(i) {
  unlist(lapply(IDCOLS, function(cn) {
    v <- cen[[cn]][i]
    if (is.na(v) || !nzchar(v)) character(0) else paste0(cn, ":", strsplit(v, ";")[[1]])
  }))
}
keys   <- lapply(seq_len(n), ids_of)
keymap <- split(rep(seq_len(n), lengths(keys)), unlist(keys))

## ---- union-find over the duplicate relations -------------------------------
parent <- seq_len(n)
find <- function(i) { while (parent[i] != i) { parent[i] <<- parent[parent[i]]; i <- parent[i] }; i }
join <- function(i, j) { a <- find(i); b <- find(j); if (a != b) parent[b] <<- a }

level <- rep("", n)
for (h in unique(cen$md5[duplicated(cen$md5) & nzchar(cen$md5)])) {
  idx <- which(cen$md5 == h)
  for (k in idx[-1]) join(idx[1], k)
  level[idx] <- "identical file"
}
for (k in names(keymap)) {
  idx <- keymap[[k]]
  if (length(idx) < 2) next
  for (i in idx) for (j in idx) {
    if (i < j && cen$family[i] == cen$family[j] && cen$kind[i] == cen$kind[j]) {
      join(i, j)
      level[c(i, j)] <- ifelse(nzchar(level[c(i, j)]), level[c(i, j)], "same document, two folders")
    }
  }
}
root <- vapply(seq_len(n), find, integer(1))
clusters <- split(seq_len(n), root)
clusters <- clusters[lengths(clusters) > 1]

## ---- which copy to keep -------------------------------------------------------
in_scope <- cen$folder %in% unname(CORPUS_DIRS)
keep_of <- function(idx) {
  own <- vapply(idx, function(i) {
    o <- family_info(cen$family[i])$owner
    !is.na(o) && identical(o, cen$source[i])
  }, logical(1))
  pg  <- ifelse(is.na(cen$pages[idx]), 0, cen$pages[idx])
  ord <- order(-own, -in_scope[idx], -pg, cen$filename[idx])
  idx[ord][1]
}

dup_rows <- list()
for (ci in seq_along(clusters)) {
  idx  <- clusters[[ci]]
  keep <- keep_of(idx)
  shared <- Reduce(intersect, keys[idx])
  for (i in setdiff(idx, keep)) {
    dup_rows[[length(dup_rows) + 1]] <- data.frame(
      cluster = ci, level = level[i],
      keep_source = cen$source[keep], keep_folder = cen$folder[keep], keep_file = cen$filename[keep],
      drop_source = cen$source[i],    drop_folder = cen$folder[i],    drop_file = cen$filename[i],
      family = cen$family[keep], kind = cen$kind[keep],
      shared_ids = paste(shared, collapse = ";"),
      pages_keep = cen$pages[keep], pages_drop = cen$pages[i],
      why_keep = if (!is.na(family_info(cen$family[keep])$owner) &&
                     identical(family_info(cen$family[keep])$owner, cen$source[keep]))
                   "funder's own folder" else if (in_scope[keep] && !in_scope[i]) "in-scope folder"
                 else "longer file or first alphabetically",
      stringsAsFactors = FALSE)
  }
}
dups <- if (length(dup_rows)) do.call(rbind, dup_rows) else
  data.frame(cluster = integer(0), level = character(0))
write.csv(dups, OUT_D, row.names = FALSE)

## ---- level 3: several documents about one project ---------------------------
proj_rows <- list()
for (k in names(keymap)) {
  idx <- unique(keymap[[k]])
  # collapse duplicates first: one representative per cluster
  reps <- unique(vapply(idx, function(i) { r <- find(i); if (r %in% as.integer(names(clusters))) keep_of(clusters[[as.character(r)]]) else i }, integer(1)))
  if (length(reps) < 2) next
  if (length(unique(cen$kind[reps])) < 2 && length(unique(cen$family[reps])) < 2) next
  proj_rows[[length(proj_rows) + 1]] <- data.frame(
    project_id = k, n_docs = length(reps),
    kinds = paste(sort(unique(cen$kind[reps])), collapse = " + "),
    families = paste(sort(unique(cen$family[reps])), collapse = " + "),
    has_progress = any(cen$progress[reps]),
    documents = paste(sprintf("%s/%s [%s, %s]", cen$source[reps], cen$filename[reps],
                              cen$family[reps], cen$kind[reps]), collapse = " | "),
    stringsAsFactors = FALSE)
}
proj <- if (length(proj_rows)) do.call(rbind, proj_rows) else
  data.frame(project_id = character(0))
proj <- proj[order(-proj$n_docs, proj$project_id), ]
write.csv(proj, OUT_P, row.names = FALSE)

## ---- report --------------------------------------------------------------------
cat("\nduplicate clusters:", length(clusters), "| files to skip as aliases:", nrow(dups), "\n")
if (nrow(dups)) {
  print(table(dups$level))
  cat("\n")
  for (i in seq_len(min(nrow(dups), 40)))
    cat(sprintf("  keep %-9s %-46s  drop %-9s %-46s  %s\n", dups$keep_source[i],
                substr(dups$keep_file[i], 1, 46), dups$drop_source[i],
                substr(dups$drop_file[i], 1, 46), dups$shared_ids[i]))
}
cat("\nprojects with several documents (not duplicates; protocol call):", nrow(proj), "\n")
if (nrow(proj)) print(table(proj$kinds))
cat("\nwritten:", OUT_D, "\n        ", OUT_P, "\n")

## ---- --apply: take the aliases out of the source folders ----------------------
# The alias is moved (never deleted) to 03_Documents/duplicates/, renamed with
# its source as a prefix so the origin stays visible, and every move is
# written to duplicates_register.xlsx: which source had the duplicate, which
# file was kept and where, which was taken out and where it went. Reversible
# from the register.
if (any(commandArgs(trailingOnly = TRUE) == "--apply") && nrow(dups)) {
  DUP_DIR <- file.path(DOCS_ROOT, "duplicates")
  dir.create(DUP_DIR, showWarnings = FALSE)
  # Windows APIs give up past 260 characters; the \\?\ prefix lifts that
  long <- function(p) paste0("\\\\?\\", gsub("/", "\\\\", normalizePath(p, mustWork = FALSE)))
  moved <- character(nrow(dups)); where <- character(nrow(dups))
  for (i in seq_len(nrow(dups))) {
    src <- file.path(DOCS_ROOT, dups$drop_folder[i], dups$drop_file[i])
    dst <- file.path(DUP_DIR, paste0(dups$drop_source[i], "__", dups$drop_file[i]))
    if (!file.exists(src) && !file.exists(long(src))) {
      moved[i] <- if (file.exists(dst)) "already moved" else "source file not found"; where[i] <- dst; next
    }
    ok <- suppressWarnings(file.rename(long(src), long(dst)))
    if (!ok) ok <- suppressWarnings(file.rename(src, dst))
    if (!ok) {
      ok <- suppressWarnings(file.copy(long(src), long(dst), overwrite = FALSE))
      if (ok) ok <- suppressWarnings(file.remove(long(src)))
    }
    moved[i] <- if (ok) "moved" else "FAILED"; where[i] <- dst
  }
  reg <- data.frame(
    date = format(Sys.Date()),
    source_with_duplicate = dups$drop_source,
    file_taken_out = dups$drop_file,
    taken_from_folder = dups$drop_folder,
    now_at = file.path("03_Documents", "duplicates", basename(where)),
    kept_source = dups$keep_source,
    kept_file = dups$keep_file,
    kept_folder = dups$keep_folder,
    why_this_one_kept = dups$why_keep,
    how_matched = dups$level,
    shared_ids = dups$shared_ids,
    family = dups$family,
    status = moved,
    stringsAsFactors = FALSE)
  summary <- as.data.frame(table(source_with_duplicate = reg$source_with_duplicate,
                                 kept_in = reg$kept_source))
  summary <- summary[summary$Freq > 0, ]
  names(summary)[3] <- "files_taken_out"
  REG <- file.path(DUP_DIR, "duplicates_register.xlsx")
  if (file.exists(REG)) {                       # append to the running register
    old <- tryCatch(openxlsx::read.xlsx(REG, sheet = "duplicates"), error = function(e) NULL)
    if (!is.null(old)) {
      old <- old[!(paste(old$source_with_duplicate, old$file_taken_out) %in%
                   paste(reg$source_with_duplicate, reg$file_taken_out)), ]
      reg <- rbind(old[names(reg)], reg)
    }
  }
  openxlsx::write.xlsx(list(duplicates = reg, by_source = summary,
                            project_clusters = proj), REG, overwrite = TRUE)
  cat("\n--apply:", sum(moved == "moved"), "moved,", sum(moved == "already moved"), "already moved,",
      sum(moved == "FAILED"), "failed ->", DUP_DIR, "\n   register:", REG, "\n")
}
