# Headline results: which three of a document's results are the main ones.
#
# Rule from the survey of 50 random in-scope documents (28 Sep 2026,
# 05_Extraction_Results/review/headline_results_survey/README.md). A reader did
# the same thing in every document: first decide what counts as a result, then
# take the project's reach, its main physical achievement and its main measured
# effect, each the largest project-level figure of its kind. The largest number
# in a document was one of the three in only 14 of 50 cases, so magnitude
# decides only inside a slot, never across slots.
#
# Two entry points, both used by extract_verbatim.R (fold_results) and by
# R/05_extract/refold_results.R (re-applies the rule to a finished run without
# new API calls):
#   results_gate(rl, family_module, pages_txt)  drops what is not a result
#   choose_headline(rl)                          fills the three slots
# rl is a list of result entries as Session 1 returns them (value,
# metric_stated, unit_stated, indicator_level, status, scope, page, and since
# prompt s1-v2.5 value_type, category, project_total, in_summary).

`%||%` <- function(a, b) if (is.null(a) || !length(a) || is.na(a[1])) b else a

rr_txt <- function(r, f) tolower(trimws(as.character(r[[f]] %||% "")))
rr_num <- function(v) {
  v <- gsub("[^0-9.]", "", as.character(v %||% ""))
  suppressWarnings(as.numeric(v))
}

RR_PEOPLE <- paste0(
  "beneficiar|bénéficiaire|household|ménage|farmer|agricult|producteur|producer|",
  "people|persons?\\b|individuals|women|femmes|\\bmen\\b|youth|jeunes|girls|children|enfants|",
  "pastoralist|fisher|herder|trainees?|participants?|members|residents|inhabitants|",
  "families|jobs|emplois|employ|users|clients|students|pupils|staff|agripreneur|",
  "entrepreneur|smallholder|returnees|refugees|communit(y|ies) members|managers|\\bmales?\\b|\\bfemales?\\b")
RR_INDIRECT <- "indirect|population of the|population in the|catchment population|potential beneficiar|population living"
RR_SUBGROUP <- "female|women|femmes|\\bmen\\b|\\bmales?\\b|youth|jeunes|girls|boys|headed|of which|\\bdont\\b|disaggregat|\\bother (vulnerable|households?|groups?|beneficiar)"
RR_BOTH_SEXES <- "males? and females?|females? and males?|men and women|women and men|hommes et femmes|femmes et hommes|by gender|by sex"
RR_AREA <- "\\bha\\b|hectare|\\bacres?\\b|square (metre|meter|kilomet)|\\bkm2\\b|\\bsq\\.? ?m\\b|superficie"
RR_RATE_UNIT <- "^%|percent|pour ?cent|t/ha|kg/ha|per ha|per hectare|/ha\\b|per cow|per day|per capita|litres? per|q/ha|quintal|\\bmho\\b"
RR_EFFECT <- paste0(
  "%|percent|pour ?cent|\\brate\\b|taux|ratio|\\bshare\\b|proportion|index|yield|rendement|",
  "productivity|productivité|income|revenu|\\bprice|\\bprix|t/ha|kg/ha|per ha|per hectare|",
  "increase in|decrease in|reduc|change in|growth|prevalence|incidence|mortality|death rate|",
  "malnutrition|food (in)?security|consumption score|adoption rate|satisf|water saving|velocity")
RR_VOLUME <- "cubic|\\bm3\\b|m³"
RR_ANIMALS <- "cattle|livestock|animals?|\\bheads?\\b|goats|sheep|poultry|cows|vaccinat|bétail|têtes|shoats|ruminants"
RR_PRODUCTION <- "^(t|tons?|tonnes?|mt|metric tons?|kg|kilograms?|litres?|liters?)$|tonnes?|\\btons?\\b|\\bmt\\b|metric ton|production of|produced|harvest|exports?\\b"
RR_LENGTH <- "\\bkm\\b|kilomet|\\bmetres?\\b|\\bmeters?\\b|\\bm\\b|\\blm\\b"
RR_STRUCTURE <- paste0(
  "boreholes?|wells?|puits|dams?|barrage|schemes?|stations?|centres?|centers?|markets?|warehouses?|",
  "storage|facilit|infrastructure|structures?|units?|ponds?|nurser|kilns?|ovens?|stoves?|sites?|",
  "canals?|roads?|pipelines?|dykes?|dikes?|weirs?|seedlings|trees|plants\\b|hangars|demonstration|",
  "landing|cages?|reservoirs?|tanks?|standpipes?|water points?|hafirs?|clinics?|posts?")
