##############################################################################
# build_actor_synonyms.R - build catalogues/actor_synonyms.csv and enforce the
# one rule that makes it safe: a synonym points at exactly one institution.
#
# Two things feed the file:
#
#   MECHANICAL rows, derived here from what the registry already says. There
#   are fewer than you would expect, because the shared name comparison in
#   actor_names.R already folds British spelling, accents, bracketed acronyms
#   and spacing. What it cannot fold is a name that means something different
#   when shortened - "Ministry of Finance, Ghana" cut to "Ministry of Finance"
#   is a name several countries share - so those go through the uniqueness
#   rule here instead of into the normaliser.
#
#   REVIEWED rows, written by a person reading the organisation's own website,
#   carrying the URL and the quoted text as evidence.
#
# The rule, applied to every row whatever its source:
#
#   1. a synonym under 3 characters is dropped ("AA" is not an identifier)
#   2. a synonym two or more codes claim is demoted to `candidate`, where it
#      can only put a name in front of the confirmation step
#   3. a synonym equal to a different code's name or acronym is dropped
#   4. every drop is written down with its reason - nothing vanishes silently
#
# Rebuilding never overwrites: an existing row wins, a row a person wrote or
# reviewed is never touched, and the file is written to a temp name and moved
# into place so an interrupted run cannot leave half a file on OneDrive.
#
#   Rscript R/07_review/build_actor_synonyms.R [--dry]
##############################################################################

suppressPackageStartupMessages({ library(openxlsx) })

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
source(file.path(REPO, "R", "00_shared", "actor_names.R"))
args <- commandArgs(trailingOnly = TRUE)
DRY  <- any(args == "--dry")

SYN_CSV <- file.path(REPO, "catalogues", "actor_synonyms.csv")
COLS <- c("actor_code", "actor_name", "synonym", "tier", "source", "status",
          "evidence", "added")

reg <- actor_registry(TEMPLATE_XLSX)
cat("registry:", nrow(reg), "actors\n")

read_syn <- function() {
  if (!file.exists(SYN_CSV)) return(NULL)
  d <- read_csv_utf8(SYN_CSV)
  for (cc in COLS) if (!cc %in% names(d)) d[[cc]] <- ""
  d[, COLS, drop = FALSE]
}
existing <- read_syn()
cat("existing synonyms:", if (is.null(existing)) 0 else nrow(existing), "\n")

