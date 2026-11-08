"""Fill the supplied workbook with saved, checked results using a portable Python writer."""

import math
from copy import copy
from pathlib import Path

from openpyxl import Workbook, load_workbook
from openpyxl.cell.cell import Cell
from openpyxl.styles import Alignment, Font, PatternFill
from openpyxl.utils import get_column_letter
from openpyxl.worksheet.datavalidation import DataValidation
from openpyxl.worksheet.table import Table, TableStyleInfo
from openpyxl.worksheet.worksheet import Worksheet

from common.files import ROOT, file_hash, read_json, write_json
from common.template import PROJECT_COLUMNS, RESULT_COLUMNS, SCHEMA


def set_value(cell: Cell, value: object) -> None:
    """Keep source strings literal, including text beginning with an equals sign."""
    cell.value = value
    if isinstance(value, str):
        cell.data_type = "s"


def populate(sheet: Worksheet, rows: list[dict], columns: list[str], header: int) -> None:
    """Write typed values with readable wrapping and fitted row heights."""
    for column, name in enumerate(columns, 1):
        cell = sheet.cell(header, column, name)
        cell.font = Font(name="Arial", size=10, bold=True, color="FFFFFF")
        cell.fill = PatternFill("solid", fgColor="1F4E78")
        cell.alignment = Alignment(wrap_text=True, vertical="center")
    sheet.row_dimensions[header].height = 30
    for row_index, row in enumerate(rows, header + 1):
        lines = 1
        for column, name in enumerate(columns, 1):
            cell = sheet.cell(row_index, column)
            set_value(cell, row.get(name))
            cell.font = Font(name="Arial", size=10, color="1F2937")
            cell.alignment = Alignment(wrap_text=True, vertical="top")
            cell.number_format = "General"
            value = row.get(name)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                cell.number_format = "#,##0" if isinstance(value, int) else "#,##0.############"
            if sheet.column_dimensions[get_column_letter(column)].hidden:
                continue
            width = sheet.column_dimensions[get_column_letter(column)].width or 20
            lines = max(
                lines,
                sum(
                    max(1, math.ceil(len(part) / max(width - 2, 1)))
                    for part in str(value or "").splitlines()
                ),
            )
        sheet.row_dimensions[row_index].height = min(409, max(30, lines * 14))
    last = header + max(1, len(rows))
    ref = f"A{header}:{get_column_letter(len(columns))}{last}"
    sheet.auto_filter.ref = None
    sheet.tables.clear()
    table = Table(displayName="Extracted" + sheet.title.title(), ref=ref)
    table.tableStyleInfo = TableStyleInfo(name="TableStyleMedium2", showRowStripes=True)
    sheet.add_table(table)


def result_sheet(sheet: Worksheet, rows: list[dict]) -> None:
    """Preserve the template's 25 columns and append method/trial/provenance details."""
    for row in sheet.iter_rows(min_row=3, max_row=sheet.max_row):
        for cell in row:
            cell.value = None
    for column in range(26, len(RESULT_COLUMNS) + 1):
        sheet.column_dimensions[get_column_letter(column)].width = 23
    for column, width in {
        "A": 34,
        "D": 54,
        "E": 42,
        "N": 30,
        "O": 25,
        "P": 45,
        "S": 90,
        "T": 30,
        "AB": 48,
        "AC": 22,
        "AD": 90,
    }.items():
        sheet.column_dimensions[column].width = width
    sheet["Z1"] = "Experiment"
    sheet["Z1"]._style = copy(sheet["W1"]._style)
    populate(sheet, rows, RESULT_COLUMNS, 2)
    for row in sheet.iter_rows(min_row=3, max_row=max(3, len(rows) + 2)):
        for column in (13, 17, 27, 31):
            row[column - 1].number_format = "0"
    sheet.freeze_panes = "D3"
    sheet.data_validations.dataValidation.clear()
    last = max(3, len(rows) + 2)
    for column, listing in {
        "F": "result_level",
        "J": "result_unit",
        "O": "target_beneficiary",
        "U": "source_kind",
        "V": "section",
        "W": "true_false",
        "X": "true_false",
        "Y": "review_reason",
    }.items():
        letter = get_column_letter(list(SCHEMA["lists"]).index(listing) + 1)
        validation = DataValidation(
            type="list",
            formula1=f"'lists'!${letter}$2:${letter}${len(SCHEMA['lists'][listing]) + 1}",
            allow_blank=True,
        )
        sheet.add_data_validation(validation)
        validation.add(f"{column}3:{column}{last}")


