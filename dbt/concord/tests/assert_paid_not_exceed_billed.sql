-- Custom test: paid_amount should never exceed billed_amount
-- If this returns any rows, the test FAILS and dbt stops
-- In prod: indicates adjudication system bug, triggers audit review

SELECT
    claim_id,
    billed_amount,
    paid_amount,
    paid_amount - billed_amount AS overpayment_amount
FROM {{ ref('stg_claims') }}
WHERE paid_amount > billed_amount 