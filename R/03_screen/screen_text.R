# screen_text.R - text extraction and the deterministic pre-pass for the
# scope screener (Phase 4a, Oct 2026). Pure functions, no API, no side
# effects, so R/08_quality/test_screen_prepass.R can exercise them directly.
#
# Two measured error modes live here:
#   1. GEF portal sheets carry a machine footer on every page -
#      "1/13/2026                         Page 1 of 7" - and the screener read
#      publication_year off it (12 documents got 2026). pretreat_text() strips
#      those lines before the model ever sees them.
#   2. AfDB PCRs carry the template table label
#      "Type (e.g. gender, climate change, social, other)", which manufactures
#      climate keyword hits and sham climate_risk_quotes. pretreat_text()
#      removes the label - both when it is contiguous (docx, model quotes) and
#      when pdftools splits it over three table-header lines with other
#      columns' text interleaved (the common PCR layout, checked against
#      afdb_PCR_Angola_-_Bom_Jesus-Calenga... and afdb_PCR_Cabo_Verde_-...).
#      is_boilerplate_quote() applies the same test to a quote the model
#      returned, so screen_rules.R can treat it as no evidence.
#
# Extraction: extract_document_text() reads .pdf (pdftools), .docx (unzip
# word/document.xml + footnotes/endnotes, text via xml2), and .doc (LibreOffice
# soffice headless if installed; otherwise "" so the screener's <500-char path
# parks the file as "needs conversion: legacy .doc"). xlsx and zip stay
# excluded: zips are unpacked at retrieval, xlsx are indicator workbooks.

## ---- patterns --------------------------------------------------------------
# a whole line that is the GEF portal machine footer: date left, page right
GEF_FOOTER_RE   <- "^\\s*\\d{1,2}/\\d{1,2}/20\\d{2}\\s+Page\\s+\\d+\\s+of\\s+\\d+\\s*$"
# a line that is nothing but an M/D/YYYY date stamp
GEF_DATELINE_RE <- "^\\s*\\d{1,2}/\\d{1,2}/20\\d{2}\\s*$"
# a line that is nothing but a page marker
GEF_PAGELINE_RE <- "^\\s*Page\\s+\\d+(\\s+of\\s+\\d+)?\\s*$"

# the AfDB PCR table label, contiguous, tolerating 'eg.' / 'e.g.' / 'others'
# and any internal whitespace (including line breaks)
AFDB_BOILER_RE  <- "type\\s*\\(\\s*e\\.?\\s*g\\.?[.,]?\\s*gender\\s*,\\s*climate\\s+change\\s*,\\s*social\\s*,\\s*others?\\s*\\)"
# the label's first fragment as pdftools lays it out in the PCR table header
AFDB_FRAG1_RE   <- "type\\s*\\(\\s*e\\.?\\s*g\\.?[.,]?\\s*gender\\s*,?"

## ---- the pre-pass ----------------------------------------------------------
# The World Bank completion report opens with a "SECTORS AND THEMES" block:
# a taxonomy assigned at appraisal, printed as label/percentage pairs. A
# Cote d'Ivoire e-agriculture report whose body never names a climate hazard
# still prints "Disaster Risk Management 33 / Flood and Drought Risk
# Management 33 / Climate change 33 / Adaptation 33". Two adjudicators
# reading different batches independently traced false positives to it.
# Like the AfDB template label, it is classification metadata, not evidence
# of what the project did, so it is removed before anything counts terms or
# reads the document.
#
# The block runs from the SECTORS AND THEMES heading to the next all-capitals
# heading, and is bounded to 120 lines so a malformed extraction cannot eat
# the document.
WB_TAXONOMY_START <- "^\\s*SECTORS\\s+AND\\s+THEMES\\s*$"
WB_TAXONOMY_END   <- "^\\s*(?:[IVX]+\\.\\s+)?[A-Z][A-Z0-9 ,&'./-]{5,}\\s*$"

strip_wb_taxonomy <- function(txt) {
  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  if (!length(lines)) return(txt)
  starts <- grep(WB_TAXONOMY_START, lines, perl = TRUE)
  if (!length(starts)) return(txt)
  drop <- rep(FALSE, length(lines))
  for (s in starts) {
    last <- min(s + 120L, length(lines))
    e <- NA_integer_
    if (s + 1L <= last) {
      tail_idx <- seq.int(s + 1L, last)
      ends <- tail_idx[grepl(WB_TAXONOMY_END, lines[tail_idx], perl = TRUE)]
      if (length(ends)) e <- ends[1] - 1L
    }
    if (is.na(e)) e <- last
    drop[seq.int(s, e)] <- TRUE
  }
  paste(lines[!drop], collapse = "\n")
}

