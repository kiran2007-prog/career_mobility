-- =============================================================================
-- 09_indexes.sql
-- Career Mobility & Employee Transition Analytics (100% PostgreSQL)
--
-- PURPOSE
--   Adds the secondary indexes this workload needs and PROVES each one with
--   EXPLAIN (ANALYZE): the plan and execution time before and after.
--
--   Indexes created (each has a stated reason):
--     ix_eh_employee_start      (employee_id, start_date)
--         The timeline of one employee (big win: no sort, ~0.03 ms). Every
--         LAG / LEAD / ROW_NUMBER window in the views
--         (PARTITION BY employee_id ORDER BY start_date) can also read rows
--         already in that order, so the sort node disappears. Measured on the
--         whole-table views the total time is about the same at this size
--         (reading 19,000 rows through an index costs about what sorting them
--         does), so the gain is for per-employee and larger-scale queries.
--     ix_eh_company_start       (company_id, start_date)
--         Hires/positions of one company over a date range; also the index the
--         company_id foreign key needs.
--     ix_eh_current_company     (company_id) WHERE end_date IS NULL
--         PARTIAL index: only current positions (~26% of rows). "Who works at
--         company X now?" reads a small index instead of the whole table.
--     foreign-key indexes       role_id, location_id, college_id, industry_id ...
--         PostgreSQL does NOT index foreign-key columns automatically. Without
--         them, deleting or updating a parent row (a role, a city) scans the
--         whole child table to check nobody still points at it.
--     materialized-view indexes lookups by source / destination company and the
--         "top chains" ranking.
--
-- RUN ORDER
--   Requires 01 to 08 (it indexes the materialized views from file 08).
--       psql -d career_mobility -f 09_indexes.sql
--   Safe to re-run: it drops its own indexes first so that the BEFORE plans are
--   genuinely "before".  Re-running 07 or 08 drops the objects these indexes
--   sit on; re-run 08 and then this file.
--
-- WHAT THE TABLES ALREADY HAVE (free indexes from file 01)
--   * primary keys and UNIQUE constraints (e.g. uq_salary_employment_date on
--     (employment_id, effective_date) already serves every "first / latest
--     salary of this position" lookup, so salary_history needs nothing more)
--   * ex_employment_no_overlap: the GiST index behind the "no overlapping
--     jobs" rule. It can find the rows of one employee_id, but it cannot
--     return them sorted by start_date, so a B-tree is still worth adding.
--
-- AN HONEST NOTE ABOUT SIZE
--   This database has ~19,000 positions. At that size PostgreSQL often decides
--   a sequential scan is as cheap as an index, and queries finish in
--   milliseconds either way. Section 6 therefore repeats two tests on a
--   temporary copy 50 times larger (about 940,000 rows), where the effect of an
--   index is obvious.
--
-- NOTE ON \echo
--   \echo is a psql command. In a GUI tool, delete those lines.
-- =============================================================================

SET client_min_messages = warning;


-- =============================================================================
-- 1. RESET: remove this file's indexes so the BEFORE measurements are honest
-- =============================================================================
DROP INDEX IF EXISTS ix_eh_employee_start, ix_eh_company_start, ix_eh_current_company,
                     ix_eh_role, ix_eh_location, ix_employees_college,
                     ix_companies_industry, ix_companies_hq_location,
                     ix_colleges_location,
                     ix_mv_matrix_from, ix_mv_matrix_to, ix_mv_chains_top;

ANALYZE;   -- fresh planner statistics


-- =============================================================================
-- 2. WHAT EXISTS BEFORE WE ADD ANYTHING
-- =============================================================================
SELECT tablename, indexname
FROM   pg_indexes
WHERE  schemaname = 'public'
  AND  tablename IN ('employees', 'employment_history', 'salary_history', 'companies')
ORDER  BY tablename, indexname;


-- =============================================================================
-- 3. BEFORE: three queries that represent how the data is used
--    (read the plan from the bottom up: the innermost node runs first)
-- =============================================================================
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT * FROM employment_history
WHERE  employee_id = 1234
ORDER  BY start_date;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM employment_history
WHERE  company_id = 5 AND end_date IS NULL;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM v_company_stints;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM employment_history
WHERE  company_id = 5
  AND  start_date >= DATE '2023-01-01' AND start_date < DATE '2024-01-01';


-- =============================================================================
-- 4. CREATE THE INDEXES
-- =============================================================================

-- Per-employee timelines and all window functions over (employee, start_date)
CREATE INDEX ix_eh_employee_start
    ON employment_history (employee_id, start_date);

-- Company over time; also covers the company_id foreign key
CREATE INDEX ix_eh_company_start
    ON employment_history (company_id, start_date);

-- PARTIAL index: current positions only
CREATE INDEX ix_eh_current_company
    ON employment_history (company_id)
    WHERE end_date IS NULL;

-- Foreign-key columns that nothing else indexes. They do not speed up the
-- analytics today; they keep deletes/updates of a role, city, college or
-- industry from scanning the whole child table.
CREATE INDEX ix_eh_role               ON employment_history (role_id);
CREATE INDEX ix_eh_location           ON employment_history (location_id);
CREATE INDEX ix_employees_college     ON employees (college_id);
CREATE INDEX ix_companies_industry    ON companies (industry_id);
CREATE INDEX ix_companies_hq_location ON companies (hq_location_id);
CREATE INDEX ix_colleges_location     ON colleges (location_id);

-- Materialized views: the access patterns they exist for
--   "where do people from company X go?"  /  "who feeds company Y?"
CREATE INDEX ix_mv_matrix_from
    ON mv_company_transition_matrix (from_company_id, transitions DESC);
CREATE INDEX ix_mv_matrix_to
    ON mv_company_transition_matrix (to_company_id, transitions DESC);
--   "top chains of a kind and length"
CREATE INDEX ix_mv_chains_top
    ON mv_career_path_chains (path_kind, chain_length, employees DESC);

ANALYZE;   -- let the planner see the new indexes' statistics


-- =============================================================================
-- 5. AFTER: the same queries
-- =============================================================================
EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT * FROM employment_history
WHERE  employee_id = 1234
ORDER  BY start_date;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM employment_history
WHERE  company_id = 5 AND end_date IS NULL;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM v_company_stints;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM employment_history
WHERE  company_id = 5
  AND  start_date >= DATE '2023-01-01' AND start_date < DATE '2024-01-01';

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT * FROM mv_company_transition_matrix
WHERE  from_company_id = 1
ORDER  BY transitions DESC
LIMIT  5;


-- =============================================================================
-- 6. DOES IT MATTER AT SCALE?  A temporary table 50 times bigger.
--    (~940,000 rows. A TEMP table disappears when your session ends; the real
--    tables are untouched. The ids are shifted so every copy looks like a
--    different employee.)
-- =============================================================================
DROP TABLE IF EXISTS eh_scale;
CREATE TEMP TABLE eh_scale AS
SELECT eh.employee_id + k * 100000 AS employee_id,
       eh.company_id,
       eh.start_date,
       eh.end_date
FROM   employment_history eh
CROSS  JOIN generate_series(0, 49) AS k;
ANALYZE eh_scale;

SELECT count(*) AS rows_in_scale_table FROM eh_scale;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT * FROM eh_scale WHERE employee_id = 501234 ORDER BY start_date;

CREATE INDEX ON eh_scale (employee_id, start_date);
ANALYZE eh_scale;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT * FROM eh_scale WHERE employee_id = 501234 ORDER BY start_date;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM eh_scale WHERE company_id = 5 AND end_date IS NULL;

CREATE INDEX ON eh_scale (company_id) WHERE end_date IS NULL;
ANALYZE eh_scale;

EXPLAIN (ANALYZE, COSTS OFF, TIMING OFF)
SELECT count(*) FROM eh_scale WHERE company_id = 5 AND end_date IS NULL;

DROP TABLE eh_scale;


-- =============================================================================
-- 7. INVENTORY: every index we own, its size and how often it was used
--    idx_scan counts uses since statistics were last reset. An index that is
--    never used after a realistic workload is a candidate to drop: every index
--    slows inserts and takes disk space.
-- =============================================================================
SELECT s.relname                                     AS table_name,
       s.indexrelname                                AS index_name,
       CASE WHEN i.indisprimary THEN 'primary key'
            WHEN i.indisunique  THEN 'unique'
            ELSE 'secondary' END                     AS kind,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS size,
       s.idx_scan                                    AS times_used
FROM   pg_stat_user_indexes s
JOIN   pg_index i ON i.indexrelid = s.indexrelid
WHERE  s.schemaname = 'public'
ORDER  BY s.relname, kind DESC, s.indexrelname;


-- =============================================================================
-- 8. INDEXES DELIBERATELY NOT CREATED (and why)
--   * salary_history (employment_id, effective_date DESC): the existing UNIQUE
--     index already serves first/latest salary lookups (a B-tree can be read
--     backwards).
--   * company_type, separation_type, seniority_level: only 3 to 8 distinct
--     values. An index on such a column rarely beats a sequential scan, and the
--     queries here GROUP BY them rather than filter on one value.
--   * end_date for "exits in year N": the views use EXTRACT(year FROM end_date),
--     which a plain index on end_date cannot serve. It would need an expression
--     index, and those queries read every row for the aggregate anyway.
--   * BRIN: useful when a column follows the physical row order (e.g. a
--     timestamp on an append-only log). Rows here are stored by employee, not
--     by date, so BRIN would not prune anything.
--   * GIN / trigram: nothing in this project searches inside text.
-- =============================================================================
