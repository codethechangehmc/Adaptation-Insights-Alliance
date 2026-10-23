##############################################################################
# corpus_inventory.R - census of the document corpus (03_Documents), for people
#
# Writes 03_Documents/Corpus_Inventory.xlsx:
#   overview                 one row per source: files on disk, screened, in
#                            scope, out, unsure, unscreened, duplicates moved
#                            out, in Zotero
#   scenario_strict_agri     the screening rule as it stands: agriculture and
#                            food systems must be the project's primary subject.
#                            Counts by source, family and year.
#   scenario_linked_sectors  what the corpus would be if documents put out on
#                            a linked sector (water, forestry and conservation,
#                            coastal zones, social protection, land) were let in
#                            when they pass every other criterion. Counts, the
#                            documents that would come in, and the ones that
#                            would still fail.
#   folders                  one row per subfolder with verdict counts
#   files                    every file with family, verdict, reason, sector
#                            group and the scenario flags
#   about                    when, how, from what
#
# Inputs: the folders under 03_Documents, 04_Screening/scope_screen.csv (verdicts),
# review/family_census.csv (families), 03_Documents/duplicates (moved copies),
# the Zotero group library (read only, attachments by file name). No model
# calls. Rerun any time:  Rscript R/04_catalogue/corpus_inventory.R
##############################################################################

suppressPackageStartupMessages({ library(httr); library(jsonlite); library(openxlsx) })

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
OUT_XLSX <- file.path(DOCS_ROOT, "Corpus_Inventory.xlsx")
YEAR_MIN <- 2015; YEAR_MAX <- 2025

## ---- what counts as a linked sector (edit here) ------------------------------
# Order matters: the first pattern that matches the screener's reason wins.
SECTOR_GROUPS <- list(
  social_protection     = "safety net|social protection|public works|cash transfer|productive safety|social assistance",
  transparency_mrv      = "transparen|\\bmrv\\b|national communication|biennial|greenhouse gas inventor|cbit\\b|unfccc reporting",
  disaster_risk         = "disaster risk|early warning|hydromet|meteorolog|flood (protection|control|management|risk)|\\bdrr\\b|civil protection",
  humanitarian          = "humanitarian|emergency (support|relief|assistance|response)|refugee|displaced",
  urban                 = "\\burban\\b|\\bcity\\b|\\bcities\\b|municipal|housing|slum",
  health_education      = "\\bhealth|nutrition|education|school|vocational|hospital|\\bhiv\\b|epidemic|pandemic|covid",
  governance_fiscal     = "governance|public (sector|finance|financial) management|fiscal|budget support|development policy|\\bpfm\\b|statistic|public administration|civil service|decentrali[sz]|\\btax|customs|economic reform|macroeconomic|competitiveness|institutional (reform|support)|justice|electoral|peace",
  energy                = "energy|electric|power (plant|sector|generation|transmission|supply)|renewable|solar|geothermal|hydropower|\\bgrid\\b|cookstove",
  transport             = "transport|\\broads?\\b|highway|railway|\\bports?\\b|airport|corridor|bridge",
  water                 = "water supply|water resource|drinking water|sanitation|hydraulic|\\bdams?\\b|groundwater|watershed|river basin|\\bwash\\b|water sector|water management",
  coastal               = "coastal|shoreline|mangrove|marine|blue economy|sea level",
  forestry_conservation = "forest|redd|biodiversity|conservation|protected area|wildlife|ecosystem|wetland|landscape restoration|national park|nature",
  private_sector        = "private sector|\\bsmes?\\b|small and medium|enterprise|financial inclusion|microfinance|\\btrade\\b|investment climate|entrepreneur|business environment|banking|credit line",
  mining_industry       = "mining|mineral|industr|tourism|manufactur|cement",
  land                  = "land administration|land tenure|land registration|cadastr|land governance|land rights"
)
GROUP_LABEL <- c(social_protection = "Social protection and safety nets",
  transparency_mrv = "Climate transparency, MRV and national reporting",
  disaster_risk = "Disaster risk management, early warning and hydromet",
  humanitarian = "Humanitarian and emergency relief", urban = "Urban development",
  health_education = "Health, nutrition and education",
  governance_fiscal = "Governance, fiscal reform, budget support and statistics",
  energy = "Energy, electricity and renewables", transport = "Transport, roads and ports",
  water = "Water supply, sanitation and water resources", coastal = "Coastal zone management",
  forestry_conservation = "Forestry, REDD+, biodiversity and conservation",
  private_sector = "Private sector, finance, trade and small enterprises",
  mining_industry = "Mining, industry and tourism", land = "Land administration and tenure",
  unnamed = "Sector not named clearly in the reason")
