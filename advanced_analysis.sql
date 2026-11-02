-- =============================================================================
-- 06_advanced_analysis.sql
-- Career Mobility & Employee Transition Analytics (100% PostgreSQL)
--
-- PURPOSE
--   The advanced analytical questions: window functions (LAG, LEAD, RANK,
--   DENSE_RANK, ROW_NUMBER), a recursive CTE, ROLLUP, percentiles and
--   conditional aggregation.
--     Q10 What are the most common career paths?
--     Q11 Which job roles have the highest switching frequency?
--     Q13 Which transitions produce the highest salary growth?
--     Q14 How much does salary change after switching companies?
--     Q15 Which employees changed both company and job role?
--     Q16 Which employees moved between industries?
--     Q17 Which employees moved between locations?
--     Q18 What percentage of employees leave a company within a given period?
--     Q19 What are the most common first > second > third company paths?
--     Q20 How has employee mobility changed over time?
--   Extra questions that add real value:
--     Q21 Unemployment gaps: how long, after which kind of exit, who is out now
--     Q22 Career progression: does the first employer type affect seniority growth?
--   (Q1-Q9 and Q12 are in 05_basic_analysis.sql.)
--
-- RUN ORDER
--   Requires 01 to 04. It does NOT need file 05: it builds its own helper
--   tables (a richer version of the same ones, so running 05 afterwards in the
--   same session still works).
--       psql -d career_mobility -f 06_advanced_analysis.sql
--   Read-only on the real tables; the temp tables vanish with your session.
--
-- DEFINITIONS (same as file 05)
--   Position    one employment_history row (a promotion starts a new one).
--   Stint       an unbroken run of positions at the SAME company.
--   Transition  a move between two stints at DIFFERENT companies.
--   Real exit   a position ended by resigned / laid_off / terminated /
--               contract_end / retired (NOT 'internal_move' = promotion).
--   As-of date  2026-10-24 (year 2026 is therefore incomplete).
--
-- NOTE ON \echo
--   The \echo lines only label the output in psql. In a GUI tool, delete them.
-- =============================================================================

SET client_min_messages = warning;

DROP TABLE IF EXISTS tmp_paths, tmp_transitions, tmp_stints, tmp_as_of;


-- =============================================================================
-- 0. HELPER TABLES (temporary)
-- =============================================================================

CREATE TEMP TABLE tmp_as_of AS
SELECT DATE '2026-10-24' AS as_of;

-- -----------------------------------------------------------------------------
-- tmp_stints: one row per employee per unbroken run at a company
-- ("gaps and islands": LAG marks where a new stint starts, a running SUM
-- numbers the stints, GROUP BY collapses each stint to one row).
-- stint_end is NULL while the stint is still running.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE tmp_stints AS
WITH marked AS (
    SELECT eh.*,
           CASE WHEN lag(eh.company_id) OVER w IS DISTINCT FROM eh.company_id
                THEN 1 ELSE 0 END AS starts_new_stint
    FROM   employment_history eh
    WINDOW w AS (PARTITION BY eh.employee_id ORDER BY eh.start_date)
),
numbered AS (
    SELECT m.*,
           sum(starts_new_stint) OVER (PARTITION BY employee_id
                                       ORDER BY start_date) AS stint_no
    FROM   marked m
)
SELECT employee_id,
       stint_no::int                                          AS stint_no,
       company_id,
       min(start_date)                                        AS stint_start,
       CASE WHEN bool_or(end_date IS NULL) THEN NULL
            ELSE max(end_date) END                            AS stint_end,
       count(*)                                               AS positions,
       (array_agg(employment_id ORDER BY start_date))[1]      AS first_employment_id,
       (array_agg(employment_id ORDER BY start_date DESC))[1] AS last_employment_id,
       (array_agg(role_id       ORDER BY start_date))[1]      AS first_role_id,
       (array_agg(role_id       ORDER BY start_date DESC))[1] AS last_role_id,
       (array_agg(location_id   ORDER BY start_date))[1]      AS first_location_id,
       (array_agg(location_id   ORDER BY start_date DESC))[1] AS last_location_id,
       (array_agg(separation_type ORDER BY start_date DESC))[1] AS exit_reason
