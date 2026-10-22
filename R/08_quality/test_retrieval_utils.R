# test_retrieval_utils.R - offline regression tests for the shared retrieval
# layer added in the Oct 2026 corpus-completion campaign (01_utils.R):
# valid_local_file, download validation kinds, assert_response, attestation
# ledger. Live canaries are exercised separately at scraper start via
# canary_check(); these tests need no network.
#
#   Rscript R/08_quality/test_retrieval_utils.R    -> PASS/FAIL per test

.find_r_dir <- function() {
  full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  normalizePath(file.path(dirname(sub("^--file=", "", full[1])), ".."), mustWork = TRUE)
}
R_DIR <- .find_r_dir()
suppressMessages({
  source(file.path(R_DIR, "00_shared", "00_config.R"))
  source(file.path(R_DIR, "00_shared", "01_utils.R"))
})
PATHS$log_file <- file.path(tempdir(), "download_log_test.csv")   # never the real log

n_pass <- 0L; n_fail <- 0L
check <- function(name, cond) {
  if (isTRUE(cond)) { n_pass <<- n_pass + 1L; cat("PASS", name, "\n") }
  else              { n_fail <<- n_fail + 1L; cat("FAIL", name, "\n") }
}
expect_error <- function(name, expr) {
  got <- tryCatch({ expr; FALSE }, error = function(e) TRUE)
  check(name, got)
}

## ---- valid_local_file -------------------------------------------------------
tmp <- tempfile(fileext = ".pdf")
writeBin(c(charToRaw("%PDF-"), as.raw(rep(32L, 11000))), tmp)
check("valid pdf accepted", valid_local_file(tmp, "pdf"))
file.remove(tmp)

tmp <- tempfile(fileext = ".pdf")
writeBin(charToRaw("%PDF- too small"), tmp)
check("undersized pdf rejected", !valid_local_file(tmp, "pdf"))
file.remove(tmp)

tmp <- tempfile(fileext = ".pdf")
writeBin(c(charToRaw("<html>err"), as.raw(rep(32L, 11000))), tmp)
check("html-masquerading pdf rejected", !valid_local_file(tmp, "pdf"))
file.remove(tmp)

tmp <- tempfile(fileext = ".docx")
writeBin(c(as.raw(c(0x50, 0x4B, 0x03, 0x04)), as.raw(rep(0L, 3000))), tmp)
check("zip-magic docx accepted", valid_local_file(tmp, "docx"))
check("kind inferred from extension", valid_local_file(tmp))
file.remove(tmp)

tmp <- tempfile(fileext = ".doc")
writeBin(c(as.raw(c(0xD0, 0xCF, 0x11, 0xE0)), as.raw(rep(0L, 5000))), tmp)
check("ole2 doc accepted", valid_local_file(tmp, "doc"))
file.remove(tmp)

check("missing file rejected", !valid_local_file(tempfile(), "pdf"))

## ---- assert_response --------------------------------------------------------
fake <- function(status, body, ct = "text/html; charset=utf-8") {
  structure(list(status_code = as.integer(status),
                 headers = structure(list(`content-type` = ct),
                                     class = c("insensitive", "list")),
                 content = charToRaw(body),
                 url = "http://fake.test/x"),
            class = "response")
}
pcr_page  <- "<html><head><title>Project/Programme Completion Reports</title></head><body>Displaying 1 - 21 of 1246</body></html>"
wild_page <- "<html><head><title>Evaluation Reports</title></head><body>Displaying 1 - 18 of 522</body></html>"
EXPECT <- list(title = "Completion Reports", contains = "Displaying 1 - \\d+ of \\d+")

check("matching view passes",
      !is.null(assert_response(fake(200, pcr_page), "u", EXPECT, on_fail = "quiet")))
check("wildcard parent view FAILS on title",
      is.null(assert_response(fake(200, wild_page), "u", EXPECT, on_fail = "quiet")))
check("http error fails",
      is.null(assert_response(fake(404, pcr_page), "u", EXPECT, on_fail = "quiet")))
check("NULL response fails",
      is.null(assert_response(NULL, "u", EXPECT, on_fail = "quiet")))
check("not_contains catches the generic-view signature",
      is.null(assert_response(fake(200, wild_page), "u",
        list(not_contains = "of 522"), on_fail = "quiet")))
check("json total check: zero fails",
      is.null(assert_response(fake(200, '{"total":0,"rows":[]}', ct = "application/json"), "u",
        list(check = function(b) if (jsonlite::fromJSON(b)$total > 0) TRUE else "total == 0"),
        on_fail = "quiet")))
check("json total check: nonzero passes",
      !is.null(assert_response(fake(200, '{"total":8617}', ct = "application/json"), "u",
        list(check = function(b) if (jsonlite::fromJSON(b)$total > 0) TRUE else "total == 0"),
        on_fail = "quiet")))
expect_error("on_fail=stop stops",
             assert_response(fake(200, wild_page), "u", EXPECT, on_fail = "stop"))

## ---- attestation ledger -----------------------------------------------------
PROJECT_ROOT <- tempdir()   # shadow the global so the ledger lands in temp
df <- data.frame(site_id = c("a", "b"), title = c("T1", "T2"),
                 doc_type_site = "PCR", listing = "pcr",
                 disposition = c("fetched", "out_by_type"),
                 local_filename = c("x.pdf", NA), notes = NA,
                 stringsAsFactors = FALSE)
write_attestation("zz_test", df)
back <- read_attestation("zz_test")
check("ledger roundtrip", nrow(back) == 2 && all(back$disposition == c("fetched", "out_by_type")))
d1 <- back$discovered_at[back$site_id == "a"]
write_attestation("zz_test", df)   # rewrite: discovered_at must be carried
back2 <- read_attestation("zz_test")
check("discovered_at carried across rewrites", back2$discovered_at[back2$site_id == "a"] == d1)
df$disposition[1] <- "not_a_thing"
expect_error("disposition outside vocabulary refused", write_attestation("zz_test", df))
unlink(file.path(tempdir(), "catalogues"), recursive = TRUE)

cat(sprintf("\n%d passed, %d failed\n", n_pass, n_fail))
if (n_fail > 0) quit(status = 1)
