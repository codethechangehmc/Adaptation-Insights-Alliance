# Regression tests: every fault that once produced a wrong value in the
# pipeline becomes a case here, so it cannot come back unnoticed. The list only
# grows. Run it before a harmonisation or after touching R/00_shared:
#   Rscript R/08_quality/test_regressions.R
# Prints one line per case and exits with status 1 when a case fails.
#
# Sources of the cases: gold set (Sep 2026), holdout set, Charity pilot
# (28 Sep 2026). Where a case names a document, that document showed the fault.

args <- commandArgs(trailingOnly = FALSE)
here <- dirname(sub("^--file=", "", grep("^--file=", args, value = TRUE)[1]))
REPO <- normalizePath(file.path(here, "..", ".."), winslash = "/", mustWork = TRUE)
suppressPackageStartupMessages({ library(openxlsx) })
source(file.path(REPO, "R", "00_shared", "paths.R"))
source(file.path(REPO, "R", "00_shared", "actor_names.R"))
source(file.path(REPO, "R", "00_shared", "clean_fields.R"))
source(file.path(REPO, "R", "00_shared", "results_rank.R"))
source(file.path(REPO, "R", "00_shared", "loc_rules.R"))
source(file.path(REPO, "R", "00_shared", "vocab_lists.R"))   # OPT, the controlled values
source(file.path(REPO, "R", "00_shared", "vocab_cache.R"))   # vocab_fingerprint()

reg  <- actor_registry(TEMPLATE_XLSX)
syn  <- read.csv(file.path(REPO, "catalogues", "actor_synonyms.csv"), stringsAsFactors = FALSE, encoding = "UTF-8")
IDX  <- actor_index(reg, syn)
CIDX <- actor_country_index(reg)

fails <- 0L; n <- 0L
check <- function(label, ok) {
  n <<- n + 1L
  if (isTRUE(ok)) cat(sprintf("  ok    %s\n", label))
  else { fails <<- fails + 1L; cat(sprintf("  FAIL  %s\n", label)) }
}
ctx <- function(...) actor_nrm(paste(...))

cat("country inside another name (actor_in_context)\n")
check("mali is not found inside somalia (CP04, Ethiopia PCR names the Somali region)",
      !actor_in_context("mali", ctx("Afar and Somali regions", "Somalia Regional State"), CIDX$traps))
check("mali is found when Mali itself is named",
      actor_in_context("mali", ctx("Republic of Mali, Somali region"), CIDX$traps))
check("niger is not found inside nigeria",
      !actor_in_context("niger", ctx("Federal Republic of Nigeria"), CIDX$traps))
check("niger is not found in Niger Delta or Niger State (Nigeria)",
      !actor_in_context("niger", ctx("Niger Delta and Niger State, Nigeria"), CIDX$traps))
check("niger is found when the Republic of Niger is named beside the Niger River",
      actor_in_context("niger", ctx("Republic of Niger, Niger River basin"), CIDX$traps))
check("sudan is not found inside South Sudan",
      !actor_in_context("sudan", ctx("Juba, South Sudan"), CIDX$traps))
check("chad is not found in Lake Chad basin (Nigeria)",
      !actor_in_context("chad", ctx("Lake Chad basin, Borno State, Nigeria"), CIDX$traps))
check("benin is not found in Benin City (Nigeria)",
      !actor_in_context("benin", ctx("Benin City, Edo State"), CIDX$traps))
check("guinea is not found inside Guinea-Bissau",
      !actor_in_context("guinea", ctx("Bissau, Guinea-Bissau"), CIDX$traps))
check("guinea is not found in the Gulf of Guinea",
      !actor_in_context("guinea", ctx("coastal zone of the Gulf of Guinea, Ghana"), CIDX$traps))
check("congo is not found inside Democratic Republic of the Congo",
      !actor_in_context("congo", ctx("Kinshasa, Democratic Republic of the Congo"), CIDX$traps))
check("a multi-word country still matches itself (sierra leone)",
      actor_in_context("sierra leone", ctx("Freetown, Sierra Leone"), CIDX$traps))

cat("ministries and the document's country (match_actor_country)\n")
cp04 <- ctx("ETHIOPIA-DROUGHT RESILIENCE & SUSTAINABLE LIVELIHOOD PROGRAM IN THE HORN OF AFRICA (PHASE I)",
            "Country Multi-Countries", "Afar and Somali regions", "Somalia Regional State")
cd <- match_actor_country("Ministry of Agriculture", cp04, CIDX)
check("Ethiopian Ministry of Agriculture is not coded to Mali (MALI24)", is.na(cd) || cd != "MALI24")
check("a body written with its country matches that country's row (Ministry of Agriculture, Mali)",
      identical(match_actor_country("Ministry of Agriculture, Mali", "", CIDX), "MALI24"))
check("the same body in another country is not Mali (Ministry of Agriculture, Kenya)",
      !identical(match_actor_country("Ministry of Agriculture, Kenya", "", CIDX), "MALI24"))
check("Mauritanian MEDD is not the Burkina Faso ministry BF91 (CP01)",
      !identical(match_actor_country("Ministry of Environment and Sustainable Development", ctx("Mauritania", "Brakna, Assaba"), CIDX), "BF91"))
check("Mozambican Ministry of Agriculture and Food Security is not Lesotho LSO2 (CP05)",
      !identical(match_actor_country("Ministry of Agriculture and Food Security", ctx("Republic of Mozambique"), CIDX), "LSO2"))
