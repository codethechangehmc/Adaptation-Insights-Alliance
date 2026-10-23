##############################################################################
# figure_workflow.R - the one-page picture of the pipeline for the protocol.
#
# Draws 01_Protocol/workflow.png (next to the Word diagram): where documents come from, what runs, the accuracy
# gate that decides whether we tune again or go to the full corpus, and every
# file the run leaves behind. Base graphics only, so it regenerates anywhere
# R runs and needs no diagram tool.
#
# Keep it in step with Section 7 of the protocol. If a step or an output
# changes, change it here and re-run - the figure is generated, not drawn by
# hand, so it cannot quietly fall out of date.
#
#   Rscript R/09_publish/figure_workflow.R
##############################################################################

full <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
REPO <- normalizePath(file.path(dirname(sub("^--file=", "", full[1])), "..", ".."), mustWork = TRUE)
source(file.path(REPO, "R", "00_shared", "paths.R"))
OUT  <- file.path(PROTOCOL_DIR, "workflow.png")

BLUE <- "#1B75BC"; BLUE_D <- "#125A91"; GREY <- "#6B6B6B"; INK <- "#222222"

# shaped for a portrait page: it sits at about 7 inches wide in the
# protocol, so it is built tall rather than wide
png(OUT, width = 1350, height = 1300, res = 150)
op <- par(mar = c(0, 0, 0, 0), xaxs = "i", yaxs = "i")
plot(NA, xlim = c(0, 100), ylim = c(0, 100), axes = FALSE, xlab = "", ylab = "")

# rounded rectangle
rbox <- function(x, y, w, h, r = 1.2, fill = BLUE, border = NA) {
  a <- seq(0, pi / 2, length.out = 12)
  xs <- c(x - w/2 + r - r*cos(a), x + w/2 - r + r*sin(a),
          x + w/2 - r + r*cos(a), x - w/2 + r - r*sin(a))
  ys <- c(y + h/2 - r + r*sin(a), y + h/2 - r + r*cos(a),
          y - h/2 + r - r*sin(a), y - h/2 + r - r*cos(a))
  polygon(xs, ys, col = fill, border = border)
}
label <- function(x, y, lines, cex = 0.72, col = "white", font = 1) {
  n <- length(lines); step <- 2.1 * cex
  for (i in seq_len(n))
    text(x, y + (n - 1) / 2 * step - (i - 1) * step, lines[i],
         col = col, cex = cex, font = font)
}
node <- function(x, y, w, h, lines, fill = BLUE, cex = 0.72, font = 1) {
  rbox(x, y, w, h, fill = fill); label(x, y, lines, cex = cex, font = font)
}
# decision
diamond <- function(x, y, w, h, lines, cex = 0.7) {
  polygon(c(x, x + w/2, x, x - w/2), c(y + h/2, y, y - h/2, y),
          col = BLUE_D, border = NA)
  label(x, y, lines, cex = cex)
}
# stacked-document shape: what the output is called, then the file it is
docs <- function(x, y, w, h, title, files, cex = 0.6, fcex = 0.46) {
  for (k in 2:1) rbox(x + k * 0.7, y + k * 0.7, w, h, fill = "#7FB5DF")
  rbox(x, y, w, h, fill = BLUE)
  nt <- length(title); nf <- length(files)
  ty <- y + h/2 - 2.4
  for (i in seq_len(nt)) text(x, ty - (i - 1) * 2.1 * cex, title[i],
                              col = "white", cex = cex, font = 2)
  fy <- ty - nt * 2.1 * cex - 1.1
  for (i in seq_len(nf)) text(x, fy - (i - 1) * 2.0 * fcex, files[i],
                              col = "#CFE4F5", cex = fcex)
}
arrow <- function(x0, y0, x1, y1) arrows(x0, y0, x1, y1, length = 0.09,
                                         col = GREY, lwd = 1.6, xpd = NA)
elbow <- function(pts) {                       # right-angled connector
  for (i in seq_len(nrow(pts) - 2))
    segments(pts[i, 1], pts[i, 2], pts[i + 1, 1], pts[i + 1, 2], col = GREY, lwd = 1.6)
  n <- nrow(pts); arrow(pts[n - 1, 1], pts[n - 1, 2], pts[n, 1], pts[n, 2])
}

