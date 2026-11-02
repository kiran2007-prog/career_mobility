-- =============================================================================
-- 03_employee_data.sql
-- Career Mobility & Employee Transition Analytics (100% PostgreSQL)
--
-- PURPOSE
--   Generates 5,000 SYNTHETIC employees using only SQL (generate_series and
--   random()). Each employee gets an anonymous code, a college and a
--   graduation year. Careers (positions, salaries) come later in file 04.
--
-- RUN ORDER
--   Requires 01_schema.sql and 02_reference_data.sql.
--       psql -d career_mobility -f 03_employee_data.sql
--   Safe to re-run: it empties employees first (and, via CASCADE, any
--   employment/salary rows, so re-run file 04 afterwards).
--
-- DESIGN NOTES
--   * No names or personal details exist. employee_code (EMP-000001 ...) is
--     the only identifier, which keeps the dataset fully anonymous.
--   * setseed() makes the random data reproducible: re-running the file in the
--     same environment gives the same employees.
--   * Colleges are drawn in two steps: first a tier (tier 1 is rarer), then a
--     college inside that tier. The second draw is skewed toward low college_id
--     values, so a few colleges supply many employees and others few. (Which
--     colleges those are depends on the ids PostgreSQL assigned in file 02; it
--     is arbitrary but stable.) This avoids a flat, uniform distribution.
--   * About 4% of employees have college_id = NULL (diploma, self-taught or
--     not recorded). Their graduation_year is still filled and means "the year
--     they entered the workforce", so file 04 has a start point for everyone.
--   * Graduation years run 2005-2025 and skew recent, because most of a
--     growing workforce is early-career.
-- =============================================================================


BEGIN;

TRUNCATE TABLE employees RESTART IDENTITY CASCADE;

-- Reproducible randomness for everything generated below.
SELECT setseed(0.42);


-- -----------------------------------------------------------------------------
-- 1. GENERATE 5,000 EMPLOYEES
-- -----------------------------------------------------------------------------
WITH college_pool AS (
    -- One row per tier, holding every college id in that tier as an array.
    -- Picking array element k later is cheap and needs no per-row subquery.
    SELECT college_tier,
           array_agg(college_id ORDER BY college_id) AS college_ids
    FROM   colleges
    GROUP  BY college_tier
),
raw AS (
    -- One row per employee with independent random draws (each random() is
    -- evaluated once per row).
    SELECT n,
           random() AS r_tier,   -- decides the college tier
           random() AS r_pick,   -- decides which college inside the tier
           random() AS r_year    -- decides the graduation year
    FROM   generate_series(1, 5000) AS n
),
tiered AS (
    SELECT n, r_pick, r_year,
           CASE
               WHEN r_tier < 0.12 THEN 1      -- 12% tier 1
               WHEN r_tier < 0.60 THEN 2      -- 48% tier 2
               WHEN r_tier < 0.96 THEN 3      -- 36% tier 3
               ELSE NULL                      --  4% no college recorded
           END AS college_tier
    FROM   raw
)
INSERT INTO employees (employee_code, college_id, graduation_year)
SELECT 'EMP-' || lpad(t.n::text, 6, '0'),
       -- power(r, 1.4) pushes picks toward the start of the array, so some
       -- colleges produce noticeably more employees than others.
       cp.college_ids[1 + floor(power(t.r_pick, 1.4) * cardinality(cp.college_ids))::int],
       -- power(r, 1.3) skews toward 0, i.e. toward 2025 (recent graduates).
       (2025 - floor(power(t.r_year, 1.3) * 21))::smallint
FROM   tiered t
LEFT   JOIN college_pool cp ON cp.college_tier = t.college_tier
ORDER  BY t.n;

COMMIT;


-- =============================================================================
-- 2. VERIFICATION
-- =============================================================================

-- Expected: 5000 employees, 5000 distinct codes
SELECT count(*)                       AS employees,
       count(DISTINCT employee_code)  AS distinct_codes,
       count(*) FILTER (WHERE college_id IS NULL) AS no_college
FROM   employees;

-- Share of employees per college tier (expected roughly 12 / 48 / 36 / 4 %)
SELECT coalesce(c.college_tier::text, 'no college') AS college_tier,
       count(*)                                     AS employees,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM   employees e
LEFT   JOIN colleges c USING (college_id)
GROUP  BY c.college_tier
ORDER  BY c.college_tier NULLS LAST;

-- Graduation years: should skew toward recent years
SELECT graduation_year, count(*) AS employees
FROM   employees
GROUP  BY graduation_year
ORDER  BY graduation_year;

-- Top 5 and bottom 3 colleges by employee count (shows the uneven spread)
(SELECT c.college_name, c.college_tier, count(*) AS employees
 FROM   employees e JOIN colleges c USING (college_id)
 GROUP  BY c.college_name, c.college_tier
 ORDER  BY employees DESC LIMIT 5)
UNION ALL
(SELECT c.college_name, c.college_tier, count(*) AS employees
 FROM   employees e JOIN colleges c USING (college_id)
 GROUP  BY c.college_name, c.college_tier
 ORDER  BY employees ASC LIMIT 3);

SELECT COUNT(*) FROM employees;
