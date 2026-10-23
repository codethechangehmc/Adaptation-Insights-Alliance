##############################################################################
# prompt_history.R - every version of the extraction prompts, with the actual
# text, pulled out of git.
#
# Two sheets, nothing else:
#   read me         how to read it
#   prompt history  one row per version per prompt block: what was going
#                   wrong, what changed, whether the fix went in the prompt or
#                   in code, and the prompt itself
#
# The prompt text is not retyped here. It is read out of the scripts as they
# stood at the commit that introduced each version, so it cannot drift from
# what actually ran. The notes on what went wrong are curated, from the commit
# log and the score files.
#
#   Rscript R/09_publish/prompt_history.R
##############################################################################

suppressPackageStartupMessages({ library(openxlsx) })

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))

## ---- read the prompts out of git -------------------------------------------
git <- function(...) {
  o <- suppressWarnings(system2("git", c("-C", shQuote(REPO), ...),
                                stdout = TRUE, stderr = FALSE))
  if (is.null(o)) character(0) else o
}

# text from the "(" at or after `from` to its matching ")", ignoring quotes
balanced <- function(s, from) {
  i <- regexpr("(", substr(s, from, nchar(s)), fixed = TRUE)[1]
  if (i < 0) return("")
  i <- from + i - 1
  ch <- strsplit(substr(s, i, nchar(s)), "")[[1]]
  depth <- 0L; inq <- ""; esc <- FALSE
  for (k in seq_along(ch)) {
    c <- ch[k]
    if (esc) { esc <- FALSE
    } else if (c == "\\") { esc <- TRUE
    } else if (nzchar(inq)) { if (c == inq) inq <- ""
    } else if (c == '"' || c == "'") { inq <- c
    } else if (c == "(") { depth <- depth + 1L
    } else if (c == ")") { depth <- depth - 1L
      if (depth == 0L) return(paste(ch[seq_len(k)], collapse = "")) }
  }
  paste(ch, collapse = "")
}

# the literal strings inside an R paste(...) call, joined the way paste joins
strings_in <- function(block) {
  ch <- strsplit(block, "")[[1]]; out <- character(0)
  i <- 1L; n <- length(ch)
  while (i <= n) {
    if (ch[i] == '"' || ch[i] == "'") {
      q <- ch[i]; j <- i + 1L; buf <- character(0); esc <- FALSE
      while (j <= n) {
        d <- ch[j]
        if (esc) { buf <- c(buf, d); esc <- FALSE }
        else if (d == "\\") esc <- TRUE
        else if (d == q) break
        else buf <- c(buf, d)
        j <- j + 1L
      }
      out <- c(out, paste(buf, collapse = "")); i <- j + 1L
    } else i <- i + 1L
  }
  paste(out, collapse = " ")
}

prompt_blocks <- function(src) {
  res <- list()
  m <- regexpr("SYSTEM[ ]*<-[ ]*", src)
  if (m > 0) {
    after <- m + attr(m, "match.length")
    if (substr(src, after, after + 4) == "paste")
      res[["system prompt"]] <- strings_in(balanced(src, after))
    else {
      q <- regmatches(substr(src, after, after + 4000),
                      regexpr('^[ ]*"([^"\\\\]|\\\\.)*"', substr(src, after, after + 4000)))
      if (length(q)) res[["system prompt"]] <- strings_in(q)
    }
  }
  for (g in gregexpr("\n[ ]{0,4}[a-z_]+[ ]*=[ ]*list\\(", src)[[1]]) {
    if (g < 0) next
    nm <- sub("^\n[ ]*([a-z_]+).*$", "\\1",
              regmatches(src, regexpr("\n[ ]{0,4}[a-z_]+[ ]*=[ ]*list\\(",
                                      substr(src, g, nchar(src))))[1])
    nm <- sub("^\n[ ]*", "", sub("[ ]*=.*$", "", substr(src, g + 1, g + 40)))
    blk <- balanced(src, g)
    t <- regexpr("task[ ]*=[ ]*", blk)
    if (t < 0) next
    rest <- substr(blk, t + attr(t, "match.length"), nchar(blk))
    txt <- if (grepl("^[ ]*paste", rest)) strings_in(balanced(rest, 1)) else
      strings_in(regmatches(rest, regexpr('^[ ]*"([^"\\\\]|\\\\.)*"', rest)))
    if (length(txt) && nzchar(txt)) res[[paste(nm, "task")]] <- txt
  }
  k <- 0
  for (h in gregexpr("system_prompt[ ]*=[ ]*paste\\(", src)[[1]]) {
    if (h < 0) next
    k <- k + 1
    res[[paste0("coding instruction ", k)]] <- strings_in(balanced(src, h))
  }
  res
}