# a grant, a sub-grant or a loan awarded is an institutional count, not a
# count of people, whatever Session 1 guessed (29 Sep 2026)
RR_GRANTS <- "\\b(sub-?grants?|grants?|loans?|vouchers?|subsidies|subsidy)\\b"
# a person-day is a volume of work, not a person reached
RR_WORKDAYS <- "person-?days?|man-?days?|labou?r days?|workdays?"
RR_INSTITUTIONAL <- paste0(
  "\\bplans?\\b|policy|policies|strateg|regulation|\\blaws?\\b|decree|agreements?|signatures?|",
  "committees?|comités?|platforms?|associations?|cooperatives?|groups?|organi[sz]ations?|",
  "institutions?|systems? (established|operational)|events?|workshops?|sessions|manuals?|studies|",
  "technolog(y|ies)|business plans?|profiles?|frameworks?")
RR_PROCESS <- paste0(
  "percent(age)? of targets?\\b|% of targets?\\b|of (the )?targets?\\b|realized|realised|achievement rate|",
  "progress towards|disbursement|commitment rate|reports? (produced|delivered)|meetings? held|",
  "missions?|audits?|grievances?|^% ?(achieved|realized|realised)|",
  "surveyed|respondents?|interviewed|sample size|focus groups?|votes?|enumerators?|questionnaire|",
  "screened|screening|safeguard|compliance rate|reports? submitted")
RR_EFFECT_PRIORITY <- "yield|rendement|productiv|income|revenu|production|food|nutrition|death|mortality|catch|adopt|access|saving|resilien|poverty|malnutrition|consumption"
# a unit that says nothing about the kind of thing counted
RR_GENERIC_UNIT <- "^(number|nbr|no\\.?|n|count|total|units?|\\(number\\)|numbers?|nombre|qty|quantity)?$"

# ---- category of a result entry ---------------------------------------------
# people, area, production, volume, animals, length, structure, institutional,
# effect, other. The UNIT decides first (a unit of % is an effect whatever the
# metric says; a unit of ha is an area; a unit of schemes is not people even
# when the metric mentions water users). The metric words decide only when the
# unit is generic or absent; the model's own category is a tie-break.
rr_category <- function(r) {
  m <- rr_txt(r, "metric_stated"); u <- rr_txt(r, "unit_stated"); mu <- paste(m, u)
  cat0 <- rr_txt(r, "category")
  if (grepl(RR_WORKDAYS, mu)) return("other")
  if (grepl(RR_GRANTS, u) && !grepl(RR_PEOPLE, u)) return("institutional")
  generic <- grepl(RR_GENERIC_UNIT, u)
  if (grepl(RR_RATE_UNIT, u) || grepl("t/ha|kg/ha|per ha|per hectare|q/ha|litres? per|per cow|\\bmho\\b", mu)) return("effect")
  if (!generic) {
    if (grepl(RR_AREA, u)) return("area")
    if (grepl(RR_VOLUME, u)) return("volume")
    if (grepl(RR_ANIMALS, u)) return("animals")
    if (grepl(RR_PEOPLE, u)) return("people")
    if (grepl("^(t|tons?|tonnes?|mt|metric tons?|kg|kilograms?|litres?|liters?|mtd)$|^mt ", u)) return("production")
    if (grepl("^(km|kilomet(re|er)s?|m|metres?|meters?|lm)$", u)) return("length")
    if (grepl(RR_STRUCTURE, u)) return("structure")
    if (grepl(RR_INSTITUTIONAL, u)) return("institutional")
    if (grepl(RR_EFFECT, u)) return("effect")
    if (grepl(RR_PRODUCTION, u)) return("production")
    return(if (identical(cat0, "reach_people")) "people" else if (identical(cat0, "effect_rate")) "effect" else if (identical(cat0, "institutional")) "institutional" else "other")
  }
  if (grepl(RR_EFFECT, m) && !grepl("number of|nombre de", m)) return("effect")
  # the head noun decides when the unit is generic: "technologies made
  # available to farmers" counts technologies, not farmers
  head <- trimws(sub("^(number|nombre|no\\.?|total( number)?|cumulative)\\s*(of|de)?\\s*", "", m))
  head <- paste(head(strsplit(head, "\\s+")[[1]], 4), collapse = " ")
  if (grepl(RR_INSTITUTIONAL, head) && !grepl(RR_PEOPLE, head)) return("institutional")
  if (grepl(RR_STRUCTURE, head) && !grepl(RR_PEOPLE, head)) return("structure")
  if (grepl(RR_AREA, head)) return("area")
  if (grepl(RR_ANIMALS, head) && !grepl(RR_PEOPLE, head)) return("animals")
  if (grepl(RR_PEOPLE, m) && !grepl(RR_ANIMALS, m)) return("people")
  if (grepl(RR_AREA, m)) return("area")
  if (grepl(RR_VOLUME, m)) return("volume")
  if (grepl(RR_ANIMALS, m)) return("animals")
  if (grepl(RR_PRODUCTION, m)) return("production")
  if (grepl("\\bkm of|kilomet", m)) return("length")
  if (grepl(RR_STRUCTURE, m)) return("structure")
  if (grepl(RR_INSTITUTIONAL, m)) return("institutional")
  if (identical(cat0, "reach_people")) return("people")
  if (identical(cat0, "effect_rate")) return("effect")
  if (identical(cat0, "institutional")) return("institutional")
  if (identical(cat0, "physical_quantity")) return("structure")
  "other"
}

