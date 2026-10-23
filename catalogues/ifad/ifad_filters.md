# IFAD — retrieval channel, filters and coverage

**Status, 3 October 2026: catalogued, not retrieved. Automated retrieval is
off by decision.** 102 target documents are identified with working project
links; none is held.

## Channel

IFAD publishes to the IATI standard as `XM-DAC-41108`. We read that through
d-portal (`https://d-portal.org/q.json`), which mirrors it with no
authentication: a listing per African country code, then one request per
activity. 413 activity records are cached in `ifad_cache/`, so everything
below is recomputed offline by `R/01_retrieve/ifad_target_list.R` without
touching the network.

We do **not** scrape ifad.org. See "Why retrieval is off".

## Why retrieval is off

Every one of the 750 document URLs IFAD publishes points at
`operations.ifad.org`. That host is a dead end, and not because of
bot-blocking:

```
operations.ifad.org → CNAME operations.ifad.org.cdn.cloudflare.net
                      172.64.150.11 / 2a06:98c1:3109::ac40:960b
  openssl s_client → SSL alert number 40 (handshake_failure)
                     "no peer certificate available"
                     identical on IPv4 and IPv6
  real Chromium    → net::ERR_SSL_VERSION_OR_CIPHER_MISMATCH

www.ifad.org → subject=CN=www.ifad.org, valid, TLS1.3 OK
ioe.ifad.org → subject=CN=www.ifad.org, valid, TLS1.3 OK
```

The server aborts the handshake **before presenting a certificate**. That is a
Cloudflare hostname with no SSL provisioned: decommissioned or misconfigured.
No client can reach it, which a real browser confirmed. **All 750 document
links in IFAD's own published data are dead links.**

The two hosts that do have certificates are behind a Cloudflare challenge. A
plain headless Chromium, launched with no arguments and identifying itself
honestly, was refused 403 on all five project pages tried and on the
evaluation office listing, while `robots.txt` returned 200 from the same
session. Probe record: `scratchpad/ifad_probe_results.json`.

Note the contradiction, which is worth putting to IFAD rather than working
around: `https://www.ifad.org/robots.txt` returns

```
User-Agent: *
Disallow:
Sitemap: https://www.ifad.org:443/sitemap.xml
```

an empty `Disallow`, which permits crawling, and it advertises a sitemap that
is itself 403. Their stated policy and their edge disagree. We asked rather
than evaded: no anti-detection flags, no browser impersonation from
non-browser clients, no challenge solving.

## Document type: read the title, never the category

The IATI category codes are unusable here. 683 of 750 rows carry `A08`
("final evaluation") because IFAD blanket-tags nearly every attachment
`A02,A07,A08`, and a best-ranked-code rule then promotes supervision reports
to evaluations. By title:

| Type | Rows |
|---|---|
| Supervision report (progress) | 544 |
| Interim (Mid-term) Review Report | 80 |
| Project Completion Report | 59 |
| Design / appraisal | 45 |
| Unclassified | 22 |

The classifier tests supervision first so nothing downstream can steal those
rows. Note all 80 mid-term reviews read **"Interim (Mid-term) Review Report"**,
so a `mid-?term review` pattern matches none of them; match the words.

The 22 unclassified are kept as an explicit bucket, never guessed: they are
annexes, audit reports, logical frameworks and a few Spanish-language design
documents.

## Target set

Completion reports and mid-term reviews, African, project ending 2015 or
later, deduplicated by URL:

**102 documents across 91 projects** — 44 completion reports, 58 mid-term
reviews. Written to `ifad_target_documents.csv` with the project page, the
dead document link, a suggested filename in the house convention, and the
named IFAD country director where one is published (79 of 102).

10 non-African documents (Ecuador, Paraguay, Mexico and others, reaching the
African catalogue through the attribution defect below) are written to
`ifad_target_documents_excluded.csv` so the exclusion is reviewable.

## Two defects in IFAD's published data

**1. 250 of 750 project-page links were wrong in our first catalogue.** The
1100-series uses a short id on the web (`1100001679` → `/w/projects/1679`).
The record publishes the correct page as an `A12` document-link; we now read
that, and keep the derivation rule as a fallback. The rule agrees with the
published link in 413 of 413 records.

**2. 164 of 750 document links are attached to the wrong activity**, in
IFAD's data, not ours. The Eswatini record `XM-DAC-41108-1100001373` carries
documents titled for Zambia and Mexico. The title carries its own project id
and country and is authoritative, so the target list keys on it; `id_agrees`
flags every disagreement (11 rows in the target set). This is a limitation we
can route around but cannot verify: if a *title* is also wrong, nothing
downstream will catch it.

## Coverage, stated honestly

| | |
|---|---|
| African activities catalogued | 413 |
| of those, with any document | 182 |
| with none | 231 |
| document links total | 750 |
| target documents | 102 |
| **held** | **0** |

**There are no independent evaluations in this catalogue at all.** No title in
all 750 matches "evaluation" or "impact". IFAD's IATI carries self-evaluation
only: supervision, mid-term review, completion, design. The Independent Office
of Evaluation's project performance evaluations and impact assessments, which
would be the highest-value documents for this synthesis, live on
`ioe.ifad.org` and are absent from IATI. That host has a working certificate
and only the challenge in front of it, so it is the better target if access is
ever granted.

Partial IFAD coverage already exists second-hand: 43 rows in the GEF ledger
and 25 in the Adaptation Fund ledger name IFAD as implementing agency, because
IFAD executes projects for both.

## Scripts

| | |
|---|---|
| `R/01_retrieve/ifad_catalogue.R` | builds the catalogue and the cache from d-portal |
| `R/01_retrieve/ifad_target_list.R` | recomputes types, fixes the links, writes the target list |
| `R/archive/ifad_dportal_v1.R` | retired; see below |

The retired script ran once and wrote 313 log rows with zero files, because it
pre-screened every IFAD host and short-circuited before requesting anything.
It was removed from the working set so `run_all.R` stops manufacturing those
rows; the discarded log rows are kept in
`audit/2026-10_completeness/ifad_discarded_log_rows.csv`.
