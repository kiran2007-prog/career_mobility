-- =============================================================================
-- 10_functions_triggers.sql
-- Career Mobility & Employee Transition Analytics (100% PostgreSQL)
--
-- PURPOSE
--   The "database engineering" layer: rules the schema cannot express with a
--   CHECK constraint, reusable parameterised queries, one maintenance
--   procedure, and live demonstrations of INSERT / UPDATE / DELETE and
--   transactions.
--
--   TRIGGERS (rules that span two tables, so a CHECK cannot enforce them)
--     trg_salary_date_in_position   a salary row must be dated inside its
--                                   position's period
--     trg_guard_position_dates      moving a position's dates must not leave
--                                   its salary rows outside the new period
--     trg_position_after_company_founded
--                                   nobody can start work at a company before
--                                   the company was founded
--   FUNCTIONS (parameterised questions)
--     fn_employee_career(code)               one employee's career timeline
--     fn_company_destinations(company, n)    where do leavers of a company go?
--     fn_company_sources(company, n)         where do a company's hires come from?
--     fn_salary_on(code, date)               what did this person earn on a date?
--     fn_attrition_rate(company, months)     % of hires who left within N months
--   PROCEDURE
--     refresh_analytics_views(concurrently)  refresh the four materialized views
--
-- RUN ORDER
--   Requires 01 to 09 (functions read the views from file 07; the procedure
--   refreshes the views from file 08).
--       psql -d career_mobility -f 10_functions_triggers.sql
--   Safe to re-run. The demonstration in section 6 changes data inside a
--   transaction and ROLLS IT BACK, so your dataset is left exactly as it was.
--   (Identity counters do not roll back: new employees created after the demo
--   would skip a few ids. Re-running file 03 resets them.)
--
--   The triggers do not slow file 04: re-running 04 afterwards simply runs the
--   rules on every inserted salary row.
--
-- NOTE ON \echo
--   \echo is a psql command. In a GUI tool, delete those lines.
-- =============================================================================

SET client_min_messages = warning;


-- =============================================================================
-- 1. TRIGGER: a salary row must fall inside its position's period
--    Position period is [start_date, end_date): end_date itself is outside
--    (exclusive), and a NULL end_date means the position is still open.
--    Why a trigger: the rule compares salary_history with employment_history,
--    and a CHECK constraint can only look at its own row.
-- =============================================================================
CREATE OR REPLACE FUNCTION trg_validate_salary_date()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_start date;
    v_end   date;
BEGIN
    SELECT start_date, end_date
    INTO   v_start, v_end
    FROM   employment_history
    WHERE  employment_id = NEW.employment_id;

    -- Unknown position: let the foreign key produce its own, clearer error.
    IF NOT FOUND THEN
        RETURN NEW;
    END IF;

    IF NEW.effective_date < v_start
       OR (v_end IS NOT NULL AND NEW.effective_date >= v_end) THEN
        RAISE EXCEPTION
            'Salary effective_date % is outside position % (% to %)',
            NEW.effective_date, NEW.employment_id, v_start,
            COALESCE(v_end::text, 'present')
            USING ERRCODE = 'check_violation',
                  HINT    = 'A salary must be effective on or after the position start and before its end date.';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_salary_date_in_position ON salary_history;
CREATE TRIGGER trg_salary_date_in_position
    BEFORE INSERT OR UPDATE OF employment_id, effective_date
    ON salary_history
    FOR EACH ROW
    EXECUTE FUNCTION trg_validate_salary_date();