check("a body named without a country in a document naming two of its countries (Mali, Zambia) is left undecided",
      is.na(match_actor_country("Ministry of Agriculture", ctx("Mali", "Zambia"), CIDX)))
check("the same body in a document naming one of its countries is decided (Zambia -> ZAM20)",
      identical(match_actor_country("Ministry of Agriculture", ctx("Republic of Zambia", "Lusaka"), CIDX), "ZAM20"))

cat("substring matches (match_actor_det)\n")
r <- match_actor_det("Enhancing Resilience of Communities to the Adverse Effects of Climate Change", IDX)
check("the one-word registry actor Resilience (NLD28) does not match a sentence (CP01)", is.na(r$code) || r$code != "NLD28")
r <- match_actor_det("Ministry of Environment and Sustainable Development", IDX)
check("a country-less generic body is not decided by a comma-rule synonym alone", is.na(r$code) || !identical(r$tier, "exact"))
gen <- syn[syn$source == "registry-rule:comma-generic", ]
check("comma-rule synonyms with a generic head are all tier candidate", nrow(gen) > 0 && all(gen$tier == "candidate"))

cat("money as plain digits (money_num, format_money, budget_notes_for)\n")
check("33000000.00 reads as 33000000", identical(money_num("33000000.00"), 33000000))
check("3.3e+07 reads as 33000000", identical(money_num("3.3e+07"), 33000000))
check("UA 1,710,000 reads as 1710000", identical(money_num("UA 1,710,000"), 1710000))
check("empty reads as NA", is.na(money_num("")))
check("33000000 is written as 33000000, not 3.3e+07", identical(format_money(33000000), "33000000"))
check("29276200.07 keeps its cents", identical(format_money(29276200.07), "29276200.07"))
check("137269000 is written in full", identical(format_money("137269000"), "137269000"))
check("budget_notes: lead 30000000; cofinancing 3000000 (CP04)",
      identical(budget_notes_for("33000000.00", "30000000.00"), "lead 30000000; cofinancing 3000000"))
check("budget_notes: lead 32000000; cofinancing 105269000 (CP10)",
      identical(budget_notes_for("137269000", "32000000"), "lead 32000000; cofinancing 105269000"))
check("budget_notes empty when the lead share is not below the total (CP01)",
      identical(budget_notes_for("7800000", "7803605"), ""))
check("budget_notes with no total: lead only", identical(budget_notes_for("", "1400000"), "lead 1400000"))
check("budget_notes empty when there is no lead share", identical(budget_notes_for("50600000", ""), ""))

cat("headline results: reach, physical achievement, effect (choose_headline)\n")
R <- function(value, metric, unit = "", level = "outcome", status = "achieved", vt = "achieved", cat = "", total = "unknown", insum = "no", scope = "")
  list(value = value, metric_stated = metric, unit_stated = unit, indicator_level = level, status = status,
       value_type = vt, category = cat, project_total = total, in_summary = insum, scope = scope, page = 1L)
vals <- function(ch) vapply(ch$top, function(r) as.character(r$value), character(1))
# Uganda ATAAS (S02): yields first in the table, beneficiaries fourth
ch <- choose_headline(list(R("111", "increase in average agricultural yields of participating households", "%"),
  R("215.5", "increase in agricultural income of participating households", "%"),
  R("20930", "additional land area with improved land and water management practices", "ha"),
  R("1684959", "direct project beneficiaries", "number"), R("51.5", "female beneficiaries", "%")))
check("S02: beneficiaries, hectares, then a yield or income percent (first outcome-level effect)", identical(vals(ch)[1:2], c("1684959", "20930")) && vals(ch)[3] %in% c("111", "215.5"))
# Zambia PPCR (CP08/S14): budget allocations and a canal flow velocity come first
ch <- choose_headline(list(R("931684711", "increase in national budget allocations to climate resilient programmes", "ZMW"),
  R("71", "targeted councils with adaptive capacity", "%"), R("0.12", "average flow velocity in rehabilitated canals", "m/s"),
  R("603", "sub-project grants awarded", "number", "output"), R("581028", "direct beneficiaries", "people", "output", insum = "yes"),
  R("128169", "households benefited", "households", "output")))
check("S14: the 581028 beneficiaries lead, not the canal velocity", vals(ch)[1] == "581028")
check("S14: the canal flow velocity is not in the first two slots", !"0.12" %in% vals(ch)[1:2])
# Kenya CSA (S45): users of information (larger) must not beat direct beneficiaries
ch <- choose_headline(list(R("5585500", "users of agro-weather and market information services", "users"),
  R("663200", "direct project beneficiaries", "number"), R("595366", "land area under climate-smart practices", "ha"),
  R("593521", "beneficiaries adopting at least one TIMP", "number")))
check("S45: direct beneficiaries beat a larger count of information users", vals(ch)[1] == "663200")
check("S45: hectares in slot 2", vals(ch)[2] == "595366")
# Ethiopia irrigation (S06): the small achieved area of a failed indicator is the headline area
ch <- choose_headline(list(R("18.25", "area provided with new/improved irrigation", "ha", status = "not achieved"),
  R("28", "water users provided with irrigation services", "number", status = "not achieved"),
  R("10320", "direct project beneficiaries", "number"), R("47.68", "length of main canals constructed", "km", "output")))
check("S06: 10320 beneficiaries then 18.25 ha (failed indicator still the achieved value)", identical(vals(ch)[1:2], c("10320", "18.25")))
# targets, baselines and estimates never enter a slot
ch <- choose_headline(list(R("90000", "irrigated area", "ha", vt = "target"), R("40000", "irrigated area", "ha"),
  R("1964831", "carbon sequestered over 20 years", "tCO2eq", vt = "estimate"), R("20000", "farmers reached", "farmers")))