# the groups that count as linked to agriculture and food systems in the
# second scenario. Change this line to test another boundary.
LINKED_GROUPS <- c("water", "forestry_conservation", "coastal", "social_protection", "land")
PROGRESS_FAMILIES <- c("wb_isr", "gef_pir", "af_ppr", "gef_indicator_sheet")

sector_group <- function(reason) {
  r <- tolower(reason)
  mentions <- grepl("sector|agricultur|farming|food system|not (about|on|primarily)", r)
  out <- rep("", length(r))
  for (g in names(SECTOR_GROUPS)) {
    hit <- out == "" & grepl(SECTOR_GROUPS[[g]], r, perl = TRUE)
    out[hit] <- g
  }
  out[out == "" & mentions] <- "unnamed"
  out
}

## ---- 1. walk 03_Documents -------------------------------------------------------
all_files <- list.files(DOCS_ROOT, recursive = TRUE, full.names = FALSE)
all_files <- all_files[!grepl("^~\\$", basename(all_files))]
# The inventory itself, and any dated copy of it, are not corpus documents.
# Matching the exact name let Corpus_Inventory_BEFORE_REPAIR_20261002.xlsx be
# counted as an evaluation in the files sheet.
all_files <- all_files[!grepl("^(Corpus_Inventory|duplicates_register)", basename(all_files)) &
                       basename(all_files) != "README.md"]
top <- sub("/.*$", "", all_files)
src_map <- c(Worldbank = "worldbank", gef = "gef", gcf = "gcf", afdb = "afdb", af = "af", cif = "cif",
             pilot = "pilot", duplicates = "duplicates")
source_of <- unname(src_map[top]); source_of[is.na(source_of)] <- tolower(top[is.na(source_of)])
rel_dir <- dirname(all_files); rel_dir[rel_dir == "."] <- ""
fname <- basename(all_files); ext <- tolower(tools::file_ext(fname))
size_mb <- round(file.info(file.path(DOCS_ROOT, all_files))$size / 1e6, 2)
# a moved duplicate carries its source as prefix: source__filename
dup_src <- ifelse(source_of == "duplicates", tolower(sub("__.*$", "", fname)), NA)
source_of[source_of == "duplicates"] <- dup_src[source_of == "duplicates"]
kind_of_file <- ifelse(top == "duplicates", "duplicate moved out",
                ifelse(top == "pilot", "pilot set",
                ifelse(grepl("(^|/)List(/|$)", rel_dir), "metadata (List)",
                ifelse(ext == "pdf", "document", "document (not PDF)"))))
files <- data.frame(source = source_of, folder = rel_dir, filename = fname, ext = ext, size_mb = size_mb,
                    kind_of_file = kind_of_file, stringsAsFactors = FALSE)
cat("files under 03_Documents:", nrow(files), "\n")

