"""Streamlit dashboard for the PBJ staffing data (Q2 2024). Run it with: streamlit run dashboard/app.py"""

import altair as alt
import pandas as pd
import streamlit as st

from data import (
    RN_BENCHMARK,
    TOTAL_BENCHMARK,
    add_facility_metrics,
    group_metrics,
    load_daily,
    load_facilities,
    ratio,
    summarize,
)

st.set_page_config(page_title="Nursing Home Staffing", layout="wide")

# Every chart has a single series, so one blue is enough (a slightly lighter one in dark mode).
DARK = st.context.theme.type == "dark"
SERIES = "#3987e5" if DARK else "#2a78d6"
REFERENCE = "#c3c2b7" if DARK else "#52514e"


@st.cache_data(ttl=24 * 3600, show_spinner="Loading staffing data from Athena…")
def get_data() -> tuple[pd.DataFrame, pd.DataFrame]:
    return add_facility_metrics(load_facilities()), load_daily()


def bar_chart(df: pd.DataFrame, category: str, value: str, value_title: str, value_format: str,
              horizontal: bool = False, benchmark: float | None = None, tooltip: list | None = None,
              axis_format: str | None = None, order: list | None = None):
    """Single-series bar chart with an optional dashed benchmark line.

    The benchmark is explained in the caption instead of labelled on the chart,
    because the label kept running into the bars.
    """
    value_axis = alt.X if horizontal else alt.Y
    category_axis = alt.Y if horizontal else alt.X
    bars = alt.Chart(df).mark_bar(color=SERIES, cornerRadiusEnd=4).encode(
        value_axis(f"{value}:Q", title=value_title,
                   axis=alt.Axis(format=axis_format or value_format, tickCount=8, grid=True)),
        category_axis(f"{category}:N", title=None, sort=order or ("-x" if horizontal else None),
                      scale=alt.Scale(paddingInner=0.35),
                      axis=alt.Axis(labelOverlap=False, labelAngle=0, labelLimit=200)),
        tooltip=tooltip or [category, alt.Tooltip(value, format=value_format)],
    )
    if benchmark is None:
        return bars
    line = alt.Chart(pd.DataFrame({"benchmark": [benchmark]})).mark_rule(
        color=REFERENCE, strokeDash=[4, 4], strokeWidth=1.5
    ).encode(value_axis("benchmark:Q"))
    return bars + line


facilities_all, daily_all = get_data()

st.title("Nursing home staffing")
st.caption(
    "CMS Payroll-Based Journal daily nurse staffing, Q2 2024 (Apr–Jun), 14,564 facilities. "
    "Facility attributes (ownership, beds, rehospitalisation) are as of October 2024. "
    f"Benchmarks: {TOTAL_BENCHMARK} total and {RN_BENCHMARK} RN hours per resident day, from the 2024 CMS "
    "minimum staffing rule, used as a reference only."
)

# ---------- Filters ----------
filter_state, filter_ownership = st.columns([3, 2])
states = filter_state.multiselect("States", sorted(facilities_all["state"].dropna().unique()),
                                  placeholder="All states")
ownership = filter_ownership.multiselect("Ownership", sorted(facilities_all["ownership_group"].unique()),
                                         placeholder="All ownership types")

facilities = facilities_all
daily = daily_all
if states:
    facilities = facilities[facilities["state"].isin(states)]
    daily = daily[daily["state"].isin(states)]
if ownership:
    facilities = facilities[facilities["ownership_group"].isin(ownership)]
    daily = daily[daily["ownership_group"].isin(ownership)]

if facilities.empty:
    st.warning("No facilities match these filters.")
    st.stop()

