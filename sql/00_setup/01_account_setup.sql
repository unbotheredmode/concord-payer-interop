-- =============================================================================
-- Concord: Payer Interoperability & Prior Authorization Data Platform
-- File   : sql/00_setup/01_account_setup.sql
-- Purpose: One-time platform foundation — run once on a fresh account
-- Author : STARTLEARNING
-- Created: 2026-07-01
--
-- Run order: Execute top to bottom in a single Snowsight worksheet session.
-- Roles used: ACCOUNTADMIN → USERADMIN → SECURITYADMIN → SYSADMIN
-- After this file: all subsequent work runs as CONCORD_ENGINEER only.
-- =============================================================================


-- =============================================================================
-- SECTION 1: COST CONTROL
-- Why: COMPUTE_WH is created by default on every Snowflake trial and starts
--      running immediately. At $2/credit (Enterprise), an X-Small left running
--      24/7 costs ~$96/day. Suspend it first — before anything else.
-- Prod parallel: First action on any new Snowflake account in a real team.
-- =============================================================================

USE ROLE ACCOUNTADMIN;

ALTER WAREHOUSE COMPUTE_WH SUSPEND;
ALTER WAREHOUSE COMPUTE_WH SET AUTO_SUSPEND = 60;   -- kill it fast if it ever wakes


-- =============================================================================
-- SECTION 2: RBAC SKELETON
-- Why: Everything in Snowflake should be built under scoped functional roles,
--      never ACCOUNTADMIN. ACCOUNTADMIN is for billing and account config only.
--      Objects built as ACCOUNTADMIN cause ownership sprawl — scoped roles
--      can't see them, grants behave unpredictably, auditors flag it.
--
-- Role hierarchy:
--   ACCOUNTADMIN        → billing/account config only (never builds objects)
--     └── SYSADMIN      → owns all Concord infrastructure
--           ├── CONCORD_ENGINEER  → builds pipelines, owns all Concord objects
--           └── CONCORD_ANALYST   → read-only on MARTS, never touches RAW
--   USERADMIN           → creates roles (Snowflake best practice: separate concern)
--   SECURITYADMIN       → grants privileges (separate from object creation)
--
-- Prod parallel: Every enterprise Snowflake deployment enforces this separation.
--   "Never build as ACCOUNTADMIN" is the equivalent of "never run as root."
-- =============================================================================

USE ROLE USERADMIN;   -- correct role for CREATE ROLE

CREATE ROLE IF NOT EXISTS CONCORD_ENGINEER
  COMMENT = 'Builds and owns all Concord pipeline objects';

CREATE ROLE IF NOT EXISTS CONCORD_ANALYST
  COMMENT = 'Read-only access to MARTS schema only — never RAW or STAGING';

USE ROLE SECURITYADMIN;   -- correct role for GRANT

-- Roll custom roles up to SYSADMIN so admins retain full visibility.
-- Without this, a SYSADMIN user cannot see objects owned by custom roles —
-- a common gotcha that breaks admin troubleshooting.
GRANT ROLE CONCORD_ENGINEER TO ROLE SYSADMIN;
GRANT ROLE CONCORD_ANALYST  TO ROLE SYSADMIN;

-- Assign both roles to the platform user.
-- In a real team, only the engineer would get CONCORD_ENGINEER;
-- analysts get CONCORD_ANALYST. We assign both here for solo development.
GRANT ROLE CONCORD_ENGINEER TO USER STARTLEARNING;
GRANT ROLE CONCORD_ANALYST  TO USER STARTLEARNING;


-- =============================================================================
-- SECTION 3: COMPUTE — WORKLOAD-ISOLATED WAREHOUSES
-- Why: A single shared warehouse means a heavy 2am backfill competes with
--      daytime BI queries. One waits. In prod that means a claims load delays
--      a dashboard, or a dbt run starves an analyst. Separate warehouses =
--      separate compute pools = no contention between workloads.
--
-- Two warehouses by workload type (not by team):
--   CONCORD_LOAD_WH      → heavy burst: COPY INTO, file ingestion
--   CONCORD_TRANSFORM_WH → steady use: dbt models, Snowpark, ad-hoc queries
--
-- Sizing: X-Small = 1 credit/hr. Each step up doubles cost AND performance.
--   For our data volume (thousands of rows, not billions), X-Small is correct.
--   Oversizing is the #1 Snowflake cost mistake after forgetting to suspend.
--
-- AUTO_SUSPEND = 60: Snowflake bills per second with a 60-second minimum per
--   resume. Setting suspend to 60s means you pay for at most 2 minutes of idle
--   per session (one 60s minimum + up to 60s before suspend kicks in).
--
-- INITIALLY_SUSPENDED: Without this, CREATE WAREHOUSE starts the warehouse
--   immediately and burns credits before a single query runs.
--
-- Prod parallel: Every production Snowflake account separates ingestion and
--   transform compute. Some teams add a third warehouse for BI/reporting.
-- =============================================================================

