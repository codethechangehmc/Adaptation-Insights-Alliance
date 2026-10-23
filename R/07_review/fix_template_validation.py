# -*- coding: utf-8 -*-
"""
fix_template_validation.py - repair the extraction template's dropdowns.

Why Python in an R repo: every list validation in the 27 Aug 2026 template
points at #REF!, because the lists tab they referenced left with another
workbook. Fixing that means rewriting the validation rules, and both Excel
writers available here (openxlsx, openpyxl) rebuild a workbook from their own
model and silently drop the threaded comments Lucy and Charity have left in
the template, the custom XML and the printer settings. So this edits the .xlsx
as the zip it is: it replaces four parts, adds one, and copies every other
byte across untouched.

What it does
  1. reads the controlled lists out of the readme sheet's `options` column, so
     a dropdown can never disagree with the documentation beside it;
  2. writes them to a new `lists` tab - which readme row 5 already tells people
     to consult - with one dynamic named range per list, so adding an option at
     the bottom of a column widens the dropdown with no further edit;
  3. discards every existing data validation on the five sheets and lays down a
     fresh set, on the right columns, over the whole data area;
  4. normalises three characters nobody can type (see NORMALISE), so a typed or
     pasted value matches the list;
  5. never touches the source file. It writes a new one and prints a report.

Usage
  python fix_template_validation.py <source.xlsx> <destination.xlsx>

The same command repairs a consultant's half-filled copy: rules are keyed on
header names, not column letters, and nothing in the data area is written.
"""
import os
import re
import sys
import zipfile

import openpyxl
from openpyxl.utils import get_column_letter

NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

# Characters the readme uses that a person cannot type and the pipeline does
# not emit. Left alone, a hand-typed "tCO2e" fails a list whose entry is
# "tCO<subscript two>e", with nothing on screen to explain why.
NORMALISE = {
    " ": " ",   # no-break space      (project_scale)
    "‑": "-",   # non-breaking hyphen (mid-term, multi-country)
    "₂": "2",   # subscript two       (tCO2e)
}


def clean(s):
    s = str(s)
    for bad, good in NORMALISE.items():
        s = s.replace(bad, good)
    return re.sub(r"\s+", " ", s).strip()


def split_list(cell, sep=","):
    return [clean(x) for x in str(cell).split(sep) if clean(x)]


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


# ---------------------------------------------------------------------------
# 1. the lists, read out of the workbook itself
# ---------------------------------------------------------------------------
def read_lists(path):
    wb = openpyxl.load_workbook(path, data_only=True)
    rm = wb["readme"]
    opts, instr = {}, {}
    section = None
    for r in range(1, rm.max_row + 1):
        a = rm.cell(r, 1).value
        a = "" if a is None else str(a).strip()
        if a.startswith("project_data") and rm.cell(r, 2).value is None:
            section = a
            continue
        if a == "field" or not a or section is None:
            continue
        opts[(section, a)] = str(rm.cell(r, 3).value or "")
        instr[(section, a)] = str(rm.cell(r, 6).value or "")

    G = "project_data_general"
    L = "project_data_location-specific"
    lists = {}
    lists["project_scale"] = split_list(opts[(G, "project_scale")])
    lists["target_beneficiary"] = split_list(opts[(G, "target_beneficiary_project")])
    lists["result_metric"] = split_list(opts[(G, "result1_metric")])
    lists["result_unit"] = split_list(opts[(G, "result1_unit")])
    lists["document_type"] = split_list(opts[(G, "document_type")])
    lists["subsector_type"] = split_list(opts[(L, "subsector type")])
    lists["result_level"] = split_list(opts[(L, "result_level")])

    # actor_type is documented only inside the prose of the project_lead
    # instruction, semicolon separated, which is a large part of why it drifted.
    m = re.search(r"actor type \(options:(.*?)\)", instr[(G, "project_lead")], re.S)
    lists["actor_type"] = split_list(m.group(1), ";") if m else []

    # funding_mechanism's options cell says "free text", but the explanation
    # beside it defines five numbered categories. The categories are the list.
    expl = str(rm.cell(35, 4).value or "")
    lists["funding_mechanism"] = [c.lower() for c in re.findall(r"\d\)\s*([A-Za-z]+)\s*:", expl)]

    # location_type: the readme names nine, the registry already uses far more.
    # Blocking what is in the file would be wrong, so the list is the union and
    # the rule is a warning rather than a stop.
    m = re.search(r"location type \(options:(.*?)\)", instr[(L, "location")], re.S)
    doc_lt = [x.rstrip(",") for x in split_list(m.group(1), ";")] if m else []
    ws = wb["location_codes"]
    used_lt = set()
    for r in range(2, ws.max_row + 1):
        v = ws.cell(r, 3).value
        if v and clean(v):
            used_lt.add(clean(v))
    lists["location_type"] = sorted(set(doc_lt) | used_lt)

    # location_country: built from what the registry holds, with the two
    # spellings of Cote d'Ivoire collapsed onto the one used most.
    seen = {}
    for r in range(2, ws.max_row + 1):
        v = ws.cell(r, 7).value
        if not v:
            continue
        k = str(v).strip()
        seen[k] = seen.get(k, 0) + 1
    merged = {}
    for name, n in sorted(seen.items(), key=lambda kv: -kv[1]):
        key = name.replace("’", "'").lower()
        merged.setdefault(key, name)
    lists["location_country"] = sorted(merged.values(), key=lambda s: s.lower())

    for k, v in lists.items():
        if len(v) < 2:
            raise SystemExit("list %r came out with %d entries - aborting" % (k, len(v)))
    return wb, lists


