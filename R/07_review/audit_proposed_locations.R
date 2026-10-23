##############################################################################
# audit_proposed_locations.R — check every proposed new location against the
# template's location_codes registry before anyone types a coordinate.
#
# The matcher proposes a code whenever it cannot find an exact name+country
# match. That is deliberately cautious, so the proposal list contains three
# kinds of thing that must NOT become new codes:
#   - places already in the registry under a slightly different spelling
#   - entries that are not places at all (institutions, "nationwide", fragments)
#   - leftovers from earlier buggy runs (composite strings, non-African sites)
#
# This writes review/proposed_new_locations_AUDIT.xlsx with one verdict per
# proposal, the best registry candidates, and whether the current run still
# uses it. Nothing is deleted; the team decides from the audit sheet.
#
#   Rscript R/07_review/audit_proposed_locations.R
##############################################################################

suppressPackageStartupMessages({ library(openxlsx) })

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))

rd <- function(f) { d <- read.csv(f, stringsAsFactors = FALSE, colClasses = "character",
                                  check.names = FALSE); d[is.na(d)] <- ""; d }
REG <- read.xlsx(TEMPLATE_XLSX, sheet = "location_codes"); REG[is.na(REG)] <- ""
PR  <- rd(file.path(VOCAB_DIR, "proposed_new_locations.csv"))
ALIAS <- if (file.exists(file.path(VOCAB_DIR, "location_aliases.csv")))
  rd(file.path(VOCAB_DIR, "location_aliases.csv")) else NULL

# rows still used by the newest harmonised run
LOCDIR <- file.path(REPO, "outputs", "extraction", "locations")
hf <- list.files(LOCDIR, pattern = "^locations_harmonized_.*\\.csv$", full.names = TRUE)
in_use <- character(0)
if (length(hf)) {
  h <- rd(hf[which.max(file.mtime(hf))])
  in_use <- unique(trimws(unlist(strsplit(h$location, ";"))))
}

## ---- normalisation ---------------------------------------------------------
ADMIN <- "\\b(district|districts|region|regions|province|provinces|commune|county|sub-?county|village|villages|town|city|watershed|department|island|islands|area|areas|zone|zones|national|the|of|and|de|du|la|le)\\b"
nrm <- function(x) {
  x <- iconv(x, "UTF-8", "ASCII//TRANSLIT", sub = " ")
  x <- tolower(x)
  x <- gsub("\\([^)]*\\)|\\(|\\)", " ", x)      # parentheticals and stray brackets
  x <- gsub(ADMIN, " ", x)
  x <- gsub("[^a-z0-9]+", " ", x)
  trimws(gsub("\\s+", " ", x))
}
REG$nrm <- nrm(REG$location_name)
PR$nrm  <- nrm(PR$location_name)

alias_of <- function(nm) {
  if (is.null(ALIAS)) return(character(0))
  n <- nrm(nm)
  unique(c(ALIAS$alias[nrm(ALIAS$name) == n], ALIAS$name[nrm(ALIAS$alias) == n]))
}

# word-bounded: a substring test flagged "Chinamacondo District" (Mozambique)
# because it contains "china"
NON_AFRICA <- paste0("\\b(paraguay|indonesia|brazil|peru|ecuador|vietnam|",
  "philippines|india|china|colombia|mexico|bolivia|sintang|matopiba|chaco|",
  "piura|tumbes|virrila)\\b")

# two places with the same name in different countries are different places.
# Without this the audit matched Rwanda's "Northern and Western Provinces" to
# Zambia's "Northern western" and "Republic of Congo" to the DRC.
cnorm <- function(x) {
  x <- iconv(x, "UTF-8", "ASCII//TRANSLIT", sub = " "); x <- tolower(x)
  x <- gsub("\\b(republic|united|union|democratic|the|of|people s)\\b", " ", x)
  x <- gsub("[^a-z0-9]+", " ", x); trimws(gsub("\\s+", " ", x))
}
# country names travel under aliases too ("Comores" is "Comoros"), so resolve
# them through the same table before comparing
ccanon <- function(x) {
  y <- cnorm(x)
  if (is.null(ALIAS)) return(y)
  m <- match(y, cnorm(ALIAS$alias))
  ifelse(is.na(m), y, cnorm(ALIAS$name[m]))
}
country_ok <- function(a, b) {
  a <- ccanon(a); b <- ccanon(b)
  if (!nzchar(a) || !nzchar(b)) return(TRUE)      # unknown: do not rule out
  a == b                                          # "congo" != "democratic congo"
}
NOT_A_PLACE <- paste0("\\b(nationwide|general|case study|cooperatives?|regional school|",
  "secretariat|ministry|directorate|agency|institute|association|committee|",
  "programme|program|project|scheme|system|dgrh|siimaip|mimaip|adnap|dsfa|",
  "tafiri|zari|iiam|ccardesa|swiofc|unspecified|other|various|several|",
  "member countries|national level|countrywide)\\b")