FILES <- c("R/05_extract/extract_verbatim.R", "R/extraction/extract_verbatim.R",
           "R/extract_verbatim.R",
           "R/05_extract/extract_locations.R", "R/extraction/extract_locations.R",
           "R/extract_locations.R",
           "R/archive/extract_general.R", "R/extraction/extract_general.R",
           "R/06_harmonise/harmonize.R", "R/extraction/harmonize.R",
           "R/06_harmonise/harmonize_locations.R", "R/extraction/harmonize_locations.R")

rows <- list(); seen <- character(0)
for (path in FILES) {
  log <- git("log", "--reverse", "--date=short", "--pretty=format:%H|%ad", "--", path)
  for (line in log) {
    if (!grepl("\\|", line)) next
    sha <- sub("\\|.*$", "", line); dt <- sub("^.*\\|", "", line)
    src <- paste(git("show", paste0(sha, ":", path)), collapse = "\n")
    if (!nzchar(trimws(src))) next
    v <- regmatches(src, regexpr('(PROMPT_VERSION|HARM_VERSION)[ ]*<-[ ]*"[^"]+"', src))
    if (!length(v)) next
    # the value between the quotes; a greedy ^.*" eats the whole match
    ver <- sub('^[^"]*"([^"]+)".*$', "\\1", v)
    script <- basename(path)
    key <- paste(script, ver)
    if (key %in% seen) next
    seen <- c(seen, key)
    for (nm in names(prompt_blocks(src))) {
      txt <- trimws(gsub("[[:space:]]+", " ", prompt_blocks(src)[[nm]]))
      if (nchar(txt) < 20) next
      rows[[length(rows) + 1L]] <- data.frame(
        version = ver, script = script, date = dt, component = nm,
        chars = nchar(txt), prompt_text = txt, stringsAsFactors = FALSE)
    }
  }
}
P <- do.call(rbind, rows)
stopifnot("no prompts found in git history" = !is.null(P) && nrow(P) > 0)

## ---- did this block change from the version before it? ----------------------
ord <- c("v0.2-qc1", "s1-v0.3", "s1-v0.4", "s1-v0.5", "s1-v0.6", "s1-v0.7",
         "s1-v0.8", "s1-v0.9", "s1-v1.0", "s1-v1.1",
         "loc-v1.0", "loc-v1.1", "loc-v1.2", "loc-v1.3", "loc-v1.4",
         "s2-v0.3", "loc-s2-v1.0")
P$rank <- match(P$version, ord); P$rank[is.na(P$rank)] <- 99
P <- P[order(P$script, P$component, P$rank), ]
P$changed <- "first version"
for (i in seq_len(nrow(P))) {
  if (i == 1) next
  same <- P$script[i] == P$script[i - 1] && P$component[i] == P$component[i - 1]
  if (!same) { P$changed[i] <- "first version"; next }
  P$changed[i] <- if (identical(P$prompt_text[i], P$prompt_text[i - 1]))
    "unchanged" else "CHANGED"
}

