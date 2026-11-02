-- =============================================================================
-- 08_materialized_views.sql
-- Career Mobility & Employee Transition Analytics (100% PostgreSQL)
--
-- PURPOSE
--   A plain view re-runs its query every time. A MATERIALIZED view stores the
--   result on disk, so reading it is a plain table scan. It is worth it for
--   queries that are heavy and whose answer changes only when the underlying
--   data changes. The price: it goes STALE until you refresh it.
--
--   Four materialized views, each chosen because recomputing it is expensive:
--     mv_company_transition_matrix   company-to-company transitions with shares,
--                                    tenure, pay change and gaps (window sums
--                                    over a join of several views)
--     mv_company_mobility_summary    one row per company: hires, exits, flow, tenure
--     mv_yearly_mobility             one row per year: mobility trend
--     mv_career_path_chains          common 2-4 company chains found with a
--                                    RECURSIVE CTE (the slowest analysis here)
--
-- RUN ORDER
--   Requires 07_views.sql (these select from its views). If you re-run 07,
--   PostgreSQL drops everything built on those views (DROP ... CASCADE), so
--   re-run this file afterwards.
--       psql -d career_mobility -f 08_materialized_views.sql
--   Safe to re-run.
--
-- DESIGN NOTES
--   * Every materialized view gets a UNIQUE index here (not in file 09). That is
--     not an optimisation: REFRESH MATERIALIZED VIEW CONCURRENTLY, which lets
--     readers keep querying during a refresh, REQUIRES one. File 09 adds the
--     other indexes.
--   * A plain REFRESH locks the view while it rebuilds. CONCURRENTLY rebuilds a
--     copy, diffs it against the old one and applies only the differences.
--     It is slower overall but never blocks readers.
--   * Data in these views changes only when employment history changes, so the
--     normal pattern is "load data, then refresh". File 10 wraps the four
--     refreshes in one procedure.
--
-- NOTE ON \echo and \timing
--   \echo and \timing are psql commands. In a GUI tool, delete those lines.
-- =============================================================================

SET client_min_messages = warning;

DROP MATERIALIZED VIEW IF EXISTS mv_career_path_chains,
                                 mv_yearly_mobility,
                                 mv_company_mobility_summary,
                                 mv_company_transition_matrix CASCADE;


-- =============================================================================
-- 1. mv_company_transition_matrix
--    Same columns as v_company_transition_summary.
-- =============================================================================
CREATE MATERIALIZED VIEW mv_company_transition_matrix AS
SELECT * FROM v_company_transition_summary;

CREATE UNIQUE INDEX uq_mv_transition_matrix_pair
    ON mv_company_transition_matrix (from_company_id, to_company_id);

COMMENT ON MATERIALIZED VIEW mv_company_transition_matrix IS
    'Stored copy of v_company_transition_summary. Stale until refreshed.';


-- =============================================================================
-- 2. mv_company_mobility_summary
-- =============================================================================
CREATE MATERIALIZED VIEW mv_company_mobility_summary AS
SELECT * FROM v_company_mobility_summary;

CREATE UNIQUE INDEX uq_mv_company_summary_company
    ON mv_company_mobility_summary (company_id);

COMMENT ON MATERIALIZED VIEW mv_company_mobility_summary IS
    'Stored copy of v_company_mobility_summary. Stale until refreshed.';


-- =============================================================================
-- 3. mv_yearly_mobility
-- =============================================================================
CREATE MATERIALIZED VIEW mv_yearly_mobility AS
SELECT * FROM v_yearly_mobility;

CREATE UNIQUE INDEX uq_mv_yearly_mobility_year
    ON mv_yearly_mobility (year);

COMMENT ON MATERIALIZED VIEW mv_yearly_mobility IS
    'Stored copy of v_yearly_mobility. Stale until refreshed.';


-- =============================================================================
-- 4. mv_career_path_chains
--    Every chain of 2 to 4 consecutive companies in anyone's career, counted
--    by how many DIFFERENT employees followed it, at two levels:
--      path_kind = 'company'       : Infosys > TCS > Amazon
--      path_kind = 'company_type'  : it_services > it_services > big_tech
--    The recursive CTE starts a chain at every stint and keeps appending the
--    employee's NEXT stint until the chain has 4 companies, so a chain is found
--    wherever it occurs in a career. Chains followed by fewer than 3 employees
--    are dropped: they are noise and would make this view huge.
--    The stints are read once (MATERIALIZED CTE) instead of once per recursion
--    step.
-- =============================================================================
CREATE MATERIALIZED VIEW mv_career_path_chains AS
WITH RECURSIVE stints AS MATERIALIZED (
    SELECT employee_id, stint_no, company_name, company_type
    FROM   v_company_stints
),
walk AS (
    SELECT employee_id,
           stint_no                  AS last_no,
           1                         AS chain_length,
           company_name::text        AS company_path,
           company_type::text        AS type_path
    FROM   stints

    UNION ALL

    SELECT w.employee_id,
           s.stint_no,
           w.chain_length + 1,
           w.company_path || ' > ' || s.company_name,
           w.type_path    || ' > ' || s.company_type
    FROM   walk w
    JOIN   stints s ON s.employee_id = w.employee_id
                   AND s.stint_no    = w.last_no + 1
    WHERE  w.chain_length < 4
),
chains AS (
    SELECT chain_length, 'company'::text AS path_kind,
           company_path AS path, count(DISTINCT employee_id) AS employees
    FROM   walk WHERE chain_length >= 2
    GROUP  BY chain_length, company_path
    UNION ALL
    SELECT chain_length, 'company_type',
           type_path, count(DISTINCT employee_id)
    FROM   walk WHERE chain_length >= 2
    GROUP  BY chain_length, type_path
)
SELECT chain_length, path_kind, path, employees
FROM   chains
WHERE  employees >= 3;

