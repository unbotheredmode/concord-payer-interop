# Concord — Interview Q&A Tracker

Every concept covered during the build. Review before interviews.
Format: Question → Your instinct → Full answer → Interview line

---

## SECTION 1: Snowflake Fundamentals

**Q: Why can't you query files directly from a stage?**
Your instinct: JSON format needs to be in a table to query it.
Full answer:
- Stage is ephemeral file storage — no ACID guarantees, no transactions
- Direct file query gives no deduplication — same file queried twice = double data
- COPY INTO tracks loaded files in metadata — rerunning skips already-loaded files
- dbt, BI tools, and downstream transforms connect to tables, not file paths
- METADATA$FILENAME gives row-level lineage — which file did this bad row come from?
Interview line: "A stage is a transit zone, not a data store. COPY INTO gives us
transactions, deduplication, and lineage — none of which exist on raw files."

---

**Q: Why VARIANT (schema-on-read) instead of mapping all fields upfront?**
Your instinct: Source schema isn't fixed, vendor can add/change fields.
Full answer:
- Upstream FHIR schema is vendor-controlled — one new field breaks a rigid table at 2am
- VARIANT preserves the original record faithfully — if STAGING transform has a bug,
  re-run against RAW. Nothing lost.
- Schema decisions belong in STAGING where they're fixable, not in RAW
- LATERAL FLATTEN extracts only what you need, when you need it
Interview line: "RAW is our system of record for what the source actually sent.
VARIANT preserves it faithfully — all interpretation happens downstream where it's fixable."

---

**Q: Why ON_ERROR = ABORT_STATEMENT instead of CONTINUE?**
Your instinct: Atomicity — all or nothing.
Full answer:
- Partial loads are worse than failed loads — they look like success
- Row counts seem plausible, downstream aggregates are silently wrong
- Nobody notices until a finance report is off by 3% three weeks later
- A failed load is loud and immediately actionable
Interview line: "Partial loads are silent failures. ABORT_STATEMENT makes failures loud
and keeps data clean — better to fix and reload than silently undercount claims."

---

**Q: Why OUTER => TRUE on LATERAL FLATTEN?**
Full answer:
- Without OUTER, LATERAL FLATTEN is like INNER JOIN — drops parent rows where array is null
- A claim with no diagnosis array silently disappears from STAGING
- OUTER => TRUE keeps the parent row, sets dx.value to NULL
- You catch missing data in dbt tests instead of losing it silently
Interview line: "OUTER=>TRUE on FLATTEN is the equivalent of LEFT JOIN — keeps parent
rows even when the nested array is missing. Without it we silently drop claims."

---

**Q: Why cast VARIANT extractions with ::STRING, ::NUMBER etc?**
Your instinct: Numeric strings lose leading zeros without cast.
Full answer:
- Without cast, value stays as VARIANT type — not a proper SQL type
- Joins between VARIANT and STRING silently fail — WHERE claim_id = 'X' returns 0 rows
- dbt not_null tests behave differently on VARIANT vs STRING columns
- JSON "null" vs SQL NULL are different in VARIANT world
- BI tools expect typed columns — VARIANT comes out as raw JSON object
Interview line: "Uncast VARIANT causes silent join failures. Every extraction gets an
explicit cast so downstream joins and tests behave predictably."

---

**Q: Why AUTO_SUSPEND = 60 and INITIALLY_SUSPENDED = TRUE?**
Full answer:
- Snowflake bills per second with a 60-second minimum per resume
- A warehouse left running overnight burns credits with zero work
- 60s suspend = at most 2 minutes idle billing per session
- INITIALLY_SUSPENDED = no credit burn the moment CREATE WAREHOUSE runs
- Most common Snowflake cost incident: warehouse someone forgot to suspend
Interview line: "The number one Snowflake cost incident is a warehouse left running.
60-second auto-suspend and INITIALLY_SUSPENDED are the two settings that prevent it."

---

**Q: Why two warehouses (LOAD_WH and TRANSFORM_WH) instead of one?**
Full answer:
- Workload isolation — a heavy 2am backfill shouldn't compete with daytime BI queries
- One shared warehouse: ingestion and queries fight for the same cluster, one waits
- Separate warehouses = separate compute pools = no contention
- Resize one independently without affecting the other
- Cost attribution — track ingestion cost vs transform cost separately
Interview line: "Workload isolation — a claims backfill competing with dashboard queries
on one warehouse means one of them loses. Separate compute, separate problems."

---