# ---------------------------------------------------------------------------
# 2. what rule belongs on what column
# ---------------------------------------------------------------------------
YEAR = dict(kind="whole", f1="2000", f2="2025", style="warning",
            title="Check the year",
            msg="The readme accepts 2000 to 2025. If the document really says "
                "otherwise, check it and keep what the document says.")

NUM = dict(kind="decimal", f1="0", f2="999999999999", style="warning",
           title="Check the number",
           msg="A number on its own: no thousands separators, no currency, no "
               "unit. The unit goes in its own column.")


def lst(name, style="stop", title=None, msg=None):
    return dict(kind="list", f1=name, style=style, title=title, msg=msg)


def note(title, msg):
    return dict(kind="note", title=title, msg=msg)


PICK_ONE = ("Pick one category. Where several apply, the readme says to take the "
            "larger beneficiary group, or an overarching one such as 'community'.")

DEPTH = ("0 = general project information only. "
         "1 = also describes concrete interventions implemented. "
         "2 = also gives results and effectiveness of those interventions.")

CODES = ("Codes from the actor_codes tab. Separate several with a semicolon, "
         "like 'GLO18; CON3'. If an organisation is not in that tab yet, add a "
         "row there first.")

RULES = {
    "project_data_general": {
        "project_lead": note("One actor code", CODES),
        "publication_year": YEAR,
        "start_year": YEAR,
        "closure_year": YEAR,
        "project_scale": lst("list_project_scale", title="Project scale",
                             msg="Pick the level at which the project worked."),
        "location_count": note("How many African locations",
                               "A number. Put ~ in front for an estimate, and "
                               "N/A if the document does not say."),
        "target_beneficiary_project": lst("list_target_beneficiary",
                                          title="One beneficiary category",
                                          msg=PICK_ONE),
        "result1": NUM,
        "result2": NUM,
        "result3": NUM,
        "result1_metric": lst("list_result_metric"),
        "result2_metric": lst("list_result_metric"),
        "result3_metric": lst("list_result_metric"),
        "result1_unit": lst("list_result_unit"),
        "result2_unit": lst("list_result_unit"),
        "result3_unit": lst("list_result_unit"),
        "budget_total": NUM,
        "disbursed": NUM,
        "currency": note("ISO currency code",
                         "Three letters as ISO writes them: USD, EUR, XOF, ZAR, KES."),
        # the readme's own explanation says funding can be a mix, so this one
        # suggests rather than blocks
        "funding_mechanism": lst("list_funding_mechanism", style="warning",
                                 title="Funding mechanism",
                                 msg="Pick one. A mix of instruments is 'blended', "
                                     "and the split goes in the next column."),
        "funding_mechanism_portion": note("The split",
                                          "Instruments with their share, like "
                                          "grant (40%) + loan (40%) + other (20%)."),
        "funder": note("Actor codes", CODES),
        "implementors": note("Actor codes", CODES),
        "document_type": lst("list_document_type"),
        "evidence_depth": dict(kind="list", f1='"0,1,2"', style="stop",
                               title="Evidence depth", msg=DEPTH),
    },
    "project_data_location-specific": {
        "row_id": dict(kind="whole", f1="1", f2="1000000", style="warning",
                       title="Row number", msg="A running number."),
        "project_lead": note("One actor code", CODES),
        "location": note("Location codes",
                         "Codes from the location_codes tab, like 'WB001.1'. "
                         "Separate several with a semicolon."),
        "subsector type": lst("list_subsector_type", title="Subsector",
                              msg="Pick the dominant one for this intervention."),
        "target_beneficiary": lst("list_target_beneficiary",
                                  title="One beneficiary category", msg=PICK_ONE),
        "result_level": lst("list_result_level", title="Impact pathway level",
                            msg="input, process, output, outcome or impact."),
        "evidence_depth": dict(kind="list", f1='"0,1,2"', style="stop",
                               title="Evidence depth", msg=DEPTH),
    },
    "actor_codes": {
        "actor_type": lst("list_actor_type"),
    },
    "location_codes": {
        # warning, not stop: the registry already holds types the readme never named
        "location_type": lst("list_location_type", style="warning",
                             title="Location type",
                             msg="Pick one. The readme names nine; the list also "
                                 "offers the types already used in this tab."),
        "coordinate_type": dict(kind="list", f1='"estimated,provided,N/A"',
                                style="stop", title="Coordinate type",
                                msg="Use 'provided' only when the document states "
                                    "the coordinates."),
        "location_country": lst("list_location_country", style="warning",
                                title="Country",
                                msg="Pick from the list so one country keeps one "
                                    "spelling."),
    },
}

