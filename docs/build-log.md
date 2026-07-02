# Build Log

One entry per phase. Updated at the end of each working session.
Format: date · what was built · decisions made · issues hit + fixes · commit · credits used.

This log exists because production platforms are built incrementally, and the reasoning
behind each decision is as important as the code itself.

---

## Phase 0 — Platform Foundation ✅
**Date:** 2026-07-01
**What:**
- Suspended default `COMPUTE_WH` immediately (was running, burning credits)
- Created `CONCORD_LOAD_WH` + `CONCORD_TRANSFORM_WH`: XS, auto-suspend 60s, initially suspended
- Created database `CONCORD` with schemas: `RAW`, `STAGING`, `MARTS`, `_INTERNAL`
- Built RBAC skeleton: `CONCORD_ENGINEER` + `CONCORD_ANALYST` roles, rolled up to `SYSADMIN`
- Applied `FUTURE GRANTS` on all schemas so new tables auto-inherit access
- Created `_INTERNAL.PIPELINE_LOG` audit table with seed entry

**Key decisions:**
- Built under `SYSADMIN`, never `ACCOUNTADMIN` — ownership hygiene
- Two warehouses by workload type, not by project — workload isolation pattern
- `FUTURE GRANTS` on every schema — prevents silent access gaps on new tables
- Analyst role has zero access to `RAW` or `STAGING` — PHI boundary enforced at schema level

**Issues hit:** `COMPUTE_WH` was already running when account was first opened — burned ~$3 before noticed. Suspended immediately.

**Commit:** `feat: Day 1 — platform foundation (warehouses, schemas, RBAC, audit log)`
**Credits used:** ~3 (default warehouse, pre-setup)

---

## Phase 1 — RAW Layer (FHIR ingestion → VARIANT) 🚧
- **Date:**
- **What:**
- **Decisions:**
- **Issues:**
- **Commit:**
- **Credits used:**

---

## Phase 2 — STAGING Layer (LATERAL FLATTEN → conformed)
- **Date:**
- **What:**
- **Decisions:**
- **Issues:**
- **Commit:**
- **Credits used:**

---

## Phase 3 — MARTS (star schema + PA metrics)  ← demoable milestone
- **Date:**
- **What:**
- **Decisions:**
- **Issues:**
- **Commit:**
- **Credits used:**

---

## Phase 4 — Governance (dynamic masking + row-access)
- **Date:**
- **What:**
- **Decisions:**
- **Issues:**
- **Commit:**
- **Credits used:**

---

## Phase 5 — dbt (models, SCD2 snapshot, tests, docs)
- **Date:**
- **What:**
- **Decisions:**
- **Issues:**
- **Commit:**
- **Credits used:**

---

## Phase 6 — CDC + Streamlit (Streams/Tasks + observability dashboard)
- **Date:**
- **What:**
- **Decisions:**
- **Issues:**
- **Commit:**
- **Credits used:**

---

## Credit tracker

| Date | Session | Credits before | Credits after | Delta |
|---|---|---|---|---|
| 2026-07-01 | Phase 0 setup | $400 | $397 | $3 (default WH, pre-setup) |
