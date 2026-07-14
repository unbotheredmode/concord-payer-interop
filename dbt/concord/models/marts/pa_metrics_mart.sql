-- =============================================================================
-- Model  : pa_metrics_mart
-- Layer  : MARTS
-- Source : stg_prior_auth
-- Output : CONCORD.MARTS.PA_METRICS_MART
--
-- Grain: one row per line_of_business + status combination
--
-- Why pre-aggregate here instead of in the BI tool:
--   Every dashboard, every report, every stakeholder asks the same questions.
--   If each BI query recomputes these aggregations, you get:
--   1. Inconsistent numbers across reports (different filters applied)
--   2. Slow dashboards (scanning 400 PA records every page load)
--   3. No single source of truth for what "approval rate" means
--   Pre-aggregating here = one definition, one number, consistent everywhere.
--
-- This mart computes exactly the metrics payer ops teams monitor daily
-- and that regulators require payers to publicly report.
-- =============================================================================

WITH pa_base AS (
    SELECT
        pa_id,
        pa.member_id,
        procedure_code,
        submitted_date,
        decision_date,
        decision_days,
        status,
        denial_reason,
        appeal_outcome,
        urgency,
        -- Join to stg_patients to get line of business
        -- We do this here not in staging — mart models can join across staging tables
        p.line_of_business
    FROM {{ ref('stg_prior_auth') }} pa
    LEFT JOIN {{ ref('stg_patients') }} p
        ON pa.member_id = p.member_id
),

-- Summary by line of business
summary_by_lob AS (
    SELECT
        COALESCE(line_of_business, 'Unknown')       AS line_of_business,

        -- Volume
        COUNT(*)                                     AS total_requests,
        COUNT(CASE WHEN status = 'approved'  THEN 1 END) AS approved_count,
        COUNT(CASE WHEN status = 'denied'    THEN 1 END) AS denied_count,
        COUNT(CASE WHEN status = 'pending'   THEN 1 END) AS pending_count,
        COUNT(CASE WHEN status = 'appealed'  THEN 1 END) AS appealed_count,

        -- Rates (rounded to 1 decimal)
        ROUND(COUNT(CASE WHEN status = 'approved' THEN 1 END) * 100.0
              / NULLIF(COUNT(*), 0), 1)              AS approval_rate_pct,
        ROUND(COUNT(CASE WHEN status = 'denied' THEN 1 END) * 100.0
              / NULLIF(COUNT(*), 0), 1)              AS denial_rate_pct,

        -- Turnaround time (only decided requests have decision_days)
        ROUND(AVG(CASE WHEN status IN ('approved','denied','appealed')
                  THEN decision_days END), 1)        AS avg_decision_days,
        ROUND(AVG(CASE WHEN status = 'approved'
                  THEN decision_days END), 1)        AS avg_approved_days,
        ROUND(AVG(CASE WHEN status = 'denied'
                  THEN decision_days END), 1)        AS avg_denied_days,

        -- Appeal overturn rate
        -- How many denials were reversed on appeal — key quality metric
        COUNT(CASE WHEN appeal_outcome = 'overturned' THEN 1 END)
                                                     AS appeals_overturned,
        ROUND(COUNT(CASE WHEN appeal_outcome = 'overturned' THEN 1 END) * 100.0
              / NULLIF(COUNT(CASE WHEN status = 'appealed' THEN 1 END), 0), 1)
                                                     AS appeal_overturn_rate_pct,

        -- Urgency breakdown
        COUNT(CASE WHEN urgency = 'urgent'   THEN 1 END) AS urgent_count,
        COUNT(CASE WHEN urgency = 'emergent' THEN 1 END) AS emergent_count,
        COUNT(CASE WHEN urgency = 'routine'  THEN 1 END) AS routine_count,

        -- Most common denial reason per LOB
        MODE(denial_reason)                          AS most_common_denial_reason,

        -- Freshness
        MAX(submitted_date)                          AS latest_submitted_date,
        CURRENT_TIMESTAMP()                          AS mart_refreshed_at

    FROM pa_base
    GROUP BY line_of_business
)

SELECT * FROM summary_by_lob
ORDER BY total_requests DESC