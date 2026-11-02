-- =============================================================================
-- 05_basic_analysis.sql
-- Career Mobility & Employee Transition Analytics (100% PostgreSQL)
--
-- PURPOSE
--   Answers the first group of analytical questions with joins, GROUP BY,
--   HAVING, CASE, FILTER, subqueries and CTEs:
--     Q1  Which companies have the highest employee outflow?
--     Q2  Which companies have the highest employee inflow?
--     Q3  What are the most common company-to-company transitions?
--         (with frequency, % of outgoing, % of incoming, tenure before the
--          move, salary change and time between jobs)
--     Q4  Where do employees from a particular company usually move?
--     Q5  Which companies are major talent SOURCES?
--     Q6  Which companies are major talent DESTINATIONS?
--     Q7  What is the average tenure at each company?
--     Q8  Which companies have the highest retention?
--     Q9  Which employees have switched companies the most?
--     Q12 Which industries experience the most employee movement?
--   Questions 10, 11 and 13-20 (career paths, salary growth, role/industry/
--   location changes, mobility over time) are in 06_advanced_analysis.sql.
--
-- RUN ORDER
--   Requires 01 to 04.   psql -d career_mobility -f 05_basic_analysis.sql
--   Read-only on the real tables. It creates three TEMP tables (below) that
--   disappear when your session ends. File 07 turns the same logic into
--   permanent views.
--
-- KEY DEFINITIONS (used consistently in every query)
--   Position    one row of employment_history (a promotion = a new position).
--   Stint       an unbroken run of positions at the SAME company. Tenure at a
--               company is measured per stint, so a promotion does not reset it.
--   Real exit   a position that ended with resigned / laid_off / terminated /
--               contract_end / retired. 'internal_move' (a promotion) is NOT an
--               exit.
--   Transition  a move from one company to a DIFFERENT company: the stint
--               before and the stint after. Someone laid off who has not been
--               hired again has an exit but no transition yet.
--   Tenure      completed stints only in averages (stints still running would
--               understate it). Retention handles running stints separately.
--   As-of date  2026-10-24, the "today" of the dataset.

SET client_min_messages = warning;

DROP TABLE IF EXISTS tmp_transitions, tmp_stints, tmp_as_of;


-- =============================================================================
-- 0. HELPER TABLES (temporary)
-- =============================================================================

-- The dataset's "today"
CREATE TEMP TABLE tmp_as_of AS
SELECT DATE '2026-10-24' AS as_of;

-- -----------------------------------------------------------------------------
-- tmp_stints: one row per employee per unbroken run at a company.
--   Technique ("gaps and islands"):
--     1. LAG() marks a position as the START of a new stint when its company
--        differs from the previous position's company.
--     2. A running SUM() of those marks numbers the stints 1, 2, 3 ...
--     3. GROUP BY collapses each stint to one row.
--   stint_end is NULL while the stint is still running.
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
       stint_no::int                                         AS stint_no,
       company_id,
       min(start_date)                                       AS stint_start,
       CASE WHEN bool_or(end_date IS NULL) THEN NULL
            ELSE max(end_date) END                           AS stint_end,
       count(*)                                              AS positions,
       (array_agg(employment_id ORDER BY start_date))[1]     AS first_employment_id,
       (array_agg(employment_id ORDER BY start_date DESC))[1] AS last_employment_id,
       (array_agg(role_id       ORDER BY start_date))[1]     AS first_role_id,
       (array_agg(role_id       ORDER BY start_date DESC))[1] AS last_role_id,
       (array_agg(location_id   ORDER BY start_date))[1]     AS first_location_id,
       (array_agg(location_id   ORDER BY start_date DESC))[1] AS last_location_id,
       (array_agg(separation_type ORDER BY start_date DESC))[1] AS exit_reason
FROM   numbered
GROUP  BY employee_id, stint_no, company_id;

-- -----------------------------------------------------------------------------
-- tmp_transitions: one row per company-to-company move.
--   Pairs every stint with the previous stint of the same employee (LAG), then
--   derives the facts of the move:
--     tenure_before_days : time spent at the company being left
--     gap_days           : time between jobs (0 = direct move)
--     salary_before      : last salary at the old company
--     salary_after       : first salary at the new company
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
       p.left_date,
       p.joined_date,
       (p.left_date - p.from_start)   AS tenure_before_days,
       (p.joined_date - p.left_date)  AS gap_days,
       p.from_role_id,
       p.to_role_id,
       p.from_location_id,
       p.to_location_id,
       p.exit_reason,
       sb.annual_salary               AS salary_before,
       sa.annual_salary               AS salary_after
