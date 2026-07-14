-- =============================================================================
-- Model : dim_provider
-- Layer : MARTS
-- Source: RAW.CLAIMS — provider details embedded in claim JSON
-- Output: CONCORD.MARTS.DIM_PROVIDER
--
-- Why source from RAW not stg_claims:
--   stg_claims already extracted provider_npi but dropped name and specialty
--   (we kept only the FK in staging — descriptive detail belongs in the dim).
--   Going back to RAW gives us the full provider object.
--
-- Why DISTINCT:
--   2000 claims, ~200 unique providers. Each provider appears ~10 times.
--   DISTINCT on all three columns deduplicates to one row per NPI.
--   This is the standard pattern when a dimension is embedded in a fact source.
-- =============================================================================

WITH raw_providers AS (
    SELECT DISTINCT
        raw_data:provider:npi::STRING           AS provider_npi,
        raw_data:provider:name::STRING          AS provider_name,
        raw_data:provider:specialty::STRING     AS provider_specialty
    FROM {{ source('raw', 'claims') }}
    WHERE raw_data:provider:npi::STRING IS NOT NULL
)

SELECT
    provider_npi,
    provider_name,
    provider_specialty
FROM raw_providers