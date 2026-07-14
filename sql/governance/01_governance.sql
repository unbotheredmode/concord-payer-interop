-- =============================================================================
-- Concord: Payer Interoperability & Prior Authorization Data Platform
-- File   : sql/governance/01_governance.sql
-- Purpose: PHI governance — dynamic data masking + row access policies
--          Enterprise-only features. Run once after marts are built.
-- =============================================================================

USE ROLE SYSADMIN;
USE DATABASE CONCORD;
USE WAREHOUSE CONCORD_TRANSFORM_WH;

-- =============================================================================
-- SECTION 1: DYNAMIC DATA MASKING POLICIES
-- Column-level PHI protection. Applied to dim_member.
-- Engineers see real values. Analysts see masked values.
-- =============================================================================

-- Policy 1: Mask date of birth → NULL for non-engineers
CREATE OR REPLACE MASKING POLICY CONCORD.MARTS.MASK_DOB
AS (val DATE) RETURNS DATE ->
    CASE
        WHEN CURRENT_ROLE() IN ('CONCORD_ENGINEER', 'SYSADMIN', 'ACCOUNTADMIN')
            THEN val
        ELSE NULL
    END
COMMENT = 'PHI: masks date of birth for non-engineer roles';

-- Policy 2: Mask zip → first 3 digits only (HIPAA safe harbor)
CREATE OR REPLACE MASKING POLICY CONCORD.MARTS.MASK_ZIP
AS (val STRING) RETURNS STRING ->
    CASE
        WHEN CURRENT_ROLE() IN ('CONCORD_ENGINEER', 'SYSADMIN', 'ACCOUNTADMIN')
            THEN val
        ELSE LEFT(val, 3) || '**'
    END
COMMENT = 'PHI: truncates zip to 3 digits for non-engineer roles (HIPAA safe harbor)';

-- Apply masking policies to dim_member columns
ALTER TABLE CONCORD.MARTS.DIM_MEMBER
    MODIFY COLUMN dob
    SET MASKING POLICY CONCORD.MARTS.MASK_DOB;

ALTER TABLE CONCORD.MARTS.DIM_MEMBER
    MODIFY COLUMN zip_code
    SET MASKING POLICY CONCORD.MARTS.MASK_ZIP;


-- =============================================================================
-- SECTION 2: ROW ACCESS POLICY
-- Row-level scoping by line of business.
-- Uses mapping table — not hardcoded — so adding roles needs no policy change.
-- =============================================================================

CREATE OR REPLACE ROW ACCESS POLICY CONCORD.MARTS.RAP_LINE_OF_BUSINESS
AS (line_of_business STRING) RETURNS BOOLEAN ->
    CASE
        -- Engineers and admins see all rows
        WHEN CURRENT_ROLE() IN ('CONCORD_ENGINEER', 'SYSADMIN', 'ACCOUNTADMIN')
            THEN TRUE
        -- All other roles: check mapping table
        ELSE EXISTS (
            SELECT 1
            FROM CONCORD._INTERNAL.ROLE_LOB_MAPPING m
            WHERE m.role_name        = CURRENT_ROLE()
              AND m.line_of_business = line_of_business
        )
    END
COMMENT = 'Scopes row visibility by line of business using role-LOB mapping table';

-- Apply to pa_metrics_mart
ALTER TABLE CONCORD.MARTS.PA_METRICS_MART
    ADD ROW ACCESS POLICY CONCORD.MARTS.RAP_LINE_OF_BUSINESS
    ON (line_of_business);

-- Apply to dim_member
ALTER TABLE CONCORD.MARTS.DIM_MEMBER
    ADD ROW ACCESS POLICY CONCORD.MARTS.RAP_LINE_OF_BUSINESS
    ON (line_of_business);


-- =============================================================================
-- SECTION 3: VERIFICATION
-- Test masking and row access as different roles
-- =============================================================================

-- Test 1: As ENGINEER — see all rows, real DOB and zip
USE ROLE CONCORD_ENGINEER;
USE WAREHOUSE CONCORD_TRANSFORM_WH;

SELECT member_id, dob, zip_code, line_of_business
FROM CONCORD.MARTS.DIM_MEMBER
LIMIT 5;
-- Expect: real DOB dates, real zip codes, all LOBs visible

-- Test 2: As ANALYST — see masked DOB, truncated zip
USE ROLE CONCORD_ANALYST;
USE WAREHOUSE CONCORD_TRANSFORM_WH;

SELECT member_id, dob, zip_code, line_of_business
FROM CONCORD.MARTS.DIM_MEMBER
LIMIT 5;
-- Expect: dob = NULL, zip = '941**', only rows where LOB in mapping table

-- Test 3: PA metrics as ANALYST — only see their scoped LOBs
SELECT line_of_business, total_requests, approval_rate_pct
FROM CONCORD.MARTS.PA_METRICS_MART;
-- Expect: only LOBs in the mapping table (all 3 for CONCORD_ANALYST in our demo)

-- Switch back to engineer
USE ROLE CONCORD_ENGINEER;

-- Confirm policies exist
SHOW MASKING POLICIES IN SCHEMA CONCORD.MARTS;
SHOW ROW ACCESS POLICIES IN SCHEMA CONCORD.MARTS;