# ---------- Headline numbers ----------
s = summarize(facilities, daily)
row1 = st.columns(5)
row1[0].metric("Total nurse HPRD", f"{s['total_hprd']:.2f}", help="Nursing hours per resident day")
row1[1].metric("RN HPRD", f"{s['rn_hprd']:.2f}")
row1[2].metric("Contract-staff share", f"{s['contract_share']:.1%}", help="Share of nursing hours from contract staff")
row1[3].metric(f"Days below {TOTAL_BENCHMARK} total", f"{s['below_total_rate']:.1%}")
row1[4].metric(f"Days below {RN_BENCHMARK} RN", f"{s['below_rn_rate']:.1%}")
row2 = st.columns(5)
row2[0].metric("Facilities", f"{s['facilities']:,}")
row2[1].metric("Resident days", f"{s['resident_days'] / 1e6:.1f} M")
row2[2].metric("Nursing hours", f"{s['total_nurse_hours'] / 1e6:.1f} M")
row2[3].metric("Weekend vs weekday HPRD", f"{s['weekend_gap']:+.2f}", help="Weekend HPRD minus weekday HPRD")
row2[4].metric("Median occupancy", f"{facilities['occupancy'].median():.0%}",
               help="Average daily residents ÷ certified beds")

tab_time, tab_state, tab_ownership, tab_load, tab_facilities = st.tabs(
    ["Over time", "By state", "By ownership", "Patient load & outcomes", "Facilities"]
)

# ---------- Over time ----------
with tab_time:
    by_day = daily.groupby(["work_date", "is_weekend"], as_index=False)[
        ["eligible_total_hours", "resident_days"]].sum()
    by_day["total_hprd"] = ratio(by_day["eligible_total_hours"], by_day["resident_days"])
    st.subheader("Total nurse HPRD by day")
    base = alt.Chart(by_day).encode(
        alt.X("work_date:T", title=None, axis=alt.Axis(format="%d %b", tickCount="week")),
        alt.Y("total_hprd:Q", title="Total nurse HPRD", scale=alt.Scale(zero=False)),
        tooltip=[alt.Tooltip("work_date:T", title="Day", format="%a %d %b"),
                 alt.Tooltip("total_hprd:Q", title="HPRD", format=".2f")],
    )
    line = base.mark_line(color=SERIES, strokeWidth=2)
    weekend_points = base.transform_filter("datum.is_weekend").mark_point(
        color=SERIES, size=64, filled=True)
    benchmark = alt.Chart(pd.DataFrame({"benchmark": [TOTAL_BENCHMARK]}))
    benchmark_line = benchmark.mark_rule(color=REFERENCE, strokeDash=[4, 4]).encode(alt.Y("benchmark:Q"))
    benchmark_label = benchmark.mark_text(color=REFERENCE, align="left", dy=-4, baseline="bottom").encode(
        alt.Y("benchmark:Q"), x=alt.value(4), text=alt.value(f"benchmark {TOTAL_BENCHMARK}"))
    st.altair_chart(line + weekend_points + benchmark_line + benchmark_label, width="stretch")
    st.caption("Dots mark weekends: staffing drops below the benchmark every Saturday and Sunday.")

    by_month = daily.assign(month=daily["work_date"].dt.strftime("%Y-%m")).groupby("month").agg(
        nursing_hours=("total_nurse_hours", "sum"), contract_hours=("contract_hours", "sum"),
        eligible_total_hours=("eligible_total_hours", "sum"), resident_days=("resident_days", "sum"))
    by_month.index.name = "Month"
    st.subheader("By month")
    st.dataframe(pd.DataFrame({
        "Nursing hours": by_month["nursing_hours"].round(),
        "Resident days": by_month["resident_days"],
        "Total HPRD": ratio(by_month["eligible_total_hours"], by_month["resident_days"]),
        "Contract share": ratio(by_month["contract_hours"], by_month["nursing_hours"]),
    }), column_config={
        "Nursing hours": st.column_config.NumberColumn(format="localized"),
        "Resident days": st.column_config.NumberColumn(format="localized"),
        "Total HPRD": st.column_config.NumberColumn(format="%.2f"),
        "Contract share": st.column_config.NumberColumn(format="percent"),
    })