pretreat_text <- function(txt) {
  if (is.null(txt) || length(txt) == 0 || is.na(txt[1]) || !nzchar(txt[1])) return("")
  txt <- txt[1]
  # contiguous boilerplate label (docx extractions, narrow layouts)
  txt <- gsub(AFDB_BOILER_RE, "", txt, ignore.case = TRUE, perl = TRUE)
  txt <- strip_wb_taxonomy(txt)

  lines <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  if (!length(lines)) return("")

  # fragmented boilerplate label: pdftools interleaves the other table
  # columns, so the label arrives as up to three header lines. Only lines in a
  # detected block are touched; a normal sentence about climate change is not.
  f1 <- grepl(AFDB_FRAG1_RE, lines, ignore.case = TRUE, perl = TRUE)
  for (i in which(f1)) {
    j <- i:min(i + 2, length(lines))
    blk <- paste(lines[j], collapse = " ")
    if (grepl("climate\\s+change", blk, ignore.case = TRUE) &&
        grepl("others?\\s*\\)", blk, ignore.case = TRUE)) {
      lines[j] <- gsub(AFDB_FRAG1_RE, "", lines[j], ignore.case = TRUE, perl = TRUE)
      lines[j] <- gsub("climate\\s+change\\s*,?", "", lines[j], ignore.case = TRUE)
      lines[j] <- gsub("social\\s*,?\\s*others?\\s*\\)", "", lines[j], ignore.case = TRUE)
      lines[j] <- gsub("\\bsocial\\s*,", "", lines[j], ignore.case = TRUE)
      lines[j] <- gsub("others?\\s*\\)", "", lines[j], ignore.case = TRUE)
    }
  }

  # machine footers: the combined date+page line, and a standalone date-stamp
  # line sitting right next to a page marker. A date inside prose, or a lone
  # date line with no page marker beside it, is left alone.
  footer <- grepl(GEF_FOOTER_RE, lines, ignore.case = TRUE)
  dateln <- grepl(GEF_DATELINE_RE, lines)
  pageln <- grepl(GEF_PAGELINE_RE, lines, ignore.case = TRUE)
  n <- length(lines)
  next_pg <- c(pageln[-1], FALSE)
  prev_pg <- c(FALSE, pageln[-n])
  drop <- footer | (dateln & (next_pg | prev_pg))

  paste(lines[!drop], collapse = "\n")
}

# TRUE when a climate_risk_quote is the AfDB template label (or the label plus
# a few stray characters): boilerplate, not evidence. screen_rules.R treats a
# TRUE as quote length 0.
is_boilerplate_quote <- function(q) {
  if (is.null(q) || length(q) == 0 || is.na(q[1])) return(FALSE)
  q <- q[1]
  if (!nzchar(trimws(q))) return(FALSE)
  if (!grepl(AFDB_BOILER_RE, q, ignore.case = TRUE, perl = TRUE)) return(FALSE)
  rest <- gsub(AFDB_BOILER_RE, "", q, ignore.case = TRUE, perl = TRUE)
  nchar(trimws(rest)) < 12
}

## ---- extraction ------------------------------------------------------------
# .docx is a zip; the narrative lives in word/document.xml with footnotes and
# endnotes in their own parts. One paragraph per line keeps the structure the
# screener relies on (headings, table rows).
read_docx_text <- function(path) {
  if (!requireNamespace("xml2", quietly = TRUE)) return("")
  names_in <- tryCatch(utils::unzip(path, list = TRUE)$Name, error = function(e) character(0))
  parts <- intersect(c("word/document.xml", "word/footnotes.xml", "word/endnotes.xml"), names_in)
  if (!length(parts)) return("")
  td <- tempfile("docx_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)
  got <- tryCatch(utils::unzip(path, files = parts, exdir = td), error = function(e) character(0))
  out <- character(0)
  for (f in got) {
    doc <- tryCatch(xml2::read_xml(f), error = function(e) NULL)
    if (is.null(doc)) next
    ps <- tryCatch(xml2::xml_find_all(doc, ".//w:p"), error = function(e) NULL)
    out <- c(out, if (!is.null(ps) && length(ps))
      paste(xml2::xml_text(ps), collapse = "\n") else xml2::xml_text(doc))
  }
  paste(out, collapse = "\n")
}

# legacy .doc needs a converter; LibreOffice headless is the only one we
# accept. Nothing installed (the usual case on this machine) returns "", and
# the screener parks the file with note "needs conversion: legacy .doc".
find_soffice <- function() {
  cands <- c(Sys.which("soffice.com"), Sys.which("soffice"),
             "C:/Program Files/LibreOffice/program/soffice.com",
             "C:/Program Files (x86)/LibreOffice/program/soffice.com")
  for (p in cands) if (nzchar(p) && file.exists(p)) return(p)
  ""
}

read_doc_text <- function(path) {
  so <- find_soffice()
  if (!nzchar(so)) return("")
  td <- tempfile("doc_"); dir.create(td)
  on.exit(unlink(td, recursive = TRUE), add = TRUE)
  suppressWarnings(try(system2(so, c("--headless", "--convert-to", "txt:Text",
                                     "--outdir", shQuote(td), shQuote(path)),
                               stdout = TRUE, stderr = TRUE, timeout = 180), silent = TRUE))
  out <- list.files(td, pattern = "[.]txt$", full.names = TRUE)
  if (!length(out)) return("")
  paste(readLines(out[1], warn = FALSE, encoding = "UTF-8"), collapse = "\n")
}

# raw text by extension; "" for anything unreadable, so callers can park it
extract_document_text <- function(path) {
  ext <- tolower(tools::file_ext(path))
  if (ext == "pdf")  return(tryCatch(paste(pdftools::pdf_text(path), collapse = "\n"),
                                     error = function(e) ""))
  if (ext == "docx") return(tryCatch(read_docx_text(path), error = function(e) ""))
  if (ext == "doc")  return(tryCatch(read_doc_text(path),  error = function(e) ""))
  ""
}
