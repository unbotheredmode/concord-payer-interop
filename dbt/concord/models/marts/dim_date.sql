-- =============================================================================
-- Model : dim_date
-- Layer : MARTS
-- Source: Generated — no upstream dependency, pure SQL date spine
-- Output: CONCORD.MARTS.DIM_DATE
--
-- Why a date dimension exists:
--   Analysts constantly slice by month, quarter, year, weekday.
--   Without this: every query writes EXTRACT(MONTH FROM service_date) inline.
--   With this: JOIN dim_date ON service_date = date_day, GROUP BY month_name.
--   Pre-calculated attributes = clean queries, consistent logic, one place to fix.
--
-- Why generated not loaded:
--   A CSV date dimension goes stale. A generated one is always correct.
--   Change ROWCOUNT to extend the range — no file to update.
-- =============================================================================

WITH date_spine AS (
    -- Generate one row per day for 2024-2025 (730 days)
    -- SEQ4() produces sequential integers: 0, 1, 2, ... 729
    -- DATEADD adds that many days to the start date
    SELECT
        DATEADD(day, SEQ4(), '2024-01-01')::DATE AS date_day
    FROM TABLE(GENERATOR(ROWCOUNT => 731))
)

SELECT
    date_day,
    YEAR(date_day)                                          AS year,
    MONTH(date_day)                                         AS month_num,
    MONTHNAME(date_day)                                     AS month_name,
    QUARTER(date_day)                                       AS quarter_num,
    'Q' || QUARTER(date_day)                                AS quarter,
    DAYOFWEEK(date_day)                                     AS day_of_week_num,
    DAYNAME(date_day)                                       AS day_name,
    DAY(date_day)                                           AS day_of_month,
    DAYOFYEAR(date_day)                                     AS day_of_year,
    WEEKOFYEAR(date_day)                                    AS week_of_year,

    -- Boolean flags — pre-calculated so analysts never write CASE statements
    CASE WHEN DAYOFWEEK(date_day) IN (1, 7) THEN TRUE
         ELSE FALSE END                                     AS is_weekend,

    CASE WHEN DAYOFWEEK(date_day) NOT IN (1, 7) THEN TRUE
         ELSE FALSE END                                     AS is_weekday,

    -- Year-month key for easy monthly grouping: 202403, 202501 etc
    -- Analysts use this instead of GROUP BY year, month separately
    YEAR(date_day) * 100 + MONTH(date_day)                 AS year_month_key,

    -- First day of month/quarter — useful for period-to-date calculations
    DATE_TRUNC('month', date_day)::DATE                     AS first_day_of_month,
    DATE_TRUNC('quarter', date_day)::DATE                   AS first_day_of_quarter

FROM date_spine
ORDER BY date_day