**Q: Why build as SYSADMIN / CONCORD_ENGINEER and never ACCOUNTADMIN?**
Full answer:
- ACCOUNTADMIN is the god role — for billing and account config only
- Objects built as ACCOUNTADMIN cause ownership sprawl
- Scoped roles can't see ACCOUNTADMIN-owned objects cleanly
- Auditors flag it immediately in compliance reviews
- "Never build as ACCOUNTADMIN" = "never run as root on Linux"
Interview line: "ACCOUNTADMIN is for billing, not building. Everything in Concord is
owned by SYSADMIN-rolled custom roles — auditable, grantable, and scoped."

---

**Q: Why FUTURE GRANTS on schemas?**
Full answer:
- Without FUTURE GRANTS: create a new table next week → analyst silently can't see it
- That gap causes dashboard failures — "table not found" with no obvious cause
- GRANT SELECT ON FUTURE TABLES means every new table auto-inherits the grant
- Schema-level + future grants = set it once, works forever
Interview line: "FUTURE GRANTS prevent silent access gaps — without them, every new
table needs a manual grant, someone always forgets, and a dashboard breaks at 9am."

---

**Q: Why METADATA$FILENAME in COPY INTO?**
Your instinct: Track which file each row came from.
Full answer:
- Pseudo-column available only during COPY INTO execution
- Stamps each row with its source file path
- "This claim looks wrong" → query source_file → trace back to upstream file
- Without it: bad row debugging requires scanning all files with no starting point
Interview line: "source_file gives us row-level lineage. Without it, debugging a bad
claim means searching all source files. With it, it's one lookup."

---

**Q: What is TRY_CAST vs CAST?**
Your instinct: TRY_CAST converts only when format is proper, CAST converts everything.
Full answer: (flip it)
- CAST: converts or THROWS AN ERROR if it can't. Pipeline crashes.
- TRY_CAST: converts or returns NULL if it can't. Pipeline continues.
- TRY_CAST('2024-13-45' AS DATE) → NULL (bad date, pipeline keeps running)
- CAST('2024-13-45' AS DATE) → ERROR (pipeline stops)
- In STAGING: use TRY_CAST everywhere, catch NULLs with dbt tests downstream
- One bad date in a 2000-row file shouldn't kill the entire load
Interview line: "TRY_CAST lets the pipeline continue on bad values — the NULL gets
caught by dbt not_null tests rather than crashing the entire load at 2am."

---

**Q: Why dead letter / error tables instead of just logging to PIPELINE_LOG?**
Your instinct: You came up with this independently — error tables per entity.
Full answer:
- PIPELINE_LOG tells you HOW MANY rows failed (count)
- Error tables tell you WHICH rows and WHY (the actual bad records)
- Each rejected row stored with: original raw_data blob, rejection_reason, source_file
- An ops engineer queries CLAIMS_ERRORS, fixes upstream, reloads just those rows
- Without error tables: "50 rows rejected" requires manually scanning source files
- With error tables: SELECT * FROM CLAIMS_ERRORS WHERE rejected_at > yesterday
Interview line: "PIPELINE_LOG tells us counts, dead letter tables tell us which rows
and why. When 50 claims reject, we query CLAIMS_ERRORS for the exact records
and reasons — no manual file scanning."

---

**Q: Why MERGE instead of INSERT or TRUNCATE+INSERT for STAGING loads?**
Your instinct: MERGE prevents duplicates on reruns.
Full answer:
- INSERT appends every run — duplicates on reruns, silent data corruption
- TRUNCATE+INSERT: table is empty during load window — dashboards return 0 rows
- MERGE on business key: update if exists, insert if new. No duplicates, no downtime.
- Handles late-arriving claim adjustments — same claim_id gets updated, not duplicated
- Date watermarks miss late-arriving adjustments (old service_date on reprocessed claim)
Interview line: "MERGE on claim_id handles reprocessed claims correctly — full truncate
creates an availability window, date watermarks miss late-arriving adjustments."

---

## SECTION 2: Star Schema & Data Modeling

**Q: What is the difference between STAGING and MARTS?**
Full answer:
STAGING = engineer-facing. One row per source record, conformed and typed,
all fields present. Shaped exactly like the source but cleaned.
Nobody queries STAGING for business answers.

MARTS = analyst-facing. Shaped for specific business questions.
Star schema: one fact table (measurements + foreign keys) surrounded by
dimension tables (descriptive attributes). Pre-joined, sometimes pre-aggregated.

