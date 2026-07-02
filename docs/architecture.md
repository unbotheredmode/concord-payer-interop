# Architecture & Design Rationale

Every decision in Concord has a production reason behind it.
This doc maps each technical choice to the real scenario that forces it.

---

## Medallion schema layout

| Schema | Purpose | Who can access |
|---|---|---|
| `RAW` | Source data landed faithfully, no transforms. PHI present. | `CONCORD_ENGINEER` only |
| `STAGING` | Cleaned, typed, deduped, conformed. Internal use. | `CONCORD_ENGINEER` only |
| `MARTS` | Star schema + metrics. Analytics-facing. PHI masked. | `CONCORD_ENGINEER` + `CONCORD_ANALYST` |
| `_INTERNAL` | Audit log, DQ results, task metadata. Ops use. | `CONCORD_ENGINEER` only |

Schema boundaries are access control boundaries — not just folders.
The analyst role physically cannot query `RAW`. No grant exists. That's the enforcement.

Naming: `RAW → STAGING → MARTS` is the Snowflake + dbt ecosystem convention.
`Bronze/Silver/Gold` is the Databricks/lakehouse convention. Using the right vocabulary
for the right platform is itself a signal of fluency.

---

## Every feature mapped to its production scenario

**`VARIANT` + `LATERAL FLATTEN`**
FHIR resources are nested JSON — arrays inside objects inside arrays. A relational
table can't land them without pre-shredding, which breaks when the upstream schema
changes. Landing as `VARIANT` means the pipeline keeps running when a vendor adds
an optional extension field at 2am. You shred what you need with `LATERAL FLATTEN`
and ignore the rest until you want it.
This is why Snowflake wins on semi-structured data — and the single biggest
differentiator between Concord and a generic "load CSV" project.

**External Stage + `COPY INTO`**
Source systems drop files into cloud storage on their own schedule. `COPY INTO`
bulk-loads them efficiently — it tracks which files have already been loaded
(via load metadata) so rerunning the command never double-loads. This is the
standard payer ingestion pattern for EDI drops, FHIR exports, and vendor feeds.

**Two warehouses (workload isolation)**
`CONCORD_LOAD_WH` handles ingestion bursts. `CONCORD_TRANSFORM_WH` handles
steady dbt + query workloads. One shared warehouse means a heavy backfill
queues behind a dashboard query — or vice versa. Separate warehouses = separate
compute pools = no contention. Resizing one doesn't affect the other.

**`AUTO_SUSPEND = 60` + `INITIALLY_SUSPENDED = TRUE`**
Snowflake bills per second with a 60-second minimum per resume. A warehouse left
running overnight burns credits with zero work done. Setting suspend to 60 seconds
means at most 2 minutes of idle billing per session. `INITIALLY_SUSPENDED` prevents
credit burn the moment `CREATE WAREHOUSE` executes. These two settings together
are the most impactful cost levers on a Snowflake account.

**RBAC with `FUTURE GRANTS`**
`CONCORD_ANALYST` has `SELECT` on `MARTS` tables — existing and future.
Without `GRANT SELECT ON FUTURE TABLES`, every new table you create next week
is silently invisible to the analyst until someone manually re-grants. That
gap causes dashboard failures. `FUTURE GRANTS` make new objects inherit access
automatically. This is the difference between RBAC that works at scale and
RBAC that breaks on week three.

**dbt for all transforms**
dbt gives transforms version control, tests, lineage docs, and a standard
execution model. A `not_null` test on `member_id` catching a null mid-pipeline
is the difference between a data quality incident and a prevented one.
dbt snapshots handle SCD Type 2 — Slowly Changing Dimensions — without
manual merge logic. The snapshot is declarative; dbt handles the history rows.

**SCD Type 2 on `dim_member`**
Member plans change — they switch coverage, change PCPs, update demographics.
Claims adjudication depends on "what was the member's plan at the time of service,"
not what it is today. Overwriting the current row loses that answer. SCD2 adds
`valid_from`, `valid_to`, and `is_current` columns so you can always reconstruct
the state at any point in time. dbt snapshots generate this automatically.

**Dynamic Data Masking (Enterprise feature)**
`DOB`, `SSN`, `member_name` columns in `MARTS` are masked for the analyst role —
they see `***-**-XXXX` instead of real values. The engineer role sees the full
value. The mask is applied at query time by a policy object, not by storing
separate masked copies. This is HIPAA minimum-necessary at the column level,
enforced by the platform — not by trusting people to be careful.

**Row-Access Policies**
Scopes which *rows* a role can see — e.g., an analyst for Plan A cannot see
members from Plan B even if they can see the table. Applied on top of masking.
Together these two policies are what a compliance audit checks first.

**Streams + Tasks (CDC)**
A Stream on a staging table captures every insert/update/delete since the last
consume. A Task runs on a schedule and propagates only those changed rows to
the mart. This means adding one new claim doesn't reload 10 million rows.
At scale, full reloads become untenable — CDC is the prod pattern.
Tasks are demonstrated then suspended to avoid continuous credit burn in trial.

**`_INTERNAL.PIPELINE_LOG`**
Every load and transform writes one row: step name, source, rows loaded,
rows rejected, status, error message, role, warehouse. When something fails at
3am, this table is opened first. It's also how you prove to a stakeholder that
last night's load ran and brought in 4,832 claims. Without it, the answer to
"did the pipeline run?" is "let me check query history" — which is not an answer.

**Streamlit-in-Snowflake**
The ops dashboard lives inside Snowflake — no separate hosting, no auth to manage.
Shows pipeline run history, row counts per step, mart freshness. The dashboard
queries `PIPELINE_LOG` and the marts directly. Built-in, always current.

---

## RBAC diagram

```
ACCOUNTADMIN       → billing + account config only (never builds objects)
  └── SYSADMIN     → owns all Concord infrastructure objects
        ├── CONCORD_ENGINEER   → builds pipelines, owns all schemas
        └── CONCORD_ANALYST    → SELECT on MARTS only, PHI masked
USERADMIN          → creates roles
SECURITYADMIN      → grants privileges
```

---

## Cost management design

| Decision | Credit impact |
|---|---|
| XS warehouses only | 1 credit/hr vs 2 (S), 4 (M) — correct for this data volume |
| `AUTO_SUSPEND = 60` | Max ~2 min idle billing per session |
| `INITIALLY_SUSPENDED` | Zero burn on warehouse creation |
| Two separate warehouses | Right-size each independently; no shared contention |
| Tasks suspended after demo | Continuous Tasks burn credits on a schedule |
| Small data volume | Storage cost is negligible; compute is the only meter |

Expected total trial consumption for the full build: well under 40 credits.
