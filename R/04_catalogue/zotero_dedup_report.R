##############################################################################
# zotero_dedup_report.R — standing duplicate report for the group library
#
# Scans ALL report items (pipeline-managed and manually-added) and lists
# potential duplicate pairs by, in order of confidence:
#   1. attachment file MD5 (same bytes)
#   2. shared project/report identifier (P-codes, AfDB codes, GEF ids,
#      GCF FP/SAP codes, AF codes, ICR numbers) found in title/fields/extra
#   3. identical URL
#   4. identical normalized title (report-only confidence)
#
# NEVER deletes or merges — writes Data/zotero_duplicate_report.csv (and a
# copy into the repo catalogues/) for team review. Zotero's own "Duplicate
# Items" pane remains the built-in fallback for eyeballing.
#
# Usage: Rscript R/zotero_dedup_report.R   (after a sync)
##############################################################################

suppressPackageStartupMessages({
  library(httr); library(jsonlite); library(dplyr); library(readr); library(stringr)
})
API_KEY <- Sys.getenv("ZOTERO_API_KEY"); LIB <- Sys.getenv("ZOTERO_LIBRARY_ID")
stopifnot(nzchar(API_KEY), nzchar(LIB))
BASE <- paste0("https://api.zotero.org/groups/", LIB)
H <- add_headers("Zotero-API-Key" = API_KEY, "Zotero-API-Version" = "3")
GL <- "C:/Users/mlolita/OneDrive - CGIAR/WP2_Evidence Synthesis/Grey Literature"

get_all <- function(type) {
  out <- list(); start <- 0
  repeat {
    r <- GET(paste0(BASE, "/items?limit=100&start=", start, "&itemType=", type), H)
    stop_for_status(r)
    js <- fromJSON(content(r, "text", encoding = "UTF-8"), simplifyVector = FALSE)
    if (length(js) == 0) break
    out <- c(out, js); start <- start + 100
    if (start >= as.numeric(headers(r)[["total-results"]])) break
  }
  out
}

ID_RE <- paste(
  "P\\d{6}",                                  # WB project
  "P-[A-Z0-9]{2}-[A-Z0-9]{3}-\\d{3}",         # AfDB project
  "ICR\\d{3,}",                               # WB report no
  "\\b(FP|SAP)\\d{3}\\b",                     # GCF
  "\\b\\d{3}[A-Z]{4,8}R?\\b",                 # AF project codes (e.g. 007NSNCR)
  sep = "|")

reports <- get_all("report")
atts <- get_all("attachment")
att_df <- bind_rows(lapply(atts, function(a) tibble(
  key = a$key,
  parent = coalesce(a$data$parentItem, ""),
  md5 = coalesce(a$data$md5, ""),
  fname = coalesce(a$data$filename, coalesce(a$data$title, "")))))

rows <- bind_rows(lapply(reports, function(it) {
  tags <- vapply(it$data$tags, function(t) t$tag, character(1))
  doc <- tags[grepl("^(wbdoc|gefdoc|afdbdoc|gcfdoc|afdoc|cifdoc):", tags)]
  blob <- paste(coalesce(it$data$title, ""), coalesce(it$data$extra, ""),
                coalesce(it$data$callNumber, ""), coalesce(it$data$reportNumber, ""),
                coalesce(it$data$url, ""))
  tibble(
    key = it$key,
    managed = length(doc) > 0,
    title = coalesce(it$data$title, ""),
    ntitle = str_squish(gsub("[^a-z0-9 ]", "", tolower(coalesce(it$data$title, "")))),
    url = sub("/$", "", sub("\\?.*$", "", tolower(coalesce(it$data$url, "")))),
    ids = paste(unique(toupper(unlist(str_extract_all(blob, ID_RE)))), collapse = ";")
  )
}))
rows$md5s <- vapply(rows$key, function(k) {
  m <- att_df$md5[att_df$parent == k & nzchar(att_df$md5)]
  paste(unique(m), collapse = ";")
}, character(1))