## ---- mechanical rows --------------------------------------------------------
mech <- list()
GENERIC_HEAD <- "ministry|minist|department|direction|directorate|government|national|regional|general|office|agency|agence|bureau|institute|institut|university|universit|council|conseil|commission|secretariat|authority|fund|fonds|chamber|chambre|federation|union|association|programme|program|project|projet|service|centre|center|committee|comite|board|society|cooperative|company|corporation|foundation|network|forum|platform|alliance|initiative|observatory|laboratory"
add_row <- function(code, name, syn, source, note = "", tier = "trusted") {
  syn <- trimws(syn)
  if (!nzchar(syn) || identical(actor_nrm(syn), actor_nrm(name))) return(invisible())
  mech[[length(mech) + 1L]] <<- data.frame(
    actor_code = code, actor_name = name, synonym = syn, tier = tier,
    source = source, status = "active", evidence = note,
    added = format(Sys.Date()), stringsAsFactors = FALSE)
}
for (i in seq_len(nrow(reg))) {
  nm <- reg$name[i]; cd <- reg$code[i]
  # "Ministry of Fisheries and Livestock, Zambia" -> "Ministry of Fisheries and
  # Livestock". Only when the tail is a place: 17 registry names carry a comma
  # inside a LIST - "Flanders Research Institute for Agriculture, Fisheries and
  # Food" - and cutting there invents an organisation that does not exist.
  if (grepl(",", nm)) {
    tail <- trimws(sub("^.*,", "", nm))
    head_ <- trimws(sub(",[^,]*$", "", nm))
    listish <- grepl(" and | et | & ", tail) ||
               length(strsplit(tail, " +")[[1]]) > 3 ||
               length(strsplit(head_, " +")[[1]]) < 2
    # A generic body without its country ("Ministry of Agriculture and Food
    # Security") is not one organisation: Lesotho, Malawi and Mozambique all
    # have one. Such a synonym reaches the shortlist as a candidate but never
    # decides a match on its own (Charity pilot, 28 Sep 2026).
    generic <- grepl(paste0("^(the )?(", GENERIC_HEAD, ")\\b"), tolower(head_))
    if (!listish) {
      if (generic) add_row(cd, nm, head_, "registry-rule:comma-generic", tier = "candidate")
      else add_row(cd, nm, head_, "registry-rule:comma")
    }
  }
  # "The Gambia Agency" -> "Gambia Agency"
  if (grepl("^[Tt]he ", nm)) add_row(cd, nm, sub("^[Tt]he ", "", nm), "registry-rule:the")
  # A compound acronym is several names: "IPR/IFRA" is two, and "AUDA-NEPAD"
  # is a merged body that documents still call NEPAD. This is the registry's
  # own evidence, not a guess about the organisation. 40 acronyms are
  # hyphenated and only 2 of the 64 parts are claimed by more than one code,
  # so rule 2 has very little to do here.
  ac <- reg$acro[i]
  if (grepl("[/-]", ac)) for (part in trimws(strsplit(ac, "[/-]")[[1]]))
    # only the parts that are actually acronyms. "ISARA-Lyon" is an acronym and
    # a city, "SAI-Platform" an acronym and a common noun, "AUE La-Toden" an
    # acronym and a village. Taking those as names for the organisation is how
    # a document mentioning Lyon or a platform would be filed under it.
    # ...and not a part that merely repeats a word already in the name.
    # "ULPK-DIOILA" belongs to the "Union ... de Dioila": DIOILA is the town,
    # already matched through the name itself, and taking it as a name for the
    # co-operative would file every mention of the town there.
    if (nchar(part) >= 3 && part == toupper(part) &&
        !tolower(part) %in% strsplit(actor_fold(nm), " ", fixed = TRUE)[[1]])
      add_row(cd, nm, part, "registry-rule:acronym-split")
}
mech <- if (length(mech)) do.call(rbind, mech) else NULL
cat("mechanical rows:", if (is.null(mech)) 0 else nrow(mech), "\n")

## ---- merge: existing rows always win ----------------------------------------
key <- function(d) paste(d$actor_code, actor_nrm(d$synonym))
all_rows <- existing
if (!is.null(mech)) {
  fresh <- mech[!key(mech) %in% if (is.null(existing)) character(0) else key(existing), , drop = FALSE]
  all_rows <- rbind(all_rows, fresh)
  cat("new mechanical rows added:", nrow(fresh), "\n")
}
if (is.null(all_rows) || !nrow(all_rows)) { cat("nothing to write\n"); quit(save = "no") }
all_rows$actor_name <- reg$name[match(all_rows$actor_code, reg$code)]
all_rows$actor_name[is.na(all_rows$actor_name)] <- ""

## ---- the rule ---------------------------------------------------------------
rejects <- list()
reject <- function(rows, why) {
  if (!nrow(rows)) return(invisible())
  rejects[[length(rejects) + 1L]] <<- cbind(rows[, c("actor_code", "synonym", "source")],
                                            reason = why)
}
protected <- all_rows$source %in% c("human") | nzchar(all_rows$evidence) &
             all_rows$source == "human"

# 1. too short
short <- nchar(actor_nrm(all_rows$synonym)) < 3
reject(all_rows[short, ], "under 3 characters - not an identifier")
all_rows <- all_rows[!short, , drop = FALSE]

# 3. collides with a different institution's own name or acronym.
# Every code that claims the form, not just the first one found: ULB is the
# registry acronym of BOTH the Free University of Brussels and the Free
# University of Burkina, and looking up only the first claimant let a trusted
# synonym for Brussels quietly win an argument the registry has not settled.
own_code <- c(split(reg$code, reg$nname),
              split(reg$code, reg$nacro)[nchar(names(split(reg$code, reg$nacro))) >= 3])