Star schema for Concord:
- FCT_CLAIMS: claim_id, member_id (FK), provider_npi (FK), billed_amount, paid_amount
- DIM_MEMBER: member_id, name, dob, state, plan_type (descriptive detail)
- DIM_PROVIDER: npi, name, specialty
- DIM_DATE: date, year, month, quarter
- PA_METRICS_MART: pre-aggregated PA KPIs by line of business

Interview answer: "STAGING is our internal engineering layer — conformed, typed, one
row per source record. MARTS are business-facing — star schema with a lean fact table
pointing to dimension tables. We never put descriptive attributes on fact rows —
a provider name change would require updating millions of claim records instead of one
dimension row."

---

**Q: What is a fact table vs a dimension table?**
Full answer:
Fact table: stores EVENTS and MEASUREMENTS.
- One row per business event (one claim, one PA request)
- Contains foreign keys to dimensions + numeric measures (amounts, counts, durations)
- Rows are never updated — new events append, old events stay

Dimension table: stores DESCRIPTIVE CONTEXT about entities in facts.
- One row per entity (one member, one provider, one date)
- Contains all "who, what, where" attributes
- Changes over time tracked via SCD2

Simple test: "Is this a measurement or a description?"
- billed_amount = measurement → fact table
- member_name = description → dimension table
- service_date = event timestamp → fact table
- provider_specialty = description → dimension table

Interview answer: "Fact tables store what happened and how much — one row per claim
with billed and paid amounts. Dimension tables store context — who the member is,
what the provider's specialty is. The join between them gives analysts the full picture
without duplicating descriptive data across millions of fact rows."

---

**Q: What is SCD Type 2 and why does healthcare data require it?**
Full answer:
SCD = Slowly Changing Dimension. Type 2 = preserve full history by adding
new rows instead of overwriting old ones.

Three columns added:
- valid_from: when this version became true
- valid_to: when it stopped (9999-12-31 = still current)
- is_current: TRUE/FALSE flag

Example — Jane Smith changes her plan:
BEFORE: MBR124302 | Medicare Advantage | TX | is_current=TRUE
AFTER:
  MBR124302 | Medicare Advantage | TX | 2024-01-01 | 2025-03-15 | FALSE
  MBR124302 | Commercial PPO | CA | 2025-03-16 | 9999-12-31 | TRUE

Why healthcare REQUIRES this:
1. Claims adjudication — "what was the member's plan at time of service?"
2. Audit trail — regulators ask "what was this member's coverage on date X?"
3. Point-in-time reporting — "how many Medicare members in Q3 2024?"

dbt handles SCD2 automatically with snapshots — you write a SELECT,
dbt manages valid_from, valid_to, is_current on each run.

Interview answer: "Healthcare claims adjudication is point-in-time dependent — a 2024
claim must be processed against the member's 2024 plan, not their current plan. SCD2
preserves that history by adding rows instead of overwriting. We implemented it via
dbt snapshots on DIM_MEMBER."

---

**Q: Why not store everything in one big table?**
Full answer:
If Jane Smith moves from Texas to California:
- Big table: UPDATE 847 claim rows, lose history of what state she was in when claim filed
- Star schema: update ONE row in DIM_MEMBER, all claims reflect it via JOIN,
  SCD2 preserves Texas history for 2024 claims

Other reasons:
- Provider name changes → update one DIM_PROVIDER row, not millions of fact rows
- New diagnosis code → add one row to DIM_DIAGNOSIS, no claim data touched
- Query performance — fact tables stay narrow and fast, dimensions are small and cached
Interview answer: "One big table means a provider name change requires updating millions
of claim rows and you lose the historical state. Star schema stores descriptive
attributes once in dimensions — facts stay lean and immutable."

---

## SECTION 3: dbt Fundamentals

**Q: What is dbt and what does it give you that plain SQL doesn't?**
Your instinct: Runs dependent objects first, handles ordering automatically,
can filter data and run tests.
Full answer:
dbt is a transformation framework that runs on top of your warehouse.
You write SELECT statements; dbt handles CREATE TABLE/VIEW, dependency
ordering, testing, and documentation.

5 things dbt gives you that plain SQL doesn't:
1. Dependency ordering via ref() — build order is automatic
2. Data quality tests as pipeline gates — not_null, unique, accepted_values
3. Lineage documentation — interactive graph, auto-generated
4. SCD Type 2 via snapshots — declarative, no manual MERGE logic
5. Incremental models — only process new/changed rows after first run

