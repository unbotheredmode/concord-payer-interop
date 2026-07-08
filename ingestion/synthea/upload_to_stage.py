"""
Concord — Upload Data Files to Snowflake Stage
File   : ingestion/synthea/upload_to_stage.py
Purpose: PUT local NDJSON files into the Snowflake internal stage.
         After this, COPY INTO will load them into RAW VARIANT tables.

Why a separate script for upload vs. generate?
    Separation of concerns — a real pipeline has distinct steps:
    extract → stage → load. Each step can be rerun independently.
    If the load fails, you don't regenerate the data — you just re-run
    the load against what's already staged.

Why PUT instead of SnowSQL CLI?
    snowflake-connector-python's execute() supports PUT natively.
    No separate tool to install. Same connector your Airflow operators
    and Lambda functions would use in production.
"""

import json
import os
from pathlib import Path
import snowflake.connector

# ── Load connection config ─────────────────────────────────────────────────────
# Config file is gitignored — credentials never in code or version control.
# In prod this would come from environment variables, AWS Secrets Manager,
# Azure Key Vault, or HashiCorp Vault. JSON config is fine for local dev.

config_path = Path("snowflake_config.json")
if not config_path.exists():
    raise FileNotFoundError(
        "snowflake_config.json not found. "
        "Create it in the repo root with your Snowflake credentials."
    )

with open(config_path) as f:
    cfg = json.load(f)

# ── Connect ────────────────────────────────────────────────────────────────────
print("Connecting to Snowflake...")
conn = snowflake.connector.connect(
    account   = cfg["account"],
    user      = cfg["user"],
    password  = cfg["password"],
    role      = cfg["role"],
    warehouse = cfg["warehouse"],
    database  = cfg["database"],
    schema    = cfg["schema"]
)
cur = conn.cursor()
print(f"  Connected as: {cfg['user']} / {cfg['role']}")

# ── Set context explicitly ─────────────────────────────────────────────────────
# Never assume context — always set it explicitly in scripts.
# If someone runs this under a different role, it fails loudly rather than
# silently loading into the wrong schema.
cur.execute("USE ROLE CONCORD_ENGINEER")
cur.execute("USE DATABASE CONCORD")
cur.execute("USE SCHEMA RAW")
cur.execute("USE WAREHOUSE CONCORD_LOAD_WH")

# ── Upload files via PUT ───────────────────────────────────────────────────────
# PUT syntax: PUT file://local/path @stage_name
# AUTO_COMPRESS = TRUE: Snowflake compresses files on upload (gzip).
#   Compressed files load faster and cost less storage — always use it.
# OVERWRITE = TRUE: re-uploading the same filename replaces it.
#   Without this, a second run would skip already-staged files.
#   In prod you'd think carefully about this — for dev, overwrite is fine.
# PARALLEL = 4: number of threads for upload. Fine for local; prod teams
#   tune this based on file size and network.

data_dir = Path("data")
files_to_upload = [
    "patients.json",
    "claims.json",
    "coverage.json",
    "prior_auth.json",
]

stage = "@RAW.CONCORD_RAW_STAGE"

print(f"\nUploading files to {stage}...")
for filename in files_to_upload:
    filepath = data_dir / filename
    if not filepath.exists():
        print(f"  ✗ MISSING: {filepath} — run generate_data.py first")
        continue

    # PUT requires forward slashes even on Windows
    put_path = str(filepath.resolve()).replace("\\", "/")
    sql = f"PUT 'file://{put_path}' {stage} AUTO_COMPRESS=TRUE OVERWRITE=TRUE PARALLEL=4"

    print(f"  Uploading {filename}...", end=" ")
    cur.execute(sql)
    result = cur.fetchone()
    # Result columns: source, target, source_size, target_size, source_compression,
    #                 target_compression, status, message
    status  = result[6] if result else "UNKNOWN"
    src_size = result[2] if result else 0
    tgt_size = result[3] if result else 0
    print(f"{status} ({src_size:,} bytes → {tgt_size:,} bytes compressed)")

# ── Verify: list what's in the stage ──────────────────────────────────────────
print(f"\nFiles currently in {stage}:")
cur.execute(f"LIST {stage}")
rows = cur.fetchall()
for row in rows:
    # Columns: name, size, md5, last_modified
    print(f"  {row[0]}  ({row[1]:,} bytes)")

if not rows:
    print("  (empty — something went wrong)")

# ── Log to pipeline audit table ───────────────────────────────────────────────
# Every step writes to PIPELINE_LOG — this is the observability pattern.
cur.execute("""
    INSERT INTO CONCORD._INTERNAL.PIPELINE_LOG
        (step_name, source, rows_loaded, status, message)
    VALUES
        ('raw.stage_upload', 'local_files', %s, 'SUCCESS',
         'Uploaded patients, claims, coverage, prior_auth to CONCORD_RAW_STAGE')
""", (len(files_to_upload),))

print("\n✓ Logged to PIPELINE_LOG")
print("Next step: run COPY INTO in Snowsight to load staged files into RAW tables.")

cur.close()
conn.close()
