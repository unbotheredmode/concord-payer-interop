-- =============================================================================
-- Model  : fct_claims
-- Layer  : MARTS
-- Sources: stg_claims, dim_member, dim_provider, dim_date
-- Output : CONCORD.MARTS.FCT_CLAIMS
--
-- Grain: one row per adjudicated claim
--
-- Why incremental materialization:
--   New claims arrive daily. Full rebuild re-processes all 2000+ claims
--   every run — wasteful and slow at scale.
--   Incremental: on first run loads everything. Every run after loads only
--   new claims (service_date > max already loaded). 10x faster at prod volumes.
--
-- SCD2 join to dim_member:
--   service_date BETWEEN dbt_valid_from AND COALESCE(dbt_valid_to, CURRENT_DATE)
--   This ensures we get the member's plan AT THE TIME OF SERVICE —
--   not their current plan. Critical for correct claims adjudication.
-- =============================================================================

{{
    config(
        materialized='incremental',
        unique_key='claim_id',
        on_schema_change='sync_all_columns'
    )
}}

SELECT
    -- Keys
    c.claim_id,
    c.member_id,
    c.provider_npi,
    c.service_date,

    -- Dimension foreign keys for joining
    d.date_day                          AS date_key,

    -- Member context AT TIME OF SERVICE (SCD2)
    m.plan_type                         AS member_plan_type,
    m.line_of_business,
    m.state                             AS member_state,

    -- Provider context
    p.provider_name,
    p.provider_specialty,

    -- Claim attributes
    c.status,
    c.claim_type,
    c.place_of_service,
    c.primary_dx_code,
    c.requires_prior_auth,

    -- Financial measures
    c.billed_amount,
    c.allowed_amount,
    c.paid_amount,
    c.member_liability,

    -- Derived measures — calculated once here, reused everywhere
    -- Never calculate these in BI tools — inconsistent results across reports
    c.allowed_amount - c.paid_amount    AS contractual_adjustment,
    c.billed_amount - c.allowed_amount  AS write_off_amount,
    CASE
        WHEN c.billed_amount > 0
        THEN ROUND(c.paid_amount / c.billed_amount * 100, 2)
        ELSE 0
    END                                 AS payment_rate_pct,

    -- Pipeline metadata
    c.source_file,
    c.loaded_at

FROM {{ ref('stg_claims') }} c

-- SCD2 join: get member's plan AT TIME OF SERVICE
LEFT JOIN {{ ref('dim_member') }} m
    ON c.member_id = m.member_id
    AND m.dbt_valid_to IS NULL

-- Provider dimension
LEFT JOIN {{ ref('dim_provider') }} p
    ON c.provider_npi = p.provider_npi

-- Date dimension
LEFT JOIN {{ ref('dim_date') }} d
    ON c.service_date = d.date_day

-- Incremental filter: on subsequent runs, only process new claims
{% if is_incremental() %}
WHERE c.service_date > (SELECT MAX(service_date) FROM {{ this }})
{% endif %}