FROM   paired p
CROSS  JOIN LATERAL (
           SELECT annual_salary FROM salary_history
           WHERE  employment_id = p.from_last_employment_id
           ORDER  BY effective_date DESC LIMIT 1) sb
CROSS  JOIN LATERAL (
           SELECT annual_salary FROM salary_history
           WHERE  employment_id = p.to_first_employment_id
           ORDER  BY effective_date ASC  LIMIT 1) sa
WHERE  p.from_company_id IS NOT NULL;

SELECT (SELECT count(*) FROM employees)             AS employees,
       (SELECT count(*) FROM employment_history)    AS positions,
       (SELECT count(*) FROM tmp_stints)            AS company_stints,
       (SELECT count(*) FROM tmp_transitions)       AS company_transitions,
       (SELECT count(DISTINCT employee_id) FROM tmp_transitions) AS employees_who_switched;


-- =============================================================================
-- Q1. Which companies have the highest employee OUTFLOW?
--     Outflow = real exits (promotions excluded). Raw counts favour big
--     companies, so 1b also shows the exit RATE per 100 employee-years.
-- =============================================================================
SELECT c.company_name,
       c.company_type,
       count(*)                                                        AS exits,
       count(*) FILTER (WHERE eh.separation_type = 'resigned')         AS resigned,
       count(*) FILTER (WHERE eh.separation_type = 'laid_off')         AS laid_off,
       count(*) FILTER (WHERE eh.separation_type
                        IN ('terminated', 'contract_end', 'retired'))  AS other_exits,
       round(100.0 * count(*) FILTER (WHERE eh.separation_type = 'laid_off')
             / count(*), 1)                                            AS pct_laid_off
FROM   employment_history eh
JOIN   companies c USING (company_id)
WHERE  eh.end_date IS NOT NULL
  AND  eh.separation_type <> 'internal_move'
GROUP  BY c.company_id, c.company_name, c.company_type
ORDER  BY exits DESC, c.company_name
LIMIT  10;

WITH company_years AS (
    SELECT eh.company_id,
           sum(COALESCE(eh.end_date, a.as_of) - eh.start_date) / 365.25 AS employee_years
    FROM   employment_history eh
    CROSS  JOIN tmp_as_of a
    GROUP  BY eh.company_id
)
SELECT c.company_name,
       c.company_type,
       count(*)                                        AS exits,
       round(cy.employee_years)::int                   AS employee_years,
       round(100.0 * count(*) / cy.employee_years, 1)  AS exits_per_100_employee_years
FROM   employment_history eh
JOIN   companies     c  USING (company_id)
JOIN   company_years cy USING (company_id)
WHERE  eh.end_date IS NOT NULL
  AND  eh.separation_type <> 'internal_move'
GROUP  BY c.company_id, c.company_name, c.company_type, cy.employee_years
HAVING cy.employee_years >= 1000
ORDER  BY exits_per_100_employee_years DESC
LIMIT  10;


-- =============================================================================
-- Q2. Which companies have the highest employee INFLOW?
--     Inflow = hires, split into people arriving from another company and
--     people whose first-ever job it is (graduate hiring).
-- =============================================================================

WITH hires AS (
    SELECT to_company_id AS company_id,
           count(*)      AS from_other_companies,
           0::bigint     AS first_job
    FROM   tmp_transitions
    GROUP  BY to_company_id
    UNION ALL
    SELECT company_id, 0, count(*)
    FROM   tmp_stints
    WHERE  stint_no = 1
    GROUP  BY company_id
)
SELECT c.company_name,
       c.company_type,
       sum(h.from_other_companies + h.first_job)::int AS total_hires,
       sum(h.from_other_companies)::int               AS from_other_companies,
       sum(h.first_job)::int                          AS first_job_hires
FROM   hires h
JOIN   companies c USING (company_id)
GROUP  BY c.company_id, c.company_name, c.company_type
ORDER  BY total_hires DESC, c.company_name
LIMIT  10;

WITH flow AS (
    SELECT c.company_id, c.company_name, c.company_type,
           (SELECT count(*) FROM tmp_transitions t WHERE t.to_company_id   = c.company_id) AS gained,
           (SELECT count(*) FROM tmp_transitions t WHERE t.from_company_id = c.company_id) AS lost
    FROM   companies c
)
SELECT company_name, company_type, gained, lost, gained - lost AS net_flow
FROM   flow
ORDER  BY net_flow DESC, company_name
LIMIT  8;