USE ROLE SYSADMIN;

CREATE WAREHOUSE IF NOT EXISTS CONCORD_LOAD_WH
  WAREHOUSE_SIZE    = 'XSMALL'
  AUTO_SUSPEND      = 60
  AUTO_RESUME       = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Ingestion workload: COPY INTO, stage loads — burst usage';

CREATE WAREHOUSE IF NOT EXISTS CONCORD_TRANSFORM_WH
  WAREHOUSE_SIZE    = 'XSMALL'
  AUTO_SUSPEND      = 60
  AUTO_RESUME       = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Transform workload: dbt runs, Snowpark, ad-hoc queries — steady use';


-- =============================================================================
-- SECTION 4: DATABASE AND MEDALLION SCHEMAS
-- Why: Schema boundaries are access control boundaries, not just folders.
--   RAW   → source data landed as-is. PHI present (member IDs, DOBs in FHIR).
--           No analyst role ever gets USAGE on this schema.
--   STAGING → conformed, typed, deduped. Internal use only. Engineers only.
--   MARTS → analyst-facing star schema + PA metrics. PHI masked at column level.
--           The ONLY schema CONCORD_ANALYST can see.
--   _INTERNAL → ops: pipeline audit log, dbt test results, task run metadata.
--
-- Prod parallel: HIPAA minimum-necessary principle. Analysts get the data they
--   need for their job, nothing more. Schema-level grants scale to 100+ tables;
--   table-level grants become unmanageable and are always incomplete.
-- =============================================================================

USE ROLE SYSADMIN;

CREATE DATABASE IF NOT EXISTS CONCORD
  COMMENT = 'Payer Interoperability & Prior Authorization Data Platform';

USE DATABASE CONCORD;

CREATE SCHEMA IF NOT EXISTS RAW
  COMMENT = 'Landing zone: source data as-is, no transforms. PHI may be present.';

CREATE SCHEMA IF NOT EXISTS STAGING
  COMMENT = 'Conformed, typed, deduped. Internal pipeline use only.';

CREATE SCHEMA IF NOT EXISTS MARTS
  COMMENT = 'Star schema + PA metrics. Analyst-facing. PHI masked at column level.';

CREATE SCHEMA IF NOT EXISTS _INTERNAL
  COMMENT = 'Ops schema: pipeline audit log, DQ results, task metadata.';


-- =============================================================================
-- SECTION 5: PRIVILEGE GRANTS
-- Why: Two patterns that prevent the most common RBAC incidents in prod:
--
--   1. FUTURE GRANTS — without these, every new table you create next week
--      is invisible to the analyst role until someone manually re-grants.
--      That silent gap causes dashboard failures and confused stakeholders.
--      FUTURE GRANTS make new objects automatically inherit the right access.
--
--   2. USAGE on database AND schema — SELECT on a table means nothing if the
--      role can't open the schema it lives in. Both layers are required.
--      A common mistake: grant SELECT on tables, forget USAGE on schema,
--      wonder why the role gets "schema does not exist" errors.
--
-- Analyst boundary: CONCORD_ANALYST has zero access to RAW or STAGING.
--   This is not a convention — it's enforced by the absence of any grant.
--   The analyst role physically cannot query PHI from the landing zone.
--
-- Prod parallel: This is what a compliance audit checks. "Show me that your
--   analyst roles cannot access the raw PHI landing zone." This is the proof.
-- =============================================================================

USE ROLE SECURITYADMIN;

-- CONCORD_ENGINEER: full build rights across all schemas
GRANT USAGE ON DATABASE CONCORD TO ROLE CONCORD_ENGINEER;
GRANT USAGE ON WAREHOUSE CONCORD_LOAD_WH      TO ROLE CONCORD_ENGINEER;
GRANT USAGE ON WAREHOUSE CONCORD_TRANSFORM_WH TO ROLE CONCORD_ENGINEER;

GRANT ALL PRIVILEGES ON SCHEMA CONCORD.RAW       TO ROLE CONCORD_ENGINEER;
GRANT ALL PRIVILEGES ON SCHEMA CONCORD.STAGING   TO ROLE CONCORD_ENGINEER;
GRANT ALL PRIVILEGES ON SCHEMA CONCORD.MARTS     TO ROLE CONCORD_ENGINEER;
GRANT ALL PRIVILEGES ON SCHEMA CONCORD._INTERNAL TO ROLE CONCORD_ENGINEER;

-- Future grants: new objects auto-inherit engineer access
GRANT ALL PRIVILEGES ON FUTURE TABLES IN SCHEMA CONCORD.RAW       TO ROLE CONCORD_ENGINEER;
GRANT ALL PRIVILEGES ON FUTURE TABLES IN SCHEMA CONCORD.STAGING   TO ROLE CONCORD_ENGINEER;
GRANT ALL PRIVILEGES ON FUTURE TABLES IN SCHEMA CONCORD.MARTS     TO ROLE CONCORD_ENGINEER;
GRANT ALL PRIVILEGES ON FUTURE TABLES IN SCHEMA CONCORD._INTERNAL TO ROLE CONCORD_ENGINEER;