## ---- what was going wrong, per version (curated) ---------------------------
why <- data.frame(rbind(
 c("v0.2-qc1","Rules written from the first hand audit of the gold standard: wrong years, report title used as project title, amounts in millions.","prompt"),
 c("s1-v0.3","First working two-session extraction.","prompt"),
 c("s1-v0.4","Early tuning against the gold standard.","prompt"),
 c("s1-v0.5","Long documents were cut at a character limit, so facts in the middle were never seen. A start year sat on page 191 of a 294 page evaluation. Short acronyms matched the wrong organisation.","prompt and code"),
 c("s1-v0.6","Years came from approval or extension dates. Amounts written as 1.71 million. Financing table row labels read as funders.","prompt"),
 c("s1-v0.7","Years still wrong on some projects. Co-implementing agencies named in the body missed. Predecessor programme figures pulled in. Account numbers used as the report id.","prompt and code"),
 c("s1-v0.8","Durations, meeting counts and disbursement rates were filling the three result slots.","prompt and code"),
 c("s1-v0.9","Budget and disbursed confused. French finance sections read badly. Report title still sometimes taken as project title.","prompt"),
 c("s1-v1.0","Indicator tables scramble when a PDF is turned into text, exactly where the numbers live.","prompt and code"),
 c("s1-v1.1","Team review: capitals in titles, document codes in titles, location count as a phrase, gender field left empty, decimals in results, the word percentage instead of a sign.","code"),
 c("loc-v1.0","First location specific extraction, one row per location, intervention and result.","prompt"),
 c("loc-v1.1","The enumeration step found 228 locations but the row step kept 74.","prompt and code"),
 c("loc-v1.2","A verified list of errors from reading the ten documents three ways.","prompt and code"),
 c("loc-v1.3","We had banned workshop counts as results, which contradicted the template's own example unit. Real results were being discarded.","prompt and code"),
 c("loc-v1.4","Beneficiary was often the delivering ministry rather than the people. Rationale was reworded rather than quoted. Coverage counts and rating scales recorded as results.","prompt and code"),
 c("s2-v0.3","The coding step could return a value that is not on the template list, and had to pick an option even when the extract stated nothing.","prompt and code"),
 c("loc-s2-v1.0","Location codes, subsector, beneficiary and result level all needed assigning from verbatim text without inventing codes.","code")),
 stringsAsFactors = FALSE)
names(why) <- c("version", "what_was_going_wrong", "fixed_in")
effect <- c("v0.2-qc1"="first measurable baseline", "s1-v0.6"="round 2: 78% field agreement",
  "s1-v0.7"="round 5: 88% on the corrected gold", "s1-v1.1"="title mismatches 4 to 1",
  "loc-v1.0"="44% of gold locations, 27 of 60 rows", "loc-v1.1"="the biggest single gain in coverage",
  "loc-v1.3"="82% of gold locations, 47 of 60 rows", "loc-v1.4"="84% of gold locations, 50 of 60 rows",
  "s2-v0.3"="32 cells correctly left empty on the gold set")
P <- merge(P, why, by = "version", all.x = TRUE)
P$measured_effect <- unname(effect[P$version]); P$measured_effect[is.na(P$measured_effect)] <- ""
P <- P[order(P$script, P$component, P$rank), ]

# one block at a time, versions in the order they happened, so a row's
# neighbours are the same instruction before and after
P <- P[order(P$script, P$component, P$rank), ]
P$step <- ave(seq_len(nrow(P)), paste(P$script, P$component), FUN = seq_along)
P$delta <- ""
for (i in seq_len(nrow(P))) {
  if (P$step[i] == 1) { P$delta[i] <- "-"; next }
  d <- P$chars[i] - P$chars[i - 1]
  P$delta[i] <- if (d == 0) "same" else sprintf("%+d", d)
}
P$block_label <- paste0(sub("[.]R$", "", P$script), ": ", P$component)

out <- data.frame(
  `Prompt block` = P$block_label,
  Step = P$step,
  Version = P$version,
  Date = P$date,
  `Changed?` = P$changed,
  Characters = P$chars,
  `Change in size` = P$delta,
  `What was going wrong` = P$what_was_going_wrong,
  `Fixed in` = P$fixed_in,
  `Measured effect` = P$measured_effect,
  `The prompt itself` = P$prompt_text,
  check.names = FALSE, stringsAsFactors = FALSE)

