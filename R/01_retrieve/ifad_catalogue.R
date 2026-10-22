##############################################################################
# ifad_catalogue.R — the IFAD document catalogue, without downloading anything.
#
# IFAD publishes its project data through IATI, which D-Portal mirrors openly.
# The document FILES are a different matter: every URL in the IATI records
# points at operations.ifad.org, whose TLS handshake is refused by every client
# tested, including a real Chrome. The files that do exist sit behind Cloudflare
# on www.ifad.org and are served to people, not to scripts.
#
# So this script does the half that works, and does it properly: it produces a
# precise list of IFAD's African project documents — what they are, which
# project they belong to, and where a person can click them. That list is
# useful on its own, and it is what any later retrieval effort would need
# first, whether that is a person downloading them or IFAD sending a bulk copy.
#
# Writes:
#   catalogues/ifad/ifad_projects.csv    one row per African IFAD project
#   catalogues/ifad/ifad_documents.csv   one row per document, best type first
#   catalogues/ifad/ifad_cache/          per-activity XSON, so a rerun is cheap
#
#   Rscript R/01_retrieve/ifad_catalogue.R [--limit N] [--refresh]
##############################################################################

suppressPackageStartupMessages({ library(httr); library(jsonlite) })

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))

args    <- commandArgs(trailingOnly = TRUE)
opt     <- function(f, d = "") { i <- which(args == f); if (length(i) && length(args) > i[1]) args[i[1] + 1] else d }
LIMIT   <- suppressWarnings(as.integer(opt("--limit", NA)))
REFRESH <- any(args == "--refresh")

OUT   <- file.path(REPO, "catalogues", "ifad")
CACHE <- file.path(OUT, "ifad_cache")
dir.create(CACHE, recursive = TRUE, showWarnings = FALSE)

UA  <- "CGIAR WP2 evidence synthesis (M.Lolita@cgiar.org)"
PUB <- "XM-DAC-41108"
Q   <- "https://d-portal.org/q.json"

# IATI document categories, ranked by how complete the evidence is. A document
# carries SEVERAL of these and the useful one can be anywhere in the list, so
# the best-ranked code wins rather than the first.
PRIO <- c(A08 = 1L, B05 = 2L, B09 = 3L, A06 = 4L, A04 = 5L,
          A07 = 6L, A09 = 7L, A01 = 8L, A02 = 9L, A03 = 10L, A05 = 11L)
LABEL <- c(A08 = "final evaluation / PPAR", B05 = "country programme evaluation",
           B09 = "performance audit",       A06 = "supervision / M&E",
           A04 = "appraisal / design",      A07 = "annual / progress",
           A09 = "other project document",  A01 = "pre-project",
           A02 = "objectives",              A03 = "budget",
           A05 = "review of project performance")

AFRICA <- c("DZ","AO","BJ","BW","BF","BI","CV","CM","CF","TD","KM","CG","CD","CI",
            "DJ","EG","GQ","ER","SZ","ET","GA","GM","GH","GN","GW","KE","LS","LR",
            "LY","MG","MW","ML","MR","MU","MA","MZ","NA","NE","NG","RW","ST","SN",
            "SC","SL","SO","ZA","SS","SD","TZ","TG","TN","UG","ZM","ZW")

`%||%` <- function(a, b) if (is.null(a) || !length(a)) b else a

get_json <- function(url, query = list(), tries = 3L) {
  for (k in seq_len(tries)) {
    r <- tryCatch(GET(url, query = query, user_agent(UA), timeout(60)),
                  error = function(e) NULL)
    if (!is.null(r) && status_code(r) == 200) {
      j <- tryCatch(fromJSON(content(r, "text", encoding = "UTF-8"),
                             simplifyVector = FALSE), error = function(e) NULL)
      if (!is.null(j)) return(j)
    }
    Sys.sleep(1.5 * k)
  }
  NULL
}

## ---- 1. every African IFAD activity ----------------------------------------
cat("querying D-Portal for", length(AFRICA), "African countries\n")
rows <- list()
for (cc in AFRICA) {
  j <- get_json(Q, list(reporting_ref = PUB, country_code = cc, limit = 500))
  rr <- (j %||% list())$rows %||% list()
  for (r in rr) rows[[length(rows) + 1]] <- list(
    aid = r$aid %||% "", country = cc, title = r$title %||% "",
    description = r$description %||% "", status = as.character(r$status_code %||% ""),
    day_start = as.integer(r$day_start %||% NA), day_end = as.integer(r$day_end %||% NA),
    commitment = as.numeric(r$commitment %||% NA))
  Sys.sleep(0.25)
}
cat("  activity-country rows:", length(rows), "\n")