WITH flow AS (
    SELECT c.company_id, c.company_name, c.company_type,
           (SELECT count(*) FROM tmp_transitions t WHERE t.to_company_id   = c.company_id) AS gained,
           (SELECT count(*) FROM tmp_transitions t WHERE t.from_company_id = c.company_id) AS lost
    FROM   companies c
)
SELECT company_name, company_type, gained, lost, gained - lost AS net_flow
FROM   flow
ORDER  BY net_flow ASC, company_name
LIMIT  8;


-- =============================================================================
-- Q3. Most common company-to-company transitions, with:
--       transitions            how many people made this move
--       pct_of_from_outgoing   share of everyone who left the FROM company
--                              for another company
--       pct_of_to_incoming     share of everyone the TO company hired from
--                              other companies
--       avg_months_before      average time spent at the old company
--       avg_salary_change_pct  average pay change (last old vs first new)
--       avg_gap_days           average time between jobs (0 = direct move)
--     sum(count(*)) OVER (PARTITION BY ...) divides each group's count by its
--     company's total WITHOUT a second query.
-- =============================================================================

SELECT fc.company_name                                              AS from_company,
       tc.company_name                                              AS to_company,
       count(*)                                                     AS transitions,
       round(100.0 * count(*)
             / sum(count(*)) OVER (PARTITION BY t.from_company_id), 1) AS pct_of_from_outgoing,
       round(100.0 * count(*)
             / sum(count(*)) OVER (PARTITION BY t.to_company_id),   1) AS pct_of_to_incoming,
       round(avg(t.tenure_before_days) / 30.44, 1)                  AS avg_months_before,
       round(avg(100.0 * (t.salary_after - t.salary_before)
                 / t.salary_before), 1)                             AS avg_salary_change_pct,
       round(avg(t.gap_days), 1)                                    AS avg_gap_days
FROM   tmp_transitions t
JOIN   companies fc ON fc.company_id = t.from_company_id
JOIN   companies tc ON tc.company_id = t.to_company_id
GROUP  BY t.from_company_id, fc.company_name, t.to_company_id, tc.company_name
ORDER  BY transitions DESC, from_company, to_company
LIMIT  20;


-- =============================================================================
-- Q4. Where do employees from a particular company usually move?
--     Change the company name in the first CTE to explore any company.
-- =============================================================================

WITH chosen AS (
    SELECT company_id, company_name
    FROM   companies
    WHERE  company_name = 'Tata Consultancy Services'     -- <-- change me
)
SELECT ch.company_name                                          AS leaving_from,
       tc.company_name                                          AS moved_to,
       tc.company_type                                          AS destination_type,
       count(*)                                                 AS people,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1)       AS pct_of_leavers
FROM   chosen ch
JOIN   tmp_transitions t ON t.from_company_id = ch.company_id
JOIN   companies tc      ON tc.company_id     = t.to_company_id
GROUP  BY ch.company_name, tc.company_name, tc.company_type
ORDER  BY people DESC, moved_to
LIMIT  10;

WITH chosen AS (
    SELECT company_id, company_name
    FROM   companies
    WHERE  company_name = 'Tata Consultancy Services'     -- <-- change me
)
SELECT ch.company_name                                          AS leaving_from,
       tc.company_type                                          AS destination_type,
       count(*)                                                 AS people,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1)       AS pct_of_leavers,
       round(avg(100.0 * (t.salary_after - t.salary_before)
                 / t.salary_before), 1)                         AS avg_salary_change_pct
FROM   chosen ch
JOIN   tmp_transitions t ON t.from_company_id = ch.company_id
JOIN   companies tc      ON tc.company_id     = t.to_company_id
GROUP  BY ch.company_name, tc.company_type
ORDER  BY people DESC;


-- =============================================================================
-- Q5. Major talent SOURCES: companies whose people go on to other companies.
--     HAVING keeps only companies with enough moves to be meaningful.
-- =============================================================================

SELECT fc.company_name,
       fc.company_type,
       count(*)                                              AS people_sent_elsewhere,
       count(DISTINCT t.to_company_id)                       AS distinct_destinations,
       round(100.0 * count(*)
             / (SELECT count(*) FROM tmp_transitions), 1)    AS pct_of_all_moves,
       round(avg(t.tenure_before_days) / 30.44, 1)           AS avg_months_before_leaving
FROM   tmp_transitions t
JOIN   companies fc ON fc.company_id = t.from_company_id
GROUP  BY fc.company_id, fc.company_name, fc.company_type
HAVING count(*) >= 50
ORDER  BY people_sent_elsewhere DESC, fc.company_name
LIMIT  10;


