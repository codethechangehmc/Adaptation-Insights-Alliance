##############################################################################
# make_qc_assignment.R — decide which consultant checks which project, and
# write catalogues/qc_assignment.csv for build_qc_workbooks.R to read.
#
# Two rules, and they pull against each other:
#
#   Balance by WORK, not by project count. A project with 60 location rows is
#   ten times the job of one with six, so splitting 656 projects three ways
#   would leave one person with twice the work and nobody would notice until
#   they were months behind.
#
#   Keep a consultant inside one source at a time. Twenty-five World Bank
#   completion reports in a row is far faster than twenty-five mixed
#   documents, because the layout, the vocabulary and the traps stay put.
#
# So projects are dealt out source by source, each one going to whoever is
# furthest behind. Each consultant ends up with contiguous blocks per source
# and a comparable total.
#
#   Rscript R/07_review/make_qc_assignment.R --consultants LM,AB,NJ [--run <file>] [--dry]
##############################################################################

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))

args <- commandArgs(trailingOnly = TRUE)
opt  <- function(flag, default = "") {
  i <- which(args == flag); if (length(i) && length(args) > i[1]) args[i[1] + 1] else default
}
DRY  <- any(args == "--dry")
WHO  <- trimws(strsplit(opt("--consultants", "LM,AB,NJ"), ",")[[1]])
WHO  <- WHO[nzchar(WHO)]
stopifnot("need at least one consultant" = length(WHO) > 0)
OUT_EXTRACT <- Sys.getenv("EXTRACT_OUT_DIR", file.path(REPO, "outputs", "extraction"))

rd <- function(f) {
  d <- read.csv(f, stringsAsFactors = FALSE, colClasses = "character", check.names = FALSE)
  d[is.na(d)] <- ""; d
}
newest_in <- function(dir, pat, exclude = NULL) {
  f <- list.files(dir, pattern = pat, full.names = TRUE)
  if (!is.null(exclude)) f <- f[!grepl(exclude, basename(f))]
  if (!length(f)) return(NA_character_)
  f[which.max(file.mtime(f))]
}

GEN <- opt("--run")
if (!nzchar(GEN))
  GEN <- newest_in(OUT_EXTRACT, "^harmonized_.*\\.csv$", exclude = "^harmonized_diagnostics_")
stopifnot("no harmonised run found - run harmonize.R first" = !is.na(GEN) && nzchar(GEN))
LOCF <- newest_in(file.path(OUT_EXTRACT, "locations"), "^locations_harmonized_.*\\.csv$")

G <- rd(GEN)
L <- if (!is.na(LOCF)) rd(LOCF) else NULL
cat("run:      ", basename(GEN), "\n")
cat("locations:", if (is.na(LOCF)) "(none)" else basename(LOCF), "\n")

codes <- unique(G$project_code); codes <- codes[nzchar(codes)]

## ---- effort per project ----------------------------------------------------
# A general row is a whole template to read; a location row is one line. The
# weights are a rough ratio, not a measurement, and only the balance between
# consultants depends on them.
W_GENERAL <- 36L   # roughly one cell per template column
W_LOCATION <- 20L
loc_n <- {
  if (is.null(L) || !"project_code" %in% names(L)) setNames(integer(0), character(0))
  else table(L$project_code)
}
effort <- vapply(codes, function(pc) {
  g <- sum(G$project_code == pc)
  l <- if (pc %in% names(loc_n)) as.integer(loc_n[[pc]]) else 0L
  g * W_GENERAL + l * W_LOCATION
}, integer(1))

source_of <- function(pc) {
  s <- sub(":.*$", "", pc)
  if (identical(s, pc)) "pilot" else s          # P001 etc. carry no source prefix
}
src <- vapply(codes, source_of, character(1))

## ---- deal out, source by source, to whoever is furthest behind -------------
load <- setNames(rep(0L, length(WHO)), WHO)
assigned <- character(length(codes)); names(assigned) <- codes
for (s in unique(src)) {
  in_s <- codes[src == s]
  in_s <- in_s[order(effort[in_s], decreasing = TRUE)]   # biggest first balances better
  for (pc in in_s) {
    pick <- names(load)[which.min(load)]
    assigned[pc] <- pick
    load[pick] <- load[pick] + effort[pc]
  }
}

out <- data.frame(project_code = codes, consultant = unname(assigned[codes]),
                  source = unname(src), effort = unname(effort[codes]),
                  stringsAsFactors = FALSE)
out <- out[order(out$consultant, out$source, -out$effort), ]

f <- file.path(REPO, "catalogues", "qc_assignment.csv")
if (!DRY) {
  tmp <- paste0(f, ".tmp")                      # OneDrive: write then rename
  write.csv(out, tmp, row.names = FALSE, na = "")
  invisible(file.rename(tmp, f))
}

cat("\nprojects:", nrow(out), "\n\nper consultant:\n")
for (w in WHO) {
  k <- out$consultant == w
  cat(sprintf("  %-10s %4d projects  effort %7d  sources: %s\n", w, sum(k), sum(out$effort[k]),
              paste(sort(unique(out$source[k])), collapse = ", ")))
}
sp <- range(vapply(WHO, function(w) sum(out$effort[out$consultant == w]), numeric(1)))
cat(sprintf("\nheaviest/lightest load: %.2f  (1.00 would be a perfect split)\n",
            if (sp[1] > 0) sp[2] / sp[1] else NA_real_))
cat(if (DRY) "\n--dry: nothing written\n" else paste("\nwritten:", f, "\n"))
