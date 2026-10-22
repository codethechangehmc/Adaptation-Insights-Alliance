##############################################################################
# score_locations.R — QC the location-specific extraction against Lucy's
# manual gold rows (catalogues/gold_v1_locations.csv, from working DB v02).
#
# Rows have no natural key, so scoring is two-level:
#   1. SET-BASED per project: row counts, location coverage (names, via the
#      registry), result-value coverage.
#   2. ALIGNMENT: each gold row is matched to its best pipeline row (value +
#      location + text overlap), then fields are compared on the aligned
#      pairs. An alignment CSV is written for human review.
#
# Usage:
#   Rscript R/08_quality/score_locations.R [harmonized.csv] [gold.csv]
##############################################################################

suppressPackageStartupMessages({ library(openxlsx) })

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- if (length(full)) normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", "..")) else getwd()
source(file.path(REPO, "R", "00_shared", "paths.R"))
OUT_DIR <- Sys.getenv("EXTRACT_OUT_DIR", file.path(REPO, "outputs", "extraction", "locations"))

args <- commandArgs(trailingOnly = TRUE)
HFILE <- if (length(args) >= 1) args[1] else {
  fs <- list.files(OUT_DIR, pattern = "^locations_harmonized_.*\\.csv$", full.names = TRUE)
  stopifnot("no harmonized locations CSV found" = length(fs) > 0)
  fs[which.max(file.mtime(fs))]
}
GFILE <- if (length(args) >= 2) args[2] else file.path(REPO, "catalogues", "gold_v1_locations.csv")
# optional: the Session 1 enumeration (s1loc_locations_*.csv) gives a second
# coverage figure, the gold sites the model NAMED anywhere, beside the sites
# that reached a row (29 Sep 2026)
EFILE <- if (length(args) >= 3) args[3] else ""
# optional 4th: the Session 1 rows, to tell a value never read from a value read
# but not chosen among the site's main results
RFILE <- if (length(args) >= 4) args[4] else ""
cat("pipeline:", HFILE, "\ngold:    ", GFILE, if (nzchar(EFILE)) paste0("\nnamed:    ", EFILE), "\n\n")

h <- read.csv(HFILE, stringsAsFactors = FALSE, colClasses = "character", check.names = FALSE)
g <- read.csv(GFILE, stringsAsFactors = FALSE, colClasses = "character", check.names = FALSE)
h[is.na(h)] <- ""; g[is.na(g)] <- ""

## code -> name/country via the template registry + this run's proposals
REG <- read.xlsx(TEMPLATE_XLSX, sheet = "location_codes")
REG[is.na(REG)] <- ""
prop_csv <- file.path(VOCAB_DIR, "proposed_new_locations.csv")
if (file.exists(prop_csv)) {
  pr <- read.csv(prop_csv, stringsAsFactors = FALSE, colClasses = "character")
  pr[is.na(pr)] <- ""
  REG <- rbind(REG[, c("location_name", "location_id", "location_country")],
               pr[, c("location_name", "location_id", "location_country")])
} else REG <- REG[, c("location_name", "location_id", "location_country")]
code2name <- setNames(REG$location_name, REG$location_id)

ALIAS <- local({
  p <- file.path(VOCAB_DIR, "location_aliases.csv")
  if (!file.exists(p)) return(NULL)
  a <- read.csv(p, stringsAsFactors = FALSE, colClasses = "character")
  a[is.na(a)] <- ""; a[nzchar(a$name) & nzchar(a$alias), , drop = FALSE]
})
norm_loc <- function(x) {
  x <- iconv(x, "UTF-8", "ASCII//TRANSLIT", sub = " ")
  x <- tolower(x)
  x <- gsub("\\s*\\([^)]*\\)", " ", x)
  x <- gsub("\\b(district|region|province|commune|county|sub-?county|village|town|city|watershed|department|the|of)\\b", " ", x)
  x <- gsub("[^a-z0-9]+", " ", x)
  x <- trimws(gsub("\\s+", " ", x))
  # canonicalise through the alias table so the same place scores as the same
  if (!is.null(ALIAS)) {
    key <- tolower(gsub("[^a-z0-9]+", " ",
             tolower(iconv(ALIAS$alias, "UTF-8", "ASCII//TRANSLIT", sub = " "))))
    key <- trimws(gsub("\\s+", " ", key))
    canon <- tolower(gsub("[^a-z0-9]+", " ",
               tolower(iconv(ALIAS$name, "UTF-8", "ASCII//TRANSLIT", sub = " "))))
    canon <- trimws(gsub("\\s+", " ", canon))
    canon <- gsub("\\b(district|region|province|commune|county|sub-?county|village|town|city|watershed|department|the|of)\\b", " ", canon)
    canon <- trimws(gsub("\\s+", " ", canon))
    key <- gsub("\\b(district|region|province|commune|county|sub-?county|village|town|city|watershed|department|the|of)\\b", " ", key)
    key <- trimws(gsub("\\s+", " ", key))
    m <- match(x, key)
    x <- ifelse(is.na(m), x, canon[m])
  }
  x
}
codes_to_names <- function(codes) {
  cds <- trimws(strsplit(codes, ";")[[1]])
  vapply(cds, function(cd) if (cd %in% names(code2name)) code2name[[cd]] else cd,
         character(1), USE.NAMES = FALSE)
}
norm_one_num <- function(x) {
  x <- gsub("[^0-9.]", "", x)
  v <- suppressWarnings(as.numeric(x))
  vapply(v, function(z) if (is.na(z)) "" else
    format(z, scientific = FALSE, trim = TRUE, digits = 15), character(1))
}
# a cell may legitimately hold several numbers ("95; 2,338,654"): return them
# all, never glue their digits together
norm_num <- function(x) {
  out <- unlist(lapply(x, function(s) {
    parts <- trimws(strsplit(as.character(s), "\\s*[;,]?\\s*(;|\\band\\b)\\s*|;")[[1]])
    parts <- parts[nzchar(parts)]
    if (!length(parts)) parts <- as.character(s)
    norm_one_num(parts)
  }))
  out[nzchar(out)]
}
toks <- function(x) {
  t <- strsplit(norm_loc(x), " ")[[1]]
  unique(t[nchar(t) > 3])
}
jac <- function(a, b) {
  if (!length(a) || !length(b)) return(0)
  length(intersect(a, b)) / length(union(a, b))
}

