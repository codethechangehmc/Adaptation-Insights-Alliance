# Template reference, exported

The extraction template is a workbook on OneDrive. These CSVs are the parts
other people need, exported so they are readable without the workbook.

| File | Rows | What |
|---|---|---|
| `codebook.csv` | 64 | Field definitions: field, description, options, example |
| `option_lists.csv` | 194 | The controlled vocabularies, 11 lists |
| `location_codes.csv` | 677 | The registry every `location_id` is drawn from |
| `fields_project_data_general.csv` | 36 | Field order, project sheet |
| `fields_project_data_location_specific.csv` | 20 | Field order, location sheet |

Regenerate with `Rscript R/00_shared/export_template.R` after any template
release, so these never drift from the workbook the pipeline reads.

Note the option lists come from the 2 October workbook; the codebook and the
location registry come from the workbook `paths.R` points at. The pipeline also
carries its own copy of seven vocabularies in `R/00_shared/vocab_lists.R`,
fingerprinted so a change invalidates cached decisions. If a list changes,
change it in one place and regenerate.

## The workbooks

`template_27Aug2026.xlsx` and `template_02Oct2026.xlsx` are the workbooks
themselves. Four scripts read a workbook directly, so a clone without one
cannot run harmonisation, location scoring or the actor audit. The committed
copies carry short names: `git clone` fails on Windows with the original
names, because the path exceeds the limit during checkout and the working
tree is left incomplete.

`paths.R` uses the OneDrive master when it is reachable, so edits by the
template owner take effect at once, and the committed copy otherwise. The
code currently reads the 27 August workbook; the option lists come from the
2 October one.