LAST_ROW = 1048576


def dv_xml(sqref, rule):
    a = ['allowBlank="1"', 'showInputMessage="1"', 'showErrorMessage="1"']
    if rule["kind"] != "note":
        a.insert(0, 'type="%s"' % rule["kind"])
        if rule.get("style") == "warning":
            a.append('errorStyle="warning"')
    if rule.get("title"):
        a.append('promptTitle="%s"' % esc(rule["title"]))
        a.append('prompt="%s"' % esc(rule["msg"]))
        if rule["kind"] != "note":
            a.append('errorTitle="%s"' % esc(rule["title"]))
            a.append('error="%s"' % esc(rule["msg"]))
    a.append('sqref="%s"' % sqref)
    inner = ""
    if rule["kind"] != "note":
        inner += "<formula1>%s</formula1>" % esc(rule["f1"])
        if rule.get("f2"):
            inner += "<formula2>%s</formula2>" % esc(rule["f2"])
    if inner:
        return "<dataValidation %s>%s</dataValidation>" % (" ".join(a), inner)
    return "<dataValidation %s/>" % " ".join(a)


def build_block(sheet, headers, applied):
    rules = RULES.get(sheet, {})
    parts = []
    for header, col in headers.items():
        rule = rules.get(header)
        if not rule:
            continue
        sqref = "%s2:%s%d" % (col, col, LAST_ROW)
        parts.append(dv_xml(sqref, rule))
        applied.append((sheet, col, header, rule["kind"],
                        rule.get("f1", ""), rule.get("style", "-")))
    if not parts:
        return ""
    return '<dataValidations count="%d">%s</dataValidations>' % (len(parts), "".join(parts))


# ---------------------------------------------------------------------------
# 3. the lists tab
# ---------------------------------------------------------------------------
def lists_sheet_xml(lists):
    names = list(lists)
    nmax = max(len(v) for v in lists.values())
    rows = []
    cells = []
    for i, n in enumerate(names):
        cells.append('<c r="%s1" t="inlineStr"><is><t>%s</t></is></c>'
                     % (get_column_letter(i + 1), esc(n)))
    rows.append('<row r="1">%s</row>' % "".join(cells))
    for r in range(nmax):
        cells = []
        for i, n in enumerate(names):
            if r < len(lists[n]):
                cells.append('<c r="%s%d" t="inlineStr"><is><t xml:space="preserve">%s</t></is></c>'
                             % (get_column_letter(i + 1), r + 2, esc(lists[n][r])))
        if cells:
            rows.append('<row r="%d">%s</row>' % (r + 2, "".join(cells)))
    cols = "".join('<col min="%d" max="%d" width="34" customWidth="1"/>' % (i + 1, i + 1)
                   for i in range(len(names)))
    return ('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
            '<worksheet xmlns="%s"><sheetPr><tabColor rgb="FFBFBFBF"/></sheetPr>'
            '<dimension ref="A1:%s%d"/>'
            '<sheetViews><sheetView workbookViewId="0"><pane ySplit="1" topLeftCell="A2" '
            'activePane="bottomLeft" state="frozen"/></sheetView></sheetViews>'
            '<sheetFormatPr defaultRowHeight="14.45"/><cols>%s</cols>'
            '<sheetData>%s</sheetData>'
            '<pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" '
            'header="0.3" footer="0.3"/></worksheet>'
            % (NS, get_column_letter(len(names)), nmax + 1, cols, "".join(rows)))


