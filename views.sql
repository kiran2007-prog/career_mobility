--=============================================================================
-- 07_views.sql
-- Career Mobility & Employee Transition Analytics (100% PostgreSQL)
--
-- PURPOSE
--   Turns the logic that files 05 and 06 rebuilt as TEMP tables into permanent,
--   reusable VIEWS. A view is a saved query: it stores no data, so it can never
--   drift out of sync with employment_history (this is why "job transitions"
--   is a view and not a table). After this file, a question like "top
--   company-to-company transitions" is a one-line SELECT.
--
--   v_as_of                      the dataset's "today" (one row)
--   v_company_stints             one row per unbroken run at a company
--   v_job_transitions            one row per company-to-company move (core view)
--   v_position_timeline          every position with previous/next neighbours
--   v_unemployment_gaps          derived gaps between jobs
--   v_career_paths               each employee's career as readable paths
--   v_employee_status            one row per employee: status, progress, pay
--   v_company_mobility_summary   one row per company: hires, exits, flow, tenure
--   v_company_transition_summary one row per company pair (the transition matrix)
--   v_yearly_mobility            one row per year: mobility trend
--
-- RUN ORDER
--   Requires 01 to 04. Independent of files 05 and 06 (it does not use their
--   temp tables). Safe to re-run: views are dropped and recreated.
--       psql -d career_mobility -f 07_views.sql
--   File 08 builds materialized views on top of three of these views.
--
-- DEFINITIONS
--   Position    one employment_history row (a promotion starts a new position).
--   Stint       an unbroken run of positions at the SAME company; tenure at a
--               company is measured per stint.
--   Transition  a move between two stints at DIFFERENT companies.
--   Real exit   a position ended by resigned / laid_off / terminated /
--               contract_end / retired. 'internal_move' (promotion) is NOT an exit.
--   Columns ending in _pct are percentages (12.5 = 12.5%).
-- =============================================================================

SET client_min_messages = warning;

-- Drop in reverse dependency order (CASCADE also removes anything built on top)
DROP VIEW IF EXISTS v_yearly_mobility, v_company_transition_summary,
                    v_company_mobility_summary, v_employee_status,
                    v_career_paths, v_unemployment_gaps, v_position_timeline,
                    v_job_transitions, v_company_stints, v_as_of CASCADE;


-- =============================================================================
-- 1. v_as_of : the dataset's "today"
--    Fixed so results are reproducible. If you load newer data, change it here
--    (the only place) and every view follows.
-- =============================================================================
CREATE VIEW v_as_of AS
SELECT DATE '2026-10-24' AS as_of_date;

COMMENT ON VIEW v_as_of IS
    'The dataset''s "today". Open positions and unemployment are measured against it.';


