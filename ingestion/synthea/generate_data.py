"""
Concord — Synthetic Healthcare Data Generator
File   : ingestion/synthea/generate_data.py
Purpose: Generate realistic FHIR-shaped synthetic data for the Concord platform.
         Produces 4 JSON files that land in Snowflake RAW as VARIANT.

Why synthetic data?
    Real patient data requires HIPAA BAAs, de-identification processes, and
    legal agreements. Real teams use synthetic data generators for development,
    testing, and portfolio work. The shape and relationships mirror production
    data exactly — only the values are fake.

Why FHIR-shaped JSON?
    FHIR (Fast Healthcare Interoperability Resources) is the standard format
    modern payers and providers exchange data in. Landing it as VARIANT in
    Snowflake and shredding it with LATERAL FLATTEN is the real ingestion
    pattern — not loading CSVs. This is what differentiates the project.

Output files (written to data/):
    patients.json       — Patient demographics (FHIR Patient-like structure)
    claims.json         — Medical claims (FHIR ExplanationOfBenefit-like)
    coverage.json       — Insurance coverage / enrollment (FHIR Coverage-like)
    prior_auth.json     — Prior authorization requests + decisions
"""

import json
import random
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from faker import Faker

# ── Configuration ─────────────────────────────────────────────────────────────
SEED            = 42        # fixed seed = reproducible data every run
NUM_PATIENTS    = 500       # members in our synthetic payer population
NUM_CLAIMS      = 2000      # claims (avg 4 per member — realistic for a year)
NUM_PA          = 400       # prior auth requests (~20% of claims need PA)
OUTPUT_DIR      = Path("data")

# ── Seed randomness for reproducibility ───────────────────────────────────────
# Why: reproducible data means your Snowflake load is idempotent —
#      running generate_data.py twice produces identical files.
#      In prod, deterministic test data is essential for debugging pipelines.
random.seed(SEED)
fake = Faker()
Faker.seed(SEED)

OUTPUT_DIR.mkdir(exist_ok=True)

# ── Reference data ─────────────────────────────────────────────────────────────
# Real payer systems use code sets. Using real codes makes your staging
# transforms realistic — you'll parse and validate these just like prod.

DIAGNOSIS_CODES = [
    {"code": "E11.9",  "display": "Type 2 diabetes mellitus without complications"},
    {"code": "I10",    "display": "Essential (primary) hypertension"},
    {"code": "J06.9",  "display": "Acute upper respiratory infection, unspecified"},
    {"code": "M54.5",  "display": "Low back pain"},
    {"code": "F32.9",  "display": "Major depressive disorder, single episode, unspecified"},
    {"code": "E78.5",  "display": "Hyperlipidemia, unspecified"},
    {"code": "J18.9",  "display": "Pneumonia, unspecified organism"},
    {"code": "N39.0",  "display": "Urinary tract infection, site not specified"},
    {"code": "K21.0",  "display": "Gastro-esophageal reflux disease with esophagitis"},
    {"code": "Z00.00", "display": "Encounter for general adult medical examination"},
]

PROCEDURE_CODES = [
    {"code": "99213", "display": "Office visit, established patient, low complexity"},
    {"code": "99214", "display": "Office visit, established patient, moderate complexity"},
    {"code": "99232", "display": "Subsequent hospital care"},
    {"code": "93000", "display": "Electrocardiogram, routine ECG"},
    {"code": "71046", "display": "Radiologic exam, chest, 2 views"},
    {"code": "80053", "display": "Comprehensive metabolic panel"},
    {"code": "90834", "display": "Psychotherapy, 45 minutes"},
    {"code": "27447", "display": "Total knee arthroplasty"},
    {"code": "43239", "display": "Upper GI endoscopy with biopsy"},
    {"code": "70553", "display": "MRI brain with contrast"},
]

PLAN_TYPES    = ["Medicare Advantage", "Medicaid MCO", "Commercial PPO", "Commercial HMO"]
CLAIM_STATUSES = ["active", "cancelled", "entered-in-error"]
PA_STATUSES    = ["approved", "denied", "pending", "appealed"]
PLACE_OF_SERVICE = ["11", "21", "22", "23"]  # Office, Inpatient, Outpatient, ER


# ── Helper functions ────────────────────────────────────────────────────────────

def random_date(start_year=2024, end_year=2025):
    """Generate a random date in the given year range."""
    start = datetime(start_year, 1, 1)
    end   = datetime(end_year, 12, 31)
    return start + timedelta(days=random.randint(0, (end - start).days))

def random_npi():
    """Generate a realistic-looking 10-digit NPI number."""
    return f"1{random.randint(100000000, 999999999)}"