-- =============================================================================
-- Q6. Major talent DESTINATIONS: companies that hire from other companies.
--     talent_magnet_ratio > 1 means it hires more from others than it loses.
-- =============================================================================
WITH lost AS (
    SELECT from_company_id AS company_id, count(*) AS people_lost
    FROM   tmp_transitions
    GROUP  BY from_company_id
)
SELECT tc.company_name,
       tc.company_type,
       count(*)                                              AS hired_from_other_companies,
       count(DISTINCT t.from_company_id)                     AS distinct_sources,
       round(100.0 * count(*)
             / (SELECT count(*) FROM tmp_transitions), 1)    AS pct_of_all_moves,
       round(avg(100.0 * (t.salary_after - t.salary_before)
                 / t.salary_before), 1)                      AS avg_salary_change_pct,
       round(count(*)::numeric / NULLIF(l.people_lost, 0), 2) AS talent_magnet_ratio
FROM   tmp_transitions t
JOIN   companies tc ON tc.company_id = t.to_company_id
LEFT   JOIN lost l  ON l.company_id  = t.to_company_id
GROUP  BY tc.company_id, tc.company_name, tc.company_type, l.people_lost
HAVING count(*) >= 50
ORDER  BY hired_from_other_companies DESC, tc.company_name
LIMIT  10;


-- =============================================================================
-- Q7. Average tenure at each company (completed stints only).
-- =============================================================================
SELECT c.company_name,
       c.company_type,
       count(*)                                                       AS completed_stints,
       round(avg(s.stint_end - s.stint_start) / 365.25, 2)            AS avg_tenure_years,
       round((percentile_cont(0.5) WITHIN GROUP
              (ORDER BY s.stint_end - s.stint_start) / 365.25)::numeric, 2) AS median_tenure_years
FROM   tmp_stints s
JOIN   companies c USING (company_id)
WHERE  s.stint_end IS NOT NULL
GROUP  BY c.company_id, c.company_name, c.company_type
HAVING count(*) >= 40
   AND avg(s.stint_end - s.stint_start)
         > (SELECT avg(stint_end - stint_start)      -- subquery: overall average
            FROM   tmp_stints WHERE stint_end IS NOT NULL)
ORDER  BY avg_tenure_years DESC
LIMIT  10;

SELECT c.company_name,
       c.company_type,
       count(*)                                            AS completed_stints,
       round(avg(s.stint_end - s.stint_start) / 365.25, 2) AS avg_tenure_years
FROM   tmp_stints s
JOIN   companies c USING (company_id)
WHERE  s.stint_end IS NOT NULL
GROUP  BY c.company_id, c.company_name, c.company_type
HAVING count(*) >= 40
ORDER  BY avg_tenure_years ASC
LIMIT  8;

WITH banded AS (
    SELECT c.company_type,
           CASE WHEN s.stint_end - s.stint_start <  365      THEN '1: under 1 year'
                WHEN s.stint_end - s.stint_start <  365 * 3  THEN '2: 1-3 years'
                WHEN s.stint_end - s.stint_start <  365 * 5  THEN '3: 3-5 years'
                ELSE                                              '4: 5+ years' END AS tenure_band
    FROM   tmp_stints s
    JOIN   companies c USING (company_id)
    WHERE  s.stint_end IS NOT NULL
)
SELECT company_type,
       count(*)                                                                AS stints,
       round(100.0 * count(*) FILTER (WHERE tenure_band = '1: under 1 year') / count(*), 1) AS pct_under_1y,
       round(100.0 * count(*) FILTER (WHERE tenure_band = '2: 1-3 years')    / count(*), 1) AS pct_1_to_3y,
       round(100.0 * count(*) FILTER (WHERE tenure_band = '3: 3-5 years')    / count(*), 1) AS pct_3_to_5y,
       round(100.0 * count(*) FILTER (WHERE tenure_band = '4: 5+ years')     / count(*), 1) AS pct_5y_plus
FROM   banded
GROUP  BY company_type
ORDER  BY pct_under_1y DESC;