pairs <- list()
add_pair <- function(a, b, on, conf) {
  pairs[[length(pairs) + 1]] <<- tibble(
    key_a = a$key, title_a = substr(a$title, 1, 60), managed_a = a$managed,
    key_b = b$key, title_b = substr(b$title, 1, 60), managed_b = b$managed,
    matched_on = on, confidence = conf)
}

n <- nrow(rows)
for (i in seq_len(n - 1)) for (j in (i + 1):n) {
  a <- rows[i, ]; b <- rows[j, ]
  if (a$managed && b$managed) next   # pipeline items are already tag-deduped
  ma <- strsplit(a$md5s, ";")[[1]]; mb <- strsplit(b$md5s, ";")[[1]]
  if (length(intersect(ma[nzchar(ma)], mb[nzchar(mb)])) > 0) {
    add_pair(a, b, "md5", "high"); next
  }
  ia <- strsplit(a$ids, ";")[[1]]; ib <- strsplit(b$ids, ";")[[1]]
  common <- intersect(ia[nzchar(ia)], ib[nzchar(ib)])
  if (length(common) > 0) { add_pair(a, b, paste0("identifier:", common[1]), "high"); next }
  if (nzchar(a$url) && identical(a$url, b$url)) { add_pair(a, b, "url", "high"); next }
  if (nchar(a$ntitle) > 25 && identical(a$ntitle, b$ntitle)) {
    add_pair(a, b, "title", "review-only")
  }
}

# --- standalone attachments (no parent item, e.g. PDFs dropped straight into
# a collection by teammates): compare by md5 against report-item attachments
# and against each other. These are invisible to the item-level checks above.
standalone <- att_df %>% filter(!nzchar(parent), nzchar(md5))
parented   <- att_df %>% filter(nzchar(parent), nzchar(md5))
if (nrow(standalone)) {
  rep_title <- setNames(rows$title, rows$key)
  hit <- standalone %>% inner_join(parented, by = "md5", suffix = c("_s", "_p"))
  for (k in seq_len(nrow(hit))) {
    h <- hit[k, ]
    pmanaged <- isTRUE(rows$managed[rows$key == h$parent_p])
    ptitle <- rep_title[h$parent_p]
    add_pair(
      list(key = h$key_s, title = paste0("[standalone] ", h$fname_s), managed = FALSE),
      list(key = h$parent_p,
           title = if (!is.na(ptitle)) unname(ptitle) else h$fname_p,
           managed = pmanaged),
      "md5(standalone-att)", "high")
  }
  dupmd5 <- standalone %>% count(md5) %>% filter(n > 1)
  for (m in dupmd5$md5) {
    g <- standalone %>% filter(md5 == m)
    for (i in seq_len(nrow(g) - 1)) add_pair(
      list(key = g$key[i], title = paste0("[standalone] ", g$fname[i]), managed = FALSE),
      list(key = g$key[i + 1], title = paste0("[standalone] ", g$fname[i + 1]), managed = FALSE),
      "md5(standalone-standalone)", "high")
  }
}

report <- if (length(pairs)) bind_rows(pairs) else
  tibble(key_a = character(), title_a = character(), managed_a = logical(),
         key_b = character(), title_b = character(), managed_b = logical(),
         matched_on = character(), confidence = character())
out1 <- file.path(GL, "04_Screening/inputs/reports/zotero_duplicate_report.csv")
out2 <- file.path(GL, "07_Pipeline/catalogues/zotero_duplicate_report.csv")
write_csv(report, out1); write_csv(report, out2)
cat("report items:", n, "| standalone attachments:", nrow(standalone),
    "| potential duplicate pairs:", nrow(report), "\n")
cat("written:", out1, "\n")
if (nrow(report)) print(head(report %>% select(matched_on, confidence, title_a, title_b), 10))