FROM   numbered
GROUP  BY employee_id, stint_no, company_id;

-- -----------------------------------------------------------------------------
-- tmp_transitions: one row per company-to-company move, with everything the
-- questions below need: companies, types, industries, roles, seniority,
-- families, cities, tenure before, gap, and salary before/after.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE tmp_transitions AS
WITH paired AS (
    SELECT s.employee_id,
           s.stint_no                              AS to_stint_no,
           lag(s.company_id)         OVER w        AS from_company_id,
           s.company_id                            AS to_company_id,
           lag(s.stint_start)        OVER w        AS from_start,
           lag(s.stint_end)          OVER w        AS left_date,
           s.stint_start                           AS joined_date,
           lag(s.last_role_id)       OVER w        AS from_role_id,
           s.first_role_id                         AS to_role_id,
           lag(s.last_location_id)   OVER w        AS from_location_id,
           s.first_location_id                     AS to_location_id,
           lag(s.last_employment_id) OVER w        AS from_last_employment_id,
           s.first_employment_id                   AS to_first_employment_id,
           lag(s.exit_reason)        OVER w        AS exit_reason
    FROM   tmp_stints s
    WINDOW w AS (PARTITION BY s.employee_id ORDER BY s.stint_no)
)
SELECT p.employee_id,
       p.to_stint_no,
       p.from_company_id,
       p.to_company_id,
       fc.company_type                AS from_company_type,
       tc.company_type                AS to_company_type,
       fc.industry_id                 AS from_industry_id,
       tc.industry_id                 AS to_industry_id,
       p.left_date,
       p.joined_date,
       (p.left_date - p.from_start)   AS tenure_before_days,
       (p.joined_date - p.left_date)  AS gap_days,
       p.from_role_id,
       p.to_role_id,
       fr.seniority_level             AS from_level,
       tr.seniority_level             AS to_level,
       fr.job_family                  AS from_family,
       tr.job_family                  AS to_family,
       p.from_location_id,
       p.to_location_id,
       fl.city_tier                   AS from_city_tier,
       tl.city_tier                   AS to_city_tier,
       p.exit_reason,
       sb.annual_salary               AS salary_before,
       sa.annual_salary               AS salary_after,
       round(100.0 * (sa.annual_salary - sb.annual_salary)
             / sb.annual_salary, 2)   AS salary_change_pct
FROM   paired p
JOIN   companies fc ON fc.company_id = p.from_company_id
JOIN   companies tc ON tc.company_id = p.to_company_id
JOIN   job_roles fr ON fr.role_id    = p.from_role_id
JOIN   job_roles tr ON tr.role_id    = p.to_role_id
JOIN   locations fl ON fl.location_id = p.from_location_id
JOIN   locations tl ON tl.location_id = p.to_location_id
CROSS  JOIN LATERAL (
           SELECT annual_salary FROM salary_history
           WHERE  employment_id = p.from_last_employment_id
           ORDER  BY effective_date DESC LIMIT 1) sb
CROSS  JOIN LATERAL (
           SELECT annual_salary FROM salary_history
           WHERE  employment_id = p.to_first_employment_id
           ORDER  BY effective_date ASC  LIMIT 1) sa
WHERE  p.from_company_id IS NOT NULL;

SELECT (SELECT count(*) FROM tmp_stints)      AS company_stints,
       (SELECT count(*) FROM tmp_transitions) AS company_transitions;