-- =============================================================================
-- Q8. Which companies have the highest RETENTION?
--     N-year retention = of the people hired at least N years before the as-of
--     date, the share who were still there N years after joining.
--     Only hires old enough to have been observed for N years are counted,
--     otherwise recent hires would make every company look better than it is.
-- =============================================================================
SELECT c.company_name,
       c.company_type,
       count(*) FILTER (WHERE s.stint_start <= a.as_of - INTERVAL '3 years') AS hires_eligible_3y,
       round(100.0 * count(*) FILTER (
                 WHERE s.stint_start <= a.as_of - INTERVAL '1 year'
                   AND (s.stint_end IS NULL
                        OR s.stint_end >= s.stint_start + INTERVAL '1 year'))
             / NULLIF(count(*) FILTER (
                 WHERE s.stint_start <= a.as_of - INTERVAL '1 year'), 0), 1) AS retained_1y_pct,
       round(100.0 * count(*) FILTER (
                 WHERE s.stint_start <= a.as_of - INTERVAL '3 years'
                   AND (s.stint_end IS NULL
                        OR s.stint_end >= s.stint_start + INTERVAL '3 years'))
             / NULLIF(count(*) FILTER (
                 WHERE s.stint_start <= a.as_of - INTERVAL '3 years'), 0), 1) AS retained_3y_pct
FROM   tmp_stints s
JOIN   companies c USING (company_id)
CROSS  JOIN tmp_as_of a
GROUP  BY c.company_id, c.company_name, c.company_type
HAVING count(*) FILTER (WHERE s.stint_start <= a.as_of - INTERVAL '3 years') >= 50
ORDER  BY retained_3y_pct DESC
LIMIT  10;


-- =============================================================================
-- Q9. Which employees have switched companies the most?
--     switches = number of stints - 1. The CTE turns each career into a
--     readable company path with string_agg().
-- =============================================================================
WITH career_summary AS (
    SELECT s.employee_id,
           count(*) - 1                                   AS company_switches,
           string_agg(c.company_name, ' > '
                      ORDER BY s.stint_no)                AS company_path
    FROM   tmp_stints s
    JOIN   companies c USING (company_id)
    GROUP  BY s.employee_id
)
SELECT e.employee_code,
       e.graduation_year,
       cs.company_switches,
       cs.company_path
FROM   career_summary cs
JOIN   employees e USING (employee_id)
WHERE  cs.company_switches = (SELECT max(company_switches) FROM career_summary)
   OR  cs.company_switches >= 9
ORDER  BY cs.company_switches DESC, e.employee_code
LIMIT  10;

SELECT switches,
       count(*)                                        AS employees,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct_of_employees
FROM  (SELECT employee_id, count(*) - 1 AS switches
       FROM   tmp_stints
       GROUP  BY employee_id) t
GROUP  BY switches
ORDER  BY switches;


-- =============================================================================
-- Q12. Which industries experience the most employee movement?
--      Looks at moves between companies and the industry of each side.
-- =============================================================================
WITH moves AS (
    SELECT fi.industry_name AS from_industry,
           ti.industry_name AS to_industry
    FROM   tmp_transitions t
    JOIN   companies  fc ON fc.company_id  = t.from_company_id
    JOIN   companies  tc ON tc.company_id  = t.to_company_id
    JOIN   industries fi ON fi.industry_id = fc.industry_id
    JOIN   industries ti ON ti.industry_id = tc.industry_id
),
outgoing AS (
    SELECT from_industry AS industry,
           count(*)                                              AS moves_out,
           count(*) FILTER (WHERE from_industry = to_industry)   AS stayed_in_industry
    FROM   moves GROUP BY from_industry
),
incoming AS (
    SELECT to_industry AS industry, count(*) AS moves_in
    FROM   moves GROUP BY to_industry
)
SELECT i.industry_name,
       i.sector_group,
       COALESCE(o.moves_out, 0)                                  AS moves_out,
       COALESCE(n.moves_in, 0)                                   AS moves_in,
       COALESCE(o.moves_out, 0) + COALESCE(n.moves_in, 0)        AS total_movement,
       round(100.0 * o.stayed_in_industry / NULLIF(o.moves_out, 0), 1) AS pct_stay_in_industry
FROM   industries i
LEFT   JOIN outgoing o ON o.industry = i.industry_name
LEFT   JOIN incoming n ON n.industry = i.industry_name
ORDER  BY total_movement DESC;

SELECT fi.industry_name                                AS from_industry,
       ti.industry_name                                AS to_industry,
       count(*)                                        AS transitions,
       round(avg(100.0 * (t.salary_after - t.salary_before)
                 / t.salary_before), 1)                AS avg_salary_change_pct
FROM   tmp_transitions t
JOIN   companies  fc ON fc.company_id  = t.from_company_id
JOIN   companies  tc ON tc.company_id  = t.to_company_id
JOIN   industries fi ON fi.industry_id = fc.industry_id
JOIN   industries ti ON ti.industry_id = tc.industry_id
WHERE  fc.industry_id <> tc.industry_id
GROUP  BY fi.industry_name, ti.industry_name
ORDER  BY transitions DESC, from_industry, to_industry
LIMIT  12;
