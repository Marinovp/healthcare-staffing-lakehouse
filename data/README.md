# Source data

The source files are **not committed** to this repository (GitHub limits files to 100 MB). This file records where they come from, so anyone can rebuild the dataset.

## Source

| | |
|---|---|
| Publisher | Centers for Medicare & Medicaid Services (CMS) |
| Dataset | Payroll-Based Journal (PBJ) Daily Nurse Staffing, Q2 2024 |
| Master file | `PBJ_Daily_Nurse_Staffing_Q2_2024.csv` |
| Supporting files | 15 CSVs (facility reference and quality data) |
| Provided via | Google Drive folders `Nursing_Data/` and `Supporting_CSV/` (project brief) |
| Original publisher site | data.cms.gov |
| Licence | Public U.S. government data |

## Local layout

To work with the files locally, download them here, keeping the Drive folder structure:

    data/
    ├── Nursing_Data/
    └── Supporting_CSV/

Everything in `data/` except this README is ignored by Git.

## How the pipeline uses them

The pipeline does **not** read these local copies. It copies the files from Google Drive into S3 `raw/` (the bronze layer), where bucket versioning keeps every file ever loaded. S3 is the durable copy of the data; this folder is for local exploration only.