text(3, 97, "EXTRACTION WORKFLOW", adj = 0, cex = 1.25, font = 2, col = INK)
text(3, 93.6, "what runs, what it is checked against, and what it leaves behind",
     adj = 0, cex = 0.66, col = GREY)

SP <- 30                                        # the spine
node(SP, 88, 40, 6.5, c("Documents", "03_Documents\\{source}\\  -  in-scope only"), cex = 0.66)
arrow(SP, 84.7, SP, 82.8)
node(SP, 79, 40, 6.5, c("Session 1  -  verbatim extraction",
                        "every quote checked against its page"), cex = 0.66)
arrow(SP, 75.7, SP, 73.8)
node(SP, 70, 40, 6.5, c("Session 2  -  coding",
                        "verbatim extract into controlled vocabularies"), cex = 0.66)
arrow(SP, 66.7, SP, 64.8)

diamond(SP, 58, 34, 11, c("Accuracy against the gold", "standard above threshold?"), cex = 0.66)
text(SP - 18.5, 58, "on a subset of", adj = 1, cex = 0.58, col = GREY)
text(SP - 18.5, 55.6, "10 gold documents", adj = 1, cex = 0.58, col = GREY)

# NO - tune and come back
text(SP + 18.5, 60, "NO", adj = 0, cex = 0.62, col = INK)
node(78, 58, 38, 13, c("Improve the prompts", "sharpen the field definitions",
                       "add the actors and locations", "the documents actually name"),
     fill = BLUE_D, cex = 0.62)
arrow(SP + 17, 58, 59, 58)
elbow(rbind(c(78, 64.5), c(78, 79), c(50.5, 79)))
text(80, 72, "run it again", adj = 0, cex = 0.58, col = GREY)

# YES - go to the whole corpus
text(SP + 1.5, 53.5, "YES", adj = 0, cex = 0.62, col = INK)
arrow(SP, 52.5, SP, 50.8)
node(SP, 45.5, 40, 6.5, c("Run on the full corpus", "656 in-scope documents"), cex = 0.66)

text(50, 39.5, "what a run leaves behind", cex = 0.72, font = 2, col = INK)
segments(SP, 42.2, SP, 41.2, col = GREY, lwd = 1.6)
segments(SP, 38.2, SP, 36.6, col = GREY, lwd = 1.6)
segments(17, 36.6, 83, 36.6, col = GREY, lwd = 1.6)
xs <- c(17, 50, 83)
for (x in xs) arrow(x, 36.6, x, 33.6)

R1 <- "05_Extraction_Results\\gold_pilot\\"
R2 <- "05_Extraction_Results\\review\\"
docs(xs[1], 27, 31, 12, c("EXTRACTED DATA"),
     c(paste0(R1, "extracted_records_latest.xlsx"),
       paste0(R1, "location_records_latest.xlsx")), cex = 0.66, fcex = 0.5)
docs(xs[2], 27, 31, 12, c("Proposed new actors"),
     c(paste0(R2, "proposed_new_actors"), "_AUDIT.xlsx"), cex = 0.66, fcex = 0.5)
docs(xs[3], 27, 31, 12, c("Proposed new locations"),
     c(paste0(R2, "proposed_new_locations"), "_AUDIT.xlsx"), cex = 0.66, fcex = 0.5)


docs(xs[1], 11.5, 31, 12, c("Fields to check by hand"),
     c("the needs_review sheet", "inside both workbooks"), cex = 0.66, fcex = 0.5)
docs(xs[2], 11.5, 31, 12, c("Questions for the template owner"),
     c(paste0(R2, "candidate_vocab_log.csv"),
       "01_Protocol\\QC_Common_Mistakes.docx"), cex = 0.62, fcex = 0.5)
docs(xs[3], 11.5, 31, 12, c("Cost and model use"),
     c("not yet written -", "printed to the console only"), cex = 0.66, fcex = 0.5)

text(50, 3.2, "the first is the result; the other five are what needs a person",
     cex = 0.62, col = GREY)

par(op); invisible(dev.off())
cat("written:", OUT, "\n")