def random_member_id():
    return f"MBR{random.randint(100000, 999999)}"

def random_claim_id():
    return f"CLM{uuid.uuid4().hex[:10].upper()}"


# ── 1. Generate Patients ───────────────────────────────────────────────────────
# FHIR Patient resource structure (simplified but realistic)
# In prod, payers receive these from enrollment feeds and CMS
print(f"Generating {NUM_PATIENTS} patients...")
patients = []
member_ids = []

for _ in range(NUM_PATIENTS):
    member_id  = random_member_id()
    dob        = fake.date_of_birth(minimum_age=18, maximum_age=85)
    gender     = random.choice(["male", "female"])
    state      = fake.state_abbr()
    plan_type  = random.choice(PLAN_TYPES)
    enrolled   = random_date(2023, 2024)

    member_ids.append(member_id)

    patients.append({
        "resourceType": "Patient",
        "id": str(uuid.uuid4()),
        "member_id": member_id,
        "name": [{
            "use": "official",
            "family": fake.last_name(),
            "given":  [fake.first_name()]
        }],
        "birthDate": str(dob),
        "gender": gender,
        "address": [{
            "state":      state,
            "postalCode": fake.zipcode(),
            "country":    "US"
        }],
        "enrollment": {
            "plan_type":       plan_type,
            "enrollment_date": str(enrolled.date()),
            "pcp_npi":         random_npi(),
            "line_of_business": plan_type.split()[0]  # "Medicare", "Medicaid", "Commercial"
        },
        "meta": {
            "source":       "enrollment_feed",
            "lastUpdated":  datetime.now().isoformat()
        }
    })

# ── 2. Generate Coverage ───────────────────────────────────────────────────────
# FHIR Coverage resource — links member to their insurance plan
# This is the enrollment record a payer holds
print("Generating coverage records...")
coverage_records = []

for patient in patients:
    start_date = datetime.strptime(
        patient["enrollment"]["enrollment_date"], "%Y-%m-%d"
    )
    end_date = start_date + timedelta(days=365)

    coverage_records.append({
        "resourceType": "Coverage",
        "id": str(uuid.uuid4()),
        "member_id":   patient["member_id"],
        "status":      "active",
        "subscriber_id": f"SUB{random.randint(100000, 999999)}",
        "plan": {
            "plan_id":    f"PLAN{random.randint(1000, 9999)}",
            "plan_name":  patient["enrollment"]["plan_type"],
            "plan_type":  patient["enrollment"]["plan_type"],
            "group_id":   f"GRP{random.randint(10000, 99999)}"
        },
        "period": {
            "start": str(start_date.date()),
            "end":   str(end_date.date())
        },
        "payor": "Concord Health Plan",
        "line_of_business": patient["enrollment"]["line_of_business"],
        "meta": {
            "source":      "enrollment_feed",
            "lastUpdated": datetime.now().isoformat()
        }
    })

# ── 3. Generate Claims ─────────────────────────────────────────────────────────
# FHIR ExplanationOfBenefit (EOB) structure — the adjudicated claim record
# This is what payers produce after processing a provider's claim submission
print(f"Generating {NUM_CLAIMS} claims...")
claims = []
claim_ids = []

for _ in range(NUM_CLAIMS):
    member_id     = random.choice(member_ids)
    dx            = random.choice(DIAGNOSIS_CODES)
    proc          = random.choice(PROCEDURE_CODES)
    service_date  = random_date(2024, 2025)
    billed        = round(random.uniform(150, 15000), 2)
    allowed       = round(billed * random.uniform(0.4, 0.85), 2)
    paid          = round(allowed * random.uniform(0.7, 0.95), 2)
    claim_id      = random_claim_id()
    claim_ids.append(claim_id)
    needs_pa      = random.random() < 0.20   # 20% of claims require prior auth

    claims.append({
        "resourceType":   "ExplanationOfBenefit",
        "id":             str(uuid.uuid4()),
        "claim_id":       claim_id,
        "member_id":      member_id,
        "status":         random.choices(
                            CLAIM_STATUSES,
                            weights=[90, 7, 3]   # 90% active, 7% cancelled, 3% error
                          )[0],
        "type":           random.choice(["professional", "institutional", "pharmacy"]),
        "service_date":   str(service_date.date()),
        "provider": {
            "npi":        random_npi(),
            "name":       fake.company(),
            "specialty":  random.choice([
                            "Internal Medicine", "Family Medicine",
                            "Cardiology", "Orthopedics", "Psychiatry",
                            "Emergency Medicine", "Radiology"
                          ])
        },
        "diagnosis": [{
            "sequence": 1,
            "code":     dx["code"],
            "display":  dx["display"],
            "system":   "ICD-10-CM"
        }],
        "procedure": [{
            "sequence": 1,
            "code":     proc["code"],
            "display":  proc["display"],
            "system":   "CPT"
        }],
        "financials": {
            "billed_amount":  billed,
            "allowed_amount": allowed,
            "paid_amount":    paid,
            "member_liability": round(allowed - paid, 2),
            "currency":       "USD"
        },
        "place_of_service": random.choice(PLACE_OF_SERVICE),
        "requires_prior_auth": needs_pa,
        "meta": {
            "source":       "claims_adjudication",
            "lastUpdated":  datetime.now().isoformat()
        }
    })

