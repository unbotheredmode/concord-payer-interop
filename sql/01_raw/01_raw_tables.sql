-- =============================================================================
-- Concord: Payer Interoperability & Prior Authorization Data Platform
-- File   : sql/01_raw/01_raw_tables.sql
-- Purpose: RAW layer — file format, internal stage, VARIANT landing tables,
--          and COPY INTO loads for all 4 healthcare data sources.
-- Run    : Once per environment setup, then COPY INTO on each data refresh.
-- =============================================================================

USE ROLE CONCORD_ENGINEER;
USE DATABASE CONCORD;
USE WAREHOUSE CONCORD_LOAD_WH;   -- ingestion work goes on the LOAD warehouse
USE SCHEMA RAW;


-- =============================================================================
-- SECTION 1: FILE FORMAT
-- Why: COPY INTO needs to know how to parse the incoming files.
--      We use NDJSON (newline-delimited JSON) — one JSON object per line.
--
-- Key decisions:
--   STRIP_OUTER_ARRAY = FALSE
--     Our generator writes one object per line, not a JSON array [{}{}].
--     If TRUE, Snowflake tries to unwrap an outer [] — wrong for NDJSON,
--     would fail or load the entire file as one row.
--
--   NULL_IF = ('null', 'NULL', '')
--     Maps JSON string "null" to SQL NULL. Critical because optional fields
--     like decision_date on pending PA records are written as JSON "null".
--     Without this, they land as the string "null" — your IS NULL checks
--     silently break and you never catch it until a metric is wrong.
--
--   COMPRESSION = AUTO
--     Detects gzip automatically. Our PUT command compressed files on upload.
--     Always compress — smaller files = faster loads = cheaper.
--
-- Prod pitfall: Wrong file format is the #1 cause of COPY INTO failures.
--   The error message is often cryptic. Always test with VALIDATION_MODE first
--   on a sample before loading production volumes.
-- =============================================================================

CREATE OR REPLACE FILE FORMAT RAW.JSON_NDJSON
  TYPE              = 'JSON'
  STRIP_OUTER_ARRAY = FALSE
  NULL_IF           = ('null', 'NULL', '')
  COMPRESSION       = 'AUTO'
  COMMENT = 'NDJSON: one JSON object per line. Used for all RAW ingestion.';


-- =============================================================================
-- SECTION 2: INTERNAL STAGE
-- Why: A stage is a named landing zone where files sit before COPY INTO.
--      Think of it as an airport gate — files pass through it, they don't
--      live there permanently.
--
-- Internal vs External stage:
--   Internal (this): Snowflake manages the storage. Files uploaded via PUT.
--   External (prod):  Points to S3/ADLS/GCS. Vendors drop files there directly.
--   The COPY INTO syntax, file format, and load metadata are IDENTICAL.
--   This skill transfers 1:1 to external stages in production.
--
-- Prod pitfall: External stages need credentials (IAM role, storage integration).
--   A misconfigured storage integration is a common day-1 prod issue.
--   Always test with LIST @stage_name before running COPY INTO.
-- =============================================================================

CREATE OR REPLACE STAGE RAW.CONCORD_RAW_STAGE
  FILE_FORMAT = RAW.JSON_NDJSON
  COMMENT     = 'Internal landing stage for synthetic FHIR JSON files';


-- =============================================================================
-- SECTION 3: RAW VARIANT TABLES
-- Why VARIANT (schema-on-read):
--   FHIR JSON structures are complex, nested, and vendor-controlled.
--   If we mapped fields upfront (20 columns), one new field from upstream
--   breaks the pipeline at 2am. VARIANT lands the JSON faithfully —
--   schema decisions happen downstream in STAGING, where they're fixable.
--
-- Why store the full blob AND metadata columns:
--   raw_data    → the complete source record, immutable. If our STAGING
--                 transform has a bug, we re-run against this. Nothing lost.
--   loaded_at   → when THIS pipeline run landed it. For debugging and auditing.
--   source_file → METADATA$FILENAME from COPY INTO. Tells you exactly which
--                 staged file this row came from. "This claim looks wrong"
--                 → trace back to source_file → find the upstream issue.
--
-- Prod pitfall: Forgetting source_file is a common mistake. Without it,
--   debugging a bad row means scanning all files. With it, it's one lookup.
-- =============================================================================

CREATE TABLE IF NOT EXISTS RAW.PATIENTS (
    raw_data        VARIANT,
    loaded_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    source_file     VARCHAR(500)
);

CREATE TABLE IF NOT EXISTS RAW.CLAIMS (
    raw_data        VARIANT,
    loaded_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    source_file     VARCHAR(500)
);