check("targets and estimates excluded: 20000 farmers then 40000 ha", identical(vals(ch), c("20000", "40000")))
# indirect beneficiaries never beat direct ones; gender shares are not effects
ch <- choose_headline(list(R("262746", "indirect beneficiaries", "people"), R("92255", "direct beneficiaries", "people"),
  R("49", "female share of direct beneficiaries", "%"), R("22828", "green jobs created", "jobs", "output"),
  R("13", "increase in maize yield", "%", insum = "yes")))
check("indirect beneficiaries lose to direct ones", vals(ch)[1] == "92255")
check("a gender share is not the effect slot; the yield increase is", "13" %in% vals(ch) && !"49" %in% vals(ch))
# AfDB emergency (S13): all counts, animals as the physical achievement
ch <- choose_headline(list(R("592350", "direct project beneficiaries", "number"), R("78710", "beneficiaries of conditional food assistance", "number"),
  R("47038", "beneficiaries receiving agricultural input packages", "number"), R("3951460", "livestock (cattle) vaccinated", "number")))
check("S13: beneficiaries, cattle vaccinated, then the next count", identical(vals(ch)[1:2], c("592350", "3951460")) && length(vals(ch)) == 3)
# percent of target achieved is never a result
ch <- choose_headline(list(R("152", "progress towards target", "%"), R("1929.08", "% realized", "%"), R("180176", "direct beneficiaries of the emergency operation", "number")))
check("percent-of-target rows are dropped", identical(vals(ch), "180176"))
# money never enters (the value_type filter and the category)
ch <- choose_headline(list(R("7803605", "Adaptation Fund contribution", "USD"), R("44392", "direct beneficiaries", "people")))
check("money is not chosen as a result", vals(ch)[1] == "44392")

cat("headline results: fixes from the first re-run (28 Sep 2026 evening)\n")
# CP04: the model read '7,520.000' as 7520000; the page shows 7,520.000 and never 7,520,000
pg <- c("Beneficiaries  Pastoralists and Agro-pastoralists  7,520.000  7,512.000  100.11%  Rangeland area rehabilitated and improved (ha)  1,352.000  800.000")
rl <- results_gate(list(R("7520000", "Pastoralists and Agro-pastoralists", "people", "narrative"), R("1352000", "Rangeland area rehabilitated and improved (ha)", "ha", "output"),
                        R("409089", "people with access to water", "people")), "afdb_pcr", pg)
check("AfDB dot-thousands repaired against the page: 7520000 -> 7520", any(vapply(rl, function(r) r$value == "7520", logical(1))))
check("AfDB dot-thousands repaired against the page: 1352000 -> 1352", any(vapply(rl, function(r) r$value == "1352", logical(1))))
ch <- choose_headline(rl)
check("CP04: the 409089 people with water access lead, not the 7520 pastoralists trained", vals(ch)[1] == "409089")
# a percentage above 1000 is not a result (AfDB '30.000' read as 30000 with unit %)
ch <- choose_headline(list(R("30000", "Number of people and livestock accessing water (%)", "%"), R("409089", "people with access to water", "people")))
check("a percentage above 1000 is dropped", !"30000" %in% vals(ch))
# CP05: a count of schemes operated by water users associations is not a people count
ch <- choose_headline(list(R("32", "irrigation schemes are now being operated by water users associations", "schemes", "output"), R("3000", "additional irrigated area managed by irrigation associations", "ha")))
check("CP05: 3000 ha leads; 32 schemes is a structure count, not reach", vals(ch)[1] == "3000")
# CP10: 'males and females benefiting' is the total, not a sub-group; it beats farmers trained
ch <- choose_headline(list(R("154296", "cumulatively a total of 154,296 (46% women) trained", "farmers", "output"), R("287398", "Number of males and females benefiting from the adoption of diversified, climate resilient livelihood options", "males and females")))
check("CP10: 287398 males and females benefiting is the reach, not the trainees", vals(ch)[1] == "287398")
# P005: a survey sample is not a result
ch <- choose_headline(list(R("400", "Number of Women Members Surveyed", "women"), R("6324", "Total Population - Members in associations assisted by OGB", "members")))
check("P005: survey sample excluded, 6324 members lead", vals(ch)[1] == "6324")
# P009: country shares and a gender share do not fill slots while whole-project outcome rows exist
ch <- choose_headline(list(R("379162", "Direct project beneficiaries", "Number"), R("1217", "Mozambique: targeted value chain actors receiving support", "Number", "output", total = "no"),
  R("45", "Tanzania: % of noncompliance incidences in a year", "%", "output", total = "no"), R("11", "new SWIOFC member country signatures to bilateral agreements", "Number"), R("7", "Fisheries Management Plans implemented", "Number")))
check("P009: beneficiaries, then the outcome-level agreements and plans, not country shares", identical(vals(ch), c("379162", "11", "7")))
# P002: a gender share is not the effect slot; with no other effect the fill takes an outcome row instead
ch <- choose_headline(list(R("4700000", "beneficiaries", "people"), R("613688", "biodiversity landscapes", "ha"), R("47", "share of beneficiaries that are women", "%"), R("350000", "land restored", "ha")))
check("P002: the gender share yields to the second area result", identical(vals(ch), c("4700000", "613688", "350000")))
# ratings are not results (CP09)
check("rating gate: 'projects rated satisfactory' is rejected", nzchar(result_reject_reason("81", "%", "Percentage of Community adaptation projects rated satisfactory or better")))
# P010: technologies made available (outcome) beat research centres rehabilitated (output) for the physical slot
ch <- choose_headline(list(R("4612946", "Direct project beneficiaries", "Number"), R("24", "Research centers rehabilitated or equipped", "Number", "output"), R("301", "Technologies that are being made available to farmers", "Number"), R("95", "Lead farmers aware of an improved technology", "%")))
check("P010: 301 technologies (outcome) fill slot 2 before 24 centres (output)", identical(vals(ch), c("4612946", "301", "95")))