## ---- 2. screening verdicts and census ------------------------------------------
sc <- read.csv(file.path(SCREEN_DIR, "scope_screen.csv"), stringsAsFactors = FALSE, colClasses = "character", encoding = "UTF-8")
sc[is.na(sc)] <- ""
sc$source <- tolower(sc$source)
key_f <- paste(files$source, tolower(files$filename)); key_s <- paste(sc$source, tolower(sc$filename))
m <- match(key_f, key_s)
pick <- function(col) ifelse(is.na(m), "", sc[[col]][m])
files$screened <- !is.na(m)
files$verdict <- pick("verdict_ruled"); files$verdict[files$verdict == ""] <- pick("verdict")[files$verdict == ""]
files$verdict_model <- pick("verdict")
files$rule_applied <- pick("rule_applied")
files$reason <- pick("reason")
files$family <- pick("family"); files$doc_type <- pick("doc_type"); files$year <- pick("publication_year")
files$language <- pick("language"); files$countries <- pick("countries")
files$covers_several_projects <- pick("covers_several_projects")
files$adaptation_or_mitigation <- pick("adaptation_or_mitigation")
files$climate_risk_quote <- pick("climate_risk_quote")
cen_p <- file.path(SCREEN_DIR, "inputs", "decisions", "family_census.csv")
if (file.exists(cen_p)) {
  cen <- read.csv(cen_p, stringsAsFactors = FALSE, colClasses = "character", encoding = "UTF-8"); cen[is.na(cen)] <- ""
  mc <- match(key_f, paste(tolower(cen$source), tolower(cen$filename)))
  files$family_rule <- ifelse(is.na(mc), "", cen$family[mc]); files$kind <- ifelse(is.na(mc), "", cen$kind[mc])
  files$family[files$family == ""] <- files$family_rule[files$family == ""]
  files$project_ids <- ifelse(is.na(mc), "", trimws(paste(cen$wb_project[mc], cen$afdb_code[mc], cen$gef_id[mc], cen$gcf_fp[mc], cen$af_id[mc])))
} else { files$family_rule <- ""; files$kind <- ""; files$project_ids <- "" }
cat("screened documents matched:", sum(files$screened), "of", nrow(sc), "judgements\n")
# text lifted from PDFs can carry control characters; Excel readers reject them
CTRL <- paste0("[", intToUtf8(c(1:8, 11, 12, 14:31), multiple = FALSE), "]")
for (cn in names(files)) if (is.character(files[[cn]])) files[[cn]] <- gsub(CTRL, "", files[[cn]], perl = TRUE)

## ---- 3. sector groups and the two scenarios ------------------------------------
files$sector_group <- ifelse(files$verdict == "out of scope", sector_group(files$reason), "")
yr <- suppressWarnings(as.integer(files$year))
year_ok <- !is.na(yr) & yr >= YEAR_MIN & yr <= YEAR_MAX
risk_ok <- nchar(trimws(files$climate_risk_quote)) >= 12
adapt_ok <- files$adaptation_or_mitigation %in% c("adaptation", "")
type_ok <- !(files$family %in% PROGRESS_FAMILIES) &
           !grepl("proposal|appraisal|progress report|performance report|implementation status|funding proposal|project document|not an evaluation", files$reason, ignore.case = TRUE)
geo_ok <- !grepl("not (in|located in|an? )africa|outside africa|non-african|not african|no african", files$reason, ignore.case = TRUE)
multi_ok <- files$covers_several_projects != "yes"
linked <- files$verdict == "out of scope" & files$sector_group %in% LINKED_GROUPS
why_not <- ifelse(!year_ok, sprintf("dated %s, outside %d to %d", ifelse(files$year == "", "no year", files$year), YEAR_MIN, YEAR_MAX),
           ifelse(!type_ok, "source type (proposal or progress document)",
           ifelse(!geo_ok, "geography",
           ifelse(!adapt_ok, "the project is mitigation or neither",
           ifelse(!risk_ok, "no climate risk quoted",
           ifelse(!multi_ok, "covers several projects", ""))))))
