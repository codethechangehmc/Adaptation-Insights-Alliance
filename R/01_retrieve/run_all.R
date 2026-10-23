##############################################################################
# run_all.R — Master runner for all grey literature scrapers
#
# Usage:
#   Rscript R/run_all.R               # Run all enabled scrapers
#   Rscript R/run_all.R worldbank gcf  # Run specific scrapers only
#
# Each scraper runs in an isolated tryCatch so one failure doesn't stop
# the rest. Results are summarised at the end.
##############################################################################

# ── Locate this script's directory ─────────────────────────────────────────
.get_r_dir <- function() {
  tryCatch({
    args <- commandArgs(trailingOnly = FALSE)
    fa <- grep("^--file=", args, value = TRUE)
    if (length(fa)) return(normalizePath(dirname(sub("^--file=", "", fa[1]))))
  }, error = function(e) NULL)
  tryCatch({
    d <- dirname(sys.frame(1)$ofile)
    if (!is.null(d) && nzchar(d)) return(normalizePath(d))
  }, error = function(e) NULL)
  getwd()
}

R_DIR <- .get_r_dir()

# ── Available scrapers (in priority order) ──────────────────────────────────
ALL_SCRAPERS <- c(
  "worldbank",   # World Bank Documents API
  "gcf",         # Green Climate Fund (Drupal AJAX)
  "gef",         # Global Environment Facility
  "afdb",        # African Development Bank      — add when built
  "ifad",        # IFAD evaluations              — add when built
  "af",          # Adaptation Fund               — add when built
  "fao",         # FAO publications              — add when built
  "undp",        # UNDP publications             — add when built
  "unep",        # UNEP publications             — add when built
  "wfp"          # WFP publications              — add when built
)

# Only run scrapers whose script actually exists
enabled_scrapers <- function(names) {
  Filter(function(s) file.exists(file.path(R_DIR, paste0(s, ".R"))), names)
}

# ── Parse command-line arguments ────────────────────────────────────────────
args <- commandArgs(trailingOnly = TRUE)
if (length(args) > 0) {
  requested <- tolower(args)
  to_run <- enabled_scrapers(requested)
  if (length(to_run) == 0) {
    cat("No matching enabled scrapers found for:", paste(requested, collapse = ", "), "\n")
    quit(status = 1)
  }
} else {
  to_run <- enabled_scrapers(ALL_SCRAPERS)
}

cat("╔══════════════════════════════════════════════════════════════╗\n")
cat("║  Africa Adaptation Grey Literature — Master Runner           ║\n")
cat("╚══════════════════════════════════════════════════════════════╝\n")
cat("Scrapers to run:", paste(to_run, collapse = ", "), "\n")
cat("Started:", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "\n\n")

# ── Run each scraper ────────────────────────────────────────────────────────
results <- list()

for (scraper in to_run) {
  script_path <- file.path(R_DIR, paste0(scraper, ".R"))
  cat("──────────────────────────────────────────────────────────────\n")
  cat("Running:", scraper, "\n")
  cat("Script: ", script_path, "\n\n")

  start_time <- proc.time()

  tryCatch({
    # Each scraper is sourced in its own environment to avoid variable collisions
    local_env <- new.env(parent = globalenv())
    sys.source(script_path, envir = local_env)
    elapsed <- (proc.time() - start_time)["elapsed"]
    results[[scraper]] <- list(status = "success", elapsed = elapsed)
    cat("\n✓", scraper, "completed in", round(elapsed / 60, 1), "minutes\n")
  }, error = function(e) {
    elapsed <- (proc.time() - start_time)["elapsed"]
    results[[scraper]] <<- list(status = "error", message = conditionMessage(e), elapsed = elapsed)
    cat("\n✗", scraper, "FAILED:", conditionMessage(e), "\n")
  })

  # Brief pause between scrapers
  if (scraper != tail(to_run, 1)) Sys.sleep(2)
}

# ── Final summary ────────────────────────────────────────────────────────────
cat("\n╔══════════════════════════════════════════════════════════════╗\n")
cat("║  Run Complete                                                ║\n")
cat("╚══════════════════════════════════════════════════════════════╝\n")
cat("Finished:", format(Sys.time(), "%Y-%m-%d %H:%M:%S"), "\n\n")

for (s in names(results)) {
  r <- results[[s]]
  icon <- if (r$status == "success") "✓" else "✗"
  time_str <- paste0(round(r$elapsed / 60, 1), "min")
  if (r$status == "success") {
    cat(icon, s, "-", time_str, "\n")
  } else {
    cat(icon, s, "- ERROR:", r$message, "\n")
  }
}

n_ok  <- sum(sapply(results, `[[`, "status") == "success")
n_err <- sum(sapply(results, `[[`, "status") == "error")
cat("\nTotal:", length(results), "scrapers |", n_ok, "succeeded |", n_err, "failed\n")

# ── Refresh the git mirror of the per-source lists ──────────────────────────
# A scraper writes its metadata next to the documents, in
# 03_Documents/<source>/List, which is the copy everything reads. The repo's
# catalogues/<source>/ is a mirror of that, so GitHub carries a catalogue of a
# corpus that is not itself in git. Nothing reads the mirror, so drift is
# invisible until someone reads a stale filter note on GitHub: it had been
# three months out of date, across eight files, before anyone noticed.
# Running it here is what keeps the two in step.
if (n_ok > 0) {
  sync <- file.path(dirname(R_DIR), "04_catalogue", "sync_metadata.R")
  if (file.exists(sync)) {
    cat("\n── Refreshing catalogues/ from the corpus lists ──\n")
    r <- tryCatch({ sys.source(sync, envir = new.env()); TRUE },
                  error = function(e) { cat("  sync failed:", conditionMessage(e), "\n"); FALSE })
    if (isTRUE(r)) cat("  done; review with git status, then commit\n")
  } else {
    cat("\n  NOTE: sync_metadata.R not found; catalogues/ may now be stale\n")
  }
}
