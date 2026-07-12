-- Model : stg_coverage
-- Source: CONCORD.RAW.COVERAGE
-- Output: CONCORD.STAGING.STG_COVERAGE

SELECT
    raw_data:member_id::STRING                                  AS member_id,
    raw_data:subscriber_id::STRING                              AS subscriber_id,
    -- nested object: plan is an object inside coverage
    raw_data:plan:plan_id::STRING                               AS plan_id,
    raw_data:plan:plan_name::STRING                             AS plan_name,
    raw_data:plan:plan_type::STRING                             AS plan_type,
    raw_data:plan:group_id::STRING                              AS group_id,
    TRY_CAST(raw_data:period:start::STRING AS DATE)             AS coverage_start,
    TRY_CAST(raw_data:period:end::STRING AS DATE)               AS coverage_end,
    raw_data:payor::STRING                                      AS payor,
    raw_data:line_of_business::STRING                           AS line_of_business,
    raw_data:status::STRING                                     AS status,
    source_file,
    loaded_at
FROM {{ source('raw', 'coverage') }}
WHERE raw_data:member_id::STRING IS NOT NULL