P <- do.call(rbind, lapply(rows, function(x) data.frame(x, stringsAsFactors = FALSE)))
P <- P[nzchar(P$aid), ]
P$project_id <- sub("^.*-", "", P$aid)
# D-Portal day numbers are days since 1970-01-01
P$start_year <- ifelse(is.na(P$day_start), NA, as.integer(format(as.Date(P$day_start, origin = "1970-01-01"), "%Y")))
P$end_year   <- ifelse(is.na(P$day_end),   NA, as.integer(format(as.Date(P$day_end,   origin = "1970-01-01"), "%Y")))
P <- P[!duplicated(P$aid), ]
cat("  distinct projects:", nrow(P), "\n")

# keep anything that could still have an evaluation: ended 2005 or later, or
# still running. The corpus year rule is applied later, on the document date.
keep <- is.na(P$end_year) | P$end_year >= 2005
P <- P[keep, ]
cat("  ending 2005 or later, or still running:", nrow(P), "\n")
if (!is.na(LIMIT)) P <- head(P, LIMIT)

## ---- 2. document links per activity, cached --------------------------------
cat("\nfetching document links for", nrow(P), "projects\n")
docs <- list(); nd <- 0L
for (i in seq_len(nrow(P))) {
  aid <- P$aid[i]
  cf  <- file.path(CACHE, paste0(gsub("[^A-Za-z0-9_-]", "_", aid), ".json"))
  j <- NULL
  if (!REFRESH && file.exists(cf))
    j <- tryCatch(fromJSON(readLines(cf, warn = FALSE), simplifyVector = FALSE),
                  error = function(e) NULL)
  if (is.null(j)) {
    j <- get_json(Q, list(aid = aid, form = "xson"))
    if (!is.null(j)) writeLines(toJSON(j, auto_unbox = TRUE), cf)
    Sys.sleep(0.35)
  }
  a <- tryCatch(j$xson[[1]][["/iati-activities/iati-activity"]][[1]],
                error = function(e) NULL)
  for (dl in (a %||% list())[["/document-link"]] %||% list()) {
    cats <- unlist(lapply(dl[["/category"]] %||% list(), function(c) c[["@code"]] %||% NA))
    cats <- cats[!is.na(cats) & nzchar(cats)]
    if (!length(cats) || all(cats == "A12")) next
    rk   <- vapply(cats, function(c) { v <- PRIO[c]; if (is.na(v)) 99L else as.integer(v) }, integer(1), USE.NAMES = FALSE)
    best <- cats[which.min(rk)]
    # IATI narrative text sits under an EMPTY key: {"": "the title",
    # "@xml:lang": "EN"}. jsonlite does not keep that empty name, it renames
    # the slot to "1", so neither [[""]] nor names(x) == "" finds it and both
    # silently yield blank titles. The stable rule is: take the first element
    # whose name is not an XML attribute.
    ttl <- tryCatch({
      nn <- dl[["/title/narrative"]][[1]]
      k  <- which(!startsWith(names(nn) %||% "", "@"))
      if (length(k)) as.character(nn[[k[1]]])[1] else ""
    }, error = function(e) "")
    nd <- nd + 1L
    docs[[nd]] <- data.frame(
      project_id = P$project_id[i], aid = aid, country = P$country[i],
      project_title = P$title[i], doc_title = ttl,
      doc_category = best, doc_type = unname(LABEL[best] %||% best),
      priority = min(rk), categories_all = paste(cats, collapse = ","),
      format = dl[["@format"]] %||% "", url = dl[["@url"]] %||% "",
      project_page = paste0("https://www.ifad.org/w/projects/", P$project_id[i]),
      start_year = P$start_year[i], end_year = P$end_year[i],
      stringsAsFactors = FALSE)
  }
  if (i %% 25 == 0) cat("   ", i, "of", nrow(P), "|", nd, "documents so far\n")
}

D <- if (nd) do.call(rbind, docs) else data.frame()
cat("\ndocuments found:", nrow(D), "\n")

## ---- 3. write --------------------------------------------------------------
wr <- function(df, f) {
  p <- file.path(OUT, f); t <- paste0(p, ".tmp")
  write.csv(df, t, row.names = FALSE, na = "")
  invisible(file.rename(t, p)); cat("written:", p, "(", nrow(df), "rows )\n")
}
wr(P, "ifad_projects.csv")
if (nrow(D)) {
  D <- D[order(D$priority, D$country, D$project_id), ]
  wr(D, "ifad_documents.csv")
  cat("\ndocuments by type:\n")
  print(sort(table(D$doc_type), decreasing = TRUE))
  cat("\nprojects with at least one document:", length(unique(D$project_id)),
      "of", nrow(P), "\n")
  ev <- D[D$priority <= 3, ]
  cat("evaluation-grade documents (final evaluation, CPE, audit):", nrow(ev),
      "across", length(unique(ev$project_id)), "projects\n")
}