# CP03: 'direct and indirect beneficiaries' is the project's total; the male and female rows are sub-groups (scope)
ch <- choose_headline(list(R("214763", "A1.2 Number of male and females benefitting from the adoption of practices", "people", scope = "direct beneficiaries - male"),
  R("223528", "A1.2 Number of male and females benefitting from the adoption of practices", "people", scope = "direct beneficiaries - female"),
  R("438291", "Number of direct and indirect beneficiaries", "people", scope = "whole project"), R("5575", "natural resource areas under improved use", "ha")))
check("CP03: 438291 direct and indirect beneficiaries lead; the female row is a sub-group", vals(ch)[1] == "438291")
# trailing zero decimals from table cells are dropped
rl <- results_gate(list(R("581028.00", "direct beneficiaries", "people")), "wb_icr")
check("581028.00 becomes 581028", rl[[1]]$value == "581028")
# P005: 'Total Population - Members in associations' is reach, not a population statistic
ch <- choose_headline(list(R("68", "No. of Women Able to Write Their Names", "women"), R("6324", "Total Population - Members in associations assisted by OGB", "Members")))
check("P005: 6324 association members lead over a survey answer about women", vals(ch)[1] == "6324")

cat("beneficiary metrics by rule (map_people_metric_det)\n")
check("'representing 44,392 beneficiaries (Direct beneficiaries)' -> direct beneficiaries", map_people_metric_det("representing 44,392 beneficiaries Direct beneficiaries") == "direct beneficiaries")
check("'beneficiaries reached by RFS' -> total beneficiaries", map_people_metric_det("beneficiaries reached by RFS people") == "total beneficiaries")
check("'Number of males and females benefiting from the adoption' -> total beneficiaries", map_people_metric_det("Number of males and females benefiting from the adoption of practices males and females") == "total beneficiaries")
check("'people with access to water' -> direct beneficiaries", map_people_metric_det("409,089 people & 1,352,522 livestock with access to water people") == "direct beneficiaries")
check("'direct beneficiary households' -> vulnerable households", map_people_metric_det("Household considered with diversification into alternative sources households") == "vulnerable households")
check("'female beneficiaries' -> women beneficiaries", map_people_metric_det("female beneficiaries number") == "women beneficiaries")
check("'of which lead farmers' is left to the model", map_people_metric_det("direct programme beneficiaries of which lead farmers") == "")
check("'farmers who benefited from the project' -> smallholder farmers reached", map_people_metric_det("nearly ten thousand farm managers who benefited farm managers") == "smallholder farmers reached")
check("a land metric is left to the model", map_people_metric_det("Area of landscapes under improved practices hectares") == "")

cat("vocabulary review (28 Sep 2026): template strings, units, labels, proposals\n")
check("export writes the template's non-breaking hyphen", template_exact("mid-term evaluation") == "mid\u2011term evaluation")
check("export writes the template's subscript in tCO2e", template_exact("tCO2e") == "tCO\u2082e")
check("template strings read back to ASCII", identical(template_ascii(template_exact(c("mid-term evaluation", "tCO2e", "hectares"))), c("mid-term evaluation", "tCO2e", "hectares")))
check("a count noun unit becomes quantity", unit_count_fallback("policies", "CANDIDATE: policies adopted") == "quantity")
check("weather stations as a unit becomes quantity", unit_count_fallback("weather stations", "CANDIDATE: weather stations") == "quantity")
check("a measure unit keeps its candidate (kilometers)", unit_count_fallback("km", "CANDIDATE: kilometers") == "CANDIDATE: kilometers")
check("a measure unit keeps its candidate (tons per hectare)", unit_count_fallback("mho", "CANDIDATE: metric tons per hectare") == "CANDIDATE: metric tons per hectare")
check("a candidate label that is only a unit word is dropped", clean_candidate_label("CANDIDATE: percentage") == "")
check("an in-list metric is untouched by the label cleaner", clean_candidate_label("direct beneficiaries") == "direct beneficiaries")
check("redundant country tail dropped from a proposal", actor_tidy_proposal("Government of Ethiopia, Ethiopia") == "Government of Ethiopia")
check("Zambia Meteorological Department, Zambia -> no tail", actor_tidy_proposal("Zambia Meteorological Department, Zambia") == "Zambia Meteorological Department")
check("a needed country tail is kept", actor_tidy_proposal("Ministry of Agriculture, Mali") == "Ministry of Agriculture, Mali")
ch <- choose_headline(list(R("100", "Percentage of KAPAP sub-projects screened for climate risk", "%"), R("37977", "Number of direct project beneficiaries", "number")))
check("a screening percentage is a process figure, not a result", !"100" %in% vals(ch))

check("a people metric with a land unit becomes a candidate from the stated wording",
      startsWith(metric_unit_consistent("vulnerable households", "hectares", "A7.1 Use by vulnerable households of Fund-supported tools"), "CANDIDATE:"))
