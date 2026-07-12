-- Model : stg_patients
-- Source: CONCORD.RAW.PATIENTS
-- Output: CONCORD.STAGING.STG_PATIENTS

SELECT
    raw_data:member_id::STRING                                          AS member_id,
    TRY_CAST(raw_data:birthDate::STRING AS DATE)                        AS dob,
    raw_data:gender::STRING                                             AS gender,
    -- address is an array — [0] gets the first (and only) address
    raw_data:address[0]:state::STRING                                   AS state,
    raw_data:address[0]:postalCode::STRING                              AS zip_code,
    raw_data:enrollment:plan_type::STRING                               AS plan_type,
    TRY_CAST(raw_data:enrollment:enrollment_date::STRING AS DATE)       AS enrollment_date,
    raw_data:enrollment:pcp_npi::STRING                                 AS pcp_npi,
    raw_data:enrollment:line_of_business::STRING                        AS line_of_business,
    source_file,
    loaded_at
FROM {{ source('raw', 'patients') }}
WHERE raw_data:member_id::STRING IS NOT NULL