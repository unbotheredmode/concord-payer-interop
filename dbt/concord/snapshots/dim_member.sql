{% snapshot dim_member %}

{{
    config(
        target_schema='MARTS',
        unique_key='member_id',
        strategy='check',
        check_cols=['plan_type', 'state', 'zip_code', 'pcp_npi', 'line_of_business'],
    )
}}

-- =============================================================================
-- Snapshot: dim_member
-- Layer   : MARTS
-- Source  : stg_patients
-- Output  : CONCORD.MARTS.DIM_MEMBER
--
-- Why a snapshot not a regular model:
--   Regular models do CREATE OR REPLACE — full rebuild, history lost.
--   Snapshots detect row changes and add new rows instead of overwriting.
--   This is how dbt implements SCD Type 2.
--
-- Strategy: check
--   On each dbt snapshot run, dbt compares check_cols against the last
--   stored version. If any column changed → close the old row (set dbt_valid_to)
--   and insert a new row. No change → nothing happens.
--
--   Two strategies exist:
--   - timestamp: uses an updated_at column to detect changes (faster)
--   - check: compares actual column values (what we use — no updated_at in source)
--
-- unique_key: member_id
--   The business key dbt uses to match incoming rows to existing snapshot rows.
--   One member can have multiple snapshot rows — one per plan change.
--
-- dbt adds automatically:
--   dbt_valid_from  — when this version became active
--   dbt_valid_to    — when it was superseded (NULL = current row)
--   dbt_updated_at  — when dbt last processed this row
--   dbt_scd_id      — unique hash per snapshot row
-- =============================================================================

SELECT
    member_id,
    dob,
    gender,
    state,
    zip_code,
    plan_type,
    enrollment_date,
    pcp_npi,
    line_of_business
FROM {{ ref('stg_patients') }}

{% endsnapshot %}