check("direct beneficiaries with a percentage unit becomes a candidate", startsWith(metric_unit_consistent("direct beneficiaries", "percentage", "Number of people and livestock accessing water (%)"), "CANDIDATE:"))
check("women beneficiaries as a share keeps percentage", metric_unit_consistent("women beneficiaries", "percentage", "female beneficiaries") == "women beneficiaries")
check("a consistent pair is untouched", metric_unit_consistent("direct beneficiaries", "individuals", "direct beneficiaries") == "direct beneficiaries")
check("the beneficiary rule is silent for a hectare row", stated_is_measure("ha") && !stated_is_measure("people"))

check("an empty unit with a count-noun stated unit becomes quantity", unit_count_fallback("titles", "") == "quantity")
check("an empty unit with no stated unit stays empty", unit_count_fallback("", "") == "")
check("a clashing people metric becomes a candidate with the exact wording", metric_unit_consistent("vulnerable households", "hectares", "A7.1 Use by vulnerable households, communities, business and public-sector services") == "CANDIDATE: A7.1 Use by vulnerable households, communities, business and public-sector services")

cat("result metrics by rule (map_metric_det), conflicts, verbatim candidates (29 Sep 2026)\n")
check("landscapes under improved practices (GEF CI4) -> biodiversity landscapes conserved", map_metric_det("Area of landscapes under improved practices (hectares; excluding protected areas)", "Hectares") == "biodiversity landscapes conserved")
check("rangeland rehabilitated -> land restored", map_metric_det("Rangeland area rehabilitated and improved (ha)", "ha") == "land restored")
check("degraded mangrove area restored -> land restored", map_metric_det("degraded mangrove area restored", "ha") == "land restored")
check("incremental area under climate resilient crops -> land under climate-smart practices", map_metric_det("Incremental area under climate resilient crops in the vicinity of canals", "ha") == "land under climate-smart practices")
check("land with sustainable landscape management -> land under climate-smart practices", map_metric_det("Land area with sustainable landscape management practices", "Hectare(Ha)") == "land under climate-smart practices")
check("additional irrigated area -> irrigated land", map_metric_det("Additional irrigated area managed by Irrigation Associations", "ha") == "irrigated land")
check("terrestrial protected areas created -> terrestrial protected areas", map_metric_det("Terrestrial protected areas created or under improved management", "Ha") == "terrestrial protected areas")
check("marine and coastal areas under conservation -> biodiversity landscapes conserved", map_metric_det("marine and coastal areas under conservation", "ha") == "biodiversity landscapes conserved")
check("a land indicator with no land words stays open (marine surface under spatial planning)", map_metric_det("marine surface under spatial planning", "ha") == "")
check("yield in mho -> crop yield increase", map_metric_det("Increased yield in cereal production (mho)", "mho") == "crop yield increase")
check("average yield per hectare in kg -> crop yield increase", map_metric_det("with an average yield per hectare of around 2,713 Kg", "Kg") == "crop yield increase")
check("increase in agricultural income -> income increase", map_metric_det("Increase in agricultural income of participating households", "%") == "income increase")
check("share of income spent on risk is not income increase", map_metric_det("farmers spend an estimated 11-20% of their income on managing risk", "%") == "")
check("post-harvest losses reduced -> harvest loss reduced", map_metric_det("post-harvest losses reduced", "%") == "harvest loss reduced")
check("extension workers trained -> extension agents trained", map_metric_det("Public and private advisory agents trained in community climate risk management", "number") == "extension agents trained")
check("green jobs created -> jobs created", map_metric_det("green jobs created", "jobs") == "jobs created")
check("water user associations -> farmer groups", map_metric_det("Water user associations established and functioning", "Number") == "farmer groups")
check("cooperatives graded A and B -> cooperatives reached", map_metric_det("cooperatives graded A and B", "%") == "cooperatives reached")
check("land titles issued to associations: no rule fires", map_metric_det("Cumulative number of land user rights titles issued to associations", "titles") == "")
check("land titles are not producer organizations (conflict guard)", metric_option_conflict("producer organizations", "Cumulative number of land user rights titles issued to associations"))
check("animals are not direct beneficiaries (conflict guard)", metric_option_conflict("direct beneficiaries", "Number of animals with access to the Ruqa water pan"))
check("direct project beneficiaries pass the conflict guard", !metric_option_conflict("direct beneficiaries", "Number of direct project beneficiaries"))
check("a candidate carries the document's exact wording", candidate_verbatim("CANDIDATE: animals with water", "Number of animals with access to the Ruqa water pan (increased to)") == "CANDIDATE: Number of animals with access to the Ruqa water pan (increased to)")
check("an in-list value is not touched by candidate_verbatim", candidate_verbatim("direct beneficiaries", "Number of direct project beneficiaries") == "direct beneficiaries")
check("AfDB unit code stays as the document wrote it", map_unit_det("mho") == "CANDIDATE: mho")
check("metric tons -> tons", map_unit_det("metric tons") == "tons")
check("women as a unit -> individuals", map_unit_det("women") == "individuals")

check("P006: farm managers with a yield mention stay a farmers count", map_metric_det("nearly ten thousand (10 000) farm managers (compared to one hundred) applying IPM with higher yields", "farm managers") == "smallholder farmers reached")
check("P003: a female share of beneficiaries is women beneficiaries, not yield", map_people_metric_det("share of GGP Production beneficiaries who are female %") == "women beneficiaries" && !stated_is_measure("%"))
check("P003: 'GGP Production' with a percent unit is not a yield", map_metric_det("share of GGP Production beneficiaries who are female", "%") == "")
check("a yield head with a percent unit is a yield", map_metric_det("Increase in average agricultural yields of participating households", "%") == "crop yield increase")

