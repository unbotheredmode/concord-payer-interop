-- =============================================================================
-- Model : stg_claims
-- Layer : STAGING
-- Source: CONCORD.RAW.CLAIMS (declared in sources.yml)
-- Output: CONCORD.STAGING.STG_CLAIMS (table, managed by dbt)
--
-- What this model does:
--   Extracts typed, named columns from the raw VARIANT blob.
--   One row in, one row out — no aggregation, no joining, no business logic.
--   STAGING models are deliberately dumb — just flatten and type.
--   All business logic (joins, aggregations, calculations) lives in MARTS.
--
-- Why dbt manages this instead of manual SQL:
--   1. dbt tests validate this output before marts ever read it
--   2. Lineage graph shows exactly what feeds this model
--   3. dbt run rebuilds this automatically in correct dependency order
--   4. Same SQL works in dev and prod — source() resolves per environment
-- =============================================================================

SELECT
    -- Business keys — cast explicitly, never leave as VARIANT
    -- Uncast VARIANT causes silent join failures downstream
    raw_data:claim_id::STRING                                       AS claim_id,
    raw_data:member_id::STRING                                      AS member_id,

    -- Dates use TRY_CAST — bad date returns NULL instead of crashing pipeline
    -- dbt not_null test on service_date catches NULLs after the fact
    TRY_CAST(raw_data:service_date::STRING AS DATE)                 AS service_date,

    -- Status and type — straight string extractions
    raw_data:status::STRING                                         AS status,
    raw_data:type::STRING                                           AS claim_type,
    raw_data:place_of_service::STRING                               AS place_of_service,

    -- Array indexing: [0] = first element, no FLATTEN needed for primary dx
    -- Full diagnosis array stays in RAW if multi-dx analysis is ever needed
    raw_data:diagnosis[0]:code::STRING                              AS primary_dx_code,

    -- Provider NPI only — name and specialty live in dim_provider (MARTS)
    -- Storing provider name here would duplicate it across 2000 claim rows
    raw_data:provider:npi::STRING                                   AS provider_npi,

    -- Financials: nested object navigation with colon (:)
    -- NUMBER(12,2) = up to 12 digits, 2 decimal places — covers any claim amount
    TRY_CAST(raw_data:financials:billed_amount::STRING  AS NUMBER(12,2)) AS billed_amount,
    TRY_CAST(raw_data:financials:allowed_amount::STRING AS NUMBER(12,2)) AS allowed_amount,
    TRY_CAST(raw_data:financials:paid_amount::STRING    AS NUMBER(12,2)) AS paid_amount,
    TRY_CAST(raw_data:financials:member_liability::STRING AS NUMBER(12,2)) AS member_liability,

    -- Boolean field — TRUE if this claim required prior authorization
    raw_data:requires_prior_auth::BOOLEAN                           AS requires_prior_auth,

    -- Pipeline metadata — carry forward for lineage and debugging
    source_file,
    loaded_at

FROM {{ source('raw', 'claims') }}

-- Only rows with valid business keys pass through
-- Rows failing this filter belong in the dead letter table (_INTERNAL.CLAIMS_ERRORS)
-- which our manual SQL already handles
WHERE raw_data:claim_id::STRING IS NOT NULL
  AND raw_data:member_id::STRING IS NOT NULL