-- =============================================================================
-- Q10. MOST COMMON CAREER PATHS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- tmp_paths: every consecutive chain of 2 to 4 stints, built with a RECURSIVE
-- CTE.  A whole career at 53 companies is almost never repeated, but short
-- chains inside careers are. Starting from every stint, the recursion keeps
-- appending the employee's NEXT stint until the chain has 4 companies. That
-- finds a chain wherever it occurs in a career (first jobs or later), which a
-- plain GROUP BY on the whole career cannot do.
--   company_path : 'Infosys > TCS > Amazon'
--   type_path    : 'it_services > it_services > big_tech'
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE tmp_paths AS
WITH RECURSIVE walk AS (
    SELECT s.employee_id,
           s.stint_no                  AS first_no,
           s.stint_no                  AS last_no,
           1                           AS len,
           c.company_name::text        AS company_path,
           c.company_type::text        AS type_path
    FROM   tmp_stints s
    JOIN   companies c USING (company_id)

    UNION ALL

    SELECT w.employee_id,
           w.first_no,
           s.stint_no,
           w.len + 1,
           w.company_path || ' > ' || c.company_name,
           w.type_path    || ' > ' || c.company_type
    FROM   walk w
    JOIN   tmp_stints s ON s.employee_id = w.employee_id
                       AND s.stint_no    = w.last_no + 1
    JOIN   companies c  ON c.company_id  = s.company_id
    WHERE  w.len < 4
)
SELECT * FROM walk WHERE len >= 2;

WITH career_types AS (
    SELECT s.employee_id,
           count(*) AS companies,
           'College > ' || string_agg(c.company_type, ' > ' ORDER BY s.stint_no) AS type_path
    FROM   tmp_stints s
    JOIN   companies c USING (company_id)
    GROUP  BY s.employee_id
)
SELECT type_path,
       count(*)                                           AS employees,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct_of_multi_company_careers
FROM   career_types
WHERE  companies >= 2
GROUP  BY type_path
ORDER  BY employees DESC, type_path
LIMIT  12;

SELECT company_path                       AS three_company_chain,
       count(*)                           AS employees
FROM   tmp_paths
WHERE  len = 3
GROUP  BY company_path
ORDER  BY employees DESC, company_path
LIMIT  10;

SELECT type_path                          AS three_step_type_chain,
       count(*)                           AS employees
FROM   tmp_paths
WHERE  len = 3
GROUP  BY type_path
ORDER  BY employees DESC, type_path
LIMIT  10;

SELECT p.pattern,
       count(DISTINCT w.employee_id)                                    AS employees,
       round(100.0 * count(DISTINCT w.employee_id)
             / (SELECT count(*) FROM (SELECT employee_id FROM tmp_stints
                                      GROUP BY employee_id
                                      HAVING count(*) >= 3) x), 2)      AS pct_of_careers_with_3plus_companies
FROM  (VALUES ('startup > product > big_tech'),
              ('startup > it_services > product'),
              ('it_services > product > big_tech'),
              ('it_services > it_services > big_tech'),
              ('it_services > it_services > product'),
              ('consulting > product > big_tech'),
              ('bank_finance > it_services > product')) AS p(pattern)
LEFT   JOIN tmp_paths w ON w.len = 3 AND w.type_path = p.pattern
GROUP  BY p.pattern
ORDER  BY employees DESC;


-- =============================================================================
-- Q11. Which job roles have the highest switching frequency?
--      Switching frequency = real company exits per 100 years spent in the
--      role. RANK() ranks all roles, and again inside each job family.
--      (Exits include layoffs; promotions are excluded.)
-- =============================================================================
WITH role_stats AS (
    SELECT r.role_title,
           r.job_family,
           r.seniority_level,
           sum(COALESCE(eh.end_date, a.as_of) - eh.start_date) / 365.25 AS role_years,
           count(*) FILTER (WHERE eh.end_date IS NOT NULL
                              AND eh.separation_type <> 'internal_move') AS company_exits
    FROM   employment_history eh
    JOIN   job_roles r USING (role_id)
    CROSS  JOIN tmp_as_of a
    GROUP  BY r.role_id, r.role_title, r.job_family, r.seniority_level
    HAVING sum(COALESCE(eh.end_date, a.as_of) - eh.start_date) / 365.25 >= 300
),
rated AS (
    SELECT *, 100.0 * company_exits / role_years AS exits_per_100_role_years
    FROM   role_stats
)
SELECT role_title,
       job_family,
       seniority_level                                  AS level,
       round(role_years)::int                           AS role_years,
       company_exits,
       round(exits_per_100_role_years, 1)               AS exits_per_100_role_years,
       RANK() OVER (ORDER BY exits_per_100_role_years DESC)                          AS rank_overall,
       RANK() OVER (PARTITION BY job_family ORDER BY exits_per_100_role_years DESC)  AS rank_in_family
