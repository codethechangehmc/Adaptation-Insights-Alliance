##############################################################################
# check_actor_synonyms.R - prove that no synonym points at two institutions,
# and that adding synonyms has not started matching the wrong one.
#
# Two halves, and the second is the one that matters.
#
#   POSITIVE cases say a name the registry writes differently still finds its
#   code. They prove the synonyms work.
#
#   NEGATIVE cases say a name must find NOTHING. They are the only thing that
#   catches a synonym which has quietly started matching the wrong body. A
#   three-letter acronym like ARC belongs to three different organisations in
#   this registry; if it ever resolves, something has gone wrong and a person
#   needs to know which synonym did it.
#
# Runs offline: no API key, no network, no model. Safe to run after every
# review batch, which is the point.
#
#   Rscript R/07_review/check_actor_synonyms.R
##############################################################################

suppressPackageStartupMessages({ library(openxlsx) })

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
source(file.path(REPO, "R", "00_shared", "actor_names.R"))

SYN_CSV <- file.path(REPO, "catalogues", "actor_synonyms.csv")
syn <- if (file.exists(SYN_CSV)) {
  d <- read_csv_utf8(SYN_CSV)
  if (nrow(d)) d else NULL
} else NULL

reg <- actor_registry(TEMPLATE_XLSX)
IDX <- actor_index(reg, syn)
cat("registry", nrow(reg), "actors | synonyms",
    if (is.null(syn)) 0 else nrow(syn),
    "| lookup forms", nrow(IDX$keys), "\n\n")

## ---- 1. no form may point at two institutions ------------------------------
# The whole guarantee in one test. A form that two codes claim cannot be used
# to decide anything, so if one is in the trusted tier the file is wrong.
# Compared against EVERY form in the index, not only against other synonyms.
# A trusted synonym that happens to equal a registry acronym another code also
# carries would otherwise win silently - which is what "ULB" did for the Free
# University of Brussels while the Free University of Burkina carries the same
# acronym.
trusted <- IDX$keys[IDX$keys$tier == "trusted", , drop = FALSE]
clash <- data.frame()
if (nrow(trusted)) {
  all_codes <- split(IDX$keys$code, IDX$keys$form)
  bad <- unique(trusted$form[vapply(trusted$form, function(f)
    length(unique(all_codes[[f]])) > 1, logical(1))])
  if (length(bad)) {
    clash <- do.call(rbind, lapply(bad, function(f) {
      k <- IDX$keys[IDX$keys$form == f, ]
      data.frame(form = f, codes = paste(unique(k$code), collapse = " / "),
                 synonyms = paste(unique(k$via[nzchar(k$via)]), collapse = " / "),
                 stringsAsFactors = FALSE)
    }))
  }
}
cat("OVERLAP CHECK: ")
if (nrow(clash)) {
  cat("FAILED -", nrow(clash), "trusted form(s) claimed by more than one code\n")
  print(utils::head(clash, 20))
} else cat("passed - no trusted synonym is claimed by two institutions\n")