# ── 4. Generate Prior Auth Records ────────────────────────────────────────────
# Prior authorization requests — submitted by providers, decided by the payer
# This drives the PA metrics mart (approval rates, turnaround time, etc.)
print(f"Generating {NUM_PA} prior auth records...")
prior_auths = []

# PA-eligible procedure codes (higher-cost, often require authorization)
PA_PROCEDURES = [
    {"code": "27447", "display": "Total knee arthroplasty"},
    {"code": "70553", "display": "MRI brain with contrast"},
    {"code": "43239", "display": "Upper GI endoscopy with biopsy"},
    {"code": "90834", "display": "Psychotherapy, 45 minutes"},
    {"code": "71250", "display": "CT thorax with contrast"},
    {"code": "93306", "display": "Echocardiography with Doppler"},
]

for _ in range(NUM_PA):
    member_id      = random.choice(member_ids)
    proc           = random.choice(PA_PROCEDURES)
    submitted_date = random_date(2024, 2025)
    status         = random.choices(
                       PA_STATUSES,
                       weights=[65, 20, 10, 5]  # 65% approved, 20% denied, 10% pending, 5% appealed
                     )[0]

    # Decision date: approved/denied get decided; pending stays open
    if status in ("approved", "denied"):
        decision_days = random.randint(1, 14)
        decision_date = submitted_date + timedelta(days=decision_days)
    elif status == "appealed":
        decision_days = random.randint(15, 30)
        decision_date = submitted_date + timedelta(days=decision_days)
    else:
        decision_date = None
        decision_days = None

    prior_auths.append({
        "pa_id":          f"PA{uuid.uuid4().hex[:8].upper()}",
        "member_id":      member_id,
        "requesting_npi": random_npi(),
        "procedure": {
            "code":    proc["code"],
            "display": proc["display"],
            "system":  "CPT"
        },
        "diagnosis_code": random.choice(DIAGNOSIS_CODES)["code"],
        "submitted_date": str(submitted_date.date()),
        "decision_date":  str(decision_date.date()) if decision_date else None,
        "decision_days":  decision_days,
        "status":         status,
        "denial_reason":  random.choice([
                            "Not medically necessary",
                            "Requires step therapy",
                            "Out of network",
                            "Missing documentation"
                          ]) if status in ("denied", "appealed") else None,
        "appeal_outcome": random.choice(["overturned", "upheld"]) if status == "appealed" else None,
        "urgency":        random.choice(["routine", "urgent", "emergent"]),
        "meta": {
            "source":      "pa_system",
            "lastUpdated": datetime.now().isoformat()
        }
    })

# ── Write output files ─────────────────────────────────────────────────────────
# One JSON record per line (newline-delimited JSON / NDJSON)
# Why NDJSON and not a JSON array?
#   Snowflake's COPY INTO with JSON file format expects one record per line.
#   A JSON array would require loading as a single VARIANT row and then
#   flattening the array — extra complexity. NDJSON = one row per line = clean.
#   This is the standard format for bulk JSON ingestion across all major
#   cloud data warehouses (Snowflake, BigQuery, Redshift).

files = {
    "patients.json":    patients,
    "claims.json":      claims,
    "coverage.json":    coverage_records,
    "prior_auth.json":  prior_auths,
}

print("\nWriting output files...")
for filename, records in files.items():
    path = OUTPUT_DIR / filename
    with open(path, "w", encoding="utf-8") as f:
        for record in records:
            f.write(json.dumps(record) + "\n")
    print(f"  ✓ {filename}: {len(records):,} records → {path}")

print(f"""
Done. Summary:
  Patients  : {len(patients):,}
  Coverage  : {len(coverage_records):,}
  Claims    : {len(claims):,}
  Prior Auth: {len(prior_auths):,}

Files are in data/ — gitignored, never committed.
Next step: load these into Snowflake RAW via COPY INTO.
""")
