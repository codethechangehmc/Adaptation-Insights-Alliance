# doc_census.R - one row per file in the corpus: what it is, before anything
# reads it properly.
#
# Walks every source folder (in scope and parked), reads the first three
# pages of each PDF and records the document family (00_shared/doc_families.R),
# its moment in the project cycle (terminal, midterm, completion, progress),
# the project and report identifiers printed on the cover, a content hash,
# the page count and the first line of the cover. The dedup step and the
# screener both start from this file, so a document is opened once for three
# questions: is it a duplicate, which family is it, is it in scope.
#
# No model call; about a second per document. Resumable: rows already in the
# census are kept unless --refresh. The cover pages are cached in
# outputs/census_heads.rds, so when only the family RULES change,
# --redetect re-runs detection over the cache in seconds without opening a
# single PDF.
#
#   Rscript R/02_dedup/doc_census.R                      new files only
#   Rscript R/02_dedup/doc_census.R --source=gef --refresh
#   Rscript R/02_dedup/doc_census.R --redetect           rules changed
#   -> 04_Screening/inputs/decisions/family_census.csv

suppressPackageStartupMessages({ library(pdftools); library(qpdf) })

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."),
                      mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
source(file.path(REPO, "R", "00_shared", "doc_families.R"))

args <- commandArgs(trailingOnly = TRUE)
opt <- function(name, default = "") {
  hit <- grep(paste0("^--", name, "="), args, value = TRUE)
  if (length(hit)) sub(paste0("^--", name, "="), "", hit[1]) else default
}
SRC      <- opt("source")
REFRESH  <- any(args == "--refresh")
REDETECT <- any(args == "--redetect")
OUT      <- file.path(SCREEN_DIR, "inputs", "decisions", "family_census.csv")
HEADS    <- file.path(REPO, "outputs", "census_heads.rds")
dir.create(dirname(HEADS), recursive = TRUE, showWarnings = FALSE)
heads <- if (file.exists(HEADS)) readRDS(HEADS) else list()
key_of <- function(source, folder, filename) paste(source, folder, filename, sep = "|")

join <- function(x) paste(x, collapse = ";")
FIELDS <- c("source", "folder", "filename", "pages", "family", "kind", "module",
            "progress", "multi", "rule", "wb_project", "wb_report", "afdb_code",
            "gef_id", "gcf_fp", "af_id", "md5", "cover")

# everything detection can say about a document, from its first pages
describe <- function(pages) {
  det  <- detect_family(pages)
  info <- family_info(det$family)
  ids  <- extract_ids(family_head(pages))
  list(family = det$family, kind = det$kind, module = info$module,
       progress = isTRUE(info$progress), multi = isTRUE(info$multi),
       rule = substr(det$rule, 1, 60),
       wb_project = join(ids$wb_project), wb_report = join(ids$wb_report),
       afdb_code = join(ids$afdb_code), gef_id = join(ids$gef_id),
       gcf_fp = join(ids$gcf_fp), af_id = join(ids$af_id),
       cover = substr(gsub("\\s+", " ", pages[1]), 1, 200))
}

report <- function() {
  cen <- read.csv(OUT, stringsAsFactors = FALSE, colClasses = "character")
  cat("\nfamily x source (all scanned folders, in scope and parked)\n")
  print(addmargins(table(family = cen$family, source = cen$source)))
  cat("\nfamily -> extraction module\n")
  mods <- unique(cen[, c("family", "module")])
  mods <- mods[order(mods$module, mods$family), ]
  for (k in seq_len(nrow(mods)))
    cat(sprintf("  %-24s -> %s\n", mods$family[k], mods$module[k]))
  cat("\nwritten:", OUT, "\n")
}

## ---- rules changed: re-run detection over the cached cover pages ------------
if (REDETECT) {
  stopifnot(file.exists(OUT), length(heads) > 0)
  cen <- read.csv(OUT, stringsAsFactors = FALSE, colClasses = "character")
  hit <- 0
  for (i in seq_len(nrow(cen))) {
    pg <- heads[[key_of(cen$source[i], cen$folder[i], cen$filename[i])]]
    if (is.null(pg) || !length(pg)) next
    d <- describe(pg)
    for (k in names(d)) cen[[k]][i] <- as.character(d[[k]])
    hit <- hit + 1
  }
  write.csv(cen[FIELDS], OUT, row.names = FALSE)
  cat("re-detected", hit, "of", nrow(cen), "rows from the cache\n")
  report()
  quit(save = "no")
}