-- =============================================================================
-- 2. v_company_stints : one row per employee per unbroken run at a company
--
--    "Gaps and islands" technique:
--      1. LAG() marks the first position of a new stint (company differs from
--         the previous position's company).
--      2. A running SUM() of those marks numbers the stints 1, 2, 3 ...
--      3. GROUP BY collapses every stint to one row.
--    stint_end is NULL while the stint is still running.
-- =============================================================================
CREATE VIEW v_company_stints AS
WITH marked AS (
    SELECT eh.*,
           CASE WHEN lag(eh.company_id) OVER w IS DISTINCT FROM eh.company_id
                THEN 1 ELSE 0 END AS starts_new_stint
    FROM   employment_history eh
    WINDOW w AS (PARTITION BY eh.employee_id ORDER BY eh.start_date)
),
numbered AS (
    SELECT m.*,
           sum(m.starts_new_stint) OVER (PARTITION BY m.employee_id
                                         ORDER BY m.start_date) AS stint_no
    FROM   marked m
),
stints AS (
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
    GROUP  BY employee_id, stint_no, company_id
)
SELECT s.employee_id,
       e.employee_code,
       s.stint_no,
       s.company_id,
       c.company_name,
       c.company_type,
       c.industry_id,
       s.stint_start,
       s.stint_end,
       (s.stint_end IS NULL)                              AS is_current,
       COALESCE(s.stint_end, a.as_of_date) - s.stint_start AS tenure_days,
       s.positions,
       s.positions - 1                                    AS promotions,
       s.first_employment_id,
       s.last_employment_id,
       s.first_role_id,
       s.last_role_id,
       s.first_location_id,
       s.last_location_id,
       s.exit_reason
FROM   stints s
JOIN   employees e ON e.employee_id = s.employee_id
JOIN   companies c ON c.company_id  = s.company_id
CROSS  JOIN v_as_of a;

COMMENT ON VIEW v_company_stints IS
    'One row per unbroken run at one company. tenure_days counts a running stint up to the as-of date; promotions = positions - 1.';


-- =============================================================================
-- 3. v_job_transitions : one row per company-to-company move (THE core view)
--
--    Pairs every stint with the previous stint of the same employee (LAG), then
--    derives what changed:
--      tenure_before_days : time spent at the company being left
--      gap_days           : time between jobs (0 = direct move)
--      salary_before      : last salary at the old company
--      salary_after       : first salary at the new company
--    plus ready-made flags for role / industry / city / state changes.
-- =============================================================================
CREATE VIEW v_job_transitions AS
WITH paired AS (
    SELECT s.employee_id,
           s.employee_code,
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
    FROM   v_company_stints s
    WINDOW w AS (PARTITION BY s.employee_id ORDER BY s.stint_no)
)
SELECT p.employee_id,
       p.employee_code,
       p.to_stint_no,
       p.from_company_id,
       fc.company_name                AS from_company,
       fc.company_type                AS from_company_type,
       fi.industry_name               AS from_industry,
       p.to_company_id,
       tc.company_name                AS to_company,
       tc.company_type                AS to_company_type,
       ti.industry_name               AS to_industry,
       p.left_date,
       p.joined_date,
       (p.left_date - p.from_start)   AS tenure_before_days,
       (p.joined_date - p.left_date)  AS gap_days,
       p.exit_reason,
       fr.role_title                  AS from_role,
       tr.role_title                  AS to_role,
       fr.seniority_level             AS from_level,
       tr.seniority_level             AS to_level,
       fr.job_family                  AS from_family,
       tr.job_family                  AS to_family,
       fl.city                        AS from_city,
       tl.city                        AS to_city,
       fl.state                       AS from_state,
       tl.state                       AS to_state,
       fl.city_tier                   AS from_city_tier,
       tl.city_tier                   AS to_city_tier,
       sb.annual_salary               AS salary_before,
       sa.annual_salary               AS salary_after,
       round(100.0 * (sa.annual_salary - sb.annual_salary)
             / sb.annual_salary, 2)   AS salary_change_pct,
       (p.joined_date = p.left_date)                  AS direct_move,
       (p.from_role_id <> p.to_role_id)               AS role_changed,
       (fr.job_family  <> tr.job_family)              AS family_changed,
       (fc.industry_id <> tc.industry_id)             AS industry_changed,
       (p.from_location_id <> p.to_location_id)       AS city_changed,
       (fl.state <> tl.state)                         AS state_changed,
       CASE WHEN tr.seniority_level > fr.seniority_level THEN 'up'
            WHEN tr.seniority_level = fr.seniority_level THEN 'same'
            ELSE 'down' END                           AS seniority_change
FROM   paired p
JOIN   companies  fc ON fc.company_id  = p.from_company_id
JOIN   companies  tc ON tc.company_id  = p.to_company_id
JOIN   industries fi ON fi.industry_id = fc.industry_id
JOIN   industries ti ON ti.industry_id = tc.industry_id
JOIN   job_roles  fr ON fr.role_id     = p.from_role_id
JOIN   job_roles  tr ON tr.role_id     = p.to_role_id
JOIN   locations  fl ON fl.location_id = p.from_location_id
JOIN   locations  tl ON tl.location_id = p.to_location_id
CROSS  JOIN LATERAL (
           SELECT annual_salary FROM salary_history
           WHERE  employment_id = p.from_last_employment_id
           ORDER  BY effective_date DESC LIMIT 1) sb
CROSS  JOIN LATERAL (
           SELECT annual_salary FROM salary_history
           WHERE  employment_id = p.to_first_employment_id
           ORDER  BY effective_date ASC  LIMIT 1) sa
WHERE  p.from_company_id IS NOT NULL;

COMMENT ON VIEW v_job_transitions IS
    'One row per company-to-company move: before/after company, role, industry, city, tenure, gap and salary, plus change flags. Derived, never stored.';


-- =============================================================================
-- 4. v_position_timeline : every position with its neighbours
--    The career timeline you can read top to bottom for one employee:
--      SELECT * FROM v_position_timeline WHERE employee_code = 'EMP-000042'
--      ORDER BY position_no;
--    LAG / LEAD supply the previous and next company and role.
-- =============================================================================
CREATE VIEW v_position_timeline AS
SELECT eh.employment_id,
       eh.employee_id,
       e.employee_code,
       row_number() OVER w                              AS position_no,
       eh.company_id,
       c.company_name,
       c.company_type,
       i.industry_name,
       r.role_title,
       r.job_family,
       r.seniority_level,
       l.city,
       l.state,
       eh.start_date,
       eh.end_date,
       (eh.end_date IS NULL)                            AS is_current,
       COALESCE(eh.end_date, a.as_of_date) - eh.start_date AS duration_days,
       eh.separation_type,
       lag(c.company_name)  OVER w                      AS previous_company,
       lag(r.role_title)    OVER w                      AS previous_role,
       lead(c.company_name) OVER w                      AS next_company,
       lead(r.role_title)   OVER w                      AS next_role,
       eh.start_date - lag(eh.end_date) OVER w          AS gap_before_days,
       CASE WHEN lag(eh.company_id) OVER w IS NULL        THEN 'first job'
            WHEN lag(eh.company_id) OVER w = eh.company_id THEN 'internal move'
            ELSE 'company change' END                   AS how_it_started,
       s1.annual_salary                                 AS joining_salary,
       s2.annual_salary                                 AS latest_salary
FROM   employment_history eh
JOIN   employees  e ON e.employee_id  = eh.employee_id
JOIN   companies  c ON c.company_id   = eh.company_id
JOIN   industries i ON i.industry_id  = c.industry_id
JOIN   job_roles  r ON r.role_id      = eh.role_id
JOIN   locations  l ON l.location_id  = eh.location_id
CROSS  JOIN v_as_of a
CROSS  JOIN LATERAL (
           SELECT annual_salary FROM salary_history
           WHERE  employment_id = eh.employment_id
           ORDER  BY effective_date ASC  LIMIT 1) s1
CROSS  JOIN LATERAL (
           SELECT annual_salary FROM salary_history
           WHERE  employment_id = eh.employment_id
           ORDER  BY effective_date DESC LIMIT 1) s2
WINDOW w AS (PARTITION BY eh.employee_id ORDER BY eh.start_date);

COMMENT ON VIEW v_position_timeline IS
    'Every position with previous/next company and role, gap before it, how it started (first job / internal move / company change), and joining vs latest salary.';


-- =============================================================================
-- 5. v_unemployment_gaps : time between jobs, derived with LEAD()
--    A gap exists when the NEXT position starts after this one ended.
--    Positions that ended with no successor are NOT gaps here: those people
--    are currently unemployed (see v_employee_status.unemployed_since).
-- =============================================================================
CREATE VIEW v_unemployment_gaps AS
WITH linked AS (
    SELECT eh.employee_id,
           eh.company_id               AS previous_company_id,
           eh.end_date                 AS gap_start,
           eh.separation_type          AS exit_reason,
           lead(eh.start_date)  OVER w AS gap_end,
           lead(eh.company_id)  OVER w AS next_company_id
    FROM   employment_history eh
    WINDOW w AS (PARTITION BY eh.employee_id ORDER BY eh.start_date)
)
SELECT l.employee_id,
       e.employee_code,
       pc.company_name              AS previous_company,
       nc.company_name              AS next_company,
       l.exit_reason,
       l.gap_start,
       l.gap_end,
       (l.gap_end - l.gap_start)    AS gap_days
FROM   linked l
JOIN   employees e  ON e.employee_id  = l.employee_id
JOIN   companies pc ON pc.company_id  = l.previous_company_id
JOIN   companies nc ON nc.company_id  = l.next_company_id
WHERE  l.gap_end > l.gap_start;

COMMENT ON VIEW v_unemployment_gaps IS
    'Completed periods between two jobs (gap_start = last day of old job, gap_end = start of next). Derived, never stored.';


-- =============================================================================
-- 6. v_career_paths : each employee's career as readable text paths
--    type_path starts with 'College' so it matches paths like
--    College > startup > it_services > big_tech.
-- =============================================================================
CREATE VIEW v_career_paths AS
SELECT s.employee_id,
       s.employee_code,
       count(*)                                               AS companies,
       count(*) - 1                                           AS switches,
       string_agg(s.company_name, ' > ' ORDER BY s.stint_no)  AS company_path,
       'College > '
         || string_agg(s.company_type, ' > ' ORDER BY s.stint_no) AS type_path,
       string_agg(i.industry_name, ' > ' ORDER BY s.stint_no) AS industry_path,
       (array_agg(s.company_name ORDER BY s.stint_no))[1]     AS first_company,
       (array_agg(s.company_name ORDER BY s.stint_no DESC))[1] AS latest_company
FROM   v_company_stints s
JOIN   industries i ON i.industry_id = s.industry_id
GROUP  BY s.employee_id, s.employee_code;

COMMENT ON VIEW v_career_paths IS
    'One row per employee: number of companies and switches, and the career as company, company-type and industry paths.';


-- =============================================================================
-- 7. v_employee_status : one row per employee
--    First vs latest position (ROW_NUMBER picks both ends of the career),
--    current status, progression and pay growth.
--    unemployed_since is set only when the last position has ended.
-- =============================================================================
CREATE VIEW v_employee_status AS
WITH ranked AS (
    SELECT t.*,
           row_number() OVER (PARTITION BY t.employee_id
                              ORDER BY t.start_date)      AS rn_first,
           row_number() OVER (PARTITION BY t.employee_id
                              ORDER BY t.start_date DESC) AS rn_last
    FROM   v_position_timeline t
)
SELECT e.employee_id,
       e.employee_code,
       e.graduation_year,
       col.college_name,
       col.college_tier,
       CASE WHEN l.is_current THEN 'employed' ELSE 'unemployed' END AS status,
       cp.companies,
       cp.switches,
       f.start_date                                         AS career_start,
       round((a.as_of_date - f.start_date) / 365.25, 1)     AS years_experience,
       f.company_name                                       AS first_company,
       f.company_type                                       AS first_company_type,
       l.company_name                                       AS current_or_last_company,
       l.role_title                                         AS current_or_last_role,
       f.seniority_level                                    AS first_level,
       l.seniority_level                                    AS latest_level,
       l.seniority_level - f.seniority_level                AS levels_gained,
       f.joining_salary                                     AS first_salary,
       l.latest_salary                                      AS latest_salary,
       round(l.latest_salary / f.joining_salary, 2)         AS salary_multiple,
       CASE WHEN NOT l.is_current THEN l.end_date END       AS unemployed_since,
       CASE WHEN NOT l.is_current
            THEN round((a.as_of_date - l.end_date) / 30.44, 1) END AS months_unemployed
FROM   employees e
JOIN   ranked f  ON f.employee_id  = e.employee_id AND f.rn_first = 1
JOIN   ranked l  ON l.employee_id  = e.employee_id AND l.rn_last  = 1
JOIN   v_career_paths cp ON cp.employee_id = e.employee_id
LEFT   JOIN colleges col ON col.college_id = e.college_id
CROSS  JOIN v_as_of a;

COMMENT ON VIEW v_employee_status IS
    'One row per employee: employed/unemployed now, first vs latest role and level, salary growth, companies and switches.';


-- =============================================================================
-- 8. v_company_mobility_summary : one row per company
--    Hires, exits, net talent flow and tenure in one place. Counts use the
--    definitions at the top (real exits only; a hire = one stint).
-- =============================================================================
CREATE VIEW v_company_mobility_summary AS
WITH employee_years AS (
    SELECT eh.company_id,
           sum(COALESCE(eh.end_date, a.as_of_date) - eh.start_date) / 365.25 AS years
    FROM   employment_history eh
    CROSS  JOIN v_as_of a
    GROUP  BY eh.company_id
),
exits AS (
    SELECT company_id,
           count(*)                                                      AS exits,
           count(*) FILTER (WHERE separation_type = 'resigned')          AS resigned,
           count(*) FILTER (WHERE separation_type = 'laid_off')          AS laid_off,
           count(*) FILTER (WHERE separation_type
                            IN ('terminated', 'contract_end', 'retired')) AS other_exits
    FROM   employment_history
    WHERE  end_date IS NOT NULL
      AND  separation_type <> 'internal_move'
    GROUP  BY company_id
),
hires AS (
    SELECT company_id,
           count(*)                                AS total_hires,
           count(*) FILTER (WHERE stint_no = 1)    AS first_job_hires
    FROM   v_company_stints
    GROUP  BY company_id
),
moves_out AS (
    SELECT from_company_id AS company_id, count(*) AS moves_out
    FROM   v_job_transitions GROUP BY from_company_id
),
moves_in AS (
    SELECT to_company_id AS company_id, count(*) AS moves_in
    FROM   v_job_transitions GROUP BY to_company_id
),
tenure AS (
    SELECT company_id, avg(tenure_days) / 365.25 AS avg_completed_tenure_years
    FROM   v_company_stints
    WHERE  NOT is_current
    GROUP  BY company_id
)
SELECT c.company_id,
       c.company_name,
       c.company_type,
       i.industry_name,
       round(ey.years)::int                                         AS employee_years,
       COALESCE(h.total_hires, 0)                                   AS total_hires,
       COALESCE(h.total_hires, 0) - COALESCE(h.first_job_hires, 0)  AS hires_from_other_companies,
       COALESCE(h.first_job_hires, 0)                               AS first_job_hires,
       COALESCE(x.exits, 0)                                         AS exits,
       COALESCE(x.resigned, 0)                                      AS resigned,
       COALESCE(x.laid_off, 0)                                      AS laid_off,
       COALESCE(x.other_exits, 0)                                   AS other_exits,
       round(100.0 * COALESCE(x.exits, 0) / NULLIF(ey.years, 0), 1) AS exits_per_100_employee_years,
       COALESCE(mo.moves_out, 0)                                    AS moves_out,
       COALESCE(mi.moves_in, 0)                                     AS moves_in,
       COALESCE(mi.moves_in, 0) - COALESCE(mo.moves_out, 0)         AS net_talent_flow,
       round(t.avg_completed_tenure_years::numeric, 2)              AS avg_completed_tenure_years
FROM   companies c
JOIN   industries i       ON i.industry_id = c.industry_id
LEFT   JOIN employee_years ey ON ey.company_id = c.company_id
LEFT   JOIN hires          h  ON h.company_id  = c.company_id
LEFT   JOIN exits          x  ON x.company_id  = c.company_id
LEFT   JOIN moves_out      mo ON mo.company_id = c.company_id
LEFT   JOIN moves_in       mi ON mi.company_id = c.company_id
LEFT   JOIN tenure         t  ON t.company_id  = c.company_id;

COMMENT ON VIEW v_company_mobility_summary IS
    'One row per company: hires (from other companies / first job), real exits, exit rate, net talent flow, completed-stint tenure.';


-- =============================================================================
-- 9. v_company_transition_summary : the company-to-company transition matrix
--    sum(count(*)) OVER (PARTITION BY ...) turns each count into a share of the
--    source company's outgoing moves and of the destination's incoming moves.
-- =============================================================================
CREATE VIEW v_company_transition_summary AS
SELECT t.from_company_id,
       t.to_company_id,
       t.from_company,
       t.to_company,
       t.from_company_type,
       t.to_company_type,
       count(*)                                                       AS transitions,
       round(100.0 * count(*)
             / sum(count(*)) OVER (PARTITION BY t.from_company_id), 2) AS pct_of_from_outgoing,
       round(100.0 * count(*)
             / sum(count(*)) OVER (PARTITION BY t.to_company_id), 2)   AS pct_of_to_incoming,
       round(avg(t.tenure_before_days) / 30.44, 1)                    AS avg_months_before_move,
       round(avg(t.salary_change_pct), 1)                             AS avg_salary_change_pct,
       round(avg(t.gap_days), 1)                                      AS avg_gap_days,
       round(100.0 * count(*) FILTER (WHERE t.gap_days > 0) / count(*), 1) AS pct_with_gap
FROM   v_job_transitions t
GROUP  BY t.from_company_id, t.to_company_id,
          t.from_company, t.to_company,
          t.from_company_type, t.to_company_type;

COMMENT ON VIEW v_company_transition_summary IS
    'One row per (from company, to company): move count, share of outgoing and incoming, tenure before, salary change and gap.';


-- =============================================================================
-- 10. v_yearly_mobility : one row per calendar year
--     employed        employees with a position active at some point in the year
--     company_changes people who joined a different company that year
--     exits/layoffs   real exits that year (promotions excluded)
--     The current (as-of) year is incomplete.
-- =============================================================================
CREATE VIEW v_yearly_mobility AS
WITH bounds AS (
    SELECT EXTRACT(year FROM min(eh.start_date))::int AS first_year,
           EXTRACT(year FROM (SELECT as_of_date FROM v_as_of))::int AS last_year
    FROM   employment_history eh
),
years AS (
    SELECT generate_series(first_year, last_year) AS yr FROM bounds
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
           count(*)                                              AS exits,
           count(*) FILTER (WHERE separation_type = 'laid_off')  AS layoffs
    FROM   employment_history
    WHERE  end_date IS NOT NULL AND separation_type <> 'internal_move'
    GROUP  BY 1
),
moves AS (
    SELECT EXTRACT(year FROM joined_date)::int AS yr, count(*) AS company_changes
    FROM   v_job_transitions
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
    LEFT   JOIN moves m ON m.yr = a.yr
    LEFT   JOIN exits x ON x.yr = a.yr
)
SELECT yr AS year,
       employed,
       company_changes,
       exits,
       layoffs,
       changes_per_100_employed,
       round(changes_per_100_employed
             - lag(changes_per_100_employed) OVER (ORDER BY yr), 1) AS change_vs_prev_year
FROM   yearly;

COMMENT ON VIEW v_yearly_mobility IS
    'One row per year: employed, company changes, real exits, layoffs, changes per 100 employed and the change from the previous year.';


-- =============================================================================
-- 11. VERIFICATION
-- =============================================================================

SELECT table_name AS view_name
FROM   information_schema.views
WHERE  table_schema = 'public'
ORDER  BY table_name;

SELECT (SELECT count(*) FROM v_job_transitions)
         = (SELECT count(*) FROM v_company_stints) - (SELECT count(*) FROM employees)
         AS transitions_equal_stints_minus_employees,
       (SELECT count(*) FROM v_position_timeline) = (SELECT count(*) FROM employment_history)
         AS timeline_has_every_position,
       (SELECT count(*) FROM v_employee_status) = (SELECT count(*) FROM employees)
         AS status_has_every_employee,
       (SELECT sum(total_hires) FROM v_company_mobility_summary)
         = (SELECT count(*) FROM v_company_stints)
         AS hires_equal_stints,
       (SELECT sum(moves_in) FROM v_company_mobility_summary)
         = (SELECT sum(moves_out) FROM v_company_mobility_summary)
         AS moves_in_equal_moves_out,
       (SELECT sum(transitions) FROM v_company_transition_summary)
         = (SELECT count(*) FROM v_job_transitions)
         AS matrix_sums_to_transitions;

SELECT position_no, company_name, role_title, city,
       start_date, end_date, how_it_started, separation_type, gap_before_days
FROM   v_position_timeline
WHERE  employee_id = (SELECT employee_id FROM employment_history
                      GROUP BY employee_id
                      ORDER BY count(*) DESC, employee_id LIMIT 1)
ORDER  BY position_no;

SELECT from_company, to_company, transitions, pct_of_from_outgoing,
       pct_of_to_incoming, avg_months_before_move, avg_salary_change_pct, avg_gap_days
FROM   v_company_transition_summary
ORDER  BY transitions DESC, from_company, to_company
LIMIT  5;

SELECT type_path, count(*) AS employees
FROM   v_career_paths
WHERE  companies >= 2
GROUP  BY type_path
ORDER  BY employees DESC, type_path
LIMIT  5;

SELECT status, count(*) AS employees,
       round(avg(salary_multiple), 2) AS avg_salary_multiple_since_first_job
FROM   v_employee_status
GROUP  BY status
ORDER  BY employees DESC;

SELECT company_name, company_type, hires_from_other_companies, moves_out,
       net_talent_flow, exits_per_100_employee_years, avg_completed_tenure_years
FROM   v_company_mobility_summary
ORDER  BY net_talent_flow DESC, company_name
LIMIT  5;

SELECT * FROM v_yearly_mobility WHERE year >= 2021 ORDER BY year;
