# XLSX Reference

Supporting detail for the xlsx skill. Read the section you need.

## Schema First

Before writing, decide:

- Sheet names and their purpose.
- Header row and expected row counts.
- Data types: text, number, currency, percent, date, datetime, boolean.
- Formulas and the exact ranges they should cover.
- Summary sheets, lookup sheets, assumptions, and raw data sheets.
- Formatting: number formats, widths, freeze panes, filters, tables, conditional formatting.
- Protection/hidden sheets, if requested.
- Whether charts or print-ready layout are required.

Ask only when the missing schema changes the workbook materially. Otherwise choose sensible defaults and make assumptions visible in the workbook.

## Authoring Patterns

New workbook with `openpyxl`:

```python
from openpyxl import Workbook
from openpyxl.styles import Font, Alignment

wb = Workbook()
ws = wb.active
ws.title = "Summary"
ws["A1"] = "Metric"
ws["B1"] = "Value"
ws["A1"].font = ws["B1"].font = Font(bold=True)
ws["B2"] = 42
ws["B2"].number_format = "#,##0"
ws.freeze_panes = "A2"
wb.save("output.xlsx")
```

Editing an existing workbook (copy first, never rebuild):

```python
from pathlib import Path
from shutil import copyfile
from openpyxl import load_workbook

copyfile(Path("input.xlsx"), Path("output.xlsx"))
wb = load_workbook("output.xlsx")
ws = wb["Sheet1"]
ws["B2"] = 42
wb.save("output.xlsx")
```

pandas for data that already lives in DataFrames (new sheets/workbooks only):

```python
import pandas as pd
df.to_excel("output.xlsx", index=False, sheet_name="Data")
```

Then reopen with `openpyxl` for formatting, formulas, widths, freeze panes, filters, and validation.

Reading cached formula results after a recalculation pass:

```python
from openpyxl import load_workbook
wb = load_workbook("output.xlsx", data_only=True)
print(wb["Summary"]["B10"].value)
```

## Common Formulas

| Need | Formula |
| --- | --- |
| Sum | `=SUM(B2:B10)` |
| Count nonblank | `=COUNTA(A2:A10)` |
| Average | `=AVERAGE(B2:B10)` |
| Conditional sum | `=SUMIF(A:A,"Category",B:B)` |
| Lookup modern Excel | `=XLOOKUP(A2,Lookup!A:A,Lookup!B:B,"")` |
| Lookup compatible Excel | `=VLOOKUP(A2,Lookup!A:B,2,FALSE)` |
| Today | `=TODAY()` |

## CSV And Data Imports

- Detect delimiter and encoding when not obvious.
- Preserve leading zeros for IDs, ZIP codes, phone numbers, SKU codes, and account numbers by storing them as text.
- Trim accidental whitespace unless whitespace is meaningful.
- Convert numeric/date fields deliberately; do not let every field become text.
- Keep an untouched raw import sheet if transformation choices matter.

## Verification Checklist

- Expected sheet names.
- Expected row and column counts.
- Headers match the schema exactly.
- Values have correct types: numbers are numeric, dates are dates, formulas are formulas.
- Formulas cover the intended ranges and are not accidentally plain text.
- Totals/subtotals reference the correct rows.
- No stray blank rows/columns inside tables.
- Freeze panes, filters, widths, number formats, and conditional formatting are present when expected.
- Existing workbooks did not lose sheets, formulas, charts, or named ranges unintentionally.
- Existing workbook edits are limited to requested cells/ranges/sheets plus any intentional dependent updates.

## Common Failures

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| SUM returns wrong result | Numbers stored as text | Write numeric types and set formats separately |
| Dates sort alphabetically | Dates stored as strings | Use date/datetime objects and date formats |
| Formula visible as text | Missing leading `=` or cell stored as text | Write formula string beginning with `=` |
| Formula result stale/missing | Workbook not recalculated | Use Excel/LibreOffice recalculation or verify formula text |
| Filter/sort breaks | Merged cells or blank rows in data | Avoid merges and keep tables rectangular |
| Leading zeros disappear | IDs treated as numbers | Store identifier columns as text |
| Columns too narrow | No auto-fit in openpyxl | Set widths explicitly based on content |
| User edits wrong cells | Inputs and formulas mixed | Separate input cells, summaries, and protected/formula areas |
| Existing formulas lost | Rebuilt sheet from scratch | Preserve workbook and edit only required cells/ranges |
| Existing formatting/charts vanished | Workbook rewritten through pandas or `Workbook()` | Load/copy the original workbook and edit in place |