# ---------- By state ----------
with tab_state:
    by_state = group_metrics(facilities, "state")
    st.subheader("Total nurse HPRD by state")
    st.altair_chart(
        bar_chart(by_state, "state", "total_hprd", "Total nurse HPRD", ".2f", horizontal=True,
                  benchmark=TOTAL_BENCHMARK,
                  tooltip=["state", alt.Tooltip("total_hprd", title="HPRD", format=".2f"),
                           alt.Tooltip("contract_share", title="Contract share", format=".1%"),
                           alt.Tooltip("facilities", title="Facilities")],
                  axis_format=".1f").properties(height=max(300, 20 * len(by_state))),
        width="stretch",
    )
    st.caption(f"Dashed line: the {TOTAL_BENCHMARK} HPRD benchmark. Hover a bar for contract share and facility count.")
    with st.expander("Table view"):
        st.dataframe(by_state.sort_values("total_hprd"), hide_index=True, column_config={
            "total_hprd": st.column_config.NumberColumn("Total HPRD", format="%.2f"),
            "rn_hprd": st.column_config.NumberColumn("RN HPRD", format="%.2f"),
            "contract_share": st.column_config.NumberColumn("Contract share", format="percent"),
            "below_total_rate": st.column_config.NumberColumn(f"Days below {TOTAL_BENCHMARK}", format="percent"),
            "total_nurse_hours": st.column_config.NumberColumn("Nursing hours", format="localized", step=1),
        })

# ---------- By ownership ----------
with tab_ownership:
    by_owner = group_metrics(facilities, "ownership_group")
    left, right = st.columns(2)
    with left:
        st.subheader("Total nurse HPRD")
        st.altair_chart(bar_chart(by_owner, "ownership_group", "total_hprd", "Total nurse HPRD", ".2f",
                                  benchmark=TOTAL_BENCHMARK, axis_format=".1f"), width="stretch")
        st.caption(f"Dashed line: the {TOTAL_BENCHMARK} HPRD benchmark.")
    with right:
        st.subheader(f"Days below {TOTAL_BENCHMARK} HPRD")
        st.altair_chart(bar_chart(by_owner, "ownership_group", "below_total_rate", "Share of days", ".0%"),
                        width="stretch")
    st.subheader("Contract-staff share")
    st.altair_chart(bar_chart(by_owner, "ownership_group", "contract_share", "Share of nursing hours", ".1%",
                              horizontal=True).properties(height=180), width="stretch")
    st.caption("“Unknown” is the 17 facilities that report staffing but are missing from the October 2024 "
               "provider file.")