# OneDrive paths run past what Windows file APIs accept; work on a short copy
short_path <- function(p) {
  if (nchar(p) <= 250) return(p)
  short <- file.path(tempdir(), paste0("c", abs(sum(utf8ToInt(p))) %% 1e8, ".pdf"))
  ok <- suppressWarnings(file.copy(paste0("\\\\?\\", gsub("/", "\\\\", p)), short,
                                   overwrite = TRUE))
  if (!ok) ok <- suppressWarnings(file.copy(p, short, overwrite = TRUE))
  if (ok) short else NA_character_
}

# the first n pages only: a 200-page evaluation should not be rendered whole
# to learn what its cover says
first_pages <- function(p, n = 3) {
  np <- tryCatch(pdf_length(p), error = function(e) NA_integer_)
  if (is.na(np)) return(list(pages = character(0), n = NA_integer_))
  sub <- tryCatch({
    tmp <- tempfile(fileext = ".pdf")
    pdf_subset(p, pages = seq_len(min(n, np)), output = tmp)
    tmp
  }, error = function(e) p)
  pg <- tryCatch(pdf_text(sub), error = function(e) character(0))
  if (identical(sub, p) && length(pg) > n) pg <- pg[seq_len(n)]
  if (!identical(sub, p)) unlink(sub)
  list(pages = pg, n = np)
}

# every file in every scanned folder
files <- do.call(rbind, lapply(names(SCAN_DIRS), function(s) {
  if (nzchar(SRC) && s != SRC) return(NULL)
  do.call(rbind, lapply(SCAN_DIRS[[s]], function(rel) {
    d  <- file.path(DOCS_ROOT, rel)
    fs <- list.files(d, pattern = "\\.(pdf|PDF)$")
    if (!length(fs)) return(NULL)
    data.frame(source = s, folder = rel, filename = fs, path = file.path(d, fs),
               stringsAsFactors = FALSE)
  }))
}))
cat("files found:", nrow(files), "\n")

done <- character(0)
if (file.exists(OUT) && REFRESH) {
  if (nzchar(SRC)) {
    prev <- read.csv(OUT, stringsAsFactors = FALSE, colClasses = "character")
    write.csv(prev[prev$source != SRC, FIELDS], OUT, row.names = FALSE)
  } else unlink(OUT)
}
if (file.exists(OUT)) {
  prev <- read.csv(OUT, stringsAsFactors = FALSE, colClasses = "character")
  # files that left the scanned folders (moved to duplicates/, re-parked,
  # deleted) drop out of the census so nothing downstream sees a ghost
  present <- paste(files$source, files$folder, files$filename)
  scanned <- if (nzchar(SRC)) prev$source == SRC else rep(TRUE, nrow(prev))
  gone <- scanned & !(paste(prev$source, prev$folder, prev$filename) %in% present)
  if (any(gone)) {
    cat("pruned", sum(gone), "census rows whose file is no longer in a scanned folder\n")
    prev <- prev[!gone, ]
    write.csv(prev[FIELDS], OUT, row.names = FALSE)
  }
  done <- paste(prev$source, prev$folder, prev$filename)
}
todo <- files[!(paste(files$source, files$folder, files$filename) %in% done), ]
cat("already in census:", length(done), "| to read:", nrow(todo), "\n")

for (i in seq_len(nrow(todo))) {
  f <- todo[i, ]
  p <- short_path(f$path)
  row <- as.list(setNames(rep("", length(FIELDS)), FIELDS))
  row$source <- f$source; row$folder <- f$folder; row$filename <- f$filename
  row$family <- "unreadable"; row$module <- "none"; row$progress <- FALSE; row$multi <- FALSE
  if (!is.na(p)) {
    fp <- first_pages(p)
    row$pages <- fp$n
    if (length(fp$pages)) {
      heads[[key_of(f$source, f$folder, f$filename)]] <- fp$pages
      d <- describe(fp$pages)
      for (k in names(d)) row[[k]] <- d[[k]]
    }
    row$md5 <- unname(tools::md5sum(p))
  }
  line <- as.data.frame(row[FIELDS], stringsAsFactors = FALSE)
  write.table(line, OUT, sep = ",", row.names = FALSE, na = "",
              col.names = !file.exists(OUT), append = file.exists(OUT), qmethod = "double")
  if (i %% 25 == 0 || i == nrow(todo)) {
    saveRDS(heads, HEADS)
    cat(sprintf("  %4d / %d  %-9s %-22s %s\n", i, nrow(todo), f$source, row$family,
                substr(f$filename, 1, 48)))
  }
}
saveRDS(heads, HEADS)
report()