GRANT ALL PRIVILEGES ON FUTURE VIEWS IN SCHEMA CONCORD.STAGING TO ROLE CONCORD_ENGINEER;
GRANT ALL PRIVILEGES ON FUTURE VIEWS IN SCHEMA CONCORD.MARTS   TO ROLE CONCORD_ENGINEER;

-- CONCORD_ANALYST: MARTS only — no access to RAW or STAGING (not even USAGE)
GRANT USAGE ON DATABASE CONCORD               TO ROLE CONCORD_ANALYST;
GRANT USAGE ON WAREHOUSE CONCORD_TRANSFORM_WH TO ROLE CONCORD_ANALYST;
GRANT USAGE ON SCHEMA CONCORD.MARTS           TO ROLE CONCORD_ANALYST;

GRANT SELECT ON ALL    TABLES IN SCHEMA CONCORD.MARTS TO ROLE CONCORD_ANALYST;
GRANT SELECT ON FUTURE TABLES IN SCHEMA CONCORD.MARTS TO ROLE CONCORD_ANALYST;
GRANT SELECT ON FUTURE VIEWS  IN SCHEMA CONCORD.MARTS TO ROLE CONCORD_ANALYST;


-- =============================================================================
-- SECTION 6: PIPELINE AUDIT LOG
-- Why: Every production data platform needs operational observability.
--   When a pipeline fails at 3am, the on-call engineer opens this table first:
--   "what ran, when, how many rows came in, what was the error?"
--   Without it you're digging through Snowflake query history per session.
--
--   Columns designed for real ops use:
--     run_ts        → when it ran (NTZ = no timezone ambiguity across regions)
--     step_name     → dot-notation: 'raw.load_fhir_bundles' (schema.step)
--     source        → which upstream system: 'synthea', 'nppes', 'pa_feed'
--     rows_loaded   → what came in successfully
--     rows_rejected → what COPY INTO rejected (file format errors, type mismatches)
--     status        → SUCCESS / FAILED / SKIPPED (queryable for alerting)
--     message       → error detail or success note (2000 chars covers most errors)
--     run_by        → which role ran it (audit trail)
--     warehouse     → which compute was used (cost attribution)
--
-- Prod parallel: Real teams query this table in monitoring dashboards and
--   set up Snowflake alerts on status = 'FAILED'. It's also what you show
--   a compliance auditor to prove pipeline runs are tracked end-to-end.
-- =============================================================================

USE ROLE SYSADMIN;
USE SCHEMA CONCORD._INTERNAL;
USE WAREHOUSE CONCORD_TRANSFORM_WH;

CREATE TABLE IF NOT EXISTS PIPELINE_LOG (
  log_id        NUMBER AUTOINCREMENT PRIMARY KEY,
  run_ts        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  step_name     VARCHAR(200),
  source        VARCHAR(100),
  rows_loaded   NUMBER        DEFAULT 0,
  rows_rejected NUMBER        DEFAULT 0,
  status        VARCHAR(20),                              -- SUCCESS | FAILED | SKIPPED
  message       VARCHAR(2000),
  run_by        VARCHAR(100)  DEFAULT CURRENT_ROLE(),
  warehouse     VARCHAR(100)  DEFAULT CURRENT_WAREHOUSE()
);

-- Seed entry: confirms platform setup completed successfully
INSERT INTO PIPELINE_LOG (step_name, source, rows_loaded, status, message)
VALUES (
  'setup.platform_foundation',
  'manual',
  0,
  'SUCCESS',
  'Day 1 complete: warehouses, schemas, RBAC, audit log verified.'
);


-- =============================================================================
-- SECTION 7: SWITCH TO WORKING ROLE
-- From this point on: CONCORD_ENGINEER only.
-- ACCOUNTADMIN and SYSADMIN are not used again in this project.
-- =============================================================================

USE ROLE CONCORD_ENGINEER;
USE DATABASE CONCORD;
USE WAREHOUSE CONCORD_TRANSFORM_WH;


-- =============================================================================
-- VERIFICATION — run after setup to confirm everything is correct
-- =============================================================================

-- 1. Confirm active context
SELECT
  CURRENT_ROLE()      AS active_role,       -- expect: CONCORD_ENGINEER
  CURRENT_USER()      AS active_user,       -- expect: STARTLEARNING
  CURRENT_DATABASE()  AS active_db,         -- expect: CONCORD
  CURRENT_WAREHOUSE() AS active_warehouse;  -- expect: CONCORD_TRANSFORM_WH

-- 2. Confirm warehouses (both should be SUSPENDED)
SHOW WAREHOUSES LIKE 'CONCORD%';

-- 3. Confirm schemas
SHOW SCHEMAS IN DATABASE CONCORD;

-- 4. Confirm audit log has seed row
SELECT * FROM CONCORD._INTERNAL.PIPELINE_LOG;