check("CP03: a row whose scope says male is a sub-group even if the indicator names both sexes",
      rr_reach_tier(R("214763", "A1.2 Number of male and females benefitting from the adoption", "people", scope = "direct beneficiaries - male")) == 4L)
ch <- choose_headline(list(R("438291", "Number of direct and indirect beneficiaries", "people", scope = "whole project"),
  R("5575", "A7.1 Use by vulnerable households of Fund-supported tools", "ha"),
  R("214763", "A1.2 Number of male and females benefitting from the adoption", "people", scope = "direct beneficiaries - male"),
  R("882", "ha planted with trees", "ha", "output", scope = "area planted with trees")))
check("CP03: the third slot takes the planted area, not the male sub-group", vals(ch)[3] == "882")

cat("AfDB numbers: three decimals, comma thousands (corrected 29 Sep 2026)\n")
g <- function(v) results_gate(list(R(v, "some indicator", "ha")), "afdb_pcr")[[1]]$value
check("'3.600' is 3.6 (a yield), not 3600", g("3.600") == "3.6")
check("'30.000' is 30, not 30000", g("30.000") == "30")
check("'7,520.000' is 7520", g("7,520.000") == "7520")
check("'1,352.000' is 1352", g("1,352.000") == "1352")
check("'1.352.000' (two dot groups, French style) is 1352000", g("1.352.000") == "1352000")
check("'202,658.000' is 202658", g("202,658.000") == "202658")

cat("location sheet: main results per site (29 Sep 2026)\n")
ch <- choose_headline(list(R("1000", "farmers trained", "farmers"), R("250", "hectares restored", "ha"), R("30", "yield increase", "%"),
  R("12", "boreholes drilled", "boreholes"), R("40", "groups formed", "groups"), R("7", "km of canal", "km"), R("3", "plans adopted", "plans")), n = 5L)
check("choose_headline fills five slots when asked", length(ch$top) == 5)
check("the first three slots keep their order (reach, physical, effect)", identical(vals(ch)[1:3], c("1000", "250", "30")))
d <- data.frame(project_code_hint = "CPX", document = "worldbank_x.pdf",
  locations_stated = c(rep("Kiboga", 7), "Mubende", "Mubende", "Hoima"),
  intervention_stated = c(rep("training and inputs", 7), "seed distribution", "a longer description of the irrigation works", "roads"),
  result_stated = c("farmers trained", "hectares restored", "yield increase", "boreholes drilled", "groups formed", "km of canal", "plans adopted", "", "", "budget spent"),
  result_value = c("1000", "250", "30", "12", "40", "7", "3", "", "", "500000"),
  result_unit_stated = c("farmers", "ha", "%", "boreholes", "groups", "km", "plans", "", "", "USD"),
  page = as.character(1:10), value_type = c(rep("achieved", 9), "achieved"), category = "", stringsAsFactors = FALSE)
m <- select_main_results(d, n = 5L)
check("a site with seven results keeps five main rows", sum(m$locations_stated == "Kiboga") == 5)
check("the two dropped results are noted on the first kept row", grepl("further results at this location", m$main_notes[m$locations_stated == "Kiboga"][1]))
check("a site without results keeps one row, the fullest", sum(m$locations_stated == "Mubende") == 1 && grepl("irrigation", m$intervention_stated[m$locations_stated == "Mubende"]))
check("a site whose only result is money keeps the row without the value", sum(m$locations_stated == "Hoima") == 1 && m$result_value[m$locations_stated == "Hoima"] == "")

cat("money in local currencies (29 Sep 2026)\n")
check("a kwacha sale is money, not a result", nzchar(result_reject_reason("3400000", "MK", "realised a total of MK3,400,000 from soybeans")))
check("a shilling figure is money, not a result", nzchar(result_reject_reason("250000", "KES", "value of the water pan")))
check("income in kwacha stays a result (income is exempt)", !nzchar(result_reject_reason("3400000", "MK", "average household income")))
check("'random sample of 300 households' is not caught by 'rand'", !grepl(CURRENCY_RE, "random sample of 300 households"))
check("the gate drops a kwacha figure from a site's results", {
  rl <- results_gate(list(R("3400000", "sale proceeds MK3,400,000", "MK"), R("22", "farmers aggregated soybeans", "farmers")), "afdb_pcr")
  length(rl) == 1 && rl[[1]]$value == "22" })