## ---- 2. cases --------------------------------------------------------------
# expect: a code, "ANY" (any single code, used where the registry itself is
# duplicated), or "NONE" (must not resolve).
cases <- read.csv(text = '
query,expect,why
"African Development Bank",CON3,plain name
"AfDB",CON3,registry acronym
"World Bank",GLO18,plain name
"MercyCorps",USA52,missing space
"Centre for Coordination of Agricultural Research and Development for Southern Africa",ZA2,British spelling
"Instituto de Investigacao Agraria de Mocambique",MOZ5,accents dropped
"Zambia Agricultural Research Institute (ZARI)",ANY,registry holds it twice
"Rwanda Agriculture Board",RWA1,former name - needs a synonym
"NEPAD Planning and Coordinating Agency",CON14,former name - needs a synonym
"NEPAD",CON14,short form - needs a synonym
"ACRE Rwanda",CON26,country arm - needs a synonym
"TAF",NONE,three letters inside unrelated names
"ARC",NONE,three registry rows share this acronym
"CARE",NONE,shared acronym
"AA",NONE,two letters is not an identifier
"WB",NONE,two letters is not an identifier
"Ministry of Agriculture",NONE,many countries have one
"Congo",NONE,a country is not an organisation
"Project Coordination Unit",NONE,part of a project
"IDA-52030",NONE,a credit number
', stringsAsFactors = FALSE, strip.white = TRUE)

res <- do.call(rbind, lapply(seq_len(nrow(cases)), function(i) {
  r <- match_actor_det(cases$query[i], IDX)
  got <- if (is.na(r$code)) "NONE" else r$code
  ok <- if (cases$expect[i] == "ANY") got != "NONE" else got == cases$expect[i]
  data.frame(query = cases$query[i], expect = cases$expect[i], got = got,
             how = r$how, via = r$via, ok = ok, why = cases$why[i],
             stringsAsFactors = FALSE)
}))
pos <- res[res$expect != "NONE", ]; neg <- res[res$expect == "NONE", ]

cat(sprintf("\nPOSITIVE cases: %d of %d resolve as expected\n", sum(pos$ok), nrow(pos)))
for (i in which(!pos$ok))
  cat(sprintf("   want %-7s got %-7s  %s\n", pos$expect[i], pos$got[i], substr(pos$query[i], 1, 60)))

cat(sprintf("\nNEGATIVE cases: %d of %d correctly resolve to nothing\n", sum(neg$ok), nrow(neg)))
for (i in which(!neg$ok))
  cat(sprintf("   REGRESSION: '%s' now resolves to %s (%s%s) - %s\n",
              neg$query[i], neg$got[i], neg$how[i],
              if (nzchar(neg$via[i])) paste0(" via synonym '", neg$via[i], "'") else "",
              neg$why[i]))

## ---- 3. report -------------------------------------------------------------
f <- file.path(VOCAB_DIR, "actor_synonyms_AUDIT.xlsx")
wb <- createWorkbook()
hdr <- createStyle(textDecoration = "bold", fgFill = "#EEEEEE", border = "bottom")
add <- function(nm, df, widths = NULL) {
  if (is.null(df) || !nrow(df)) { df <- data.frame(none = "nothing to report"); widths <- NULL }
  addWorksheet(wb, nm); writeData(wb, nm, df, headerStyle = hdr, withFilter = TRUE)
  freezePane(wb, nm, firstRow = TRUE)
  setColWidths(wb, nm, cols = seq_along(df),
               widths = if (is.null(widths)) pmin(60, pmax(12, nchar(names(df)) + 4)) else widths)
}
add("cases", res, c(60, 10, 10, 12, 30, 8, 34))
add("overlaps", clash, c(40, 22, 46))
if (!is.null(syn)) {
  by_src <- as.data.frame(table(source = syn$source, tier = syn$tier, status = syn$status))
  add("synonyms_by_source", by_src[by_src$Freq > 0, ])
}
add("about", data.frame(
  what = c("registry actors", "synonyms", "lookup forms", "overlap check",
           "positive cases", "negative cases", "generated", "regenerate with"),
  value = c(nrow(reg), if (is.null(syn)) 0 else nrow(syn), nrow(IDX$keys),
            if (nrow(clash)) paste("FAILED:", nrow(clash), "clashes") else "passed",
            sprintf("%d/%d", sum(pos$ok), nrow(pos)),
            sprintf("%d/%d", sum(neg$ok), nrow(neg)),
            format(Sys.time(), "%Y-%m-%d %H:%M"),
            "Rscript 07_Pipeline/R/07_review/check_actor_synonyms.R"),
  stringsAsFactors = FALSE), c(20, 70))
saveWorkbook(wb, f, overwrite = TRUE)
cat("\nwritten:", f, "\n")

if (nrow(clash) || any(!neg$ok)) {
  cat("\nCHECK FAILED - a synonym is pointing at the wrong institution.\n")
  quit(save = "no", status = 1)
}
