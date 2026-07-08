# Concord — Interview Q&A Tracker

Concepts covered during the build. Review before interviews.
Format: Question → Your instinct → Full answer → Interview line

---

## Snowflake Fundamentals

**Q: Why can't you query files directly from a stage?**
Your instinct: JSON format needs to be in a table to query it.
Full answer:
- Stage is ephemeral file storage — no ACID guarantees, no transactions
- Direct file query gives no deduplication — same file queried twice = double data
- COPY INTO tracks loaded files in metadata — rerunning skips already-loaded files automatically
- dbt, BI tools, and downstream transforms connect to tables, not file paths
- METADATA$FILENAME gives row-level lineage — which file did this bad row come from?
Interview line: "A stage is a transit zone, not a data store. COPY INTO gives us transactions, deduplication, and lineage — none of which exist on raw files."

---

**Q: Why VARIANT (schema-on-read) instead of mapping all fields upfront?**
Your instinct: Source schema isn't fixed, vendor can add/change fields.
Full answer:
- Upstream FHIR schema is vendor-controlled — one new field breaks a rigid table at 2am
- VARIANT preserves the original record faithfully — if your STAGING transform has a bug, re-run against RAW. Nothing lost.
- Schema decisions belong in STAGING where they're fixable, not in RAW where they're permanent
- LATERAL FLATTEN extracts only what you need, when you need it
Interview line: "RAW is our system of record for what the source actually sent. VARIANT preserves it faithfully — all interpretation happens downstream where it's fixable."

---

**Q: Why ON_ERROR = ABORT_STATEMENT instead of CONTINUE?**
Your instinct: Atomicity — all or nothing.
Full answer:
- Partial loads are worse than failed loads — they look like success
- Row counts seem plausible, downstream aggregates are silently wrong
- Nobody notices until a finance report is off by 3% three weeks later
- A failed load is loud and immediately actionable
- Fix the issue, reload clean
Interview line: "Partial loads are silent failures. ABORT_STATEMENT makes failures loud and keeps data clean — better to fix and reload than silently undercount claims."

---

**Q: Why OUTER => TRUE on LATERAL FLATTEN?**
Your instinct: —
Full answer:
- Without OUTER, LATERAL FLATTEN is like an INNER JOIN — drops parent rows where the array is null/empty
- A claim with no diagnosis array silently disappears from STAGING
- OUTER => TRUE keeps the parent row, sets dx.value to NULL
- You catch missing data in dbt tests instead of losing it silently
Interview line: "OUTER=>TRUE on FLATTEN is the equivalent of LEFT JOIN — keeps parent rows even when the nested array is missing. Without it we were silently dropping claims."

---

**Q: Why cast VARIANT extractions with ::STRING, ::NUMBER etc?**
Your instinct: Numeric strings lose leading zeros without cast.
Full answer:
- Without cast, value stays as VARIANT type — not a proper SQL type
- Joins between VARIANT and STRING silently fail — WHERE claim_id = 'X' returns 0 rows even when data exists
- dbt not_null tests behave differently on VARIANT vs STRING columns
- JSON "null" vs SQL NULL are different in VARIANT world
- BI tools and pandas expect typed columns — VARIANT comes out as a raw JSON object
- Leading zeros on numeric strings get coerced to numbers (0012345 → 12345)
Interview line: "Uncast VARIANT causes silent join failures. Every extraction gets an explicit cast — ::STRING, ::NUMBER, ::DATE — so downstream joins and tests behave predictably."

---

**Q: Why AUTO_SUSPEND = 60 and INITIALLY_SUSPENDED = TRUE?**
Your instinct: —
Full answer:
- Snowflake bills per second with a 60-second minimum per resume
- A warehouse left running overnight burns credits with zero work
- 60s suspend = at most 2 minutes idle billing per session
- INITIALLY_SUSPENDED = no credit burn the moment CREATE WAREHOUSE runs
- Most common Snowflake cost incident: warehouse someone forgot to suspend
Interview line: "The number one Snowflake cost incident is a warehouse left running. 60-second auto-suspend and INITIALLY_SUSPENDED are the two settings that prevent it."

---

**Q: Why two warehouses (LOAD_WH and TRANSFORM_WH) instead of one?**
Your instinct: —
Full answer:
- Workload isolation — a heavy 2am backfill shouldn't compete with daytime BI queries
- One shared warehouse: ingestion and queries fight for the same cluster, one waits
- Separate warehouses = separate compute pools = no contention
- Resize one independently — scale up LOAD_WH for a big monthly claims file without affecting query performance
- Cost attribution — you can track ingestion cost vs transform cost separately
Interview line: "Workload isolation — a claims backfill competing with dashboard queries on one warehouse means one of them loses. Separate compute, separate problems."

---

**Q: Why build as SYSADMIN / CONCORD_ENGINEER and never ACCOUNTADMIN?**
Your instinct: —
Full answer:
- ACCOUNTADMIN is the god role — for billing and account config only
- Objects built as ACCOUNTADMIN cause ownership sprawl
- Scoped roles (SYSADMIN, custom roles) can't see ACCOUNTADMIN-owned objects cleanly
- Grants behave unpredictably when ownership is ACCOUNTADMIN
- Auditors flag it immediately in compliance reviews
- "Never build as ACCOUNTADMIN" = "never run as root on Linux"
Interview line: "ACCOUNTADMIN is for billing, not building. Everything in Concord is owned by SYSADMIN-rolled custom roles — auditable, grantable, and scoped."

---

**Q: Why FUTURE GRANTS on schemas?**
Your instinct: —
Full answer:
- Without FUTURE GRANTS: create a new table next week → analyst silently can't see it
- That gap causes dashboard failures — "table not found" with no obvious cause
- GRANT SELECT ON FUTURE TABLES means every new table auto-inherits the grant
- Scale: at 50+ tables, table-level grants become unmanageable and always incomplete
- Schema-level + future grants = set it once, works forever
Interview line: "FUTURE GRANTS prevent silent access gaps — without them, every new table needs a manual grant, someone always forgets, and a dashboard breaks at 9am."

---

**Q: Why METADATA$FILENAME in COPY INTO?**
Your instinct: Track which file each row came from.
Full answer:
- Pseudo-column available only during COPY INTO execution
- Stamps each row with its source file path (e.g. concord_raw_stage/claims.json.gz)
- "This claim looks wrong" → query source_file → trace back to upstream file → find the issue
- Without it: bad row debugging requires scanning all files with no starting point
- Also useful for monitoring — "how many rows came from yesterday's file vs today's?"
Interview line: "source_file gives us row-level lineage. Without it, debugging a bad claim means searching all source files. With it, it's one lookup."

---

## STAGING Layer

**Q: STAGING tables vs STAGING views — which and why?**
Your instinct: —
Full answer: (covered in Day 3)

---

## To be filled as we build...

**Q: What is SCD Type 2 and why does claims adjudication require it?**
**Q: Why dbt tests as data quality gates instead of SQL assertions?**
**Q: What is a Stream in Snowflake and how does CDC work?**
**Q: Why dynamic masking instead of storing separate masked copies?**
**Q: What is FUTURE GRANTS on views vs tables?**