def project_sheet(book: Workbook, projects: list[dict]) -> None:
    """Keep project identifiers and numbers readable while grouping longer source narratives."""
    sheet = book.create_sheet("projects")
    for column in range(1, len(PROJECT_COLUMNS) + 1):
        sheet.column_dimensions[get_column_letter(column)].width = 22
    for column, width in {
        "F": 62,
        "H": 40,
        "L": 55,
        "M": 65,
        "O": 70,
        "P": 70,
        "Q": 70,
        "W": 60,
        "X": 60,
        "AE": 100,
        "AF": 90,
    }.items():
        sheet.column_dimensions[column].width = width
    # Long narrative fields remain available in expandable groups beside the summary.
    for column in ("O", "P", "Q", "AE", "AF"):
        sheet.column_dimensions[column].hidden = True
        sheet.column_dimensions[column].outlineLevel = 1
    sheet.sheet_properties.outlinePr.summaryRight = False
    for column in ("N", "AD"):
        sheet.column_dimensions[column].collapsed = True
    populate(sheet, projects, PROJECT_COLUMNS, 1)
    for row in sheet.iter_rows(min_row=2, max_row=max(2, len(projects) + 1)):
        for column in (4, 9, 10, 11, 14, 25):
            row[column - 1].number_format = "0"
    sheet.freeze_panes = "E2"
    sheet.sheet_view.showGridLines = False


def export_xlsx(run_dir: Path) -> Path:
    """Fill a copy of the template and verify every saved result/project cell on reopening."""
    output = run_dir / "exports"
    rows, projects = (
        read_json(output / "template_results.json"),
        read_json(output / "projects.json"),
    )
    book = load_workbook(ROOT / "inputs/results_template.xlsx")
    result_sheet(book["results"], rows)
    project_sheet(book, projects)
    spec = book["columns"]
    updates = {
        "A2": "One row per result claim per paper, method and trial. Project fields are on projects.",
        "A4": "Illustrative answers removed. Blanks mean unsupported/unmapped fields, not zero. Raw facts remain in saved exports.",
        "A6": "verified checks only stated-value occurrence on a cited PDF text page. It does not establish indicator, scope, attribution or human correctness.",
        "A7": "Exact repeated claims merge citations. Conflicting values remain for review. CANDIDATE metrics and unmapped units need review.",
        "D10": "Content-based ID scoped by paper, method and trial. Unchanged claims keep their ID across reruns.",
        "D11": "Original PDF filename stem, matching the parsed paper folder.",
        "D29": "Experiment chunk ID for hybrid only; blank for full PDF/full parsed. source_block_id identifies matched parsed provenance.",
    }
    for cell, value in updates.items():
        spec[cell] = value
    target = output / "extraction_results.xlsx"
    book.save(target)
    book.close()

    # Source values must survive export exactly, including zeros, booleans and empty cells.
    saved = load_workbook(target, data_only=False)
    for name, records, columns, start in (
        ("results", rows, RESULT_COLUMNS, 3),
        ("projects", projects, PROJECT_COLUMNS, 2),
    ):
        for index, row in enumerate(records, start):
            for column, key in enumerate(columns, 1):
                actual = saved[name].cell(index, column).value
                expected = row.get(key)
                if (actual if actual is not None else "") != (
                    expected if expected is not None else ""
                ):
                    raise ValueError(
                        f"Workbook round-trip mismatch at {name}!{get_column_letter(column)}{index}"
                    )
    saved.close()
    write_json(
        output / "workbook_metadata.json",
        {
            "writer": "openpyxl",
            "exporter_sha256": file_hash(Path(__file__)),
            "template_sha256": file_hash(ROOT / "inputs/results_template.xlsx"),
            "data_hashes": {
                name: file_hash(output / name)
                for name in ("template_results.json", "projects.json")
            },
            "result_rows": len(rows),
            "project_rows": len(projects),
            "all_saved_cells_verified": True,
        },
    )
    return target