-- =============================================================================
-- 2. TRIGGER: do not move a position's dates out from under its salary rows
--    The first trigger guards new salary rows; this one guards the other
--    direction (editing the position afterwards).
-- =============================================================================
CREATE OR REPLACE FUNCTION trg_guard_position_dates()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_bad date;
BEGIN
    SELECT s.effective_date
    INTO   v_bad
    FROM   salary_history s
    WHERE  s.employment_id = NEW.employment_id
      AND (s.effective_date < NEW.start_date
           OR (NEW.end_date IS NOT NULL AND s.effective_date >= NEW.end_date))
    ORDER  BY s.effective_date
    LIMIT  1;

    IF FOUND THEN
        RAISE EXCEPTION
            'Cannot change position % to % - %: salary row dated % would fall outside it',
            NEW.employment_id, NEW.start_date,
            COALESCE(NEW.end_date::text, 'present'), v_bad
            USING ERRCODE = 'check_violation',
                  HINT    = 'Move or delete the salary rows first.';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_position_dates ON employment_history;
CREATE TRIGGER trg_guard_position_dates
    BEFORE UPDATE OF start_date, end_date
    ON employment_history
    FOR EACH ROW
    EXECUTE FUNCTION trg_guard_position_dates();


-- =============================================================================
-- 3. TRIGGER: no job before the company existed
--    companies.founded_year is NULL for a few old firms; those are skipped.
-- =============================================================================
CREATE OR REPLACE FUNCTION trg_check_company_founded()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
    v_name    text;
    v_founded smallint;
BEGIN
    SELECT company_name, founded_year
    INTO   v_name, v_founded
    FROM   companies
    WHERE  company_id = NEW.company_id;

    IF FOUND AND v_founded IS NOT NULL
       AND EXTRACT(year FROM NEW.start_date) < v_founded THEN
        RAISE EXCEPTION
            'Position starts in % but % was founded in %',
            EXTRACT(year FROM NEW.start_date)::int, v_name, v_founded
            USING ERRCODE = 'check_violation';
    END IF;

    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_position_after_company_founded ON employment_history;
CREATE TRIGGER trg_position_after_company_founded
    BEFORE INSERT OR UPDATE OF company_id, start_date
    ON employment_history
    FOR EACH ROW
    EXECUTE FUNCTION trg_check_company_founded();


-- =============================================================================
-- 4. FUNCTIONS
-- =============================================================================

