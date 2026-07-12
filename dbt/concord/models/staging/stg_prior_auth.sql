-- Model : stg_prior_auth
-- Source: CONCORD.RAW.PRIOR_AUTH
-- Output: CONCORD.STAGING.STG_PRIOR_AUTH

SELECT
    raw_data:pa_id::STRING                                      AS pa_id,
    raw_data:member_id::STRING                                  AS member_id,
    raw_data:requesting_npi::STRING                             AS requesting_npi,
    -- procedure is a nested object
    raw_data:procedure:code::STRING                             AS procedure_code,
    raw_data:diagnosis_code::STRING                             AS diagnosis_code,
    TRY_CAST(raw_data:submitted_date::STRING AS DATE)           AS submitted_date,
    -- decision_date is NULL for pending records — TRY_CAST handles this cleanly
    TRY_CAST(raw_data:decision_date::STRING AS DATE)            AS decision_date,
    TRY_CAST(raw_data:decision_days::STRING AS NUMBER(5))       AS decision_days,
    raw_data:status::STRING                                     AS status,
    raw_data:denial_reason::STRING                              AS denial_reason,
    raw_data:appeal_outcome::STRING                             AS appeal_outcome,
    raw_data:urgency::STRING                                    AS urgency,
    source_file,
    loaded_at
FROM {{ source('raw', 'prior_auth') }}
WHERE raw_data:pa_id::STRING IS NOT NULL
  AND raw_data:member_id::STRING IS NOT NULL