# reach tiers: 1 direct beneficiaries / people benefiting, 2 households,
# 3 farmers, participants, trained, jobs, users, 4 a gender or age sub-group or
# a country share, 5 indirect or population figures
rr_reach_tier <- function(r) {
  m <- rr_txt(r, "metric_stated"); u <- rr_txt(r, "unit_stated"); mu <- paste(m, u)
  sc <- rr_txt(r, "scope")
  # "direct and indirect beneficiaries" is the project's own total, not an
  # indirect figure (GCF FP049: 438,291)
  if (grepl(RR_INDIRECT, paste(mu, sc)) && !grepl("direct and indirect|direct & indirect|directs? et indirects?", mu)) return(5L)
  if (identical(rr_txt(r, "project_total"), "no")) return(4L)
  # the scope alone can name the sub-group: an indicator "male and females
  # benefitting" reported in a row whose scope says "male" is a sub-group
  if (nzchar(sc) && grepl(RR_SUBGROUP, sc) && !grepl(RR_BOTH_SEXES, sc) && !grepl("total|\\ball\\b", sc)) return(4L)
  if (grepl(RR_SUBGROUP, mu) && !grepl(RR_BOTH_SEXES, mu) && !grepl("total|\\ball\\b", mu)) return(4L)
  if (grepl("direct (project )?beneficiar|beneficiar|bénéficiaire|benefit(t)?(ing|ed)|people (reached|benefit|served|with|supported)|persons? (reached|benefit|served|with)|individuals", mu)) return(1L)
  if (grepl("household|ménage|famil", mu)) return(2L)
  3L
}

rr_metric_key <- function(r) {
  k <- tolower(paste(r$metric_stated %||% "", collapse = " "))
  k <- gsub("[(][^)]*[)]", " ", k)
  k <- gsub(paste0("- *(of which|male|female|men|women|total|regional|national|",
                   "overall|cumulative|disaggregated).*$"), " ", k)
  k <- gsub("[^a-z ]", " ", k)
  k <- trimws(gsub(" +", " ", k))
  substr(k, 1, 42)
}

rr_level_rank <- function(r) {
  lv <- rr_txt(r, "indicator_level")
  if (lv == "outcome") 0L else if (lv == "output") 1L else 2L
}
rr_in_summary <- function(r) identical(rr_txt(r, "in_summary"), "yes")
rr_is_share <- function(r) identical(rr_txt(r, "project_total"), "no")
rr_is_subgroup_share <- function(r) {
  mu <- paste(rr_txt(r, "metric_stated"), rr_txt(r, "unit_stated"))
  grepl(RR_SUBGROUP, mu) && !grepl(RR_BOTH_SEXES, mu) && !grepl("income|yield|production|access|adopt", mu)
}

# eligible: an achieved value (value_type achieved or absent), numeric and
# above zero, not a process or survey number, not a percentage above 1000
rr_eligible <- function(r) {
  vt <- rr_txt(r, "value_type")
  if (nzchar(vt) && vt != "achieved") return(FALSE)
  v <- rr_num(r$value)
  if (is.na(v) || v <= 0) return(FALSE)
  m <- paste(rr_txt(r, "metric_stated"), rr_txt(r, "unit_stated"))
  if (grepl(RR_PROCESS, m)) return(FALSE)
  if (grepl(RR_RATE_UNIT, rr_txt(r, "unit_stated")) && grepl("^%|percent|pour ?cent", rr_txt(r, "unit_stated")) && v > 1000) return(FALSE)
  TRUE
}

