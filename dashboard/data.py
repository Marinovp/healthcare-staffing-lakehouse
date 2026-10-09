"""Pulls the published marts from Athena and works out the numbers for the dashboard."""

import io
import os
import time

import boto3
import pandas as pd

REGION = os.environ.get("AWS_REGION", "us-west-2")
WORKGROUP = os.environ.get("ATHENA_WORKGROUP", "hsl-dev-dashboard")
MARTS = os.environ.get("MARTS_DATABASE", "hsl_dev_marts")

TOTAL_BENCHMARK = 3.48  # 2024 CMS minimum staffing numbers, only used as a reference
RN_BENCHMARK = 0.55

# One row per facility for the quarter. I load the sums instead of the ratios so the numbers
# stay right after filtering (HPRD = eligible hours / resident days).
FACILITIES_SQL = f"""
SELECT
    a.provnum,
    f.provider_name,
    f.city,
    f.state,
    f.ownership_group,
    f.ownership_type,
    f.certified_beds,
    f.staffing_rating,
    f.short_stay_rehospitalisation_pct,
    sum(a.days_reported)                                    AS days_reported,
    sum(a.days_with_residents)                              AS days_with_residents,
    sum(a.resident_days)                                    AS resident_days,
    sum(a.total_hprd * a.resident_days)                     AS eligible_total_hours,
    sum(a.rn_hprd * a.resident_days)                        AS eligible_rn_hours,
    sum(a.total_nurse_hours)                                AS total_nurse_hours,
    sum(a.contract_hours)                                   AS contract_hours,
    sum(a.below_total_benchmark_rate * a.days_with_residents) AS days_below_total,
    sum(a.below_rn_benchmark_rate * a.days_with_residents)    AS days_below_rn
FROM {MARTS}.agg_facility_month AS a
JOIN {MARTS}.dim_facility AS f ON f.provnum = a.provnum
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8, 9
"""

# Daily sums by state and ownership, used for the trend chart and the weekend gap.
DAILY_SQL = f"""
SELECT
    d.work_date,
    d.is_weekend,
    f.state,
    f.ownership_group,
    sum(IF(x.hprd_eligible, x.total_nurse_hours, 0))  AS eligible_total_hours,
    sum(IF(x.hprd_eligible, x.rn_hours, 0))           AS eligible_rn_hours,
    sum(x.mds_census)                                 AS resident_days,
    sum(x.total_nurse_hours)                          AS total_nurse_hours,
    sum(x.contract_hours)                             AS contract_hours
FROM {MARTS}.fact_daily_staffing AS x
JOIN {MARTS}.dim_date AS d ON d.work_date = x.work_date
JOIN {MARTS}.dim_facility AS f ON f.provnum = x.provnum
GROUP BY 1, 2, 3, 4
"""


def run_query(sql: str, dtype: dict | None = None, parse_dates: list | None = None) -> pd.DataFrame:
    """Run a query in the dashboard workgroup and read the CSV result straight from S3."""
    athena = boto3.client("athena", region_name=REGION)
    query_id = athena.start_query_execution(QueryString=sql, WorkGroup=WORKGROUP)["QueryExecutionId"]
    while True:
        execution = athena.get_query_execution(QueryExecutionId=query_id)["QueryExecution"]
        state = execution["Status"]["State"]
        if state == "SUCCEEDED":
            break
        if state in ("FAILED", "CANCELLED"):
            raise RuntimeError(execution["Status"].get("StateChangeReason", state))
        time.sleep(1)

    bucket, key = execution["ResultConfiguration"]["OutputLocation"].removeprefix("s3://").split("/", 1)
    body = boto3.client("s3", region_name=REGION).get_object(Bucket=bucket, Key=key)["Body"].read()
    return pd.read_csv(io.BytesIO(body), dtype=dtype, parse_dates=parse_dates)


def load_facilities() -> pd.DataFrame:
    # keep provnum as text, otherwise 015009 loses its leading zero and 39A433 breaks
    return run_query(FACILITIES_SQL, dtype={"provnum": str})


def load_daily() -> pd.DataFrame:
    return run_query(DAILY_SQL, parse_dates=["work_date"])


def ratio(numerator: pd.Series | float, denominator: pd.Series | float):
    """Safe divide: NaN instead of a crash or inf when the denominator is 0."""
    if isinstance(denominator, pd.Series):
        return numerator / denominator.where(denominator != 0)
    return numerator / denominator if denominator else float("nan")


def add_facility_metrics(facilities: pd.DataFrame) -> pd.DataFrame:
    """Ratios per facility, used in the tables."""
    f = facilities.copy()
    f["total_hprd"] = ratio(f["eligible_total_hours"], f["resident_days"])
    f["rn_hprd"] = ratio(f["eligible_rn_hours"], f["resident_days"])
    f["contract_share"] = ratio(f["contract_hours"], f["total_nurse_hours"])
    f["below_total_rate"] = ratio(f["days_below_total"], f["days_with_residents"])
    f["avg_daily_census"] = ratio(f["resident_days"], f["days_reported"])
    f["occupancy"] = ratio(f["avg_daily_census"], f["certified_beds"])
    return f


def summarize(facilities: pd.DataFrame, daily: pd.DataFrame) -> dict:
    """Headline numbers for whatever is selected, rebuilt from the sums."""
    weekend = daily[daily["is_weekend"]]
    weekday = daily[~daily["is_weekend"]]
    return {
        "facilities": len(facilities),
        "resident_days": facilities["resident_days"].sum(),
        "total_nurse_hours": facilities["total_nurse_hours"].sum(),
        "total_hprd": ratio(facilities["eligible_total_hours"].sum(), facilities["resident_days"].sum()),
        "rn_hprd": ratio(facilities["eligible_rn_hours"].sum(), facilities["resident_days"].sum()),
        "contract_share": ratio(facilities["contract_hours"].sum(), facilities["total_nurse_hours"].sum()),
        "below_total_rate": ratio(facilities["days_below_total"].sum(), facilities["days_with_residents"].sum()),
        "below_rn_rate": ratio(facilities["days_below_rn"].sum(), facilities["days_with_residents"].sum()),
        "weekend_gap": ratio(weekend["eligible_total_hours"].sum(), weekend["resident_days"].sum())
        - ratio(weekday["eligible_total_hours"].sum(), weekday["resident_days"].sum()),
    }


def group_metrics(facilities: pd.DataFrame, by: str) -> pd.DataFrame:
    """HPRD, contract share and % of days below benchmark for each value of a column."""
    sums = facilities.groupby(by, dropna=False).agg(
        facilities=("provnum", "count"),
        resident_days=("resident_days", "sum"),
        eligible_total_hours=("eligible_total_hours", "sum"),
        eligible_rn_hours=("eligible_rn_hours", "sum"),
        total_nurse_hours=("total_nurse_hours", "sum"),
        contract_hours=("contract_hours", "sum"),
        days_below_total=("days_below_total", "sum"),
        days_with_residents=("days_with_residents", "sum"),
    )
    return pd.DataFrame({
        "facilities": sums["facilities"],
        "total_hprd": ratio(sums["eligible_total_hours"], sums["resident_days"]),
        "rn_hprd": ratio(sums["eligible_rn_hours"], sums["resident_days"]),
        "contract_share": ratio(sums["contract_hours"], sums["total_nurse_hours"]),
        "below_total_rate": ratio(sums["days_below_total"], sums["days_with_residents"]),
        "total_nurse_hours": sums["total_nurse_hours"],
    }).reset_index()