files$strict_agri <- ifelse(files$verdict == "in scope", "in scope", ifelse(files$verdict == "unsure", "unsure", ""))
files$linked_sectors <- ifelse(files$verdict %in% c("in scope", "unsure"), files$strict_agri,
                        ifelse(linked & why_not == "", "in scope (linked sector)",
                        ifelse(linked, paste("still out:", why_not), "")))

## ---- 4. Zotero attachments (read only) ------------------------------------------
zotero_files <- NULL; zotero_note <- ""
if (!nzchar(Sys.getenv("ZOTERO_API_KEY")))
  for (p in c(file.path(Sys.getenv("OneDrive"), "Documents", ".Renviron"), file.path(Sys.getenv("USERPROFILE"), "Documents", ".Renviron")))
    if (file.exists(p)) { readRenviron(p); break }
zkey <- Sys.getenv("ZOTERO_API_KEY"); zlib <- Sys.getenv("ZOTERO_LIBRARY_ID")
if (nzchar(zkey) && nzchar(zlib)) {
  zotero_files <- tryCatch({
    fn <- character(0); start <- 0
    repeat {
      r <- GET(sprintf("https://api.zotero.org/groups/%s/items", zlib),
               query = list(itemType = "attachment", format = "json", limit = 100, start = start),
               add_headers(`Zotero-API-Key` = zkey, `Zotero-API-Version` = "3"), timeout(60))
      stop_for_status(r)
      js <- fromJSON(content(r, "text", encoding = "UTF-8"), simplifyVector = FALSE)
      fn <- c(fn, vapply(js, function(it) { f <- it$data$filename; if (is.null(f)) "" else f }, character(1)))
      total <- as.integer(headers(r)[["total-results"]]); start <- start + 100
      if (is.na(total) || start >= total || length(js) == 0) break
    }
    unique(tolower(fn[nzchar(fn)]))
  }, error = function(e) { zotero_note <<- conditionMessage(e); NULL })
}
if (is.null(zotero_files)) { cat("Zotero not read (", zotero_note, ")\n"); files$in_zotero <- NA
} else { cat("Zotero attachments:", length(zotero_files), "\n")
  files$in_zotero <- tolower(files$filename) %in% zotero_files
  files$in_zotero[!files$kind_of_file %in% c("document", "document (not PDF)")] <- NA }

## ---- 5. tables -------------------------------------------------------------------
docs <- files[files$kind_of_file %in% c("document", "document (not PDF)"), ]
SRC_ORDER <- c("worldbank", "gef", "gcf", "afdb", "af", "cif")
SRC_LABEL <- c(worldbank = "World Bank", gef = "GEF", gcf = "GCF", afdb = "AfDB", af = "Adaptation Fund", cif = "CIF")
by_src <- function(d, f) { out <- lapply(SRC_ORDER, function(s) f(d[d$source == s, ])); do.call(rbind, out) }
add_total <- function(df) { tot <- df[1, ]; tot[[1]] <- "TOTAL"
  for (cn in names(df)[-1]) tot[[cn]] <- if (is.numeric(df[[cn]])) sum(df[[cn]], na.rm = TRUE) else ""
  rbind(df, tot) }
nz <- function(x) if (is.null(zotero_files)) NA_integer_ else sum(x, na.rm = TRUE)

overview <- add_total(by_src(files, function(g) { d <- g[g$kind_of_file %in% c("document", "document (not PDF)"), ]
  data.frame(source = SRC_LABEL[[g$source[1]]],
    files_on_disk = nrow(d), pdf = sum(d$ext == "pdf"), not_pdf = sum(d$ext != "pdf"),
    screened = sum(d$screened), in_scope = sum(d$verdict == "in scope"), out_of_scope = sum(d$verdict == "out of scope"),
    unsure = sum(d$verdict == "unsure"),
    proposal_stage_parked = sum(!d$screened & grepl("proposal", d$folder, ignore.case = TRUE)),
    unscreened_other = sum(!d$screened & !grepl("proposal", d$folder, ignore.case = TRUE)),
    duplicates_moved_out = sum(g$kind_of_file == "duplicate moved out"),
    in_zotero = nz(d$in_zotero[d$screened]), size_mb = round(sum(d$size_mb, na.rm = TRUE), 1),
    stringsAsFactors = FALSE) }))