## ---- the workbook -----------------------------------------------------------
readme <- data.frame(` ` = c(
 "WHAT THIS IS",
 "Every version of the extraction prompts, with the actual text, and what each",
 "change was trying to fix.",
 "",
 "HOW TO READ IT",
 "One row per version per prompt block. A document is read by a system prompt",
 "plus one instruction per group of fields, so a version has several rows.",
 "Sort by 'Prompt block' to read one instruction down the versions and see how",
 "it grew. The 'Changed from previous' column marks where the text actually",
 "moved, so you can skip the versions where a block stayed the same.",
 "",
 "WHERE THE TEXT COMES FROM",
 "It is read out of the scripts as they stood at the commit that introduced each",
 "version, not retyped, so it cannot drift from what really ran.",
 "",
 "WHY 'FIXED IN' MATTERS",
 "A fix in code is deterministic and free, and it applies to old runs when they",
 "are reprocessed. A fix in the prompt costs a rerun of the documents. We move a",
 "rule into code whenever the answer is mechanical, which is why the later rows",
 "say code.",
 "",
 "THE THIRD KIND OF FIX",
 "Some disagreements could not be fixed either way, because the template does",
 "not say what the right answer is. Those became questions for the template",
 "owner. They are tracked in QC_Common_Mistakes.docx, not here.",
 "",
 "Rebuilt with: Rscript 07_Pipeline/R/09_publish/prompt_history.R"),
 check.names = FALSE, stringsAsFactors = FALSE)

wb <- createWorkbook()
hdr  <- createStyle(textDecoration = "bold", fgFill = "#DCE9F5", border = "bottom", valign = "top")
wrap <- createStyle(wrapText = TRUE, valign = "top")
boldc<- createStyle(textDecoration = "bold", valign = "top")
small<- createStyle(fontSize = 9, wrapText = TRUE, valign = "top")

addWorksheet(wb, "read me")
writeData(wb, "read me", readme)
setColWidths(wb, "read me", 1, 92)
addStyle(wb, "read me", boldc, rows = c(2, 6, 13, 17, 23), cols = 1, gridExpand = TRUE)

addWorksheet(wb, "prompt history")
writeData(wb, "prompt history", out, headerStyle = hdr, withFilter = TRUE)
setColWidths(wb, "prompt history", 1:11, c(34, 6, 13, 11, 16, 11, 13, 54, 16, 30, 120))
addStyle(wb, "prompt history", wrap, rows = 2:(nrow(out) + 1), cols = 1:10, gridExpand = TRUE)
addStyle(wb, "prompt history", small, rows = 2:(nrow(out) + 1), cols = 11, gridExpand = TRUE)
addStyle(wb, "prompt history", boldc, rows = 2:(nrow(out) + 1), cols = 1, gridExpand = TRUE)
# a line above each new block, so the groups are visible without reading
newblock <- which(out$Step == 1) + 1
addStyle(wb, "prompt history",
         createStyle(border = "top", borderColour = "#4472C4", borderStyle = "medium",
                     wrapText = TRUE, valign = "top"),
         rows = newblock, cols = 1:11, gridExpand = TRUE, stack = TRUE)
changed <- which(out[["Changed?"]] == "CHANGED") + 1
if (length(changed))
  addStyle(wb, "prompt history",
           createStyle(fgFill = "#FFF2CC", wrapText = TRUE, valign = "top"),
           rows = changed, cols = 5:7, gridExpand = TRUE, stack = TRUE)
freezePane(wb, "prompt history", firstActiveRow = 2, firstActiveCol = 4)
for (r in 2:(nrow(out) + 1)) setRowHeights(wb, "prompt history", r, 90)

f <- file.path(RESULTS_DIR, "prompt_history.xlsx")
writable <- function(p) {
  if (!file.exists(p)) return(TRUE)
  con <- suppressWarnings(try(file(p, "ab"), silent = TRUE))
  if (inherits(con, "try-error")) return(FALSE)
  close(con); TRUE
}
if (!writable(f)) f <- sub("[.]xlsx$", format(Sys.time(), "_%Y%m%d_%H%M.xlsx"), f)
saveWorkbook(wb, f, overwrite = TRUE)
cat("written:", f, "\n")
cat("  versions:", length(unique(out$Version)),
    "| prompt blocks:", nrow(out),
    "| blocks that changed:", sum(out[["Changed?"]] == "CHANGED"), "\n")