cat("location sheet rules (29 Sep 2026, after the first pilot score)\n")
check("'4 market gardening cooperatives' counts cooperatives", det_target("market gardening cooperatives") == "cooperative")
check("'66 households engaged in fish farming' counts households", det_target("households engaged in fish farming") == "household")
check("a group of 200 farmers comprising 100 women and 50 youths is a farmer group", det_target("a group of 200 farmers comprising 100 women and 50 youths") == "farmer group")
check("202,658 farmers of which 113,660 female are farmers", det_target("Farmers 202,658 of which 113,660 female farmers") == "smallholder farmer")
check("'200 women trained in fish processing' stays women", det_target("200 women were trained in fish processing") == "women (female-headed households)")
check("'the wider population' is the community (superseded the 29 Sep empty answer)", det_target("the wider population") == "community")
check("'nbr' becomes the counted noun", loc_unit_fix("nbr", "Pastoralists and Agro-pastoralists trained (nbr) 7,520.000") == "pastoralists and agro-pastoralists trained")
check("'Number of Federal, Regional and Woreda Staff trained' gives the staff", loc_unit_fix("nbr", "Number of Federal, Regional and Woreda Staff trained") == "federal regional and woreda staff trained")
check("'mtd' is tons", loc_unit_fix("mtd", "Volume of certified seeds delivered") == "tons")
check("a real unit is left alone", loc_unit_fix("hectares", "area restored") == "hectares")
check("a bare count with a long statement falls back to 'number'", loc_unit_fix("number", "an extremely long statement about many different things that were counted at the same time by the team") == "number")
check("a yield with a delivery word is an outcome", det_level("Increased yield in cereal production: 3.6 mt/ha against seeds delivered") == "outcome")
check("'hectares' alone now means an output: the unit decides where the wording does not", det_level("1352 ha") == "output")
check("'rangeland rehabilitated' is an output", det_level("rangeland area rehabilitated and improved | 1352 ha") == "output")
check("coastal risk management is not fisheries", det_subsector("coastal risk management | mangrove restoration and weather stations") == "land use")
check("fish farming is fisheries", det_subsector("fish farming | households engaged in fish farming") == "farming system-fish")
check("'other vulnerable households' is a sub-group (tier 4)", rr_reach_tier(R("68446", "Number of direct beneficiaries (cumulative): other vulnerable households", "other vulnerable households")) == 4L)
ch <- choose_headline(list(R("581028", "total number of people reached", "people"), R("128169", "total households reached", "households"),
  R("68446", "direct beneficiaries: other vulnerable households", "other vulnerable households"), R("2233", "sub-grants approved and completed", "sub-grants"),
  R("5914", "additional area under climate-resilient crops", "ha"), R("722.53", "secondary and ancillary canals rehabilitated", "canals"),
  R("71", "share of beneficiaries reporting improved resilience", "%")), n = 5L)
check("Barotse: five main results are people, area, effect, canals, households", identical(vals(ch), c("581028", "5914", "71", "722.53", "128169")))

cat("proposed location codes are stable across runs (29 Sep 2026)\n")
# the rule under test: a place already in the review file keeps its code, so a
# second run of the same documents does not mint CP01.11 for CP01.4's place
local({
  PREV <- data.frame(location_name = c("Brakna", "Trarza", "Brakna"),
                     location_id = c("CP01.4", "CP01.2", "CP02.7"),
                     location_country = c("Mauritania", "Mauritania", "Mauritania"),
                     first_seen_project = c("CP01", "CP01", "CP02"),
                     stringsAsFactors = FALSE)
  nrm <- function(x) trimws(tolower(gsub("[^a-z0-9]+", " ", tolower(x))))
  prev_code <- function(name, pcode, ctry) {
    same <- nrm(PREV$location_name) == nrm(name) & PREV$first_seen_project == pcode
    if (nzchar(ctry) && any(same & tolower(trimws(PREV$location_country)) == ctry))
      same <- same & tolower(trimws(PREV$location_country)) == ctry
    if (any(same)) PREV$location_id[which(same)[1]] else ""
  }
  check("a re-run reuses the code the review file already holds", prev_code("Brakna", "CP01", "mauritania") == "CP01.4")
  check("the same name in another project keeps that project's code", prev_code("Brakna", "CP02", "mauritania") == "CP02.7")
  check("a place never proposed gets no code from the review file", prev_code("Gorgol", "CP01", "mauritania") == "")
})

cat("location site rules, third pass (29 Sep 2026)\n")
check("a water pan is cross cutting, not a farming system", det_subsector("Water harvesting technologies for crop and livestock production | water pan constructed") == "cross cutting")
check("a borehole is cross cutting", det_subsector("borehole developed for the village") == "cross cutting")
check("an irrigation scheme stays with crops", det_subsector("irrigation scheme rehabilitated for rice production") == "farming system-crop")
check("dune fixing is land use", det_subsector("Dune fixing to protect the village") == "land use")
check("rangeland rehabilitation is land use", det_subsector("rangeland area rehabilitated and improved") == "land use")
check("'direct beneficiaries' names the community", det_target("direct beneficiaries") == "community")
check("'2,245 residents' names the community", det_target("residents served by the water pan") == "community")
check("a narrower group still wins over the community", det_target("smallholder farmers reached") == "smallholder farmer")
check("a bare number is not a statement", !has_words("1 194"))
check("a real statement has words", has_words("150 bags of maize sold"))

cat("the result level follows what was counted (29 Sep 2026)\n")
check("'4 market gardens' is an output, not a process", det_level("4 | market gardens") == "output")
check("'plans developed' stays a process (the project team's own activity)", det_level("87 Adaptation Action Plans developed | Adaptation Action Plans") == "process")
check("a bare share of a delivered quantity is an output", det_level("%") == "output")
check("a share of beneficiaries satisfied is an outcome", det_level("63.3% of beneficiaries satisfied with the water pan | %") == "outcome")
check("a yield per hectare is an outcome", det_level("maize yield rose to 3.6 | mt/ha") == "outcome")
check("'2245 residents served' is an output", det_level("Completed | direct beneficiaries") == "output")
check("'inspections conducted' stays a process", det_level("72 inspections were conducted | inspections conducted") == "process")
check("an unknown unit still yields no level", det_level("luh") == "")

cat("faults found on the real Barotse rows (29 Sep 2026)\n")
check("'percentage of targeted councils' is a result, not a percent-of-target figure",
      rr_eligible(R("71", "Percentage of targeted councils, wards and community groups with improved resilience", "%")))