# ---------- Patient load & outcomes ----------
with tab_load:
    left, right = st.columns(2)
    with left:
        st.subheader("Staffing by occupancy")
        band_labels = ["Under 60%", "60–75%", "75–90%", "90–100%", "Over 100%*"]
        with_beds = facilities.dropna(subset=["occupancy"])
        bands = pd.cut(with_beds["occupancy"], [0, 0.6, 0.75, 0.9, 1.0, float("inf")], labels=band_labels)
        by_band = group_metrics(with_beds.assign(occupancy_band=bands.astype(str)), "occupancy_band")
        st.altair_chart(bar_chart(by_band, "occupancy_band", "total_hprd", "Total nurse HPRD", ".2f",
                                  benchmark=TOTAL_BENCHMARK,
                                  tooltip=["occupancy_band",
                                           alt.Tooltip("total_hprd", title="HPRD", format=".2f"),
                                           alt.Tooltip("facilities", title="Facilities")],
                                  axis_format=".1f", order=band_labels),
                        width="stretch")
        st.caption(f"Dashed line: the {TOTAL_BENCHMARK} HPRD benchmark. *Census from Q2 2024 against beds counted in October 2024: a facility that reduced its "
                   "beds can show more than 100%.")
    with right:
        st.subheader("Rehospitalisation by staffing level")
        rated = facilities.dropna(subset=["total_hprd", "short_stay_rehospitalisation_pct"])
        rated = rated.assign(hprd_quartile=pd.qcut(rated["total_hprd"], 4,
                                                   labels=["Lowest 25%", "Second", "Third", "Highest 25%"]))
        by_quartile = rated.groupby("hprd_quartile", observed=True).agg(
            rehospitalisation=("short_stay_rehospitalisation_pct", "mean"),
            facilities=("provnum", "count")).reset_index()
        by_quartile["rehospitalisation"] = by_quartile["rehospitalisation"] / 100
        st.altair_chart(bar_chart(by_quartile, "hprd_quartile", "rehospitalisation",
                                  "Short-stay residents rehospitalised", ".1%",
                                  tooltip=["hprd_quartile",
                                           alt.Tooltip("rehospitalisation", title="Rehospitalised", format=".1%"),
                                           alt.Tooltip("facilities", title="Facilities")]),
                        width="stretch")
        corr = rated["total_hprd"].corr(rated["short_stay_rehospitalisation_pct"])
        st.caption(f"Facilities grouped by total HPRD. Correlation between HPRD and the rehospitalisation "
                   f"rate: {corr:.2f}. CMS measure 521, risk-adjusted; {len(rated):,} facilities with a "
                   "published score. Correlation, not causation.")

# ---------- Facilities ----------
with tab_facilities:
    columns = {
        "provider_name": st.column_config.TextColumn("Facility"),
        "city": st.column_config.TextColumn("City"),
        "state": st.column_config.TextColumn("State"),
        "ownership_group": st.column_config.TextColumn("Ownership"),
        "avg_daily_census": st.column_config.NumberColumn("Avg residents", format="%.0f"),
        "certified_beds": st.column_config.NumberColumn("Beds", format="%d"),
        "occupancy": st.column_config.NumberColumn("Occupancy", format="%.0f%%"),
        "total_hprd": st.column_config.NumberColumn("Total HPRD", format="%.2f"),
        "rn_hprd": st.column_config.NumberColumn("RN HPRD", format="%.2f"),
        "below_total_rate": st.column_config.NumberColumn(f"Days below {TOTAL_BENCHMARK}", format="%.0f%%"),
        "contract_share": st.column_config.NumberColumn("Contract share", format="%.0f%%"),
        "short_stay_rehospitalisation_pct": st.column_config.NumberColumn("Rehospitalised %", format="%.1f"),
        "resident_days": st.column_config.NumberColumn("Resident days", format="localized"),
    }
    shown = list(columns)

    def for_display(df: pd.DataFrame) -> pd.DataFrame:
        """Show shares as whole percents (0.88 -> 88) so all the % columns look the same."""
        shares = ["occupancy", "below_total_rate", "contract_share"]
        return df[shown].assign(**{c: df[c] * 100 for c in shares})

    st.subheader("Lowest staffing for their patient load")
    st.caption("Facilities with at least 30 days of residents and an average of 20 or more, ranked by total HPRD. "
               "Values far below 1 HPRD more likely reflect incomplete payroll submissions than actual staffing.")
    lowest = facilities[(facilities["days_with_residents"] >= 30) & (facilities["avg_daily_census"] >= 20)]
    st.dataframe(for_display(lowest.nsmallest(25, "total_hprd")), hide_index=True, column_config=columns)

    st.subheader("Top 10 by patient throughput")
    st.caption("Ranked by resident days in the quarter.")
    st.dataframe(for_display(facilities.nlargest(10, "resident_days")), hide_index=True, column_config=columns)

    st.subheader("All facilities")
    st.caption("Use the table's search and column sorting to find a facility.")
    st.dataframe(for_display(facilities), hide_index=True, column_config=columns)