def defined_names(lists):
    out = []
    for i, n in enumerate(lists):
        col = get_column_letter(i + 1)
        out.append('<definedName name="list_%s">OFFSET(lists!$%s$2,0,0,'
                   'COUNTA(lists!$%s:$%s)-1,1)</definedName>' % (n, col, col, col))
    return "<definedNames>%s</definedNames>" % "".join(out)


# ---------------------------------------------------------------------------
# 4. rewrite the package
# ---------------------------------------------------------------------------
def main(src, dst):
    wb, lists = read_lists(src)
    if "lists" in wb.sheetnames:
        raise SystemExit("this workbook already has a 'lists' tab - run the "
                         "script on the original template instead")

    zin = zipfile.ZipFile(src)
    names = zin.namelist()
    book = zin.read("xl/workbook.xml").decode("utf-8")
    rels = zin.read("xl/_rels/workbook.xml.rels").decode("utf-8")
    rid2tgt = dict(re.findall(r'Id="([^"]+)"[^>]*Target="([^"]+)"', rels))
    sheet_part = {}
    for m in re.finditer(r'<sheet name="([^"]+)"[^>]*r:id="([^"]+)"', book):
        sheet_part[m.group(1)] = "xl/" + rid2tgt[m.group(2)].lstrip("/")

    applied, report, newparts = [], [], {}
    for sheet, part in sheet_part.items():
        if sheet not in RULES:
            continue
        ws = wb[sheet]
        headers = {}
        for c in range(1, 80):
            v = ws.cell(1, c).value
            if v is None or not str(v).strip():
                continue
            headers[str(v).strip()] = get_column_letter(c)
        missing = [h for h in RULES[sheet] if h not in headers]
        if missing:
            report.append("  %s: no column found for %s" % (sheet, missing))
        xml = zin.read(part).decode("utf-8")
        old = re.search(r"<dataValidations\b.*?</dataValidations>", xml, re.S)
        block = build_block(sheet, headers, applied)
        if old:
            xml = xml[:old.start()] + block + xml[old.end():]
        elif block:
            xml = xml.replace("<pageMargins", block + "<pageMargins", 1)
        newparts[part] = xml.encode("utf-8")

    nums = [int(re.search(r"sheet(\d+)\.xml", n).group(1))
            for n in names if re.match(r"xl/worksheets/sheet\d+\.xml$", n)]
    newnum = max(nums) + 1
    newpart = "xl/worksheets/sheet%d.xml" % newnum
    newparts[newpart] = lists_sheet_xml(lists).encode("utf-8")

    rid = "rId%d" % (max(int(x[3:]) for x in rid2tgt if x.startswith("rId")) + 1)
    sid = max(int(x) for x in re.findall(r'sheetId="(\d+)"', book)) + 1
    book = book.replace("</sheets>",
                        '<sheet name="lists" sheetId="%d" r:id="%s"/></sheets>%s'
                        % (sid, rid, defined_names(lists)), 1)
    newparts["xl/workbook.xml"] = book.encode("utf-8")
    newparts["xl/_rels/workbook.xml.rels"] = rels.replace(
        "</Relationships>",
        '<Relationship Id="%s" Type="http://schemas.openxmlformats.org/'
        'officeDocument/2006/relationships/worksheet" '
        'Target="worksheets/sheet%d.xml"/></Relationships>' % (rid, newnum),
        1).encode("utf-8")
    ct = zin.read("[Content_Types].xml").decode("utf-8")
    newparts["[Content_Types].xml"] = ct.replace(
        "</Types>",
        '<Override PartName="/%s" ContentType="application/vnd.openxmlformats-'
        'officedocument.spreadsheetml.worksheet+xml"/></Types>' % newpart,
        1).encode("utf-8")

    tmp = dst + ".tmp"
    zout = zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED)
    for item in zin.infolist():
        data = newparts.pop(item.filename, None)
        zout.writestr(item, zin.read(item.filename) if data is None else data)
    for name, data in newparts.items():
        zout.writestr(name, data)
    zout.close()
    zin.close()
    os.replace(tmp, dst)

    print("source      : %s" % src)
    print("destination : %s" % dst)
    print("\nlists tab, %d controlled lists:" % len(lists))
    for n, v in lists.items():
        print("   %-20s %3d   %s ..." % (n, len(v), ", ".join(v[:4])[:58]))
    print("\nvalidation rules written: %d" % len(applied))
    for sheet, col, header, kind, f1, style in applied:
        print("   %-32s %-3s %-28s %-8s %-26s %s"
              % (sheet, col, header, kind, f1[:26], style))
    for line in report:
        print(line)
    print("\nevery other part of the workbook copied byte for byte "
          "(comments, custom XML, print settings kept).")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2])