FROM   rated
ORDER  BY rank_overall
LIMIT  12;


-- =============================================================================
-- Q13. Which transitions produce the highest salary growth?
--      DENSE_RANK() gives tied averages the same rank without leaving gaps.
-- =============================================================================
WITH pairs AS (
    SELECT fc.company_name AS from_company,
           tc.company_name AS to_company,
           count(*)                         AS moves,
           round(avg(t.salary_change_pct), 1) AS avg_salary_change_pct
    FROM   tmp_transitions t
    JOIN   companies fc ON fc.company_id = t.from_company_id
    JOIN   companies tc ON tc.company_id = t.to_company_id
    GROUP  BY fc.company_name, tc.company_name
    HAVING count(*) >= 20
)
SELECT from_company, to_company, moves, avg_salary_change_pct,
       DENSE_RANK() OVER (ORDER BY avg_salary_change_pct DESC) AS growth_rank
FROM   pairs
ORDER  BY growth_rank, from_company, to_company
LIMIT  12;

WITH type_pairs AS (
    SELECT from_company_type, to_company_type,
           count(*)                           AS moves,
           round(avg(salary_change_pct), 1)   AS avg_salary_change_pct,
           round((percentile_cont(0.5) WITHIN GROUP (ORDER BY salary_change_pct))::numeric, 1)
                                              AS median_salary_change_pct
    FROM   tmp_transitions
    GROUP  BY from_company_type, to_company_type
    HAVING count(*) >= 30
)
SELECT from_company_type, to_company_type, moves,
       avg_salary_change_pct, median_salary_change_pct,
       DENSE_RANK() OVER (ORDER BY avg_salary_change_pct DESC) AS growth_rank
FROM   type_pairs
ORDER  BY growth_rank
LIMIT  10;

SELECT from_company_type, to_company_type,
       count(*)                         AS moves,
       round(avg(salary_change_pct), 1) AS avg_salary_change_pct,
       round(100.0 * count(*) FILTER (WHERE salary_change_pct < 0) / count(*), 1) AS pct_with_pay_cut
FROM   tmp_transitions
GROUP  BY from_company_type, to_company_type
HAVING count(*) >= 30
ORDER  BY avg(salary_change_pct) ASC
LIMIT  5;


-- =============================================================================
-- Q14. How much does salary change after switching companies?
-- =============================================================================
SELECT count(*)                                                          AS moves,
       round(avg(salary_change_pct), 1)                                  AS avg_pct,
       round((percentile_cont(0.25) WITHIN GROUP (ORDER BY salary_change_pct))::numeric, 1) AS p25_pct,
       round((percentile_cont(0.50) WITHIN GROUP (ORDER BY salary_change_pct))::numeric, 1) AS median_pct,
       round((percentile_cont(0.75) WITHIN GROUP (ORDER BY salary_change_pct))::numeric, 1) AS p75_pct,
       round(100.0 * count(*) FILTER (WHERE salary_change_pct < 0) / count(*), 1) AS pct_with_pay_cut,
       round(100.0 * count(*) FILTER (WHERE salary_change_pct >= 30) / count(*), 1) AS pct_with_30plus_raise
FROM   tmp_transitions;

SELECT CASE WHEN to_level > from_level THEN '1: moved UP in seniority'
            WHEN to_level = from_level THEN '2: same seniority'
            ELSE                            '3: moved DOWN in seniority' END AS seniority_change,
       count(*)                         AS moves,
       round(avg(salary_change_pct), 1) AS avg_salary_change_pct
FROM   tmp_transitions
GROUP  BY 1
ORDER  BY 1;

SELECT CASE WHEN gap_days = 0   THEN '1: direct move (no gap)'
            WHEN gap_days <= 90 THEN '2: gap up to 3 months'
            WHEN gap_days <= 270 THEN '3: gap 3 to 9 months'
            ELSE                      '4: gap over 9 months' END AS time_between_jobs,
       count(*)                         AS moves,
       round(avg(salary_change_pct), 1) AS avg_salary_change_pct
FROM   tmp_transitions
GROUP  BY 1
ORDER  BY 1;