overview_notes <- data.frame(note = c(
  "files_on_disk: documents in the source's Docs folders (metadata lists, the pilot sets and moved duplicates not counted).",
  "screened: judged by the screener; the verdict shown is the ruled verdict (rules and human overrides applied).",
  "proposal_stage_parked: files in proposal stage folders; parked at retrieval, never screened (a proposal describes an intention, not what was done).",
  "unscreened_other: files in evaluation folders the screener has not judged; mostly Word and Excel files the pipeline cannot read yet.",
  "not_pdf: Word and Excel files (counted inside files_on_disk).",
  "duplicates_moved_out: copies moved to 03_Documents/duplicates with the register there.",
  "in_zotero: screened documents whose file is attached in the Zotero group library (match on file name).",
  sprintf("Screening file: %s (%d judgements). Generated %s.", file.path("04_Screening", "scope_screen.csv"), nrow(sc), format(Sys.time(), "%Y-%m-%d %H:%M"))))

# scenario 1: strict agriculture (the rule as it stands)
s1_src <- add_total(by_src(docs, function(d) data.frame(source = SRC_LABEL[[d$source[1]]],
  screened = sum(d$screened), in_scope = sum(d$verdict == "in scope"), unsure = sum(d$verdict == "unsure"),
  out_of_scope = sum(d$verdict == "out of scope"), in_scope_if_all_unsure_accepted = sum(d$verdict %in% c("in scope", "unsure")),
  stringsAsFactors = FALSE)))
fam_tab <- function(d) { t <- table(factor(d$family[d$verdict == "in scope"])); u <- table(factor(d$family[d$verdict == "unsure"]))
  fams <- sort(unique(c(names(t), names(u)))); if (!length(fams)) return(data.frame(family = character(0), in_scope = integer(0), unsure = integer(0)))
  add_total(data.frame(family = fams, in_scope = as.integer(t[fams]), unsure = as.integer(u[fams]), stringsAsFactors = FALSE)) }
s1_fam <- fam_tab(docs); s1_fam[is.na(s1_fam)] <- 0
yrs <- as.character(YEAR_MIN:YEAR_MAX)
s1_year <- add_total(data.frame(year = yrs, in_scope = as.integer(table(factor(docs$year[docs$verdict == "in scope"], levels = yrs))),
                                unsure = as.integer(table(factor(docs$year[docs$verdict == "unsure"], levels = yrs))), stringsAsFactors = FALSE))
s1_notes <- data.frame(note = c(
  "Scenario 1, strict agriculture: the screening rule as it stands.",
  "A document is in scope when agriculture and food systems are the project's primary subject (crops, livestock, fisheries, agroforestry, food security, rural livelihoods built on farming),",
  "the document is an evaluation type document dated 2015 to 2025, the project is in Africa, and the project acts on a climate risk it names.",
  "A project in another sector is out even if farmers benefit. Unsure documents wait for a person; the last column shows the ceiling if every unsure document were accepted."))

# scenario 2: agriculture plus linked sectors
added <- docs[docs$linked_sectors == "in scope (linked sector)", ]
still <- docs[startsWith(docs$linked_sectors, "still out"), ]
s2_src <- add_total(by_src(docs, function(d) data.frame(source = SRC_LABEL[[d$source[1]]],
  strict_in_scope = sum(d$verdict == "in scope"), linked_sector_added = sum(d$linked_sectors == "in scope (linked sector)"),
  scenario_in_scope = sum(d$verdict == "in scope" | d$linked_sectors == "in scope (linked sector)"), unsure = sum(d$verdict == "unsure"),
  linked_sector_but_fails_another_criterion = sum(startsWith(d$linked_sectors, "still out")), stringsAsFactors = FALSE)))
