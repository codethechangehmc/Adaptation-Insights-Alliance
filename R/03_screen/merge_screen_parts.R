# merge_screen_parts.R - fold parallel screening shards into scope_screen.csv.
#
# screen_scope.R can run as several processes at once, each writing its own
# file under 04_Screening/inputs/working/scope_screen_parts/ (--out=working/scope_screen_parts/x.csv,
# --shard=k/n). This folds those files into the one scope_screen.csv the rest
# of the pipeline reads: one row per (source, filename), the newest wins,
# columns in the screener's order. The part files are left in place so a
# shard can be resumed; they are ignored by everything else.
#
#   Rscript R/03_screen/merge_screen_parts.R
#   -> 04_Screening/scope_screen.csv

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."),
                      mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))

MAIN  <- file.path(SCREEN_DIR, "scope_screen.csv")
PARTS <- list.files(file.path(SCREEN_DIR, "inputs", "working", "scope_screen_parts"), pattern = "\\.csv$",
                    full.names = TRUE)
rd <- function(f) {
  d <- tryCatch(read.csv(f, stringsAsFactors = FALSE, colClasses = "character",
                         encoding = "UTF-8"), error = function(e) NULL)
  if (is.null(d) || !nrow(d)) return(NULL)
  d$.file <- basename(f); d$.mtime <- as.numeric(file.info(f)$mtime)
  d
}
pieces <- Filter(Negate(is.null), lapply(c(if (file.exists(MAIN)) MAIN, PARTS), rd))
stopifnot(length(pieces) > 0)
cols <- names(pieces[[1]]); cols <- cols[!cols %in% c(".file", ".mtime")]
for (i in seq_along(pieces)) for (cn in cols) if (!cn %in% names(pieces[[i]])) pieces[[i]][[cn]] <- ""
all <- do.call(rbind, lapply(pieces, function(d) d[c(cols, ".file", ".mtime")]))
all <- all[order(all$.mtime), ]                  # newest last, so it wins below
key <- paste(all$source, all$filename)
all <- all[!duplicated(key, fromLast = TRUE), cols]
all <- all[order(all$source, all$filename), ]
write.csv(all, MAIN, row.names = FALSE, na = "", fileEncoding = "UTF-8")
cat("merged", length(pieces), "files ->", nrow(all), "judgements in", MAIN, "\n")
print(addmargins(table(source = all$source, verdict = all$verdict)))
cat("\nfamily agreement with the rule:\n"); print(table(all$family_agrees, useNA = "ifany"))