SELECT exit_reason,
       count(*)                         AS moves,
       round(avg(salary_change_pct), 1) AS avg_salary_change_pct,
       round(avg(gap_days), 0)          AS avg_gap_days
FROM   tmp_transitions
GROUP  BY exit_reason
ORDER  BY moves DESC;


-- =============================================================================
-- Q15. Which employees changed BOTH company and job role?
-- =============================================================================
SELECT count(*)                                                    AS company_switches,
       count(*) FILTER (WHERE from_role_id <> to_role_id)          AS role_also_changed,
       round(100.0 * count(*) FILTER (WHERE from_role_id <> to_role_id) / count(*), 1) AS pct_role_changed,
       count(*) FILTER (WHERE from_family <> to_family)            AS job_family_changed,
       round(100.0 * count(*) FILTER (WHERE from_family <> to_family) / count(*), 1)  AS pct_family_changed,
       count(DISTINCT employee_id) FILTER (WHERE from_role_id <> to_role_id) AS employees_with_company_and_role_change,
       count(DISTINCT employee_id)                                 AS employees_who_switched
FROM   tmp_transitions;

SELECT e.employee_code,
       fc.company_name  AS from_company,
       fr.role_title    AS from_role,
       tc.company_name  AS to_company,
       tr.role_title    AS to_role,
       t.to_level - t.from_level AS levels_gained,
       t.salary_change_pct
FROM   tmp_transitions t
JOIN   employees e  USING (employee_id)
JOIN   companies fc ON fc.company_id = t.from_company_id
JOIN   companies tc ON tc.company_id = t.to_company_id
JOIN   job_roles fr ON fr.role_id    = t.from_role_id
JOIN   job_roles tr ON tr.role_id    = t.to_role_id
WHERE  t.from_role_id <> t.to_role_id
ORDER  BY levels_gained DESC, t.salary_change_pct DESC, e.employee_code
LIMIT  10;


-- =============================================================================
-- Q16. Which employees moved between industries?
-- =============================================================================
WITH per_employee AS (
    SELECT s.employee_id,
           count(*)                          AS companies,
           count(DISTINCT c.industry_id)     AS industries
    FROM   tmp_stints s
    JOIN   companies c USING (company_id)
    GROUP  BY s.employee_id
)
SELECT CASE WHEN companies = 1 THEN '0: only one company'
            WHEN industries = 1 THEN '1: several companies, one industry'
            WHEN industries = 2 THEN '2: two industries'
            ELSE                     '3: three or more industries' END AS industry_profile,
       count(*)                                            AS employees,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1)  AS pct_of_employees
FROM   per_employee
GROUP  BY 1
ORDER  BY 1;

WITH diverse AS (
    SELECT s.employee_id,
           count(DISTINCT c.industry_id) AS industries,
           string_agg(i.industry_name, ' > ' ORDER BY s.stint_no) AS industry_path
    FROM   tmp_stints s
    JOIN   companies  c USING (company_id)
    JOIN   industries i ON i.industry_id = c.industry_id
    GROUP  BY s.employee_id
)
SELECT e.employee_code, d.industries, d.industry_path
FROM   diverse d
JOIN   employees e USING (employee_id)
ORDER  BY d.industries DESC, e.employee_code
LIMIT  6;


-- =============================================================================
-- Q17. Which employees moved between locations?
-- =============================================================================
SELECT count(*)                                                           AS company_switches,
       count(*) FILTER (WHERE t.from_location_id <> t.to_location_id)     AS city_changed,
       round(100.0 * count(*) FILTER (WHERE t.from_location_id <> t.to_location_id)
             / count(*), 1)                                               AS pct_city_changed,
       count(*) FILTER (WHERE fl.state <> tl.state)                       AS state_changed,
       round(100.0 * count(*) FILTER (WHERE fl.state <> tl.state)
             / count(*), 1)                                               AS pct_state_changed,
       count(DISTINCT t.employee_id) FILTER (WHERE t.from_location_id <> t.to_location_id)
                                                                          AS employees_who_relocated
FROM   tmp_transitions t
JOIN   locations fl ON fl.location_id = t.from_location_id
JOIN   locations tl ON tl.location_id = t.to_location_id;

