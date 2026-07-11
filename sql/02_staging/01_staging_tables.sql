-- =============================================================================
-- Concord: Payer Interoperability & Prior Authorization Data Platform
-- File   : sql/02_staging/01_staging_tables.sql
-- Purpose: STAGING layer — flatten VARIANT blobs into typed, conformed tables.
--          Uses MERGE (upsert) to prevent duplicates on reruns.
--          Dead letter tables capture rejected rows with rejection reasons.
-- Run    : After 01_raw/01_raw_tables.sql is complete and verified.
-- =============================================================================

USE ROLE CONCORD_ENGINEER;
USE DATABASE CONCORD;
USE WAREHOUSE CONCORD_TRANSFORM_WH;  -- transforms go on TRANSFORM warehouse
USE SCHEMA STAGING;


-- =============================================================================
-- SECTION 1: DEAD LETTER / ERROR TABLES (in _INTERNAL schema)
-- Why: TRY_CAST returns NULL on bad values instead of crashing the pipeline.
--      But NULL on a business key (claim_id, member_id) = unusable row.
--      Dead letter tables capture these with:
--        - original raw_data blob (preserve source record exactly as received)
--        - rejection_reason (what failed — human-readable)
--        - source_file (which upstream file the bad row came from)
--        - rejected_at (when it was caught)
--
--      PIPELINE_LOG tells you HOW MANY rows failed.
--      Error tables tell you WHICH rows and WHY.
--
-- Prod parallel: Every mature data platform has dead letter tables.
--   Without them, "50 rows rejected" requires manually scanning source files.
--   With them, SELECT * FROM CLAIMS_ERRORS gives the exact rows + reasons.
-- =============================================================================