check("'% of target achieved' is still rejected", !rr_eligible(R("98", "Progress: 98% of target achieved", "%")))
check("'of the target' is still rejected", !rr_eligible(R("98", "reached 98 percent of the target", "%")))
check("'56 enterprise grants implemented' is an institutional count, not people",
      rr_category(R("56", "Number of enterprise grants implemented = 56", "enterprise grants implemented")) == "institutional")
check("'50,386 person-days of labour' is not a count of people",
      rr_category(R("50386", "Person-days of labor generated through cash-for-works", "person-days of labor generated")) == "other")
check("a grant to farmers is still people", rr_category(R("300", "farmers receiving grants", "farmers")) == "people")
local({
  rl <- list(R("581028", "The project reached 581,028 direct beneficiaries", "total number of people"),
             R("128169", "The project reached 128,169 direct beneficiary households", "total households"),
             R("53783", "Number of direct beneficiaries (cumulative): women-headed households", "women-headed household"),
             R("68446", "Number of direct beneficiaries (cumulative): other vulnerable households", "other vulnerable households"),
             R("71", "Percentage of targeted councils, wards and community groups with improved resilience", "%"),
             R("2233", "A total of 2,233 sub-grants were awarded and completed", "sub-grants approved and completed"),
             R("56", "Number of enterprise grants implemented = 56", "enterprise grants implemented"),
             R("722.53", "A total of 722 secondary and ancillary canals were rehabilitated", "secondary and ancillary canals rehabilitated"),
             R("5914", "The additional area under climate-resilient crops", "ha"),
             R("50386", "Person-days of labor generated through cash-for-works", "person-days of labor generated"))
  ch <- choose_headline(results_gate(rl, "wb_icr"), n = 5L)
  check("the Barotse sub-basin keeps the five results the reading reference chose",
        identical(vals(ch), c("581028", "5914", "71", "722.53", "128169")))
})

cat("plain digits: no thousands separator reaches a slot (29 Sep 2026)\n")
gv <- function(v, fm = "") { g <- results_gate(list(R(v, "fertilizer delivered", "mt")), fm); if (length(g)) g[[1]]$value else "" }
check("'10,226' becomes 10226 without a family", gv("10,226") == "10226")
check("'10,226' becomes 10226 in an AfDB report", gv("10,226", "afdb_pcr") == "10226")
check("'581,028' becomes 581028", gv("581,028") == "581028")
check("a decimal value keeps its decimals", gv("3.6") == "3.6")
check("'1.352.000' is still read as 1352000 in an AfDB report", gv("1.352.000", "afdb_pcr") == "1352000")
check("two rows quoting the same figure collapse to one slot", {
  ch <- choose_headline(results_gate(list(R("10,226", "Urea distributed", "mt"), R("10226", "Urea distributed", "mt"),
                                          R("500", "boreholes drilled", "boreholes")), "afdb_pcr"), n = 3L)
  sum(vals(ch) == "10226") == 1 })

cat("filename-safe project codes (30 Sep 2026): a corpus run builds every code\n")
cat("as source:id, and a colon cannot go in a Windows path\n")
check("a pilot code is left exactly as it is", safe_name("P001") == "P001")
check("a World Bank corpus code loses its colon",
      safe_name("worldbank:P119380") == "worldbank_P119380")
check("a CIF fallback code (filename with spaces, commas, dots) becomes one safe token",
      safe_name("cif:CIF_eval, 2019 (final).pdf") == "cif_CIF_eval_2019_final_pdf")
check("an AfDB code keeps its hyphens", safe_name("afdb:P-Z1-AA0-006") == "afdb_P-Z1-AA0-006")
check("an empty code never yields an empty filename", safe_name("") == "unnamed")
check("no character Windows forbids survives",
      !grepl("[:*?<>|]", safe_name("cif:a*b?c<d>e|f.pdf")) &&
      !grepl("/", safe_name("cif:a/b/c.pdf"), fixed = TRUE))

cat("one source of truth for the controlled vocabularies (30 Sep 2026)\n")
check("the five general lists are there",
      all(c("scale", "beneficiary", "doc_type", "metric", "unit") %in% names(OPT)))
check("the two location lists live beside them",
      all(c("subsector", "result_level") %in% names(OPT)))
check("subsector still has its 7 values, 'cross cutting' included",
      length(OPT$subsector) == 7 && "cross cutting" %in% OPT$subsector)
check("result_level still has its 5 values", length(OPT$result_level) == 5)
check("beneficiary still has its 24 values", length(OPT$beneficiary) == 24)
# vocab_cache.R keys every recorded decision on the option list itself, so one
# edited string silently invalidates every decision in vocab_decisions.csv and
# costs a corpus of model calls. These pin the fingerprints that were live when
# the lists moved out of the two harmonisers.
check("the scale fingerprint is unchanged", vocab_fingerprint(OPT$scale) == "6-143903628")
check("the beneficiary fingerprint is unchanged", vocab_fingerprint(OPT$beneficiary) == "24-115445661")
check("the doc_type fingerprint is unchanged", vocab_fingerprint(OPT$doc_type) == "19-942938535")
check("the metric fingerprint is unchanged", vocab_fingerprint(OPT$metric) == "27-87336763")
check("the unit fingerprint is unchanged", vocab_fingerprint(OPT$unit) == "12-10592817")
check("the subsector fingerprint is unchanged", vocab_fingerprint(OPT$subsector) == "7-809569049")
check("the result_level fingerprint is unchanged", vocab_fingerprint(OPT$result_level) == "5-529304297")

cat(sprintf("\n%d cases, %d failed\n", n, fails))
if (fails > 0L) quit(status = 1L)