SELECT fl.city AS from_city,
       tl.city AS to_city,
       count(*) AS moves,
       round(avg(t.salary_change_pct), 1) AS avg_salary_change_pct
FROM   tmp_transitions t
JOIN   locations fl ON fl.location_id = t.from_location_id
JOIN   locations tl ON tl.location_id = t.to_location_id
WHERE  t.from_location_id <> t.to_location_id
GROUP  BY fl.city, tl.city
ORDER  BY moves DESC, from_city, to_city
LIMIT  10;

SELECT CASE WHEN from_location_id = to_location_id THEN '1: stayed in the same city'
            WHEN to_city_tier < from_city_tier      THEN '2: moved to a bigger city'
            WHEN to_city_tier = from_city_tier      THEN '3: moved to a similar-size city'
            ELSE                                         '4: moved to a smaller city' END AS relocation,
       count(*)                         AS moves,
       round(avg(salary_change_pct), 1) AS avg_salary_change_pct
FROM   tmp_transitions
GROUP  BY 1
ORDER  BY 1;


-- =============================================================================
-- Q18. What percentage of employees leave a company within a given period?
--      Only hires old enough to be observed for the whole period are counted.
--      ROLLUP adds the all-companies total row.
-- =============================================================================
SELECT COALESCE(c.company_type, 'ALL COMPANIES') AS company_type,
       count(*) FILTER (WHERE s.stint_start <= a.as_of - INTERVAL '3 years') AS hires_observed_3y,
       round(100.0 * count(*) FILTER (
                 WHERE s.stint_start <= a.as_of - INTERVAL '1 year'
                   AND s.stint_end < s.stint_start + INTERVAL '1 year')
             / NULLIF(count(*) FILTER (
                 WHERE s.stint_start <= a.as_of - INTERVAL '1 year'), 0), 1) AS left_within_1y_pct,
       round(100.0 * count(*) FILTER (
                 WHERE s.stint_start <= a.as_of - INTERVAL '2 years'
                   AND s.stint_end < s.stint_start + INTERVAL '2 years')
             / NULLIF(count(*) FILTER (
                 WHERE s.stint_start <= a.as_of - INTERVAL '2 years'), 0), 1) AS left_within_2y_pct,
       round(100.0 * count(*) FILTER (
                 WHERE s.stint_start <= a.as_of - INTERVAL '3 years'
                   AND s.stint_end < s.stint_start + INTERVAL '3 years')
             / NULLIF(count(*) FILTER (
                 WHERE s.stint_start <= a.as_of - INTERVAL '3 years'), 0), 1) AS left_within_3y_pct
FROM   tmp_stints s
JOIN   companies c USING (company_id)
CROSS  JOIN tmp_as_of a
GROUP  BY ROLLUP (c.company_type)
ORDER  BY GROUPING(c.company_type), left_within_3y_pct DESC;

SELECT CASE WHEN s.stint_no = 1 THEN 'first job (campus/entry hire)'
            ELSE 'joined from another company' END AS how_they_joined,
       count(*) FILTER (WHERE s.stint_start <= a.as_of - INTERVAL '2 years') AS hires_observed_2y,
       round(100.0 * count(*) FILTER (
                 WHERE s.stint_start <= a.as_of - INTERVAL '2 years'
                   AND s.stint_end < s.stint_start + INTERVAL '2 years')
             / NULLIF(count(*) FILTER (
                 WHERE s.stint_start <= a.as_of - INTERVAL '2 years'), 0), 1) AS left_within_2y_pct
FROM   tmp_stints s
CROSS  JOIN tmp_as_of a
GROUP  BY 1
ORDER  BY 1;