CREATE UNIQUE INDEX uq_mv_career_chains_path
    ON mv_career_path_chains (path_kind, chain_length, path);

COMMENT ON MATERIALIZED VIEW mv_career_path_chains IS
    'Common 2-4 company chains (company and company-type level) with the number of employees who followed them; chains with fewer than 3 employees are dropped. Built with a recursive CTE.';


-- =============================================================================
-- 5. VERIFICATION
-- =============================================================================

SELECT m.matviewname                                       AS materialized_view,
       m.ispopulated                                       AS populated,
       (xpath('/row/c/text()',
              query_to_xml('SELECT count(*) AS c FROM ' || quote_ident(m.matviewname),
                           false, true, '')))[1]::text::int AS row_count,
       pg_size_pretty(pg_total_relation_size(
           format('%I.%I', m.schemaname, m.matviewname)::regclass)) AS total_size
FROM   pg_matviews m
WHERE  m.schemaname = 'public'
ORDER  BY m.matviewname;

SELECT (SELECT count(*) FROM mv_company_transition_matrix) = (SELECT count(*) FROM v_company_transition_summary)
         AS transition_matrix_rows_match,
       (SELECT sum(transitions) FROM mv_company_transition_matrix)
         = (SELECT count(*) FROM v_job_transitions)
         AS matrix_sums_to_all_transitions,
       (SELECT count(*) FROM mv_company_mobility_summary) = (SELECT count(*) FROM companies)
         AS company_summary_has_every_company,
       (SELECT count(*) FROM mv_yearly_mobility) = (SELECT count(*) FROM v_yearly_mobility)
         AS yearly_rows_match;

SELECT count(*) AS rows_from_view FROM (
    SELECT * FROM v_company_transition_summary
    ORDER  BY transitions DESC, from_company, to_company LIMIT 20) x;

SELECT count(*) AS rows_from_materialized_view FROM (
    SELECT * FROM mv_company_transition_matrix
    ORDER  BY transitions DESC, from_company, to_company LIMIT 20) x;

SELECT count(*) AS chains_recomputed FROM (
    WITH RECURSIVE stints AS MATERIALIZED (
        SELECT employee_id, stint_no, company_name FROM v_company_stints),
    walk AS (
        SELECT employee_id, stint_no AS last_no, 1 AS chain_length, company_name::text AS path
        FROM stints
        UNION ALL
        SELECT w.employee_id, s.stint_no, w.chain_length + 1, w.path || ' > ' || s.company_name
        FROM walk w JOIN stints s ON s.employee_id = w.employee_id AND s.stint_no = w.last_no + 1
        WHERE w.chain_length < 4)
    SELECT path FROM walk WHERE chain_length = 3 GROUP BY path HAVING count(DISTINCT employee_id) >= 3) x;

SELECT count(*) AS chains_from_materialized_view
FROM   mv_career_path_chains WHERE path_kind = 'company' AND chain_length = 3;

SELECT path AS three_step_type_chain, employees
FROM   mv_career_path_chains
WHERE  path_kind = 'company_type' AND chain_length = 3
ORDER  BY employees DESC, path
LIMIT  6;


-- =============================================================================
-- 6. STALENESS DEMO (everything is rolled back at the end)
--    Delete the employee with the most company switches. The plain view sees it
--    at once; the materialized view does not until it is refreshed.
-- =============================================================================
BEGIN;
SAVEPOINT staleness_demo;

SELECT 'before delete' AS step,
       (SELECT sum(transitions) FROM v_company_transition_summary)   AS view_total,
       (SELECT sum(transitions) FROM mv_company_transition_matrix)   AS materialized_total;

DELETE FROM employees
WHERE  employee_id = (SELECT employee_id FROM v_career_paths
                      ORDER BY switches DESC, employee_id LIMIT 1);

SELECT 'after delete (MV is stale)' AS step,
       (SELECT sum(transitions) FROM v_company_transition_summary)   AS view_total,
       (SELECT sum(transitions) FROM mv_company_transition_matrix)   AS materialized_total;

REFRESH MATERIALIZED VIEW mv_company_transition_matrix;

SELECT 'after REFRESH' AS step,
       (SELECT sum(transitions) FROM v_company_transition_summary)   AS view_total,
       (SELECT sum(transitions) FROM mv_company_transition_matrix)   AS materialized_total;

ROLLBACK TO SAVEPOINT staleness_demo;   -- undo only the demo; keep the materialized views created above

SELECT 'after ROLLBACK' AS step,
       (SELECT sum(transitions) FROM v_company_transition_summary)   AS view_total,
       (SELECT sum(transitions) FROM mv_company_transition_matrix)   AS materialized_total;

RELEASE SAVEPOINT staleness_demo;
COMMIT;


-- =============================================================================
-- 7. REFRESHING WITHOUT BLOCKING READERS
--    Run these whenever employment history has changed. CONCURRENTLY needs the
--    unique indexes created above. (Nothing changed here, so this is a no-op
--    in content; it just proves the commands work.)
-- =============================================================================
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_company_transition_matrix;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_company_mobility_summary;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_yearly_mobility;
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_career_path_chains;

SELECT 'refreshed' AS status, count(*) AS transition_pairs FROM mv_company_transition_matrix;
