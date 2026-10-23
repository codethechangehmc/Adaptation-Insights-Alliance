suppressPackageStartupMessages(library(openxlsx))
# check_actor_countries.R - does the matcher find the registry's own national
# bodies when a document writes them the way prompt s1-v2.3 asks ("body,
# Country"), without the country in a document that names it, in capitals,
# with the country in brackets, by acronym, or with a redundant country
# appended to a name that already carries one? Every registry row with a
# country tail is written each way and resolved; the outcome per variant is
# right code / wrong code / nothing, with the first failures listed. Run it
# after a registry or matcher change.
#
#   Rscript R/07_review/check_actor_countries.R
#
# Wrong answers with the country present point at registry rows that share a
# name or an acronym (see 04_Screening/inputs/reports/registry_duplicates.csv).

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
source(file.path(REPO, "R", "00_shared", "actor_names.R"))
reg <- actor_registry(TEMPLATE_XLSX)
syn <- read.csv(file.path(REPO, "catalogues", "actor_synonyms.csv"), stringsAsFactors = FALSE, encoding = "UTF-8")
IDX <- actor_index(reg, syn); CIDX <- actor_country_index(reg)
cat("registry:", nrow(reg), "| with a country tail:", sum(nzchar(CIDX$tail)), "\n")

# heads that exist in several countries: the country is essential there
dup <- table(CIDX$head[nzchar(CIDX$tail)]); dup <- dup[dup > 1]
cat("bodies that exist in more than one country:", length(dup), "\n")
print(head(sort(dup, decreasing = TRUE), 12))

resolve <- function(name, ctx) {
  cd <- match_actor_det(name, IDX)$code
  if (is.na(cd)) cd <- match_actor_country(name, ctx, CIDX)
  cd
}
outcome <- function(got, want) if (is.na(got)) "none" else if (identical(got, want)) "right" else "wrong"

nat <- which(nzchar(CIDX$tail))
raw_tail <- vapply(reg$name[nat], function(nm) trimws(sub("^.*,", "", nm)), character(1), USE.NAMES = FALSE)
raw_head <- vapply(reg$name[nat], function(nm) trimws(sub(",[^,]*$", "", nm)), character(1), USE.NAMES = FALSE)
variants <- list(
  "body, Country (as the prompt asks)"       = function(i) list(name = paste0(raw_head[i], ", ", raw_tail[i]), ctx = ""),
  "BODY, COUNTRY in capitals"                = function(i) list(name = toupper(paste0(raw_head[i], ", ", raw_tail[i])), ctx = ""),
  "body (Country)"                           = function(i) list(name = paste0(raw_head[i], " (", raw_tail[i], ")"), ctx = ""),
  "body alone, document names the country"   = function(i) list(name = raw_head[i], ctx = actor_nrm(raw_tail[i])),
  "body alone, no context (old extractions)" = function(i) list(name = raw_head[i], ctx = ""),
  "body with & for and, Country"             = function(i) list(name = paste0(gsub(" and ", " & ", raw_head[i]), ", ", raw_tail[i]), ctx = ""),
  "acronym alone, document names the country"= function(i) if (nzchar(reg$acro[nat][i]) && nchar(reg$acro[nat][i]) >= 3) list(name = reg$acro[nat][i], ctx = actor_nrm(raw_tail[i])) else NULL
)
res <- list()
for (v in names(variants)) {
  out <- character(0); fails <- character(0)
  for (i in seq_along(nat)) {
    x <- variants[[v]](i); if (is.null(x)) next
    got <- resolve(x$name, x$ctx); o <- outcome(got, reg$code[nat][i])
    out <- c(out, o)
    if (o != "right" && length(fails) < 6) fails <- c(fails, sprintf("%s -> %s [%s]", x$name, if (is.na(got)) "none" else paste(got, reg$name[reg$code == got][1]), reg$code[nat][i]))
  }
  t <- table(factor(out, levels = c("right", "wrong", "none")))
  cat(sprintf("\n%-44s n=%d right %d (%.0f%%) wrong %d none %d\n", v, length(out), t["right"], 100 * t["right"] / length(out), t["wrong"], t["none"]))
  for (f in fails) cat("     ", f, "\n")
  res[[v]] <- t
}

# registry names that carry the country inside the name (no comma), written
# by the model with ", Country" appended
inside <- which(!nzchar(CIDX$tail) & grepl("kenya|zambia|malawi|ethiopia|mozambique|rwanda|uganda|tanzania|ghana|nigeria|senegal|mali|niger|burkina|benin|togo|cameroon|zimbabwe|namibia|botswana|lesotho|madagascar|sudan|egypt|morocco|tunisia|algeria|somalia|angola|congo|liberia|sierra leone|gambia|guinea|chad|burundi|mauritania|mauritius|eswatini|djibouti|eritrea|comoros|seychelles|gabon", reg$nname))
country_word <- vapply(reg$nname[inside], function(n) regmatches(n, regexpr("kenya|zambia|malawi|ethiopia|mozambique|rwanda|uganda|tanzania|ghana|nigeria|senegal|mali|niger|burkina faso|burkina|benin|togo|cameroon|zimbabwe|namibia|botswana|lesotho|madagascar|sudan|egypt|morocco|tunisia|algeria|somalia|angola|congo|liberia|sierra leone|gambia|guinea|chad|burundi|mauritania|mauritius|eswatini|djibouti|eritrea|comoros|seychelles|gabon", n)), character(1))
out <- character(0); fails <- character(0)
for (j in seq_along(inside)) {
  i <- inside[j]; nm <- paste0(reg$name[i], ", ", tools::toTitleCase(country_word[j]))
  got <- resolve(nm, ""); o <- outcome(got, reg$code[i]); out <- c(out, o)
  if (o != "right" && length(fails) < 6) fails <- c(fails, sprintf("%s -> %s [%s]", nm, if (is.na(got)) "none" else got, reg$code[i]))
}
t <- table(factor(out, levels = c("right", "wrong", "none")))
cat(sprintf("\n%-44s n=%d right %d (%.0f%%) wrong %d none %d\n", "country inside the name, ', Country' appended", length(out), t["right"], 100 * t["right"] / length(out), t["wrong"], t["none"]))
for (f in fails) cat("     ", f, "\n")