-- =============================================================================
-- Q19. Most common first > second > third company paths.
--      ROW_NUMBER() numbers each employee's stints; conditional aggregation
--      (FILTER) pivots rows 1, 2 and 3 into columns.
-- =============================================================================
WITH numbered AS (
    SELECT employee_id,
           company_id,
           row_number() OVER (PARTITION BY employee_id ORDER BY stint_start) AS nth_company
    FROM   tmp_stints
),
first_three AS (
    SELECT employee_id,
           max(company_id) FILTER (WHERE nth_company = 1) AS first_company_id,
           max(company_id) FILTER (WHERE nth_company = 2) AS second_company_id,
           max(company_id) FILTER (WHERE nth_company = 3) AS third_company_id
    FROM   numbered
    WHERE  nth_company <= 3
    GROUP  BY employee_id
)
SELECT c1.company_name AS first_company,
       c2.company_name AS second_company,
       c3.company_name AS third_company,
       count(*)        AS employees
FROM   first_three f
JOIN   companies c1 ON c1.company_id = f.first_company_id
JOIN   companies c2 ON c2.company_id = f.second_company_id
JOIN   companies c3 ON c3.company_id = f.third_company_id
GROUP  BY c1.company_name, c2.company_name, c3.company_name
ORDER  BY employees DESC, first_company, second_company, third_company
LIMIT  12;


-- =============================================================================
-- Q20. How has employee mobility changed over time?
--      employed  = employees with a position active at some point in the year
--      LAG() gives the previous year's rate to show the year-on-year change.
--      2026 is incomplete (data ends 2026-10-24).
-- =============================================================================
WITH years AS (
    SELECT generate_series(2010, 2026) AS yr
),
active AS (
    SELECT y.yr, count(DISTINCT eh.employee_id) AS employed
    FROM   years y
    JOIN   employment_history eh
           ON  eh.start_date <= make_date(y.yr, 12, 31)
           AND COALESCE(eh.end_date, DATE '9999-12-31') > make_date(y.yr, 1, 1)
    GROUP  BY y.yr
),
exits AS (
    SELECT EXTRACT(year FROM end_date)::int AS yr,
           count(*)                                          AS exits,
           count(*) FILTER (WHERE separation_type = 'laid_off') AS layoffs
    FROM   employment_history
    WHERE  end_date IS NOT NULL AND separation_type <> 'internal_move'
    GROUP  BY 1
),
moves AS (
    SELECT EXTRACT(year FROM joined_date)::int AS yr, count(*) AS company_changes
    FROM   tmp_transitions
    GROUP  BY 1
),
yearly AS (
    SELECT a.yr,
           a.employed,
           COALESCE(m.company_changes, 0) AS company_changes,
           COALESCE(x.exits, 0)           AS exits,
           COALESCE(x.layoffs, 0)         AS layoffs,
           round(100.0 * COALESCE(m.company_changes, 0) / a.employed, 1) AS changes_per_100_employed
    FROM   active a
    LEFT   JOIN moves m USING (yr)
    LEFT   JOIN exits x USING (yr)
)
SELECT yr AS year, employed, company_changes, exits, layoffs,
       changes_per_100_employed,
       round(changes_per_100_employed
             - lag(changes_per_100_employed) OVER (ORDER BY yr), 1) AS change_vs_prev_year
FROM   yearly
ORDER  BY yr;

SELECT EXTRACT(year FROM joined_date)::int                       AS year_of_move,
       count(*)                                                  AS moves,
       round(avg(salary_change_pct), 1)                          AS avg_salary_change_pct,
       round(100.0 * count(*) FILTER (WHERE to_company_type = 'big_tech') / count(*), 1) AS pct_moving_to_big_tech
FROM   tmp_transitions
WHERE  joined_date >= DATE '2012-01-01'
GROUP  BY 1
ORDER  BY 1;


-- =============================================================================
-- Q21. Unemployment gaps (derived, never stored).
--      LEAD() looks at the employee's NEXT position; the gap is the time
--      between this position's end_date and the next one's start_date.
--      A position that ended with no next position = currently unemployed.
-- =============================================================================
WITH gaps AS (
    SELECT eh.employee_id,
           eh.end_date,
           eh.separation_type,
           lead(eh.start_date) OVER w - eh.end_date AS gap_days
    FROM   employment_history eh
    WINDOW w AS (PARTITION BY eh.employee_id ORDER BY eh.start_date)
)
SELECT separation_type,
       count(*)                                                       AS exits_with_a_next_job,
       count(*) FILTER (WHERE gap_days > 0)                           AS followed_by_a_gap,
       round(100.0 * count(*) FILTER (WHERE gap_days > 0) / count(*), 1) AS pct_with_gap,
       round(avg(gap_days) FILTER (WHERE gap_days > 0) / 30.44, 1)    AS avg_gap_months,
       max(gap_days)                                                  AS longest_gap_days