## gold location names come pre-translated in location_names
g$loc_names <- lapply(ifelse(nzchar(g$location_names), g$location_names, g$location),
                      function(x) norm_loc(trimws(strsplit(x, ";")[[1]])))
h$loc_names <- lapply(h$location, function(x) norm_loc(codes_to_names(x)))
enum <- if (nzchar(EFILE) && file.exists(EFILE)) {
  e <- read.csv(EFILE, stringsAsFactors = FALSE, colClasses = "character"); e[is.na(e)] <- ""; e
} else NULL
s1rows <- if (nzchar(RFILE) && file.exists(RFILE)) {
  e <- read.csv(RFILE, stringsAsFactors = FALSE, colClasses = "character"); e[is.na(e)] <- ""; e
} else NULL

summary_rows <- list(); align_rows <- list()
for (pc in sort(unique(g$project_code))) {
  gp <- g[g$project_code == pc, ]; hp <- h[h$project_code == pc, ]
  g_locs <- unique(unlist(gp$loc_names)); g_locs <- g_locs[nzchar(g_locs) & g_locs != "unspecified"]
  h_locs <- unique(unlist(hp$loc_names)); h_locs <- h_locs[nzchar(h_locs) & h_locs != "unspecified"]
  # a gold location counts as covered on exact match OR word-level containment
  # ("tanzania" is covered by "mainland tanzania bagamoyo"), both directions
  covers <- function(g) any(vapply(h_locs, function(h)
    g == h || grepl(paste0("\\b", g, "\\b"), h) || grepl(paste0("\\b", h, "\\b"), g),
    logical(1)))
  loc_hit <- sum(vapply(g_locs, covers, logical(1)))
  named_hit <- NA_integer_
  if (!is.null(enum)) {
    e_locs <- unique(c(h_locs, norm_loc(enum$location_name[enum$project_code_hint == pc])))
    e_locs <- e_locs[nzchar(e_locs)]
    named_hit <- sum(vapply(g_locs, function(g) any(vapply(e_locs, function(h)
      g == h || grepl(paste0("\\b", g, "\\b"), h) || grepl(paste0("\\b", h, "\\b"), g), logical(1))), logical(1)))
  }
  # a gold cell may carry " || " alternates; the row counts as covered when ANY
  # alternate is found (same convention as the general-fields scorer)
  g_alt <- lapply(gp$result_value, function(x) {
    a <- norm_num(trimws(strsplit(x, "\\|\\|")[[1]])); a[nzchar(a)] })
  g_alt <- Filter(length, g_alt)
  h_vals <- unique(norm_num(hp$result_value)); h_vals <- h_vals[nzchar(h_vals)]
  val_hit <- sum(vapply(g_alt, function(a) any(a %in% h_vals), logical(1)))
  g_vals <- g_alt
  read_hit <- NA_integer_
  if (!is.null(s1rows)) {
    s_vals <- unique(norm_num(s1rows$result_value[s1rows$project_code_hint == pc]))
    s_vals <- unique(c(h_vals, s_vals[nzchar(s_vals)]))
    read_hit <- sum(vapply(g_alt, function(a) any(a %in% s_vals), logical(1)))
  }

  # align each gold row to its best pipeline row
  lvl_ok <- sub_ok <- ben_ok <- n_aligned <- 0
  for (i in seq_len(nrow(gp))) {
    if (!nrow(hp)) break
    sc <- vapply(seq_len(nrow(hp)), function(j) {
      s <- 0
      gv <- norm_num(trimws(strsplit(gp$result_value[i], "\\|\\|")[[1]]))
      hvj <- norm_num(hp$result_value[j])
      if (length(gv) && length(hvj) && any(hvj %in% gv)) s <- s + 3
      s <- s + 2 * jac(gp$loc_names[[i]], hp$loc_names[[j]])
      s <- s + jac(toks(gp$result_stated[i]), toks(hp$result_stated[j]))
      s <- s + jac(toks(gp$intervention_stated[i]), toks(hp$intervention_stated[j]))
      s
    }, numeric(1))
    j <- which.max(sc)
    matched <- sc[j] >= 0.8
    if (matched) {
      n_aligned <- n_aligned + 1
      if (tolower(gp$result_level[i]) == tolower(hp$result_level[j]) &&
          nzchar(gp$result_level[i])) lvl_ok <- lvl_ok + 1
      if (tolower(gp$subsector_type[i]) == tolower(hp$`subsector type`[j]) &&
          nzchar(gp$subsector_type[i])) sub_ok <- sub_ok + 1
      if (tolower(gp$target_beneficiary[i]) == tolower(hp$target_beneficiary[j]) &&
          nzchar(gp$target_beneficiary[i])) ben_ok <- ben_ok + 1
    }
    align_rows[[length(align_rows) + 1]] <- data.frame(
      project = pc, gold_row = gp$row_id[i], matched = matched,
      score = round(sc[j], 2),
      gold_loc = substr(gp$location_names[i], 1, 40),
      pipe_loc = substr(paste(codes_to_names(hp$location[j]), collapse = "; "), 1, 40),
      gold_value = gp$result_value[i], pipe_value = hp$result_value[j],
      gold_level = gp$result_level[i], pipe_level = hp$result_level[j],
      gold_subsector = gp$subsector_type[i], pipe_subsector = hp$`subsector type`[j],
      gold_beneficiary = gp$target_beneficiary[i], pipe_beneficiary = hp$target_beneficiary[j],
      gold_result = substr(gp$result_stated[i], 1, 70),
      pipe_result = substr(hp$result_stated[j], 1, 70),
      stringsAsFactors = FALSE)
  }
  summary_rows[[pc]] <- data.frame(
    project = pc, rows_gold = nrow(gp), rows_pipe = nrow(hp),
    gold_locs = length(g_locs), locs_covered = loc_hit, locs_named = named_hit,
    extra_pipe_locs = length(setdiff(h_locs, g_locs)),
    gold_values = length(g_vals), values_covered = val_hit, values_read = read_hit,
    rows_aligned = n_aligned,
    level_agree = lvl_ok, subsector_agree = sub_ok, beneficiary_agree = ben_ok,
    stringsAsFactors = FALSE)
}
S <- do.call(rbind, summary_rows)
A <- do.call(rbind, align_rows)

