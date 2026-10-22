# Request to IFAD — draft

Two recipients, two different asks. Send both; they are different offices.

- **IFAD open data / IATI team** — the broken document links and a bulk copy of
  the 102 operational documents. Contact point published by IFAD at
  `https://www.ifad.org/en/iati`.
- **Independent Office of Evaluation** — `evaluation@ifad.org`. They hold the
  independent evaluations, which are absent from IATI entirely and are the
  documents we would value most.

Attach `ifad_target_documents.csv` to the first. Written for a technical
reader at a UN agency, not for us.

---

## To the IATI / open data team

**Subject:** IFAD IATI document links unreachable — operations.ifad.org has no
TLS certificate

Dear colleagues,

I work on an evidence synthesis at CGIAR, reviewing what evaluations of
African agriculture projects report about climate adaptation. IFAD is the
agriculture lender, so your project documents matter to us more than most. We
are reading them for a systematic review; we are not republishing or
redistributing them.

**The problem.** Every document URL in IFAD's IATI data points at
`operations.ifad.org`, and that host cannot be reached by anything:

```
operations.ifad.org → CNAME operations.ifad.org.cdn.cloudflare.net
                      172.64.150.11 / 2a06:98c1:3109::ac40:960b

openssl s_client -connect operations.ifad.org:443
  → SSL alert number 40 (handshake_failure)
  → "no peer certificate available"
  identical over IPv4 and IPv6

Google Chrome → net::ERR_SSL_VERSION_OR_CIPHER_MISMATCH
```

The server aborts the TLS handshake before presenting a certificate, which
means Cloudflare has no certificate provisioned for that hostname. This is not
a question of bot filtering, and it is not something a client can work around:
the connection never reaches HTTP. By contrast `www.ifad.org` and
`ioe.ifad.org` both serve a valid certificate.

We catalogued 413 African activities from your IATI data via d-portal, giving
750 document links. **All 750 are affected.** Our best guess is that the
hostname was retired during a platform migration without the IATI
document-links being updated.

**What we are asking for.** The 102 documents listed in the attached CSV:
project completion reports and interim (mid-term) review reports for 91
African projects that ended in 2015 or later. A bulk copy of that slice, or
corrected URLs, would both work. The file gives the project id, title,
document title and the current dead link for each.

**A second finding, offered because it is probably useful to you.** Around
one in five document links appears to be attached to the wrong activity. For
example activity `XM-DAC-41108-1100001373` (Eswatini, dataset
`ifad-activitity-sz`) carries documents titled

- `Zambia 2000001405: E-SAPP ...`
- `Mexico 1100001597: Semiarid-Mixteca ...`

We route around it by reading the project id out of the document title, which
your titles carry reliably, but you may want to look at the generation step.

**One last note, raised because we would rather ask than work around it.**
`https://www.ifad.org/robots.txt` returns

```
User-Agent: *
Disallow:
Sitemap: https://www.ifad.org:443/sitemap.xml
```

an empty `Disallow`, which permits crawling, and it advertises a sitemap that
returns 403. The site returns 403 to automated clients generally. We have not
attempted to circumvent that and we will not; we are asking instead. If you
would prefer we use a different route, or a rate we agree in advance, tell us
and we will follow it.

Happy to credit IFAD in the synthesis and to share the results.

With thanks,
[name], CGIAR — M.Lolita@cgiar.org

---

## To the Independent Office of Evaluation

**Subject:** Access to IOE project evaluations for a CGIAR evidence synthesis

Dear colleagues,

I work on an evidence synthesis at CGIAR on climate adaptation in African
agriculture, reading project evaluations to record what was done and what
changed. We have assembled around 470 evaluations from the World Bank, the
African Development Bank, GEF, GCF, the Adaptation Fund and CIF.

IFAD's independent evaluations are the gap. We can see IFAD's self-evaluation
documents through your IATI data, but the IATI feed carries no independent
evaluation at all: no project performance evaluation, no impact assessment, no
country strategy evaluation. Those appear to live only on `ioe.ifad.org`,
which returns 403 to automated clients.

Could you let us have the project performance evaluations and impact
assessments for African projects from 2015 onwards, or point us at a bulk
route? We would happily work from a list you provide rather than asking you to
assemble files.

For completeness: the document URLs in IFAD's IATI data all point at
`operations.ifad.org`, which currently terminates TLS without presenting a
certificate and so is unreachable by any client. We have raised that
separately with the IATI team.

We are reading these for a systematic review, not redistributing them, and we
are glad to credit IOE and share what we find.

With thanks,
[name], CGIAR — M.Lolita@cgiar.org

---

## Follow-up

One polite reminder at three weeks. Budget six. Nothing in the pipeline blocks
on a reply: the target list stands on its own and the documents can be
retrieved by hand from the project pages if a person opens them in a browser,
which works.

## Also worth doing, free and self-service

- **IATI Datastore key** — `https://developer.iatistandard.org/`. It serves
  IFAD's *current* published files, so it is the cheapest test of whether the
  URLs have already been fixed upstream and our d-portal mirror is simply
  stale. If so, this whole problem disappears.
- **ReliefWeb v2 app name** — free by email. Low expected yield, ten minutes,
  and it closes the route properly.