Interview answer: "dbt gave us version-controlled, tested, documented transforms.
Before dbt, a new engineer read 400 lines of SQL to understand the pipeline.
After dbt, they run dbt docs generate and see the full lineage graph in 30 seconds.
Tests catch data quality issues at layer boundaries — a null claim_id fails in STAGING
and never reaches FCT_CLAIMS."

---

**Q: What does dbt actually execute in Snowflake when you run dbt run?**
Your instinct: Creates the table, rebuilds it.
Full answer:
For table materialization:
  CREATE OR REPLACE TABLE CONCORD.STAGING.STG_CLAIMS AS
  SELECT ... FROM CONCORD.RAW.CLAIMS

CREATE OR REPLACE = full rebuild every time. Not skip, not error.
dbt drops and recreates from your SELECT on every run.

Four materializations:
1. table — CREATE OR REPLACE every run (our staging models)
2. view — CREATE OR REPLACE VIEW every run (lightweight, no storage)
3. incremental — MERGE on subsequent runs (our mart models — no downtime)
4. ephemeral — no object created, inlined as CTE in downstream models

Interview answer: "Table materialization runs CREATE OR REPLACE TABLE AS SELECT —
full rebuild every run. Fine for staging because only dbt reads it. For marts
analysts query live, we use incremental so dbt does a MERGE — no downtime window."

---

**Q: What is the ingestion boundary in dbt? What does dbt NOT do?**
Your instinct: RAW tables are always created through manual SQL scripts first.
Full answer:
dbt is a T tool — the Transform in ELT. It does not Extract or Load.

Boundary:
  INGESTION (outside dbt)    │  TRANSFORMATION (dbt owns)
  Python + COPY INTO      ───┼──▶ STG_CLAIMS
  Fivetran / Airbyte      ───┼──▶ STG_PATIENTS  ──▶ FCT_CLAIMS
  Snowpipe                ───┼──▶ STG_COVERAGE  ──▶ DIM_MEMBER
  RAW tables live here       │  dbt starts here

RAW tables always created by something else — our project uses Python + COPY INTO.
dbt reads them via source() but never creates, modifies, or drops RAW tables.
If dbt owned RAW, a bad dbt run could wipe source data.

Interview answer: "dbt owns the T in ELT — STAGING through MARTS. RAW tables are
created and loaded by our ingestion pipeline. Clear separation — ingestion engineers
own RAW, analytics engineers own dbt models."

---

**Q: What is ref() in dbt and why does it matter?**
Full answer:
{{ ref('stg_claims') }} instead of hardcoding FROM CONCORD.STAGING.STG_CLAIMS

Three things ref() does:
1. Tells dbt "this model depends on stg_claims" — build order is automatic
2. Resolves to correct schema per environment:
   dev  → CONCORD.DEV_STAGING.STG_CLAIMS
   prod → CONCORD.STAGING.STG_CLAIMS
   Same code, different environments, zero manual changes
3. Appears in lineage graph — dbt docs shows the dependency visually

Interview answer: "ref() does three things: build order, environment resolution, and
lineage tracking. Hardcoding schema names breaks in CI/CD — ref() is how dbt models
stay environment-agnostic."

---

**Q: What is the difference between source() and ref()?**
Full answer:
source('raw', 'claims') = tables dbt READS but didn't BUILD
- Declared in sources.yml with database + schema
- Resolves to CONCORD.RAW.CLAIMS
- Green node in lineage graph
- Enables dbt source freshness checks

ref('stg_claims') = tables dbt BUILT
- dbt owns these, manages dependencies, tracks lineage
- Resolves to correct schema per environment automatically
- Blue node in lineage graph
- Creates build dependency — stg_claims built before any model that refs it

Interview answer: "source() is for tables we read but don't own — our RAW VARIANT
tables. ref() is for models dbt built. ref() creates tracked dependencies and resolves
to the correct schema per environment. Hardcoding breaks in CI/CD."

---

**Q: What is --select in dbt and why do you use it?**
Full answer:
dbt run runs ALL models by default. --select runs only specified models.

Patterns:
  dbt run --select stg_claims          # one model
  dbt run --select staging.*           # all models in staging folder
  dbt run --select +fct_claims         # fct_claims AND all upstream deps
  dbt run --select fct_claims+         # fct_claims AND all downstream models

Why critical:
- 50-model project takes 20 minutes full run — debugging one model = waste
- + operator includes upstream deps so mart never runs against stale staging
- CI/CD: only run models affected by the current code change
- Cost: every dbt run uses Snowflake compute — unnecessary full runs burn credits