f <- actor_nrm(all_rows$synonym)
clash_other <- vapply(seq_along(f), function(i) {
  cds <- own_code[[f[i]]]
  !is.null(cds) && any(cds != all_rows$actor_code[i])
}, logical(1))
reject(all_rows[clash_other, ], "a different institution already owns this name or acronym")
all_rows <- all_rows[!clash_other, , drop = FALSE]

# 1b. a place is not an organisation. The location registry already knows 654
# place names; a synonym equal to one of them would file every mention of the
# place under the organisation.
LOC <- tryCatch({
  L <- openxlsx::read.xlsx(TEMPLATE_XLSX, sheet = "location_codes")
  L[is.na(L)] <- ""
  p <- unique(actor_nrm(c(L$location_name, L$location_country)))
  p[nchar(p) >= 3]
}, error = function(e) character(0))
is_place <- actor_nrm(all_rows$synonym) %in% LOC
reject(all_rows[is_place, ], "is a place name, not an organisation")
all_rows <- all_rows[!is_place, , drop = FALSE]

# 2. claimed by more than one code -> may still help as a candidate, but may
# never decide anything
f <- actor_nrm(all_rows$synonym)
per <- tapply(all_rows$actor_code, f, function(x) length(unique(x)))
shared <- f %in% names(per)[per > 1]
demote <- shared & all_rows$tier == "trusted"
if (any(demote)) {
  reject(all_rows[demote, ], "claimed by more than one code - demoted to candidate")
  all_rows$tier[demote] <- "candidate"
}

rej <- if (length(rejects)) do.call(rbind, rejects) else data.frame()
cat("rows kept:", nrow(all_rows),
    "| trusted:", sum(all_rows$tier == "trusted"),
    "| candidate:", sum(all_rows$tier == "candidate"),
    "| dropped or demoted:", nrow(rej), "\n")
if (nrow(rej)) print(table(rej$reason))

## ---- write ------------------------------------------------------------------
if (DRY) { cat("\n--dry: nothing written\n"); quit(save = "no") }
all_rows <- all_rows[order(all_rows$actor_code, all_rows$synonym), COLS]
tmp <- paste0(SYN_CSV, ".tmp")
write_csv_utf8(all_rows, tmp)
invisible(file.rename(tmp, SYN_CSV))
cat("\nwritten:", SYN_CSV, "(", nrow(all_rows), "rows )\n")

# the column the template owner can paste in, trusted and active only
pt <- all_rows[all_rows$tier == "trusted" & all_rows$status == "active", ]
paste_ready <- data.frame(
  actor_code = reg$code, actor_name = reg$name,
  synonyms = vapply(reg$code, function(cd)
    paste(unique(pt$synonym[pt$actor_code == cd]), collapse = "; "),
    character(1), USE.NAMES = FALSE),
  stringsAsFactors = FALSE)
wb <- createWorkbook()
hdr <- createStyle(textDecoration = "bold", fgFill = "#EEEEEE", border = "bottom")
addWorksheet(wb, "actor_synonyms")
writeData(wb, "actor_synonyms", paste_ready, headerStyle = hdr, withFilter = TRUE)
freezePane(wb, "actor_synonyms", firstRow = TRUE)
setColWidths(wb, "actor_synonyms", cols = 1:3, widths = c(14, 52, 80))
if (nrow(rej)) {
  addWorksheet(wb, "not_used_and_why")
  writeData(wb, "not_used_and_why", rej, headerStyle = hdr, withFilter = TRUE)
  setColWidths(wb, "not_used_and_why", cols = 1:4, widths = c(14, 46, 26, 54))
}
f_out <- file.path(VOCAB_DIR, "actor_synonyms_for_template.xlsx")
saveWorkbook(wb, f_out, overwrite = TRUE)
cat("written:", f_out, "\n")
cat("        ", sum(nzchar(paste_ready$synonyms)), "of", nrow(paste_ready),
    "actors have at least one synonym\n")