# ---- the gate: what is not a result -----------------------------------------
# Moved here from fold_results() so that refold_results.R applies the same
# filters. pages_txt (one string per page) lets the AfDB repair check the page.
results_gate <- function(rl, family_module = "", pages_txt = NULL) {
  if (!length(rl)) return(rl)
  fm <- if (is.null(family_module) || !length(family_module) || is.na(family_module[1])) "" else as.character(family_module[1])
  # the team asked for plain digits: a thousands separator never survives, in
  # any family ("10,226" is 10226). A French-style "1.352.000" is handled by
  # the African Development Bank branch below, so only commas go here.
  rl <- lapply(rl, function(r) {
    v <- trimws(as.character(r$value %||% ""))
    if (grepl("^[0-9]{1,3}(,[0-9]{3})+$", v)) r$value <- gsub(",", "", v, fixed = TRUE)
    r
  })
  if (identical(fm, "afdb_pcr")) {
    # AfDB tables print every number with three decimals and a comma for
    # thousands: "7,520.000" is 7,520, "1,352.000" is 1,352, "30.000" is 30 and
    # "3.600" is 3.6. Only a number with two or more dot groups ("1.352.000",
    # French style) is dot-thousands. Two failure modes are repaired: the model
    # keeps the printed string (fixed by pattern), or it has multiplied by a
    # thousand because it took the dot for a thousands separator (fixed against
    # the page text: the page shows 7,520.000 and never 7,520,000). The wrong
    # rule of 28 Sep 2026 ("30.000 is 30,000") is gone.
    rl <- lapply(rl, function(r) {
      v <- trimws(as.character(r$value %||% ""))
      if (grepl("^[0-9]{1,3}(\\.[0-9]{3}){2,}$", v)) r$value <- gsub(".", "", v, fixed = TRUE)
      else if (grepl("^[0-9,]+\\.000$", v)) r$value <- gsub(",", "", sub("\\.000$", "", v), fixed = TRUE)
      else if (grepl("^[0-9,]+\\.[0-9]{3}$", v)) r$value <- gsub(",", "", sub("0+$", "", v), fixed = TRUE)
      else if (!is.null(pages_txt) && grepl("^[0-9]+000$", v)) {
        n <- as.numeric(v); small <- n / 1000
        pg <- suppressWarnings(as.integer(r$page %||% NA))
        txt <- if (!is.na(pg) && pg >= 1 && pg <= length(pages_txt)) pages_txt[pg] else paste(pages_txt, collapse = "\n")
        comma_form <- format(small, big.mark = ",", scientific = FALSE, trim = TRUE)
        small_forms <- unique(c(paste0(comma_form, ".000"), paste0(format(small, scientific = FALSE, trim = TRUE), ".000")))
        big_forms <- c(format(n, big.mark = ",", scientific = FALSE, trim = TRUE), as.character(n))
        if (any(vapply(small_forms, function(p) grepl(p, txt, fixed = TRUE), logical(1))) &&
            !any(vapply(big_forms, function(p) grepl(p, txt, fixed = TRUE), logical(1)))) {
          r$value <- format(small, scientific = FALSE, trim = TRUE)
          r$scope <- paste(trimws(paste(r$scope %||% "", "")), "[thousandfold misread repaired]")
        }
      }
      r
    })
  }
  # "581028.00" is 581028: trailing zero decimals are noise from table cells
  rl <- lapply(rl, function(r) {
    v <- trimws(as.character(r$value %||% ""))
    if (grepl("^[0-9]+\\.0+$", v)) r$value <- sub("\\.0+$", "", v)
    r
  })
  is_money <- vapply(rl, function(r) grepl(
    "US ?\\$|\\$ ?[0-9]|dollars?|USD|EUR|CFAF|\\bUA\\b|disburs|financ|budget|grant amount|contribution of|fund contribution",
    paste(r$unit_stated, r$metric_stated), ignore.case = TRUE), logical(1))
  rl <- rl[!is_money]
  if (!length(rl)) return(rl)
  is_junk <- vapply(rl, function(r) {
    v <- tolower(as.character(r$value %||% "")); m <- tolower(as.character(r$metric_stated %||% ""))
    no_digit  <- !grepl("[0-9]", v) && !v %in% c("n", "y", "no", "yes")
    duration  <- grepl("[0-9]\\s*-?\\s*(month|week|year)s?\\b", v) ||
                 grepl("duration|extension|time ?frame|closing date|implementation period", m)
    datelike  <- grepl("^\\s*[0-9]{1,2} (january|february|march|april|may|june|july|august|september|october|november|december)|(19|20)[0-9]{2}\\s*$", v) &&
                 grepl("date|closing|launch|approval", m)
    admin     <- grepl("reports?|meetings?|missions?|recommendations?|contracts?|audits?|supervision", m) &&
                 !grepl("beneficiar|farmer|train|hectare|household", m)
    longtext  <- nchar(v) > 40
    zero_nodata <- grepl("^\\s*0(\\.0+)?\\s*$", v) && !identical(r$status, "not achieved")
    shared <- if (exists("result_reject_reason")) nzchar(result_reject_reason(as.character(r$value %||% ""),
                                          as.character(r$unit_stated %||% ""),
                                          as.character(r$metric_stated %||% ""))) else FALSE
    no_digit || duration || datelike || admin || longtext || zero_nodata || shared
  }, logical(1))
  rl[!is_junk]
}