-- -----------------------------------------------------------------------------
-- fn_employee_career: one employee's career, position by position.
--   SELECT * FROM fn_employee_career('EMP-000042');
-- Looks the id up first and filters the view by employee_id: that column is the
-- PARTITION BY of the view's window functions, so PostgreSQL can push the
-- filter inside and compute one employee instead of all 5,000.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_employee_career(p_employee_code text)
RETURNS TABLE (
    position_no     bigint,
    company         text,
    company_type    text,
    role            text,
    seniority_level smallint,
    city            text,
    start_date      date,
    end_date        date,
    how_it_started  text,
    joining_salary  numeric,
    latest_salary   numeric
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_id integer;
BEGIN
    SELECT e.employee_id INTO v_id
    FROM   employees e
    WHERE  e.employee_code = p_employee_code;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee code: %', p_employee_code
            USING ERRCODE = 'no_data_found';
    END IF;

    RETURN QUERY
    SELECT t.position_no, t.company_name, t.company_type, t.role_title,
           t.seniority_level, t.city, t.start_date, t.end_date,
           t.how_it_started, t.joining_salary::numeric, t.latest_salary::numeric
    FROM   v_position_timeline t
    WHERE  t.employee_id = v_id
    ORDER  BY t.position_no;
END;
$$;

-- -----------------------------------------------------------------------------
-- fn_company_destinations: where do people who leave a company go? (Q4)
--   SELECT * FROM fn_company_destinations('Tata Consultancy Services', 5);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_company_destinations(p_company text, p_top integer DEFAULT 10)
RETURNS TABLE (
    destination           text,
    destination_type      text,
    people                bigint,
    pct_of_leavers        numeric,
    avg_salary_change_pct numeric
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_top < 1 THEN
        RAISE EXCEPTION 'p_top must be at least 1 (got %)', p_top
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM companies c WHERE c.company_name = p_company) THEN
        RAISE EXCEPTION 'Unknown company: %', p_company
            USING ERRCODE = 'no_data_found';
    END IF;

    RETURN QUERY
    SELECT t.to_company,
           t.to_company_type,
           count(*),
           round(100.0 * count(*) / sum(count(*)) OVER (), 1),
           round(avg(t.salary_change_pct), 1)
    FROM   v_job_transitions t
    WHERE  t.from_company = p_company
    GROUP  BY t.to_company, t.to_company_type
    ORDER  BY count(*) DESC, t.to_company
    LIMIT  p_top;
END;
$$;

-- -----------------------------------------------------------------------------
-- fn_company_sources: where do a company's hires come from? (the mirror image)
--   SELECT * FROM fn_company_sources('Amazon', 5);
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_company_sources(p_company text, p_top integer DEFAULT 10)
RETURNS TABLE (
    source                text,
    source_type           text,
    people                bigint,
    pct_of_hires          numeric,
    avg_salary_change_pct numeric
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_top < 1 THEN
        RAISE EXCEPTION 'p_top must be at least 1 (got %)', p_top
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM companies c WHERE c.company_name = p_company) THEN
        RAISE EXCEPTION 'Unknown company: %', p_company
            USING ERRCODE = 'no_data_found';
    END IF;

    RETURN QUERY
    SELECT t.from_company,
           t.from_company_type,
           count(*),
           round(100.0 * count(*) / sum(count(*)) OVER (), 1),
           round(avg(t.salary_change_pct), 1)
    FROM   v_job_transitions t
    WHERE  t.to_company = p_company
    GROUP  BY t.from_company, t.from_company_type
    ORDER  BY count(*) DESC, t.from_company
    LIMIT  p_top;
END;
$$;

-- -----------------------------------------------------------------------------
-- fn_salary_on: point-in-time salary.
--   SELECT fn_salary_on('EMP-000042', DATE '2020-06-30');
-- Finds the position that covers the date, then the latest salary row effective
-- on or before it. NULL if the person was not employed that day.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_salary_on(p_employee_code text, p_date date)
RETURNS numeric
LANGUAGE sql
STABLE
AS $$
    SELECT s.annual_salary
    FROM   employees e
    JOIN   employment_history eh
           ON  eh.employee_id = e.employee_id
           AND eh.start_date <= p_date
           AND (eh.end_date IS NULL OR eh.end_date > p_date)
    JOIN   salary_history s
           ON  s.employment_id  = eh.employment_id
           AND s.effective_date <= p_date
    WHERE  e.employee_code = p_employee_code
    ORDER  BY s.effective_date DESC
    LIMIT  1;
$$;

-- -----------------------------------------------------------------------------
-- fn_attrition_rate: of the people hired at least N months ago, how many had
-- left within N months of joining? (Q18, parameterised)
--   SELECT * FROM fn_attrition_rate('Infosys', 24);
--   SELECT * FROM fn_attrition_rate(NULL, 12);     -- NULL = all companies
-- Only hires old enough to be observed for the whole period are counted.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_attrition_rate(p_company text, p_months integer)
RETURNS TABLE (
    hires_observed  bigint,
    left_in_period  bigint,
    pct_left        numeric
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    IF p_months < 1 THEN
        RAISE EXCEPTION 'p_months must be at least 1 (got %)', p_months
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    IF p_company IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM companies c WHERE c.company_name = p_company) THEN
        RAISE EXCEPTION 'Unknown company: %', p_company
            USING ERRCODE = 'no_data_found';
    END IF;

    RETURN QUERY
    SELECT count(*),
           count(*) FILTER (WHERE s.stint_end IS NOT NULL
                              AND s.stint_end < s.stint_start + make_interval(months => p_months)),
           round(100.0 * count(*) FILTER (WHERE s.stint_end IS NOT NULL
                              AND s.stint_end < s.stint_start + make_interval(months => p_months))
                 / NULLIF(count(*), 0), 1)
    FROM   v_company_stints s
    CROSS  JOIN v_as_of a
    WHERE  (p_company IS NULL OR s.company_name = p_company)
      AND  s.stint_start <= a.as_of_date - make_interval(months => p_months);
END;
$$;


-- =============================================================================
-- 5. PROCEDURE: refresh the materialized views
--    Run after loading or changing employment data.
--      CALL refresh_analytics_views();          -- readers are not blocked
--      CALL refresh_analytics_views(false);     -- plain refresh (locks, faster)
--    The first refresh of a view that has never held data must be non-concurrent;
--    ours are always populated by file 08.
-- =============================================================================
CREATE OR REPLACE PROCEDURE refresh_analytics_views(p_concurrently boolean DEFAULT true)
LANGUAGE plpgsql
AS $$
DECLARE
    v_name  text;
    v_start timestamptz;
BEGIN
    -- Order matters: nothing depends on another materialized view, so any order works.
    FOREACH v_name IN ARRAY ARRAY['mv_company_transition_matrix',
                                  'mv_company_mobility_summary',
                                  'mv_yearly_mobility',
                                  'mv_career_path_chains']
    LOOP
        v_start := clock_timestamp();
        EXECUTE format('REFRESH MATERIALIZED VIEW %s %I',
                       CASE WHEN p_concurrently THEN 'CONCURRENTLY' ELSE '' END,
                       v_name);
        RAISE NOTICE 'refreshed % in % ms', v_name,
                     round(EXTRACT(milliseconds FROM clock_timestamp() - v_start)::numeric, 1);
    END LOOP;
END;
$$;


-- =============================================================================
-- 6. LIVE DEMONSTRATION: INSERT, UPDATE, DELETE and transactions
--    Everything between the demo SAVEPOINT and rollback-to-savepoint vanishes at the end.
--    The story: a fictional hire joins Infosys, is promoted, then moves to TCS
--    after a gap. The views and functions then describe it without any extra
--    bookkeeping, because transitions and gaps are DERIVED, not stored.
-- =============================================================================
-- The rejection messages below are printed with RAISE NOTICE, so notices must
-- be visible from here to the end of the file. (Set BEFORE the BEGIN: a plain
-- SET inside a transaction would be undone by the ROLLBACK.)
SET client_min_messages = notice;

COMMIT;
BEGIN;

-- INSERT: a new (fictional) employee
INSERT INTO employees (employee_code, college_id, graduation_year)
SELECT 'EMP-DEMO-01', college_id, 2023
FROM   colleges
WHERE  college_name = 'IIT Madras';

-- INSERT: their first position at Infosys (open: end_date is NULL)
INSERT INTO employment_history (employee_id, company_id, role_id, location_id, start_date)
SELECT e.employee_id, c.company_id, r.role_id, l.location_id, DATE '2023-07-03'
FROM   employees e, companies c, job_roles r, locations l
WHERE  e.employee_code = 'EMP-DEMO-01'
  AND  c.company_name  = 'Infosys'
  AND  r.role_title    = 'Software Engineer'
  AND  l.city          = 'Bengaluru';

-- INSERT: joining salary and the first yearly raise (the trigger checks the dates)
INSERT INTO salary_history (employment_id, effective_date, annual_salary, change_reason)
SELECT eh.employment_id, v.d, v.amount, v.reason
FROM   employment_history eh
JOIN   employees e USING (employee_id)
CROSS  JOIN (VALUES (DATE '2023-07-03', 650000, 'joining'),
                    (DATE '2024-07-03', 715000, 'annual_increment')) AS v(d, amount, reason)
WHERE  e.employee_code = 'EMP-DEMO-01';

-- UPDATE + INSERT: a promotion = close the old position, open a new one
UPDATE employment_history eh
SET    end_date = DATE '2025-01-01', separation_type = 'internal_move'
FROM   employees e
WHERE  e.employee_id = eh.employee_id AND e.employee_code = 'EMP-DEMO-01';

INSERT INTO employment_history (employee_id, company_id, role_id, location_id, start_date)
SELECT e.employee_id, c.company_id, r.role_id, l.location_id, DATE '2025-01-01'
FROM   employees e, companies c, job_roles r, locations l
WHERE  e.employee_code = 'EMP-DEMO-01'
  AND  c.company_name  = 'Infosys'
  AND  r.role_title    = 'Senior Software Engineer'
  AND  l.city          = 'Bengaluru';

INSERT INTO salary_history (employment_id, effective_date, annual_salary, change_reason)
SELECT eh.employment_id, DATE '2025-01-01', 920000, 'promotion'
FROM   employment_history eh
JOIN   employees e USING (employee_id)
WHERE  e.employee_code = 'EMP-DEMO-01' AND eh.end_date IS NULL;

-- A job change after a gap: close the Infosys position, start TCS 74 days later
UPDATE employment_history eh
SET    end_date = DATE '2025-12-31', separation_type = 'resigned'
FROM   employees e
WHERE  e.employee_id = eh.employee_id AND e.employee_code = 'EMP-DEMO-01'
  AND  eh.end_date IS NULL;

INSERT INTO employment_history (employee_id, company_id, role_id, location_id, start_date)
SELECT e.employee_id, c.company_id, r.role_id, l.location_id, DATE '2026-03-15'
FROM   employees e, companies c, job_roles r, locations l
WHERE  e.employee_code = 'EMP-DEMO-01'
  AND  c.company_name  = 'Tata Consultancy Services'
  AND  r.role_title    = 'Senior Software Engineer'
  AND  l.city          = 'Pune';

INSERT INTO salary_history (employment_id, effective_date, annual_salary, change_reason)
SELECT eh.employment_id, DATE '2026-03-15', 1080000, 'joining'
FROM   employment_history eh
JOIN   employees e USING (employee_id)
WHERE  e.employee_code = 'EMP-DEMO-01' AND eh.end_date IS NULL;

SELECT position_no, company, role, city, start_date, end_date,
       how_it_started, joining_salary, latest_salary
FROM   fn_employee_career('EMP-DEMO-01');

SELECT from_company, to_company, gap_days, direct_move, seniority_change,
       salary_before, salary_after, salary_change_pct
FROM   v_job_transitions
WHERE  employee_code = 'EMP-DEMO-01';

SELECT previous_company, next_company, exit_reason, gap_start, gap_end, gap_days
FROM   v_unemployment_gaps
WHERE  employee_code = 'EMP-DEMO-01';

SELECT d AS on_date, fn_salary_on('EMP-DEMO-01', d) AS annual_salary
FROM   (VALUES (DATE '2023-01-01'), (DATE '2023-07-03'), (DATE '2024-12-31'),
               (DATE '2025-06-01'), (DATE '2026-01-20'), (DATE '2026-04-01')) AS t(d);


-- -----------------------------------------------------------------------------
-- SAVEPOINT: undo only part of a transaction
-- -----------------------------------------------------------------------------
SAVEPOINT before_mistake;

DELETE FROM employment_history
WHERE  employee_id = (SELECT employee_id FROM employees WHERE employee_code = 'EMP-DEMO-01');

SELECT 'after the DELETE' AS step,
       (SELECT count(*) FROM employment_history eh JOIN employees e USING (employee_id)
        WHERE e.employee_code = 'EMP-DEMO-01') AS positions_left,
       (SELECT count(*) FROM salary_history s JOIN employment_history eh USING (employment_id)
        JOIN employees e USING (employee_id) WHERE e.employee_code = 'EMP-DEMO-01') AS salary_rows_left;

ROLLBACK TO SAVEPOINT before_mistake;

SELECT 'after ROLLBACK TO SAVEPOINT' AS step,
       (SELECT count(*) FROM employment_history eh JOIN employees e USING (employee_id)
        WHERE e.employee_code = 'EMP-DEMO-01') AS positions_left,
       (SELECT count(*) FROM salary_history s JOIN employment_history eh USING (employment_id)
        JOIN employees e USING (employee_id) WHERE e.employee_code = 'EMP-DEMO-01') AS salary_rows_left;


-- -----------------------------------------------------------------------------
-- RULES IN ACTION: every statement below must be REJECTED.
-- Each is wrapped in a DO block that catches the error, so the script goes on
-- and prints what stopped it.
-- -----------------------------------------------------------------------------

-- 1. Salary dated before the position started (trigger)
DO $$
BEGIN
    INSERT INTO salary_history (employment_id, effective_date, annual_salary, change_reason)
    SELECT eh.employment_id, DATE '2022-01-01', 500000, 'joining'
    FROM   employment_history eh JOIN employees e USING (employee_id)
    WHERE  e.employee_code = 'EMP-DEMO-01' AND eh.start_date = DATE '2023-07-03';
    RAISE NOTICE '1. UNEXPECTEDLY ACCEPTED';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '1. Rejected (salary before the position): %', SQLERRM;
END $$;

-- 2. Overlapping jobs for the same employee (exclusion constraint)
DO $$
BEGIN
    INSERT INTO employment_history (employee_id, company_id, role_id, location_id, start_date, end_date, separation_type)
    SELECT e.employee_id, c.company_id, r.role_id, l.location_id,
           DATE '2024-01-01', DATE '2024-06-01', 'resigned'
    FROM   employees e, companies c, job_roles r, locations l
    WHERE  e.employee_code = 'EMP-DEMO-01' AND c.company_name = 'Wipro'
      AND  r.role_title = 'Software Engineer' AND l.city = 'Chennai';
    RAISE NOTICE '2. UNEXPECTEDLY ACCEPTED';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '2. Rejected (two jobs at once): %', SQLERRM;
END $$;

-- 3. A job before the company existed (trigger). CRED was founded in 2018.
DO $$
BEGIN
    INSERT INTO employment_history (employee_id, company_id, role_id, location_id, start_date, end_date, separation_type)
    SELECT e.employee_id, c.company_id, r.role_id, l.location_id,
           DATE '2015-01-01', DATE '2016-01-01', 'resigned'
    FROM   employees e, companies c, job_roles r, locations l
    WHERE  e.employee_code = 'EMP-DEMO-01' AND c.company_name = 'CRED'
      AND  r.role_title = 'Software Engineer' AND l.city = 'Bengaluru';
    RAISE NOTICE '3. UNEXPECTEDLY ACCEPTED';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '3. Rejected (company not founded yet): %', SQLERRM;
END $$;

-- 4. A position that ends before it starts (CHECK constraint)
DO $$
BEGIN
    INSERT INTO employment_history (employee_id, company_id, role_id, location_id, start_date, end_date, separation_type)
    SELECT e.employee_id, c.company_id, r.role_id, l.location_id,
           DATE '2019-05-01', DATE '2019-01-01', 'resigned'
    FROM   employees e, companies c, job_roles r, locations l
    WHERE  e.employee_code = 'EMP-DEMO-01' AND c.company_name = 'Wipro'
      AND  r.role_title = 'Software Engineer' AND l.city = 'Chennai';
    RAISE NOTICE '4. UNEXPECTEDLY ACCEPTED';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '4. Rejected (ends before it starts): %', SQLERRM;
END $$;

-- 5. A closed position without a reason for leaving (CHECK constraint)
DO $$
BEGIN
    UPDATE employment_history eh
    SET    separation_type = NULL
    FROM   employees e
    WHERE  e.employee_id = eh.employee_id AND e.employee_code = 'EMP-DEMO-01'
      AND  eh.start_date = DATE '2023-07-03';
    RAISE NOTICE '5. UNEXPECTEDLY ACCEPTED';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '5. Rejected (closed position with no reason): %', SQLERRM;
END $$;

-- 6. Shrinking a position so a salary row falls outside it (trigger)
DO $$
BEGIN
    UPDATE employment_history eh
    SET    end_date = DATE '2024-01-01'
    FROM   employees e
    WHERE  e.employee_id = eh.employee_id AND e.employee_code = 'EMP-DEMO-01'
      AND  eh.start_date = DATE '2023-07-03';
    RAISE NOTICE '6. UNEXPECTEDLY ACCEPTED';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '6. Rejected (would orphan a salary row): %', SQLERRM;
END $$;

-- 7. Deleting a role that people still hold (foreign key)
DO $$
BEGIN
    DELETE FROM job_roles WHERE role_title = 'Software Engineer';
    RAISE NOTICE '7. UNEXPECTEDLY ACCEPTED';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '7. Rejected (role still in use): %', SQLERRM;
END $$;

-- 8. A negative salary (CHECK constraint)
DO $$
BEGIN
    UPDATE salary_history s
    SET    annual_salary = -1
    FROM   employment_history eh JOIN employees e USING (employee_id)
    WHERE  s.employment_id = eh.employment_id AND e.employee_code = 'EMP-DEMO-01';
    RAISE NOTICE '8. UNEXPECTEDLY ACCEPTED';
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '8. Rejected (salary must be positive): %', SQLERRM;
END $$;

-- DELETE with CASCADE: removing the employee removes their positions and salaries
DELETE FROM employees WHERE employee_code = 'EMP-DEMO-01';

SELECT (SELECT count(*) FROM employees WHERE employee_code = 'EMP-DEMO-01')   AS employees_left,
       (SELECT count(*) FROM employment_history) - 18859                      AS extra_positions_vs_original,
       (SELECT count(*) FROM salary_history)     - 58289                      AS extra_salary_rows_vs_original;

ROLLBACK;   -- undo the entire demo, but keep all functions/triggers/procedures created above


-- =============================================================================
-- 7. TRY THE FUNCTIONS AND THE PROCEDURE ON THE REAL DATA
-- =============================================================================
SELECT * FROM fn_company_destinations('Tata Consultancy Services', 5);

SELECT * FROM fn_company_sources('Amazon', 5);

SELECT 'Infosys, 24 months' AS question, * FROM fn_attrition_rate('Infosys', 24)
UNION ALL
SELECT 'All companies, 12 months', * FROM fn_attrition_rate(NULL, 12);

SELECT position_no, company, role, city, start_date, end_date, how_it_started
FROM   fn_employee_career('EMP-000007');

DO $$
BEGIN
    PERFORM * FROM fn_company_destinations('No Such Company');
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Rejected as expected: %', SQLERRM;
END $$;
DO $$
BEGIN
    PERFORM * FROM fn_attrition_rate('Infosys', 0);
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Rejected as expected: %', SQLERRM;
END $$;

CALL refresh_analytics_views();


-- =============================================================================
-- 8. VERIFICATION: what this file created, and proof the data is untouched
-- =============================================================================
SELECT c.relname AS table_name,
       t.tgname  AS trigger_name,
       CASE WHEN t.tgtype & 2  = 2  THEN 'BEFORE' ELSE 'AFTER' END AS timing,
       concat_ws(' OR ',
                 CASE WHEN t.tgtype & 4  = 4  THEN 'INSERT' END,
                 CASE WHEN t.tgtype & 16 = 16 THEN 'UPDATE' END,
                 CASE WHEN t.tgtype & 8  = 8  THEN 'DELETE' END) AS fires_on
FROM   pg_trigger t
JOIN   pg_class c ON c.oid = t.tgrelid
WHERE  NOT t.tgisinternal
  AND  c.relnamespace = 'public'::regnamespace
ORDER  BY c.relname, t.tgname;

SELECT p.proname AS name,
       CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END AS kind,
       pg_get_function_arguments(p.oid) AS arguments
FROM   pg_proc p
WHERE  p.pronamespace = 'public'::regnamespace
  AND  (p.proname LIKE 'fn\_%' OR p.proname LIKE 'trg\_%' OR p.proname LIKE 'refresh\_%')
ORDER  BY kind DESC, p.proname;

SELECT (SELECT count(*) FROM employees)          AS employees,
       (SELECT count(*) FROM employment_history) AS positions,
       (SELECT count(*) FROM salary_history)     AS salary_rows,
       (SELECT count(*) FROM employees WHERE employee_code LIKE 'EMP-DEMO%') AS demo_rows_left;