CREATE TABLE IF NOT EXISTS RAW.COVERAGE (
    raw_data        VARIANT,
    loaded_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    source_file     VARCHAR(500)
);

CREATE TABLE IF NOT EXISTS RAW.PRIOR_AUTH (
    raw_data        VARIANT,
    loaded_at       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
    source_file     VARCHAR(500)
);


-- =============================================================================
-- SECTION 4: COPY INTO
-- Why COPY INTO beats INSERT for bulk loads:
--   INSERT processes row by row. COPY INTO is a bulk parallel operation —
--   orders of magnitude faster for large files.
--
-- Key decisions:
--   SELECT $1, METADATA$FILENAME
--     $1 = the entire JSON document (one per line = one row).
--     METADATA$FILENAME = pseudo-column available only during COPY INTO
--     that captures the staged filename for each row. This populates
--     source_file so we have full row-level lineage.
--
--   ON_ERROR = ABORT_STATEMENT
--     If any row fails parsing, abort the entire load and roll back.
--     Why not CONTINUE? Partial loads are worse than failed loads.
--     A partial load looks like success — row counts seem reasonable,
--     downstream aggregates are silently wrong. A failed load is loud
--     and immediately actionable. Always abort, fix, reload clean.
--
-- Load deduplication (important prod behaviour):
--   COPY INTO tracks every file it loads in Snowflake's internal metadata.
--   Running this again on the same file = skipped automatically. No duplicates.
--   To force a reload: COPY INTO ... FORCE = TRUE (use carefully in prod).
-- =============================================================================

COPY INTO RAW.PATIENTS (raw_data, source_file)
FROM (
    SELECT $1, METADATA$FILENAME
    FROM @RAW.CONCORD_RAW_STAGE/patients.json.gz
)
FILE_FORMAT = (FORMAT_NAME = 'RAW.JSON_NDJSON')
ON_ERROR    = 'ABORT_STATEMENT';

COPY INTO RAW.CLAIMS (raw_data, source_file)
FROM (
    SELECT $1, METADATA$FILENAME
    FROM @RAW.CONCORD_RAW_STAGE/claims.json.gz
)
FILE_FORMAT = (FORMAT_NAME = 'RAW.JSON_NDJSON')
ON_ERROR    = 'ABORT_STATEMENT';

COPY INTO RAW.COVERAGE (raw_data, source_file)
FROM (
    SELECT $1, METADATA$FILENAME
    FROM @RAW.CONCORD_RAW_STAGE/coverage.json.gz
)
FILE_FORMAT = (FORMAT_NAME = 'RAW.JSON_NDJSON')
ON_ERROR    = 'ABORT_STATEMENT';

COPY INTO RAW.PRIOR_AUTH (raw_data, source_file)
FROM (
    SELECT $1, METADATA$FILENAME
    FROM @RAW.CONCORD_RAW_STAGE/prior_auth.json.gz
)
FILE_FORMAT = (FORMAT_NAME = 'RAW.JSON_NDJSON')
ON_ERROR    = 'ABORT_STATEMENT';


-- =============================================================================
-- VERIFICATION — run after every load
-- =============================================================================

-- Row counts — should match generator output: 500, 2000, 500, 400
SELECT 'PATIENTS'   AS table_name, COUNT(*) AS row_count FROM RAW.PATIENTS   UNION ALL
SELECT 'CLAIMS'     AS table_name, COUNT(*) AS row_count FROM RAW.CLAIMS      UNION ALL
SELECT 'COVERAGE'   AS table_name, COUNT(*) AS row_count FROM RAW.COVERAGE    UNION ALL
SELECT 'PRIOR_AUTH' AS table_name, COUNT(*) AS row_count FROM RAW.PRIOR_AUTH;

-- Spot check: one raw VARIANT row — confirm nested JSON is intact
SELECT raw_data, source_file, loaded_at FROM RAW.CLAIMS LIMIT 1;

-- Confirm source_file is populated (not null)
SELECT DISTINCT source_file FROM RAW.CLAIMS;

-- Quick LATERAL FLATTEN preview — what STAGING will do at scale
-- Shows how the nested diagnosis array explodes into individual rows
SELECT
    c.raw_data:claim_id::STRING     AS claim_id,
    dx.value:code::STRING           AS diagnosis_code,
    dx.value:display::STRING        AS diagnosis_display
FROM RAW.CLAIMS c,
LATERAL FLATTEN(input => c.raw_data:diagnosis, OUTER => TRUE) dx
LIMIT 10;