# ---- the chooser -------------------------------------------------------------
choose_headline <- function(rl, n = 3L) {
  if (!length(rl)) return(list(top = list(), rest = list()))
  ok <- vapply(rl, rr_eligible, logical(1))
  pool <- rl[ok]
  if (!length(pool)) return(list(top = list(), rest = list()))
  cats <- vapply(pool, rr_category, character(1))
  vals <- vapply(pool, function(r) rr_num(r$value), numeric(1))
  lvl  <- vapply(pool, rr_level_rank, integer(1))
  insum <- vapply(pool, rr_in_summary, logical(1))
  share <- vapply(pool, rr_is_share, logical(1))
  ord  <- seq_along(pool)   # document order as Session 1 listed them
  used <- rep(FALSE, length(pool)); keys <- character(0)
  take <- function(i) { used[i] <<- TRUE; keys <<- c(keys, rr_metric_key(pool[[i]])); pool[[i]] }
  free <- function(i) !used[i] && !(rr_metric_key(pool[[i]]) %in% keys)
  freev <- function() vapply(seq_along(pool), free, logical(1))
  top <- list()

  # slot 1: reach. best tier, then the largest value
  ppl <- which(cats == "people" & freev())
  if (length(ppl)) {
    tiers <- vapply(pool[ppl], rr_reach_tier, integer(1))
    keep <- ppl[tiers <= 3L]; tk <- tiers[tiers <= 3L]
    if (!length(keep)) { keep <- ppl[tiers == 4L]; tk <- tiers[tiers == 4L] }
    if (length(keep)) {
      o <- order(tk, -vals[keep], ord[keep])
      top[[length(top) + 1L]] <- take(keep[o[1]])
    }
  }

  # slot 2: main physical achievement. class order area > production > volume
  # > animals > length, project totals before shares; inside a class outcome
  # level first, then the largest value. Structures and institutional counts
  # come last and are ranked together by level, then value.
  for (cl in c("area", "production", "volume", "animals", "length")) {
    cand <- which(cats == cl & freev())
    if (length(cand)) {
      o <- order(share[cand], lvl[cand], -vals[cand], ord[cand])
      top[[length(top) + 1L]] <- take(cand[o[1]]); break
    }
  }
  if (length(top) < 2L || !any(cats[used] %in% c("area", "production", "volume", "animals", "length"))) {
    cand <- which(cats %in% c("structure", "institutional") & freev())
    if (length(cand)) {
      o <- order(share[cand], lvl[cand], -vals[cand], ord[cand])
      top[[length(top) + 1L]] <- take(cand[o[1]])
    }
  }

  # slot 3: main measured effect. outcome level first, then quoted in the
  # summary, then the metrics a reader treats as the project's effect, then
  # document order. A share of a sub-group (percent female) or a country
  # share is not the effect when a whole-project effect exists.
  eff <- which(cats == "effect" & freev())
  if (length(eff)) {
    sub <- vapply(pool[eff], rr_is_subgroup_share, logical(1)) | share[eff]
    eff2 <- eff[!sub]
    if (length(eff2)) {
      prio <- vapply(pool[eff2], function(r) if (grepl(RR_EFFECT_PRIORITY, rr_txt(r, "metric_stated"))) 0L else 1L, integer(1))
      o <- order(lvl[eff2], !insum[eff2], prio, ord[eff2])
      top[[length(top) + 1L]] <- take(eff2[o[1]])
    }
  }

  # fill: whole-project figures first, outcome level, quoted in the summary,
  # document order; sub-groups, shares and indirect figures last
  while (length(top) < n) {
    cand <- which(freev())
    if (!length(cand)) break
    weak <- vapply(cand, function(i) {
      r <- pool[[i]]
      share[i] || (cats[i] == "people" && rr_reach_tier(r) >= 4L) ||
        (cats[i] == "effect" && rr_is_subgroup_share(r))
    }, logical(1))
    # The first slot already holds the site's reach figure, so the fill takes
    # the physical achievements next, then any further people count, then the
    # institutional and unclassified ones (Barotse: 722 canals rehabilitated
    # before 50,386 person-days and 2,233 sub-grants) - 29 Sep 2026
    crank <- c(area = 1L, production = 1L, volume = 1L, animals = 1L, length = 1L,
               structure = 1L, people = 2L, effect = 3L, institutional = 4L, other = 5L)[cats[cand]]
    crank[is.na(crank)] <- 5L
    o <- order(weak, crank, lvl[cand], !insum[cand], ord[cand])
    top[[length(top) + 1L]] <- take(cand[o[1]])
  }

  rest_i <- which(!used)
  rest <- pool[rest_i[order(lvl[rest_i], !insum[rest_i], ord[rest_i])]]
  list(top = top, rest = rest)
}

