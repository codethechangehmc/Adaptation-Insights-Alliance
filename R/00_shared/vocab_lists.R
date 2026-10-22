##############################################################################
# vocab_lists.R — the template's controlled vocabularies, in one place.
#
# Transcribed from the 27 Aug 2026 template readme (regenerate on template
# release). Lifted out of harmonize.R on 30 Sep 2026 so the QC workbook
# builder can offer consultants exactly the lists harmonisation chose from;
# two copies would drift and a dropdown would start disagreeing with the data.
#
# DO NOT EDIT A STRING WITHOUT MEANING TO. vocab_cache.R fingerprints every
# recorded decision from the option list itself (sorted, lowercased, hashed
# with a length prefix), so changing one character or adding one entry
# invalidates every cached vocabulary decision in catalogues/vocab_decisions.csv.
# That costs a corpus of model calls and breaks the byte-identical reruns won
# in September. Changing a list is a deliberate act: it retires the decisions
# taken under the old one.
##############################################################################

# From the 27 Aug 2026 template readme (regenerate on template release).
OPT <- list(
  scale = c("individual/ household", "community", "sub-national", "national",
            "multinational", "unclear/ unspecified"),
  beneficiary = c("agribusiness", "artisanal fisher", "children", "community",
    "cooperative", "elderly", "farm laborer", "farmer association",
    "farmer group", "household", "indigenous peoples", "low-income households",
    "marginalized group", "migrant", "pastoralist/herder",
    "people with disabilities/ disability", "producer", "producer organization",
    "smallholder farmer", "subsistence farmer", "vulnerable population",
    "women (female-headed households)", "women's group/organization", "youth"),
  doc_type = c("implementation status report", "implementation completion report",
    "impact evaluation report", "case study", "policy brief", "technical note",
    "monitoring & evaluation report", "terminal evaluation", "mid-term evaluation",
    "conference proceeding", "donor report", "resilience assessment",
    "learning brief", "practice note", "multi-country synthesis",
    "regional policy brief", "results framework", "portfolio performance review",
    "thematic adaptation evaluation"),
  metric = c("association members", "biodiversity landscapes conserved",
    "cooperatives reached", "crop producers", "crop yield increase",
    "direct beneficiaries", "extension agents trained", "farmer groups",
    "fishers", "harvest loss reduced", "income increase", "irrigated land",
    "jobs created", "land restored", "land under climate-smart practices",
    "livestock producers", "pest/disease reduction", "processors",
    "producer organizations", "smallholder farmers reached",
    "soil organic matter improved", "terrestrial protected areas",
    "total beneficiaries", "vulnerable households", "wholesalers",
    "women beneficiaries", "youth beneficiaries"),
  unit = c("groups", "hectares", "households", "individuals", "kg",
    "kg/hectare", "liters", "organizations", "percentage", "quantity",
    "tCO2e", "tons"))

DEFS <- list(
  scale = "individual/household: persons or families receiving direct or indirect benefits; community: local residents benefitting collectively; sub-national: interventions benefit regional populations (a landscape, district, or agricultural production zone); national: an entire country's citizens benefit broadly; multinational: involves and benefits multiple nations; unclear/ unspecified: affected beneficiaries remain unidentified.",
  beneficiary = "agribusiness: commercial enterprises in production/processing/distribution of agricultural products; artisanal fisher: small-scale traditional fishers; children: under eighteen; community: a social group sharing space/culture/interests; cooperative: member-owned enterprise; elderly: sixty-five and above; farm laborer: wage farm workers without land; farmer association: organized farmer group for advocacy/markets; farmer group: small collective of farmers collaborating; household: residential unit sharing income and consumption; indigenous peoples: distinct ethnic groups with historical territorial ties; low-income households: earnings below basic-needs threshold; marginalized group: systematically excluded populations; migrant: person moving for opportunity or safety; pastoralist/herder: livelihood from moving livestock; people with disabilities: long-term impairments; producer: cultivates crops or rears animals; producer organization: formal entity representing producers; smallholder farmer: cultivates a small plot with family labor; subsistence farmer: produces mainly to feed own family; vulnerable population: higher risk of poverty/exclusion/harm; women (female-headed households): woman is primary decision-maker/provider; women's group/organization: women's collectives; youth: fifteen to twenty-four.",
  doc_type = "Note: an independent ex-post evaluation that reviews/re-rates a completion report (AfDB PPER, IEG review) = terminal evaluation; an independent evaluation office's multi-program evaluation = portfolio performance review; a completion report written by the financier at project close = implementation completion report.")

# ---- the location sheet's own controlled values ----------------------------
# Moved here 30 Sep 2026 from harmonize_locations.R, which held a second copy.
# TARGETS there was character-for-character OPT$beneficiary, which is exactly
# the duplication this file exists to end: two lists that agree today and
# quietly stop agreeing the first time somebody edits one of them.
OPT$subsector <- c("agri-food", "farming system-crop", "farming system-livestock",
                   "farming system-mixed", "farming system-fish", "land use",
                   "cross cutting")
OPT$result_level <- c("input", "process", "output", "outcome", "impact")