grp_levels <- names(SECTOR_GROUPS); grp_levels <- c(grp_levels, "unnamed")
s2_grp <- data.frame(sector_group = GROUP_LABEL[grp_levels], counted_as_linked = ifelse(grp_levels %in% LINKED_GROUPS, "yes", "no"),
  out_on_this_sector = as.integer(table(factor(docs$sector_group[docs$verdict == "out of scope"], levels = grp_levels))),
  would_come_in = as.integer(table(factor(added$sector_group, levels = grp_levels))),
  fails_another_criterion = as.integer(table(factor(still$sector_group, levels = grp_levels))), stringsAsFactors = FALSE)
s2_grp <- s2_grp[order(-s2_grp$out_on_this_sector), ]
s2_fam <- add_total(data.frame(family = names(table(added$family)), would_come_in = as.integer(table(added$family)), stringsAsFactors = FALSE))
short <- function(x, n = 220) ifelse(nchar(x) > n, paste0(substr(x, 1, n - 3), "..."), x)
s2_added <- added[order(added$sector_group, added$source, added$filename),
                  c("source", "folder", "filename", "family", "year", "sector_group", "reason", "climate_risk_quote")]
s2_added$sector_group <- GROUP_LABEL[s2_added$sector_group]; s2_added$reason <- short(s2_added$reason); s2_added$climate_risk_quote <- short(s2_added$climate_risk_quote)
s2_still <- still[order(still$sector_group, still$source, still$filename), c("source", "folder", "filename", "family", "year", "sector_group", "linked_sectors", "reason")]
s2_still$sector_group <- GROUP_LABEL[s2_still$sector_group]; names(s2_still)[7] <- "why_still_out"; s2_still$why_still_out <- sub("^still out: ", "", s2_still$why_still_out); s2_still$reason <- short(s2_still$reason)
s2_notes <- data.frame(note = c(
  "Scenario 2, agriculture plus linked sectors: documents the screener put out of scope on the sector criterion come in when the sector is one of the linked groups below",
  sprintf("(%s)", paste(GROUP_LABEL[LINKED_GROUPS], collapse = "; ")),
  "and the document passes every other criterion: dated 2015 to 2025, an evaluation type document, a project in Africa, adaptation (not mitigation), a climate risk quoted, one project.",
  "The sector group is read from the screener's reason. A reason that says sector without naming one cannot be placed and is not counted.",
  "To move the boundary, change LINKED_GROUPS in R/04_catalogue/corpus_inventory.R and rerun. To accept these documents for real, add them to 04_Screening/inputs/decisions/scope_screen_overrides.csv and rerun screen_rules.R."))

folders <- do.call(rbind, lapply(split(files, paste(files$source, files$folder)), function(g) data.frame(
  source = g$source[1], folder = g$folder[1], kind_of_file = g$kind_of_file[1], n_files = nrow(g), n_pdf = sum(g$ext == "pdf"),
  screened = sum(g$screened), in_scope = sum(g$verdict == "in scope"), out_of_scope = sum(g$verdict == "out of scope"), unsure = sum(g$verdict == "unsure"),
  size_mb = round(sum(g$size_mb, na.rm = TRUE), 1), n_in_zotero = nz(g$in_zotero), stringsAsFactors = FALSE)))
folders <- folders[order(folders$source, folders$folder), ]
files_out <- files[order(files$source, files$folder, files$filename),
  c("source", "kind_of_file", "folder", "filename", "ext", "size_mb", "screened", "verdict", "verdict_model", "rule_applied", "family", "kind",
    "doc_type", "year", "language", "countries", "project_ids", "sector_group", "strict_agri", "linked_sectors", "reason", "in_zotero")]
files_out$sector_group <- ifelse(files_out$sector_group == "", "", GROUP_LABEL[files_out$sector_group])
files_out$reason <- short(files_out$reason, 300)

