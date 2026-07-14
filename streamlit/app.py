# =============================================================================
# Concord — PA Compliance & Pipeline Observability Dashboard
# File   : streamlit/app.py
# Purpose: Streamlit-in-Snowflake dashboard showing PA metrics and pipeline health
#
# How Streamlit-in-Snowflake works:
#   - Runs INSIDE Snowflake — no external hosting, no credentials needed
#   - Gets Snowflake session via get_active_session() — already authenticated
#   - Queries your tables directly via session.sql()
#   - Deployed through Snowsight UI (Projects → Streamlit)
# =============================================================================

import streamlit as st
from snowflake.snowpark.context import get_active_session

# Get the active Snowflake session — no credentials needed inside Snowflake
session = get_active_session()

# Page config
st.set_page_config(
    page_title="Concord — PA Compliance Dashboard",
    page_icon="🏥",
    layout="wide"
)

st.title("🏥 Concord Payer Platform")
st.caption("Prior Authorization Compliance & Pipeline Observability")
st.divider()

# =============================================================================
# ROW 1: Pipeline health KPIs
# =============================================================================
st.subheader("Pipeline Health")

pipeline_df = session.sql("""
    SELECT step_name, source, rows_loaded, rows_rejected, status, run_ts
    FROM CONCORD._INTERNAL.PIPELINE_LOG
    ORDER BY run_ts DESC
    LIMIT 10
""").to_pandas()

col1, col2, col3, col4 = st.columns(4)

total_runs   = len(pipeline_df)
success_runs = len(pipeline_df[pipeline_df['STATUS'] == 'SUCCESS'])
total_loaded = pipeline_df['ROWS_LOADED'].sum()
total_rejected = pipeline_df['ROWS_REJECTED'].sum()

col1.metric("Pipeline Runs",     total_runs)
col2.metric("Successful Runs",   success_runs)
col3.metric("Total Rows Loaded", f"{int(total_loaded):,}")
col4.metric("Rows Rejected",     int(total_rejected))

st.dataframe(pipeline_df, use_container_width=True)
st.divider()

# =============================================================================
# ROW 2: PA Metrics by Line of Business
# =============================================================================
st.subheader("Prior Authorization Metrics by Line of Business")

pa_df = session.sql("""
    SELECT
        line_of_business,
        total_requests,
        approved_count,
        denied_count,
        pending_count,
        approval_rate_pct,
        denial_rate_pct,
        avg_decision_days,
        avg_approved_days,
        avg_denied_days,
        appeal_overturn_rate_pct,
        most_common_denial_reason
    FROM CONCORD.MARTS.PA_METRICS_MART
    ORDER BY total_requests DESC
""").to_pandas()

# KPI row
col1, col2, col3, col4 = st.columns(4)
col1.metric("Total PA Requests",  int(pa_df['TOTAL_REQUESTS'].sum()))
col2.metric("Total Approved",     int(pa_df['APPROVED_COUNT'].sum()))
col3.metric("Total Denied",       int(pa_df['DENIED_COUNT'].sum()))
col4.metric("Avg Decision Days",  round(pa_df['AVG_DECISION_DAYS'].mean(), 1))

# Bar chart — approval vs denial by LOB
st.bar_chart(
    pa_df.set_index('LINE_OF_BUSINESS')[['APPROVED_COUNT', 'DENIED_COUNT']],
    color=["#2dd4bf", "#fb7185"]
)

# Full metrics table
st.dataframe(pa_df, use_container_width=True)
st.divider()

# =============================================================================
# ROW 3: Claims Summary
# =============================================================================
st.subheader("Claims Summary")

claims_df = session.sql("""
    SELECT
        member_plan_type,
        COUNT(*)                        AS total_claims,
        ROUND(SUM(billed_amount), 2)    AS total_billed,
        ROUND(SUM(paid_amount), 2)      AS total_paid,
        ROUND(AVG(payment_rate_pct), 1) AS avg_payment_rate_pct
    FROM CONCORD.MARTS.FCT_CLAIMS
    WHERE member_plan_type IS NOT NULL
    GROUP BY member_plan_type
    ORDER BY total_claims DESC
""").to_pandas()

col1, col2, col3 = st.columns(3)
col1.metric("Total Claims",   f"{int(claims_df['TOTAL_CLAIMS'].sum()):,}")
col2.metric("Total Billed",   f"${claims_df['TOTAL_BILLED'].sum():,.0f}")
col3.metric("Total Paid",     f"${claims_df['TOTAL_PAID'].sum():,.0f}")

st.dataframe(claims_df, use_container_width=True)
st.divider()

st.caption(f"Concord Payer Platform · Built with Snowflake + dbt · Data refreshed via pipeline audit log")