# ---- the location sheet: main results per site --------------------------------
# Lolita, 29 Sep 2026: the location sheet holds the MAIN results of each site,
# one row per result, up to n (five) and one is fine, chosen with the same rule
# as the general sheet but tied to the site. Every other quantitative result the
# document gives for the site goes to the notes of the first kept row. A site
# with interventions but no quantitative result keeps one row, the fullest.
# d is the Session 1 row table (locations_stated, result_value, result_stated,
# result_unit_stated, page, project_code_hint, document, and since loc-v1.5
# value_type and category). Returns d with kept rows and a main_notes column.
select_main_results <- function(d, n = 5L) {
  if (!nrow(d)) { d$main_notes <- character(0); return(d) }
  gcol <- function(nm) if (nm %in% names(d)) as.character(d[[nm]]) else rep("", nrow(d))
  key <- paste(gcol("project_code_hint"), tolower(trimws(gcol("locations_stated"))))
  keep <- rep(FALSE, nrow(d)); notes <- rep("", nrow(d)); scrub <- rep(FALSE, nrow(d))
  val <- gcol("result_value"); rs <- gcol("result_stated"); ru <- gcol("result_unit_stated")
  pg <- gcol("page"); doc <- tolower(gcol("document")); iv <- gcol("intervention_stated")
  vt <- gcol("value_type"); ct <- gcol("category")
  for (k in unique(key)) {
    idx <- which(key == k)
    has <- idx[nzchar(val[idx])]; none <- idx[!nzchar(val[idx])]
    chosen <- integer(0)
    if (length(has)) {
      fm <- if (any(grepl("afdb", doc[idx]))) "afdb_pcr" else ""
      rl <- lapply(has, function(i) list(value = val[i], metric_stated = paste(rs[i], ru[i]),
        unit_stated = ru[i], indicator_level = "", status = "achieved", value_type = if (nzchar(vt[i])) vt[i] else "achieved",
        category = ct[i], project_total = "unknown", in_summary = "no", scope = "", page = pg[i], .row = i))
      rl <- results_gate(rl, fm)
      ch <- choose_headline(rl, n = n)
      chosen <- vapply(ch$top, function(r) as.integer(r$.row), integer(1))
      # the gate may have cleaned a value (AfDB three decimals): write it back
      for (r in ch$top) val[as.integer(r$.row)] <- as.character(r$value)
      keep[chosen] <- TRUE
      rest <- setdiff(has, chosen)
      if (length(rest) && length(chosen))
        notes[chosen[1]] <- paste0("further results at this location: ",
          paste(paste0(val[rest], " ", ru[rest], " (p", pg[rest], ")"), collapse = "; "))
    }
    if (!length(chosen)) {
      if (length(none)) keep[none[which.max(nchar(iv[none]))]] <- TRUE
      else { keep[has[1]] <- TRUE; scrub[has[1]] <- TRUE }
    }
  }
  d$result_value <- val
  d$main_notes <- notes
  if (any(scrub)) {
    d$result_value[scrub] <- ""; d$result_stated[scrub] <- ""; d$result_unit_stated[scrub] <- ""
    d$main_notes[scrub] <- "its quantitative results were not achieved values (targets, money or process figures); row kept for the intervention"
  }
  d[keep, , drop = FALSE]
}