Interview answer: "--select avoids running 50 models when changing one. We use
+model_name to include all upstream deps — so you never run a mart against stale
staging. In CI/CD we use state:modified+ to only run models in the PR."

---

**Q: What is a dbt test and how is it different from a SQL assertion?**
Full answer:
SQL assertion: you write and run manually. No automation, no blocking.
dbt test: runs automatically on dbt test, blocks deployment if fails.

Two types:

1. Schema tests (YAML, zero SQL):
   - name: claim_id
     tests:
       - not_null
       - unique
   - name: status
     tests:
       - accepted_values:
           values: ['active', 'cancelled', 'entered-in-error']

2. Custom data tests (SQL returning 0 rows = pass):
   -- tests/assert_paid_not_exceed_billed.sql
   SELECT claim_id FROM ref('stg_claims')
   WHERE paid_amount > billed_amount
   → any rows returned = test fails, pipeline stops

In prod: dbt test runs after dbt run in CI/CD.
Test failure → deployment blocked → bad data never reaches production marts.

Interview answer: "dbt tests are automated data contracts. A not_null test on claim_id
means a null business key never propagates to FCT_CLAIMS. A custom test catches
paid_amount exceeding billed_amount before analysts see wrong numbers. We run dbt test
in CI/CD — test failure blocks the deployment."

---

**Q: What is dbt source freshness?**
Full answer:
Checks when a source table last received data and alerts if stale.

Config in sources.yml:
  loaded_at_field: loaded_at
  freshness:
    warn_after: {count: 12, period: hour}
    error_after: {count: 24, period: hour}

Run: dbt source freshness

Real scenario:
Claims feed lands every night at 2am. At 9am analyst runs report — numbers low.
Without freshness: analyst thinks it's a real trend, raises alarm.
With freshness: dbt alerted at 7am that claims table is 28 hours stale.
Ops investigating before analyst even opens the dashboard.

Interview answer: "Source freshness on our RAW claims table — warn at 12 hours, error
at 24. Caught a clearinghouse feed failure before analysts noticed missing claims.
Without freshness checks, stale data looks like a real business trend."

---

**Q: What are macros in dbt? What language are they written in?**
Full answer:
Macros are reusable functions written in Jinja — a Python-based templating language.

dbt compiles your models in two passes:
1. Jinja pass: evaluates all {{ }} blocks, resolves ref(), source(), macros
2. SQL pass: sends the resulting pure SQL to Snowflake

You write this (Jinja + SQL):
  FROM {{ source('raw', 'claims') }}

dbt compiles to this (pure SQL):
  FROM CONCORD.RAW.CLAIMS

generate_schema_name is a special macro dbt calls automatically when
deciding which schema to build objects in. Without overriding it, dbt
generates schema names like "STAGING_STAGING" (target + custom concatenated).
The override makes dbt use custom schema names exactly as declared.

Interview answer: "dbt macros are Jinja functions — reusable logic dbt evaluates
before sending SQL to Snowflake. We overrode generate_schema_name so models/staging/
builds in CONCORD.STAGING exactly, not STAGING_STAGING. It's the most common macro
override in any production dbt project."

---

**Q: Why not use FLATTEN in dbt staging models? You used it in manual SQL.**
Your instinct: Coverage needs FLATTEN?
Full answer:
STAGING must preserve source grain — one row in, one row out.
FLATTEN changes grain — one claim with 3 diagnoses becomes 3 rows.
COUNT(*) on STG_CLAIMS returns 2600 instead of 2000. Downstream models break.

Rule: NEVER change grain in STAGING.

For primary diagnosis: use array indexing raw_data:diagnosis[0]:code
— takes only the first element, grain stays 1:1.

For multi-diagnosis analysis: build a SEPARATE mart model fct_claim_diagnoses
that FLATTENs from RAW with clearly documented grain: one row per claim+diagnosis.

Interview answer: "STAGING preserves source grain — one row per claim. We use array
indexing [0] for the primary diagnosis. Multi-diagnosis analysis gets its own mart
model with a documented grain of claim+diagnosis. Flattening in staging breaks
every COUNT and SUM in downstream models."

---

## SECTION 4: To be added as we build MARTS, SCD2, CDC, Governance

**Q: What is an incremental model in dbt?**
**Q: How does dbt snapshot implement SCD Type 2?**
**Q: What is dynamic data masking in Snowflake?**
**Q: What is a row access policy and how does it differ from masking?**
**Q: What are Snowflake Streams and Tasks? How does CDC work?**
**Q: What is the PA metrics mart and what does it compute?**