FROM   gaps
WHERE  gap_days IS NOT NULL
  AND  separation_type <> 'internal_move'
GROUP  BY separation_type
ORDER  BY exits_with_a_next_job DESC;

WITH last_position AS (
    SELECT eh.employee_id, eh.company_id, eh.end_date, eh.separation_type,
           row_number() OVER (PARTITION BY eh.employee_id
                              ORDER BY eh.start_date DESC) AS rn
    FROM   employment_history eh
)
SELECT e.employee_code,
       c.company_name                                      AS last_company,
       lp.separation_type                                  AS how_it_ended,
       lp.end_date                                         AS left_on,
       round((a.as_of - lp.end_date) / 30.44, 1)           AS months_unemployed
FROM   last_position lp
JOIN   employees e USING (employee_id)
JOIN   companies c USING (company_id)
CROSS  JOIN tmp_as_of a
WHERE  lp.rn = 1
  AND  lp.end_date IS NOT NULL
ORDER  BY months_unemployed DESC, e.employee_code
LIMIT  8;

WITH last_position AS (
    SELECT eh.employee_id, eh.end_date, eh.separation_type,
           row_number() OVER (PARTITION BY eh.employee_id
                              ORDER BY eh.start_date DESC) AS rn
    FROM   employment_history eh
)
SELECT count(*)                                                      AS unemployed_now,
       round(100.0 * count(*) / (SELECT count(*) FROM employees), 1) AS pct_of_all_employees,
       round(avg(a.as_of - lp.end_date) / 30.44, 1)                  AS avg_months_unemployed,
       round(100.0 * count(*) FILTER (WHERE lp.separation_type = 'laid_off')
             / count(*), 1)                                          AS pct_laid_off
FROM   last_position lp
CROSS  JOIN tmp_as_of a
WHERE  lp.rn = 1 AND lp.end_date IS NOT NULL;


-- =============================================================================
-- Q22. Career progression: does the TYPE of first employer affect how fast
--      seniority grows?  For each employee, ROW_NUMBER() (ascending and
--      descending) finds the first and the latest position. Only employees
--      with 5+ years of experience are compared, so recent graduates do not
--      distort the averages. (This describes the data; it does not prove cause:
--      college tier also drives where people start.)
-- =============================================================================
WITH ranked AS (
    SELECT eh.employee_id,
           r.seniority_level                                                  AS lvl,
           eh.start_date,
           row_number() OVER (PARTITION BY eh.employee_id ORDER BY eh.start_date)      AS rn_first,
           row_number() OVER (PARTITION BY eh.employee_id ORDER BY eh.start_date DESC) AS rn_latest
    FROM   employment_history eh
    JOIN   job_roles r USING (role_id)
),
per_employee AS (
    SELECT employee_id,
           max(lvl)        FILTER (WHERE rn_first  = 1) AS first_level,
           max(lvl)        FILTER (WHERE rn_latest = 1) AS latest_level,
           min(start_date)                              AS career_start
    FROM   ranked
    GROUP  BY employee_id
)
SELECT c.company_type                                            AS first_employer_type,
       count(*)                                                  AS employees,
       round(avg((a.as_of - p.career_start) / 365.25), 1)        AS avg_years_experience,
       round(avg(p.latest_level), 2)                             AS avg_current_level,
       round(avg((p.latest_level - p.first_level)
                 / ((a.as_of - p.career_start) / 365.25)), 2)    AS avg_levels_gained_per_year
FROM   per_employee p
JOIN   tmp_stints s ON s.employee_id = p.employee_id AND s.stint_no = 1
JOIN   companies c  ON c.company_id  = s.company_id
CROSS  JOIN tmp_as_of a
WHERE  (a.as_of - p.career_start) / 365.25 >= 5
GROUP  BY c.company_type
HAVING count(*) >= 30
ORDER  BY avg_levels_gained_per_year DESC;