## ---- 6. write ------------------------------------------------------------------------
wb <- createWorkbook()
hdr <- createStyle(textDecoration = "bold", border = "bottom", fgFill = "#E8EEE8")
ttl <- createStyle(textDecoration = "bold", fontSize = 12)
put <- function(sheet, df, row, title = NULL, widths = NULL, filter = FALSE) {
  if (!is.null(title)) { writeData(wb, sheet, title, startRow = row); addStyle(wb, sheet, ttl, rows = row, cols = 1); row <- row + 1 }
  writeData(wb, sheet, df, startRow = row, headerStyle = hdr, withFilter = filter)
  if (!is.null(widths)) setColWidths(wb, sheet, cols = seq_along(widths), widths = widths)
  invisible(row + nrow(df) + 2)
}
addWorksheet(wb, "overview"); r <- put("overview", overview, 1, "Corpus inventory by source", c(16, 12, 8, 8, 10, 10, 12, 8, 20, 16, 20, 10, 9)); put("overview", overview_notes, r, "Notes")
addWorksheet(wb, "scenario_strict_agri"); r <- put("scenario_strict_agri", s1_notes, 1, "Scenario 1: strict agriculture (current rule)", c(28, 12, 12, 12, 30))
r <- put("scenario_strict_agri", s1_src, r, "By source"); r <- put("scenario_strict_agri", s1_fam, r, "In scope documents by family"); put("scenario_strict_agri", s1_year, r, "In scope documents by publication year")
addWorksheet(wb, "scenario_linked_sectors"); r <- put("scenario_linked_sectors", s2_notes, 1, "Scenario 2: agriculture plus linked sectors", c(16, 30, 60, 22, 8, 40, 60, 60))
r <- put("scenario_linked_sectors", s2_src, r, "By source"); r <- put("scenario_linked_sectors", s2_grp, r, "Documents out on the sector criterion, by sector group")
r <- put("scenario_linked_sectors", s2_fam, r, "Documents that would come in, by family")
r <- put("scenario_linked_sectors", s2_added, r, "Documents that would come in (linked sector, every other criterion passed)", filter = TRUE)
put("scenario_linked_sectors", s2_still, r, "Out on a linked sector but failing another criterion (would stay out)", filter = TRUE)
addWorksheet(wb, "folders"); put("folders", folders, 1, NULL, c(10, 40, 20, 8, 8, 9, 9, 12, 8, 9, 12), filter = TRUE); freezePane(wb, "folders", firstRow = TRUE)
addWorksheet(wb, "files"); put("files", files_out, 1, NULL, c(10, 18, 30, 55, 5, 8, 9, 13, 13, 30, 20, 12, 26, 6, 8, 20, 18, 30, 12, 26, 60, 9), filter = TRUE); freezePane(wb, "files", firstRow = TRUE)
addWorksheet(wb, "about")
info <- data.frame(what = c("generated", "generated by", "screening file", "census file", "zotero library", "zotero status", "linked sector groups", "year window"),
  value = c(format(Sys.time(), "%Y-%m-%d %H:%M"), "07_Pipeline/R/04_catalogue/corpus_inventory.R (rerun any time)",
            sprintf("04_Screening/scope_screen.csv, %d judgements", nrow(sc)), "04_Screening/inputs/decisions/family_census.csv", zlib,
            if (is.null(zotero_files)) paste("unavailable:", zotero_note) else sprintf("%d attachments read; in_zotero matches on exact file name", length(zotero_files)),
            paste(GROUP_LABEL[LINKED_GROUPS], collapse = "; "), sprintf("%d to %d", YEAR_MIN, YEAR_MAX)), stringsAsFactors = FALSE)