CREATE TABLE IF NOT EXISTS _INTERNAL.CLAIMS_ERRORS (
    raw_data         VARIANT,
    source_file      VARCHAR(500),
    rejection_reason VARCHAR(1000),
    rejected_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS _INTERNAL.PATIENTS_ERRORS (
    raw_data         VARIANT,
    source_file      VARCHAR(500),
    rejection_reason VARCHAR(1000),
    rejected_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS _INTERNAL.COVERAGE_ERRORS (
    raw_data         VARIANT,
    source_file      VARCHAR(500),
    rejection_reason VARCHAR(1000),
    rejected_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS _INTERNAL.PRIOR_AUTH_ERRORS (
    raw_data         VARIANT,
    source_file      VARCHAR(500),
    rejection_reason VARCHAR(1000),
    rejected_at      TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);


-- =============================================================================
-- SECTION 2: STAGING TABLES
-- Why tables not views:
--   Views re-run LATERAL FLATTEN on every downstream query.
--   With 2000 claims and multiple dbt models, that's the same expensive
--   flatten running dozens of times per dbt run. Tables: flatten once,
--   result stored, everything downstream is fast. dbt manages refresh.
--
-- Why MERGE not INSERT:
--   INSERT appends every run — duplicates guaranteed on reruns.
--   TRUNCATE+INSERT creates an empty-table window — dashboards break.
--   MERGE on business key: update if exists, insert if new.
--   Handles reprocessed/adjusted claims correctly. No duplicates, no downtime.
--
-- TRY_CAST everywhere:
--   CAST crashes on bad values. TRY_CAST returns NULL — pipeline continues.
--   Bad rows get caught by rejection filters below or dbt tests downstream.
-- =============================================================================

CREATE TABLE IF NOT EXISTS STAGING.STG_CLAIMS (
    claim_id            VARCHAR(50),
    member_id           VARCHAR(50),
    service_date        DATE,
    status              VARCHAR(50),
    claim_type          VARCHAR(50),
    place_of_service    VARCHAR(10),
    primary_dx_code     VARCHAR(20),   -- display name in dim_diagnosis (MARTS)
    provider_npi        VARCHAR(20),   -- name/specialty in dim_provider (MARTS)
    billed_amount       NUMBER(12,2),
    allowed_amount      NUMBER(12,2),
    paid_amount         NUMBER(12,2),
    member_liability    NUMBER(12,2),
    requires_prior_auth BOOLEAN,
    source_file         VARCHAR(500),
    loaded_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS STAGING.STG_PATIENTS (
    member_id           VARCHAR(50),
    dob                 DATE,
    gender              VARCHAR(20),
    state               VARCHAR(5),
    zip_code            VARCHAR(20),
    plan_type           VARCHAR(100),
    enrollment_date     DATE,
    pcp_npi             VARCHAR(20),
    line_of_business    VARCHAR(50),
    source_file         VARCHAR(500),
    loaded_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS STAGING.STG_COVERAGE (
    member_id           VARCHAR(50),
    subscriber_id       VARCHAR(50),
    plan_id             VARCHAR(50),
    plan_name           VARCHAR(200),
    plan_type           VARCHAR(100),
    group_id            VARCHAR(50),
    coverage_start      DATE,
    coverage_end        DATE,
    payor               VARCHAR(200),
    line_of_business    VARCHAR(50),
    status              VARCHAR(20),
    source_file         VARCHAR(500),
    loaded_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE TABLE IF NOT EXISTS STAGING.STG_PRIOR_AUTH (
    pa_id               VARCHAR(50),
    member_id           VARCHAR(50),
    requesting_npi      VARCHAR(20),
    procedure_code      VARCHAR(20),
    diagnosis_code      VARCHAR(20),
    submitted_date      DATE,
    decision_date       DATE,
    decision_days       NUMBER(5),
    status              VARCHAR(20),
    denial_reason       VARCHAR(500),
    appeal_outcome      VARCHAR(50),
    urgency             VARCHAR(20),
    source_file         VARCHAR(500),
    loaded_at           TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);


-- =============================================================================
-- SECTION 3: MERGE TRANSFORMS (RAW → STAGING)
-- Pattern per table:
--   Step 1: MERGE clean rows into STG_ table (upsert on business key)
--   Step 2: INSERT rejected rows into _INTERNAL.*_ERRORS (with reason)
--
-- Key VARIANT extraction syntax:
--   raw_data:field::STRING          → top-level field, cast to STRING
--   raw_data:nested:field::STRING   → nested object navigation with :
--   raw_data:array[0]:field::STRING → array index [0] = first element
--   TRY_CAST(... AS DATE)           → returns NULL on bad date, not an error
-- =============================================================================

-- ── MERGE STG_CLAIMS ─────────────────────────────────────────────────────────
MERGE INTO STAGING.STG_CLAIMS AS target
USING (
    SELECT
        raw_data:claim_id::STRING                                     AS claim_id,
        raw_data:member_id::STRING                                    AS member_id,
        TRY_CAST(raw_data:service_date::STRING AS DATE)               AS service_date,
        raw_data:status::STRING                                       AS status,
        raw_data:type::STRING                                         AS claim_type,
        raw_data:place_of_service::STRING                             AS place_of_service,
        raw_data:diagnosis[0]:code::STRING                            AS primary_dx_code,
        raw_data:provider:npi::STRING                                 AS provider_npi,
        TRY_CAST(raw_data:financials:billed_amount::STRING   AS NUMBER(12,2)) AS billed_amount,
        TRY_CAST(raw_data:financials:allowed_amount::STRING  AS NUMBER(12,2)) AS allowed_amount,
        TRY_CAST(raw_data:financials:paid_amount::STRING     AS NUMBER(12,2)) AS paid_amount,
        TRY_CAST(raw_data:financials:member_liability::STRING AS NUMBER(12,2)) AS member_liability,
        raw_data:requires_prior_auth::BOOLEAN                         AS requires_prior_auth,
        source_file,
        loaded_at
    FROM RAW.CLAIMS
    WHERE raw_data:claim_id::STRING IS NOT NULL
      AND raw_data:member_id::STRING IS NOT NULL
) AS source
ON target.claim_id = source.claim_id
WHEN MATCHED THEN UPDATE SET
    member_id           = source.member_id,
    service_date        = source.service_date,
    status              = source.status,
    claim_type          = source.claim_type,
    place_of_service    = source.place_of_service,
    primary_dx_code     = source.primary_dx_code,
    provider_npi        = source.provider_npi,
    billed_amount       = source.billed_amount,
    allowed_amount      = source.allowed_amount,
    paid_amount         = source.paid_amount,
    member_liability    = source.member_liability,
    requires_prior_auth = source.requires_prior_auth,
    source_file         = source.source_file
WHEN NOT MATCHED THEN INSERT
    (claim_id, member_id, service_date, status, claim_type,
     place_of_service, primary_dx_code, provider_npi,
     billed_amount, allowed_amount, paid_amount, member_liability,
     requires_prior_auth, source_file, loaded_at)
VALUES
    (source.claim_id, source.member_id, source.service_date, source.status,
     source.claim_type, source.place_of_service, source.primary_dx_code,
     source.provider_npi, source.billed_amount, source.allowed_amount,
     source.paid_amount, source.member_liability, source.requires_prior_auth,
     source.source_file, source.loaded_at);

-- Capture rejected claims
INSERT INTO _INTERNAL.CLAIMS_ERRORS (raw_data, source_file, rejection_reason)
SELECT
    raw_data,
    source_file,
    CASE
        WHEN raw_data:claim_id::STRING IS NULL AND raw_data:member_id::STRING IS NULL
            THEN 'null claim_id and member_id'
        WHEN raw_data:claim_id::STRING IS NULL  THEN 'null claim_id'
        WHEN raw_data:member_id::STRING IS NULL THEN 'null member_id'
    END
FROM RAW.CLAIMS
WHERE raw_data:claim_id::STRING IS NULL
   OR raw_data:member_id::STRING IS NULL;


-- ── MERGE STG_PATIENTS ───────────────────────────────────────────────────────
MERGE INTO STAGING.STG_PATIENTS AS target
USING (
    SELECT
        raw_data:member_id::STRING                                        AS member_id,
        TRY_CAST(raw_data:birthDate::STRING AS DATE)                      AS dob,
        raw_data:gender::STRING                                           AS gender,
        raw_data:address[0]:state::STRING                                 AS state,
        raw_data:address[0]:postalCode::STRING                            AS zip_code,
        raw_data:enrollment:plan_type::STRING                             AS plan_type,
        TRY_CAST(raw_data:enrollment:enrollment_date::STRING AS DATE)     AS enrollment_date,
        raw_data:enrollment:pcp_npi::STRING                               AS pcp_npi,
        raw_data:enrollment:line_of_business::STRING                      AS line_of_business,
        source_file,
        loaded_at
    FROM RAW.PATIENTS
    WHERE raw_data:member_id::STRING IS NOT NULL
) AS source
ON target.member_id = source.member_id
WHEN MATCHED THEN UPDATE SET
    dob              = source.dob,
    gender           = source.gender,
    state            = source.state,
    zip_code         = source.zip_code,
    plan_type        = source.plan_type,
    enrollment_date  = source.enrollment_date,
    pcp_npi          = source.pcp_npi,
    line_of_business = source.line_of_business,
    source_file      = source.source_file
WHEN NOT MATCHED THEN INSERT
    (member_id, dob, gender, state, zip_code, plan_type,
     enrollment_date, pcp_npi, line_of_business, source_file, loaded_at)
VALUES
    (source.member_id, source.dob, source.gender, source.state,
     source.zip_code, source.plan_type, source.enrollment_date,
     source.pcp_npi, source.line_of_business, source.source_file, source.loaded_at);

-- Capture rejected patients
INSERT INTO _INTERNAL.PATIENTS_ERRORS (raw_data, source_file, rejection_reason)
SELECT raw_data, source_file, 'null member_id'
FROM RAW.PATIENTS
WHERE raw_data:member_id::STRING IS NULL;


-- ── MERGE STG_COVERAGE ───────────────────────────────────────────────────────
MERGE INTO STAGING.STG_COVERAGE AS target
USING (
    SELECT
        raw_data:member_id::STRING                              AS member_id,
        raw_data:subscriber_id::STRING                         AS subscriber_id,
        raw_data:plan:plan_id::STRING                          AS plan_id,
        raw_data:plan:plan_name::STRING                        AS plan_name,
        raw_data:plan:plan_type::STRING                        AS plan_type,
        raw_data:plan:group_id::STRING                         AS group_id,
        TRY_CAST(raw_data:period:start::STRING AS DATE)        AS coverage_start,
        TRY_CAST(raw_data:period:end::STRING AS DATE)          AS coverage_end,
        raw_data:payor::STRING                                 AS payor,
        raw_data:line_of_business::STRING                      AS line_of_business,
        raw_data:status::STRING                                AS status,
        source_file,
        loaded_at
    FROM RAW.COVERAGE
    WHERE raw_data:member_id::STRING IS NOT NULL
) AS source
ON target.member_id = source.member_id
WHEN MATCHED THEN UPDATE SET
    subscriber_id    = source.subscriber_id,
    plan_id          = source.plan_id,
    plan_name        = source.plan_name,
    plan_type        = source.plan_type,
    group_id         = source.group_id,
    coverage_start   = source.coverage_start,
    coverage_end     = source.coverage_end,
    payor            = source.payor,
    line_of_business = source.line_of_business,
    status           = source.status,
    source_file      = source.source_file
WHEN NOT MATCHED THEN INSERT
    (member_id, subscriber_id, plan_id, plan_name, plan_type, group_id,
     coverage_start, coverage_end, payor, line_of_business, status,
     source_file, loaded_at)
VALUES
    (source.member_id, source.subscriber_id, source.plan_id, source.plan_name,
     source.plan_type, source.group_id, source.coverage_start, source.coverage_end,
     source.payor, source.line_of_business, source.status,
     source.source_file, source.loaded_at);

-- Capture rejected coverage
INSERT INTO _INTERNAL.COVERAGE_ERRORS (raw_data, source_file, rejection_reason)
SELECT raw_data, source_file, 'null member_id'
FROM RAW.COVERAGE
WHERE raw_data:member_id::STRING IS NULL;


-- ── MERGE STG_PRIOR_AUTH ─────────────────────────────────────────────────────
MERGE INTO STAGING.STG_PRIOR_AUTH AS target
USING (
    SELECT
        raw_data:pa_id::STRING                                  AS pa_id,
        raw_data:member_id::STRING                              AS member_id,
        raw_data:requesting_npi::STRING                        AS requesting_npi,
        raw_data:procedure:code::STRING                        AS procedure_code,
        raw_data:diagnosis_code::STRING                        AS diagnosis_code,
        TRY_CAST(raw_data:submitted_date::STRING AS DATE)      AS submitted_date,
        TRY_CAST(raw_data:decision_date::STRING AS DATE)       AS decision_date,
        TRY_CAST(raw_data:decision_days::STRING AS NUMBER(5))  AS decision_days,
        raw_data:status::STRING                                AS status,
        raw_data:denial_reason::STRING                         AS denial_reason,
        raw_data:appeal_outcome::STRING                        AS appeal_outcome,
        raw_data:urgency::STRING                               AS urgency,
        source_file,
        loaded_at
    FROM RAW.PRIOR_AUTH
    WHERE raw_data:pa_id::STRING IS NOT NULL
      AND raw_data:member_id::STRING IS NOT NULL
) AS source
ON target.pa_id = source.pa_id
WHEN MATCHED THEN UPDATE SET
    member_id      = source.member_id,
    status         = source.status,
    decision_date  = source.decision_date,
    decision_days  = source.decision_days,
    denial_reason  = source.denial_reason,
    appeal_outcome = source.appeal_outcome,
    source_file    = source.source_file
WHEN NOT MATCHED THEN INSERT
    (pa_id, member_id, requesting_npi, procedure_code, diagnosis_code,
     submitted_date, decision_date, decision_days, status, denial_reason,
     appeal_outcome, urgency, source_file, loaded_at)
VALUES
    (source.pa_id, source.member_id, source.requesting_npi, source.procedure_code,
     source.diagnosis_code, source.submitted_date, source.decision_date,
     source.decision_days, source.status, source.denial_reason,
     source.appeal_outcome, source.urgency, source.source_file, source.loaded_at);

-- Capture rejected prior auth
INSERT INTO _INTERNAL.PRIOR_AUTH_ERRORS (raw_data, source_file, rejection_reason)
SELECT raw_data, source_file,
    CASE
        WHEN raw_data:pa_id::STRING IS NULL AND raw_data:member_id::STRING IS NULL
            THEN 'null pa_id and member_id'
        WHEN raw_data:pa_id::STRING IS NULL     THEN 'null pa_id'
        WHEN raw_data:member_id::STRING IS NULL THEN 'null member_id'
    END
FROM RAW.PRIOR_AUTH
WHERE raw_data:pa_id::STRING IS NULL
   OR raw_data:member_id::STRING IS NULL;


-- =============================================================================
-- SECTION 4: PIPELINE LOG
-- =============================================================================

INSERT INTO CONCORD._INTERNAL.PIPELINE_LOG
    (step_name, source, rows_loaded, rows_rejected, status, message)
SELECT
    'staging.load_all',
    'raw_layer',
    (SELECT COUNT(*) FROM STAGING.STG_CLAIMS) +
    (SELECT COUNT(*) FROM STAGING.STG_PATIENTS) +
    (SELECT COUNT(*) FROM STAGING.STG_COVERAGE) +
    (SELECT COUNT(*) FROM STAGING.STG_PRIOR_AUTH),
    (SELECT COUNT(*) FROM _INTERNAL.CLAIMS_ERRORS) +
    (SELECT COUNT(*) FROM _INTERNAL.PATIENTS_ERRORS) +
    (SELECT COUNT(*) FROM _INTERNAL.COVERAGE_ERRORS) +
    (SELECT COUNT(*) FROM _INTERNAL.PRIOR_AUTH_ERRORS),
    'SUCCESS',
    'STAGING load complete: STG_CLAIMS, STG_PATIENTS, STG_COVERAGE, STG_PRIOR_AUTH';


-- =============================================================================
-- VERIFICATION
-- =============================================================================

-- Row counts: expect 2000, 500, 500, 400
SELECT 'STG_CLAIMS'     AS table_name, COUNT(*) AS row_count FROM STAGING.STG_CLAIMS      UNION ALL
SELECT 'STG_PATIENTS'   AS table_name, COUNT(*) AS row_count FROM STAGING.STG_PATIENTS    UNION ALL
SELECT 'STG_COVERAGE'   AS table_name, COUNT(*) AS row_count FROM STAGING.STG_COVERAGE    UNION ALL
SELECT 'STG_PRIOR_AUTH' AS table_name, COUNT(*) AS row_count FROM STAGING.STG_PRIOR_AUTH;

-- Error tables: expect 0 (synthetic data is clean)
SELECT 'CLAIMS_ERRORS'     AS table_name, COUNT(*) AS rejected_count FROM _INTERNAL.CLAIMS_ERRORS     UNION ALL
SELECT 'PATIENTS_ERRORS'   AS table_name, COUNT(*) AS rejected_count FROM _INTERNAL.PATIENTS_ERRORS   UNION ALL
SELECT 'COVERAGE_ERRORS'   AS table_name, COUNT(*) AS rejected_count FROM _INTERNAL.COVERAGE_ERRORS   UNION ALL
SELECT 'PRIOR_AUTH_ERRORS' AS table_name, COUNT(*) AS rejected_count FROM _INTERNAL.PRIOR_AUTH_ERRORS;

-- Spot check: confirm properly typed columns (not VARIANT)
SELECT claim_id, member_id, service_date, primary_dx_code,
       provider_npi, billed_amount, paid_amount, requires_prior_auth
FROM STAGING.STG_CLAIMS LIMIT 5;

-- Prior auth: pending rows should have NULL decision_date
SELECT pa_id, status, submitted_date, decision_date, decision_days, denial_reason
FROM STAGING.STG_PRIOR_AUTH LIMIT 10;