tag <- paste0(sub("^locations_harmonized_", "", sub("\\.csv$", "", basename(HFILE))),
              "_vs_", sub("^(gold_v1_|claude_)", "", sub("\\.csv$", "", basename(GFILE))))
dir.create(SCORES_DIR, recursive = TRUE, showWarnings = FALSE)
sf <- file.path(SCORES_DIR, paste0("score_locations_", tag, ".csv"))
af <- file.path(SCORES_DIR, paste0("align_locations_", tag, ".csv"))
write.csv(S, sf, row.names = FALSE); write.csv(A, af, row.names = FALSE)

print(S, row.names = FALSE)
cat(sprintf(paste0(
  "\nTOTALS: gold rows %d | pipeline rows %d | gold locations covered %d/%d",
  " (%.0f%%)\n        gold result values found %d/%d (%.0f%%) | gold rows",
  " aligned %d/%d\n        on aligned rows - level %d, subsector %d,",
  " beneficiary %d agree\n"),
  sum(S$rows_gold), sum(S$rows_pipe), sum(S$locs_covered), sum(S$gold_locs),
  100 * sum(S$locs_covered) / max(1, sum(S$gold_locs)),
  sum(S$values_covered), sum(S$gold_values),
  100 * sum(S$values_covered) / max(1, sum(S$gold_values)),
  sum(S$rows_aligned), sum(S$rows_gold),
  sum(S$level_agree), sum(S$subsector_agree), sum(S$beneficiary_agree)))
if (!is.null(s1rows)) cat(sprintf(paste0("        gold result values PRESENT in Session 1 %d/%d (%.0f%%)",
  " - the rest were never read;\n        the gap to the %d kept is the choice of each site's main results\n"),
  sum(S$values_read, na.rm = TRUE), sum(S$gold_values),
  100 * sum(S$values_read, na.rm = TRUE) / max(1, sum(S$gold_values)), sum(S$values_covered)))
if (!is.null(enum)) cat(sprintf("        gold locations named anywhere by the model %d/%d (%.0f%%)\n",
  sum(S$locs_named, na.rm = TRUE), sum(S$gold_locs), 100 * sum(S$locs_named, na.rm = TRUE) / max(1, sum(S$gold_locs))))
cat("\nwritten:", sf, "\n         ", af, "\n")