put("about", info, 1, NULL, c(22, 110))
saveWorkbook(wb, OUT_XLSX, overwrite = TRUE)
# openxlsx leaves relationship entries that point at drawing parts it never
# writes. Excel ignores them; strict readers (openpyxl, some validators) stop
# on them. Drop every relationship whose target is missing.
#
# TWO BUGS FIXED HERE, 2 Oct 2026, after this function corrupted the workbook
# it was meant to tidy:
#
#   1. `parts` came from list.files() WITHOUT all.files = TRUE, which skips
#      names beginning with a dot. The package's root relationship part is
#      called `_rels/.rels`, so it was never in the list and the rezip wrote a
#      workbook without it. That part is what tells Excel where the workbook
#      is, so Excel reported the file as corrupt and offered to recover it.
#      Every regeneration since 25 Sep produced an unopenable file.
#   2. The sweep only read xl/worksheets/_rels. [Content_Types].xml declared
#      six /xl/drawings/drawingN.xml parts that openxlsx never wrote, and a
#      declared part that does not exist is itself a validity error.
#
# Both are now covered, and the function refuses to write a package that is
# missing its root part rather than shipping a broken file quietly.
tidy_xlsx <- function(path) {
  if (!requireNamespace("zip", quietly = TRUE)) return(invisible(FALSE))
  tmp <- file.path(tempdir(), "xlsx_tidy"); unlink(tmp, recursive = TRUE); dir.create(tmp)
  utils::unzip(path, exdir = tmp)
  # all.files = TRUE: without it `_rels/.rels` is silently left out
  parts <- list.files(tmp, recursive = TRUE, all.files = TRUE, no.. = TRUE)
  rels <- list.files(file.path(tmp, "xl", "worksheets", "_rels"), full.names = TRUE)
  n <- 0
  # a content type for a part that was never written is a validity error
  ct <- file.path(tmp, "[Content_Types].xml")
  if (file.exists(ct)) {
    txt <- readChar(ct, file.info(ct)$size, useBytes = TRUE)
    ms <- gregexpr('<Override [^>]*/>', txt)[[1]]
    if (ms[1] != -1) for (e in regmatches(txt, list(ms))[[1]]) {
      part <- sub('.*PartName="/?([^"]+)".*', "\\1", e)
      if (!file.exists(file.path(tmp, part))) {
        txt <- sub(e, "", txt, fixed = TRUE); n <- n + 1
      }
    }
    writeChar(txt, ct, eos = NULL, useBytes = TRUE)
  }
  for (rp in rels) {
    txt <- readChar(rp, file.info(rp)$size, useBytes = TRUE)
    ms <- gregexpr('<Relationship [^>]*/>', txt)[[1]]
    if (ms[1] == -1) next
    elems <- regmatches(txt, list(ms))[[1]]
    for (e in elems) {
      target <- sub('.*Target="([^"]+)".*', "\\1", e)
      full <- normalizePath(file.path(tmp, "xl", "worksheets", target), mustWork = FALSE)
      if (!file.exists(full)) { txt <- sub(e, "", txt, fixed = TRUE); n <- n + 1 }
    }
    writeChar(txt, rp, eos = NULL, useBytes = TRUE)
  }
  # never ship a package without its root relationship part: that is the
  # failure this function used to cause
  if (!any(parts == "_rels/.rels")) {
    warning("tidy_xlsx: _rels/.rels missing from the unpacked parts; ",
            "leaving ", basename(path), " exactly as openxlsx wrote it")
    return(invisible(0L))
  }
  if (n) zip::zip(path, files = parts, root = tmp, mode = "mirror", include_directories = FALSE)
  invisible(n)
}
n_fixed <- tidy_xlsx(OUT_XLSX)
cat("written:", OUT_XLSX, if (isTRUE(n_fixed > 0)) sprintf("(%d dangling links removed)", n_fixed) else "", "\n\n"); print(overview, row.names = FALSE); cat("\nscenario 1 (strict):\n"); print(s1_src, row.names = FALSE)
cat("\nscenario 2 (linked sectors):\n"); print(s2_src, row.names = FALSE); cat("\nby sector group:\n"); print(s2_grp, row.names = FALSE)