## ---- per-proposal verdict ---------------------------------------------------
res <- vector("list", nrow(PR))
for (i in seq_len(nrow(PR))) {
  p <- PR[i, ]
  n <- p$nrm
  forms <- unique(c(n, nrm(alias_of(p$location_name))))
  forms <- forms[nzchar(forms)]

  ok <- vapply(REG$location_country, country_ok, logical(1), p$location_country)
  exact <- REG[REG$nrm %in% forms & nzchar(REG$nrm) & ok, ]
  contain <- if (nchar(n) >= 5)
    REG[nzchar(REG$nrm) & ok & (grepl(paste0("\\b", n, "\\b"), REG$nrm) |
                                grepl(paste0("\\b", REG$nrm, "\\b"), n)), ] else REG[0, ]
  dabs <- if (nchar(n) >= 3 && any(nzchar(REG$nrm)))
    as.numeric(adist(n, REG$nrm)) else rep(99, nrow(REG))
  d <- dabs / pmax(nchar(n), nchar(REG$nrm))
  d[!nzchar(REG$nrm) | !ok] <- 1
  near <- order(d)[1:min(3, length(d))]
  # short names generate spurious neighbours (Mansa/Manso, Male/Mali), so a
  # close spelling needs a small ABSOLUTE distance and the same country
  close <- min(d) <= 0.25 & min(dabs[ok & nzchar(REG$nrm)], Inf) <= 2

  dup_prop <- which(PR$nrm == n)
  dup_prop <- dup_prop[dup_prop != i & dup_prop < i]
  composite <- grepl("\\b(and|et|&)\\b", tolower(p$location_name)) &&
               grepl("provinces|districts|regions|villages|islands", tolower(p$location_name))
  # a bare all-caps token is an institution, not a place (IRAD, ITRAD, DSFA)
  acronym <- grepl("^[A-Z]{3,7}$", trimws(p$location_name))

  verdict <-
    if (composite)                                               "COMPOSITE - split it first"
    else if (nrow(exact))                                        "ALREADY IN REGISTRY"
    else if (grepl(NON_AFRICA, n))                               "OUTSIDE AFRICA - drop"
    else if (grepl(NOT_A_PLACE, n) || acronym || !nzchar(n))     "NOT A PLACE - check"
    else if (length(dup_prop))                                   "DUPLICATE OF EARLIER PROPOSAL"
    else if (nrow(contain))                                      "LIKELY IN REGISTRY - check"
    else if (close)                                              "CLOSE SPELLING - check"
    else                                                          "NEW - needs a code"

  cand <- if (nrow(exact)) exact else if (nrow(contain)) contain else REG[near, ]
  cand <- head(cand, 3)

  res[[i]] <- data.frame(
    verdict = verdict,
    proposed_name = p$location_name,
    proposed_country = p$location_country,
    suggested_code = p$location_id,
    still_used_in_latest_run = if (p$location_id %in% in_use) "yes" else "no",
    first_seen_project = p$first_seen_project,
    registry_match_code = paste(cand$location_id, collapse = " | "),
    registry_match_name = paste(cand$location_name, collapse = " | "),
    registry_match_country = paste(cand$location_country, collapse = " | "),
    closest_distance = round(min(d), 2),
    duplicate_of = if (length(dup_prop)) PR$location_id[dup_prop[1]] else "",
    needs_coordinates = if (verdict == "NEW - needs a code") "YES" else "",
    stringsAsFactors = FALSE)
}
A <- do.call(rbind, res)
ord <- c("ALREADY IN REGISTRY", "LIKELY IN REGISTRY - check", "CLOSE SPELLING - check", "COMPOSITE - split it first",
         "DUPLICATE OF EARLIER PROPOSAL", "NOT A PLACE - check", "OUTSIDE AFRICA - drop",
         "NEW - needs a code")
A <- A[order(match(A$verdict, ord), A$proposed_country, A$proposed_name), ]

cat("verdicts over", nrow(A), "proposals:\n")
print(table(factor(A$verdict, levels = ord)))
cat("\nof which still used by the latest run:\n")
print(table(A$verdict[A$still_used_in_latest_run == "yes"]))

## ---- registry coverage, for context ----------------------------------------
cov <- as.data.frame(sort(table(REG$location_country), decreasing = TRUE),
                     stringsAsFactors = FALSE)
names(cov) <- c("country", "codes_in_registry")
cov$share <- sprintf("%.0f%%", 100 * cov$codes_in_registry / nrow(REG))
newc <- as.data.frame(sort(table(A$proposed_country[A$verdict == "NEW - needs a code"]),
                           decreasing = TRUE), stringsAsFactors = FALSE)
if (nrow(newc)) names(newc) <- c("country", "new_locations_proposed") else
  newc <- data.frame(country = character(0), new_locations_proposed = integer(0))

wb <- createWorkbook()
hdr <- createStyle(textDecoration = "bold", border = "bottom", wrapText = TRUE)
add <- function(nm, df, w) { addWorksheet(wb, nm); writeData(wb, nm, df, headerStyle = hdr, withFilter = TRUE)
  freezePane(wb, nm, firstRow = TRUE); setColWidths(wb, nm, seq_along(df), w) }
add("audit", A, c(26, 34, 20, 14, 12, 12, 22, 34, 20, 10, 12, 12))
add("registry_coverage", cov, c(34, 18, 10))
add("new_by_country", newc, c(34, 22))
add("about", data.frame(what = c("generated", "registry rows", "proposals audited",
                                 "regenerate with", "note"),
  value = c(format(Sys.time(), "%Y-%m-%d %H:%M"), nrow(REG), nrow(A),
            "Rscript 07_Pipeline/R/07_review/audit_proposed_locations.R",
            "verdicts are suggestions - only ALREADY IN REGISTRY is decided by an exact or alias match"),
  stringsAsFactors = FALSE), c(20, 90))
f <- file.path(VOCAB_DIR, "proposed_new_locations_AUDIT.xlsx")
saveWorkbook(wb, f, overwrite = TRUE)
cat("\nwritten:", f, "\n")
