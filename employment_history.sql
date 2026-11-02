-- =============================================================================
-- 04_employment_history.sql
-- Career Mobility & Employee Transition Analytics (100% PostgreSQL)
--
-- PURPOSE
--   Generates the TRANSACTIONAL / HISTORY data for every employee, using SQL
--   only:
--     1. employment_history : each employee's career, one row per POSITION
--     2. salary_history     : salary at joining/promotion plus yearly raises
--
-- RUN ORDER
--   Requires 01_schema.sql, 02_reference_data.sql and 03_employee_data.sql.
--       psql -d career_mobility -f 04_employment_history.sql
--   Safe to re-run: it empties both history tables first.
--
-- HOW THE CAREERS ARE GENERATED (read this before the code)
--   A career is a chain: each position is followed by either
--     * a PROMOTION   (same company, higher role), or
--     * a JOB CHANGE  (different company, maybe after an unemployment gap), or
--     * nothing       (the position is still current on the "as-of" date).
--   That is a Markov-style process, and a RECURSIVE CTE is the natural SQL
--   tool for it: every recursion step creates the next position from the
--   previous one, and the recursion stops when the next position would start
--   after the as-of date.
--
--   Realism comes from small weight tables (temp tables, dropped at the end):
--     gen_type_affinity : which company TYPE people move to from which type
--     gen_family_fit    : which job families suit which company types
--     gen_entry_weight  : where graduates of each college tier start
--     gen_family_shift  : which job families people drift into
--   The next company is chosen by weighted random sampling: for every
--   candidate company we compute  -ln(1 - random()) / weight  and keep the
--   SMALLEST value. (This "exponential race" picks each candidate with
--   probability proportional to its weight, in plain SQL.)
--
--   Other realism built in:
--     * Tenure is random and type-dependent (average position: ~25 months at
--       startups, ~47 at banks); 12% of employees are frequent job-hoppers
--       and 18% are loyalists who stay much longer.
--     * Companies cannot hire before they were founded.
--     * ~79% of job changes are direct; the rest have gaps of weeks to
--       ~2 years. Layoffs are more likely in 2020 and in the 2022-2024 tech
--       slowdown, and are followed by longer gaps.
--     * Salary follows level, company type, city tier and inflation; job
--       changes give a raise that depends on the type of company moved to.
--
-- DATA RULES THAT HOLD BY CONSTRUCTION
--   * Positions of one employee never overlap and have at most one current
--     position (also enforced by the exclusion constraint in file 01).
--   * end_date is EXCLUSIVE; a direct move starts on the previous end_date.
--   * The first salary row of a position is dated at the position start
--     (reason 'joining' for a new employer, 'promotion' for an internal move).
--   * An employee whose last position has an end_date and no successor is
--     currently unemployed (this is derived, never stored).
--   * "As-of" date of the dataset: 2026-10-24 (see gen_params below).
-- =============================================================================

SET client_min_messages = warning;   -- hides "table does not exist" notices

BEGIN;

TRUNCATE TABLE salary_history, employment_history RESTART IDENTITY;

-- Reproducible randomness (see 03_employee_data.sql).
SELECT setseed(0.84);


-- -----------------------------------------------------------------------------
-- 0. CLEAN UP TEMP TABLES FROM ANY EARLIER RUN IN THIS SESSION
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS gen_params, gen_company_weight, gen_type_affinity,
                     gen_family_fit, gen_entry_weight, gen_family_shift,
                     gen_next_level, gen_work_location, gen_type_pay,
                     gen_employee_profile, gen_position, gen_anniversary,
                     gen_position_mult, gen_salary_chain;


-- =============================================================================
-- 1. GENERATION PARAMETERS AND WEIGHT TABLES (temporary)
-- =============================================================================

-- The date "today" means for this dataset. Fixed (not current_date) so results
-- stay reproducible no matter when the script is run.
CREATE TEMP TABLE gen_params AS
SELECT DATE '2026-10-24' AS as_of_date;

-- -----------------------------------------------------------------------------
-- Company sampling weights. Bigger companies hire more people; a few household
-- names get an extra boost so the transition rankings are not flat.
--   mean_months : average extra tenure by company type
--   p_hq        : chance a new hire sits in the company's main hub city
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE gen_company_weight AS
SELECT c.company_id,
       c.company_type,
       c.industry_id,
       c.founded_year,
       c.hq_location_id,
       ( CASE c.size_band WHEN 'enterprise' THEN 6.0
                          WHEN 'large'      THEN 3.5
                          WHEN 'medium'     THEN 1.6
                          ELSE 0.7 END
         * (0.7 + 0.6 * random())                       -- company-specific luck
         * CASE WHEN c.company_type = 'startup' THEN 3.0 ELSE 1.0 END  -- startups are many but small
         * CASE c.company_name
               WHEN 'Tata Consultancy Services' THEN 2.2
               WHEN 'Infosys'                   THEN 1.8
               WHEN 'Wipro'                     THEN 1.4
               WHEN 'Cognizant'                 THEN 1.3
               WHEN 'HCLTech'                   THEN 1.3
               WHEN 'Accenture'                 THEN 1.3
               ELSE 1.0 END
       )::numeric(8,3) AS base_weight,
       CASE c.company_type WHEN 'it_services'  THEN 32
                           WHEN 'bank_finance' THEN 40
                           WHEN 'other'        THEN 44
                           WHEN 'consulting'   THEN 28
                           WHEN 'product'      THEN 28
                           WHEN 'big_tech'     THEN 32
                           WHEN 'startup'      THEN 18 END AS mean_months,
       CASE c.size_band WHEN 'small'  THEN 0.85
                        WHEN 'medium' THEN 0.85
                        WHEN 'large'  THEN 0.55
                        ELSE 0.45 END AS p_hq
FROM   companies c;

-- -----------------------------------------------------------------------------
-- Which company TYPE people move to, given the type they leave (relative weights)
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE gen_type_affinity (
    from_type text, to_type text, weight numeric
);
INSERT INTO gen_type_affinity VALUES
    ('startup',      'startup',      3.0), ('startup',      'product',      3.0),
    ('startup',      'it_services',  1.5), ('startup',      'big_tech',     1.2),
    ('startup',      'bank_finance', 0.5), ('startup',      'consulting',   0.8),
    ('startup',      'other',        0.4),

    ('it_services',  'it_services',  6.0), ('it_services',  'product',      2.5),
    ('it_services',  'big_tech',     1.8), ('it_services',  'startup',      1.2),
    ('it_services',  'bank_finance', 1.2), ('it_services',  'consulting',   1.5),
    ('it_services',  'other',        0.5),

    ('product',      'product',      4.0), ('product',      'big_tech',     2.5),
    ('product',      'startup',      2.5), ('product',      'it_services',  1.0),
    ('product',      'bank_finance', 0.8), ('product',      'consulting',   0.7),
    ('product',      'other',        0.3),

    ('big_tech',     'big_tech',     3.5), ('big_tech',     'product',      3.5),
    ('big_tech',     'startup',      2.5), ('big_tech',     'it_services',  0.4),
    ('big_tech',     'bank_finance', 0.8), ('big_tech',     'consulting',   0.6),
    ('big_tech',     'other',        0.2),

    ('bank_finance', 'bank_finance', 5.0), ('bank_finance', 'it_services',  1.2),
    ('bank_finance', 'consulting',   1.5), ('bank_finance', 'product',      1.2),
    ('bank_finance', 'big_tech',     0.6), ('bank_finance', 'startup',      0.7),
    ('bank_finance', 'other',        0.8),

    ('consulting',   'consulting',   4.0), ('consulting',   'bank_finance', 2.0),
    ('consulting',   'it_services',  1.5), ('consulting',   'product',      1.5),
    ('consulting',   'big_tech',     1.0), ('consulting',   'startup',      0.8),
    ('consulting',   'other',        0.8),

    ('other',        'other',        4.0), ('other',        'it_services',  1.5),
    ('other',        'bank_finance', 1.5), ('other',        'consulting',   1.0),
    ('other',        'product',      0.8), ('other',        'big_tech',     0.4),
    ('other',        'startup',      0.5);

-- -----------------------------------------------------------------------------
-- How well each job family fits each company type (relative weights)
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE gen_family_fit (
    family text, company_type text, weight numeric
);
INSERT INTO gen_family_fit VALUES
    ('Engineering',    'startup', 1.0), ('Engineering',    'it_services', 1.2), ('Engineering',    'product', 1.2),
    ('Engineering',    'big_tech',1.2), ('Engineering',    'bank_finance',0.5), ('Engineering',    'consulting',0.2), ('Engineering',    'other', 0.4),
    ('Data',           'startup', 1.0), ('Data',           'it_services', 0.9), ('Data',           'product', 1.1),
    ('Data',           'big_tech',1.2), ('Data',           'bank_finance',0.8), ('Data',           'consulting',0.5), ('Data',           'other', 0.3),
    ('Infrastructure', 'startup', 0.7), ('Infrastructure', 'it_services', 1.3), ('Infrastructure', 'product', 0.9),
    ('Infrastructure', 'big_tech',1.0), ('Infrastructure', 'bank_finance',0.8), ('Infrastructure', 'consulting',0.3), ('Infrastructure', 'other', 0.5),
    ('Product',        'startup', 1.3), ('Product',        'it_services', 0.1), ('Product',        'product', 1.5),
    ('Product',        'big_tech',1.5), ('Product',        'bank_finance',0.3), ('Product',        'consulting',0.2), ('Product',        'other', 0.1),
    ('Consulting',     'startup', 0.3), ('Consulting',     'it_services', 0.5), ('Consulting',     'product', 0.2),
    ('Consulting',     'big_tech',0.2), ('Consulting',     'bank_finance',0.5), ('Consulting',     'consulting',3.0), ('Consulting',     'other', 0.3),
    ('Finance',        'startup', 0.4), ('Finance',        'it_services', 0.1), ('Finance',        'product', 0.2),
    ('Finance',        'big_tech',0.2), ('Finance',        'bank_finance',3.0), ('Finance',        'consulting',1.0), ('Finance',        'other', 0.8),
    ('Operations',     'startup', 0.5), ('Operations',     'it_services', 0.8), ('Operations',     'product', 0.6),
    ('Operations',     'big_tech',0.6), ('Operations',     'bank_finance',1.0), ('Operations',     'consulting',1.0), ('Operations',     'other', 2.0);

-- -----------------------------------------------------------------------------
-- Where graduates start, by college tier (tier 0 = no college recorded)
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE gen_entry_weight (
    college_tier int, company_type text, weight numeric
);
INSERT INTO gen_entry_weight VALUES
    (1,'big_tech',3.0), (1,'product',3.0), (1,'startup',1.5), (1,'consulting',2.0),
    (1,'bank_finance',1.8), (1,'it_services',1.2), (1,'other',0.6),
    (2,'big_tech',0.7), (2,'product',1.5), (2,'startup',1.2), (2,'consulting',0.8),
    (2,'bank_finance',1.2), (2,'it_services',3.0), (2,'other',1.0),
    (3,'big_tech',0.1), (3,'product',0.4), (3,'startup',1.0), (3,'consulting',0.3),
    (3,'bank_finance',1.0), (3,'it_services',4.0), (3,'other',1.2),
    (0,'big_tech',0.02),(0,'product',0.2), (0,'startup',1.5), (0,'consulting',0.2),
    (0,'bank_finance',1.0), (0,'it_services',2.5), (0,'other',2.0);

-- -----------------------------------------------------------------------------
-- Which job families people drift into when they change family (10% of changes)
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE gen_family_shift (
    from_family text, to_family text, weight numeric
);
INSERT INTO gen_family_shift VALUES
    ('Engineering',    'Data',           3.0), ('Engineering',    'Infrastructure', 2.0),
    ('Engineering',    'Product',        2.0), ('Engineering',    'Operations',     1.0),
    ('Data',           'Engineering',    3.0), ('Data',           'Product',        1.5),
    ('Data',           'Consulting',     1.0), ('Data',           'Finance',        1.0),
    ('Infrastructure', 'Engineering',    3.0), ('Infrastructure', 'Operations',     1.0),
    ('Infrastructure', 'Data',           1.0),
    ('Product',        'Engineering',    1.5), ('Product',        'Consulting',     1.5),
    ('Product',        'Operations',     1.0),
    ('Consulting',     'Finance',        2.0), ('Consulting',     'Product',        2.0),
    ('Consulting',     'Operations',     2.0),
    ('Finance',        'Consulting',     2.0), ('Finance',        'Data',           1.5),
    ('Finance',        'Operations',     1.5),
    ('Operations',     'Consulting',     1.5), ('Operations',     'Product',        1.0),
    ('Operations',     'Finance',        1.0), ('Operations',     'Engineering',    1.0);

-- -----------------------------------------------------------------------------
-- For every (job family, seniority level): the next HIGHER level that exists in
-- that family (NULL at the top). Used to decide whether a promotion is possible.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE gen_next_level AS
SELECT f.job_family,
       l.lvl AS lvl,
       (SELECT min(r.seniority_level)
        FROM   job_roles r
        WHERE  r.job_family = f.job_family
          AND  r.seniority_level > l.lvl) AS next_level
FROM   (SELECT DISTINCT job_family FROM job_roles) f
CROSS  JOIN generate_series(1, 8) AS l(lvl);

-- Cities where people can work (tier 1 and 2 only; tier 3 are college towns).
CREATE TEMP TABLE gen_work_location AS
SELECT location_id,
       CASE city_tier WHEN 1 THEN 5.0 ELSE 1.2 END AS weight
FROM   locations
WHERE  city_tier <= 2;

-- Pay by company type: entry-salary multiplier and a "premium" used when
-- someone moves between types (moving to big tech pays more than leaving it).
CREATE TEMP TABLE gen_type_pay (
    company_type text, entry_mult numeric, premium numeric
);
INSERT INTO gen_type_pay VALUES
    ('big_tech',     1.90,  0.12),
    ('product',      1.40,  0.07),
    ('consulting',   1.20,  0.04),
    ('bank_finance', 1.10,  0.03),
    ('startup',      1.00,  0.00),
    ('other',        0.90, -0.03),
    ('it_services',  0.85, -0.02);


-- =============================================================================
-- 2. EMPLOYEE "PERSONAS" (temporary)
--    The traits that stay constant across one employee's whole career.
-- =============================================================================
CREATE TEMP TABLE gen_employee_profile AS
WITH base AS (
    SELECT e.employee_id,
           e.graduation_year,
           COALESCE(c.college_tier, 0) AS college_tier,
           c.location_id               AS college_location_id,
           random() AS r_family,
           random() AS r_stay,
           random() AS r_start
    FROM   employees e
    LEFT   JOIN colleges c ON c.college_id = e.college_id
)
SELECT employee_id,
       college_tier,
       college_location_id,
       -- Starting job family
       CASE WHEN r_family < 0.52 THEN 'Engineering'
            WHEN r_family < 0.66 THEN 'Data'
            WHEN r_family < 0.75 THEN 'Infrastructure'
            WHEN r_family < 0.83 THEN 'Consulting'
            WHEN r_family < 0.90 THEN 'Finance'
            WHEN r_family < 0.94 THEN 'Product'
            ELSE 'Operations' END                                  AS family,
       -- Tenure multiplier: 12% job-hoppers, 70% typical, 18% loyalists
       CASE WHEN r_stay < 0.12 THEN 0.55 + 0.20 * random()
            WHEN r_stay < 0.82 THEN 0.80 + 0.50 * random()
            ELSE                    1.50 + 1.00 * random() END::float8 AS stay_factor,
       -- Starting seniority: 1 (trainee) or 2; diploma/no-college start at 1
       CASE WHEN college_tier = 0 THEN 1
            WHEN random() < 0.35  THEN 1
            ELSE 2 END                                              AS start_level,
       -- First joining date: campus hiring season for graduates, any time of
       -- the year for employees without a recorded college
       CASE WHEN college_tier = 0
            THEN make_date(graduation_year, 1, 1) + floor(r_start * 360)::int
            ELSE make_date(graduation_year, 6, 1) + floor(r_start * 130)::int
       END                                                          AS first_start
FROM   base;


-- =============================================================================
-- 3. EMPLOYMENT HISTORY  (the career simulation: a recursive CTE)
--
--    Row "step 0" is a virtual starting row (not inserted): it represents the
--    moment of graduation, so the very first company is picked with the same
--    logic as every later job change.
--    Each recursive step creates ONE position from the previous one. The
--    LATERAL subqueries are the decisions, in order (A to F):
--      A  when does the next position start, and does the job family change?
--      B  how much can seniority change (capped by years of experience)?
--      C  which company (or the same one, for a promotion)?
--      D  which role in that company / family?
--      E  which city?
--      F  how long does it last, and how does it end?
-- =============================================================================
INSERT INTO employment_history
       (employee_id, company_id, role_id, location_id,
        start_date, end_date, separation_type)
WITH RECURSIVE career AS (

    -- ANCHOR: the virtual step-0 row for every employee ----------------------
    SELECT p.employee_id,
           0                       AS step,
           NULL::int               AS company_id,
           NULL::text              AS company_type,
           NULL::int               AS industry_id,
           NULL::int               AS role_id,
           p.start_level           AS role_level,
           p.family                AS family,
           p.college_location_id   AS location_id,
           p.first_start           AS start_date,
           p.first_start           AS end_date,       -- planned end
           false                   AS is_current,
           'switch'::text          AS next_action,    -- promote | switch | none
           NULL::text              AS sep_type,
           0                       AS gap_days,       -- unemployment before the next position
           p.first_start           AS career_start,
           p.stay_factor           AS stay_factor,
           p.college_tier          AS college_tier
    FROM   gen_employee_profile p

    UNION ALL

    -- RECURSIVE STEP: build the next position ---------------------------------
    SELECT c.employee_id,
           c.step + 1,
           co.company_id,
           co.company_type,
           co.industry_id,
           ro.role_id,
           ro.seniority_level,
           a.new_family,
           loc.location_id,
           a.next_start,
           f1.end_date,
           f2.is_current,
           f3.next_action,
           f4.sep_type,
           f5.gap_days,
           c.career_start,
           c.stay_factor,
           c.college_tier
    FROM   career c
    CROSS  JOIN gen_params gp

    -- A: start date of the next position; 10% of job changes also shift the
    --    job family (e.g. Engineering -> Data). Never at step 0.
    CROSS  JOIN LATERAL (
        SELECT c.end_date
                 + CASE WHEN c.next_action = 'switch' THEN c.gap_days ELSE 0 END
                   AS next_start,
               CASE WHEN c.step > 0
                     AND c.next_action = 'switch'
                     AND random() < 0.10
                    THEN (SELECT fs.to_family
                          FROM   gen_family_shift fs
                          WHERE  fs.from_family = c.family
                          ORDER  BY -ln(1 - random()) / fs.weight
                          LIMIT  1)
                    ELSE c.family END AS new_family
    ) a

    -- B: seniority ceiling from experience, and a random level change for a
    --    job change (-1: 10%, 0: 38%, +1: 42%, +2: 10%). Step 0 keeps its level.
    CROSS  JOIN LATERAL (
        SELECT LEAST(8, 2 + floor((a.next_start - c.career_start) / 365.25 / 2.7))::int
                 AS lvl_cap,
               CASE WHEN c.step = 0 THEN 0
                    WHEN x.r < 0.10 THEN -1
                    WHEN x.r < 0.48 THEN  0
                    WHEN x.r < 0.90 THEN  1
                    ELSE 2 END AS delta
        -- "+ 0 * c.employee_id" ties the random draw to the current row;
        -- otherwise PostgreSQL would draw once and reuse it for every row.
        FROM   (SELECT random() + 0 * c.employee_id AS r) x
    ) b

    -- C: the company. A promotion stays; a job change draws a weighted random
    --    company. Weight = size/popularity x type affinity (or entry weight
    --    at step 0) x family fit x same-industry bonus. Companies not yet
    --    founded and the current employer are excluded.
    CROSS  JOIN LATERAL (
        SELECT COALESCE(
                 CASE WHEN c.next_action = 'promote' THEN c.company_id END,
                 (SELECT cw.company_id
                  FROM   gen_company_weight cw
                  LEFT   JOIN gen_type_affinity ta
                         ON  ta.from_type = c.company_type
                         AND ta.to_type   = cw.company_type
                  LEFT   JOIN gen_entry_weight ew
                         ON  c.step = 0
                         AND ew.college_tier  = c.college_tier
                         AND ew.company_type  = cw.company_type
                  JOIN   gen_family_fit ff
                         ON  ff.family       = a.new_family
                         AND ff.company_type = cw.company_type
                  WHERE  cw.company_id IS DISTINCT FROM c.company_id
                    AND (cw.founded_year IS NULL
                         OR cw.founded_year <= EXTRACT(year FROM a.next_start))
                  ORDER  BY -ln(1 - random())
                            / ( cw.base_weight
                                * COALESCE(ta.weight, ew.weight, 1.0)
                                * ff.weight
                                * CASE WHEN cw.industry_id = c.industry_id
                                       THEN 1.6 ELSE 1.0 END )
                  LIMIT  1)
               ) AS company_id
    ) cc
    JOIN   gen_company_weight co ON co.company_id = cc.company_id

    -- D: the role. A promotion takes the next higher level in the family; a
    --    job change takes the role closest to the desired level. Ties prefer
    --    "Software Development Engineer" titles at big tech, "Software
    --    Engineer" titles elsewhere, then break randomly.
    CROSS  JOIN LATERAL (
        SELECT r.role_id, r.seniority_level
        FROM   job_roles r
        WHERE  r.job_family = a.new_family
        ORDER  BY CASE WHEN c.next_action = 'promote'
                       THEN CASE WHEN r.seniority_level > c.role_level
                                 THEN r.seniority_level ELSE 99 END
                       ELSE abs(r.seniority_level
                                - GREATEST(1, LEAST(b.lvl_cap, c.role_level + b.delta)))
                  END,
                  (r.role_title LIKE '%Development Engineer%')
                      <> (co.company_type = 'big_tech'),
                  random()
        LIMIT  1
    ) ro

    -- E: the city. Promotions almost always stay put (92%); job changes keep
    --    the old city 38% of the time, else the company hub, else a random city.
    CROSS  JOIN LATERAL (
        SELECT CASE
                 WHEN c.location_id IS NOT NULL
                  AND random() < CASE WHEN c.next_action = 'promote'
                                      THEN 0.92 ELSE 0.38 END
                      THEN c.location_id
                 WHEN random() < co.p_hq
                      THEN co.hq_location_id
                 -- "+ 0 * c.employee_id" makes the subquery depend on the current
                 -- row. Without it PostgreSQL would run it ONCE and reuse the same
                 -- city for every employee.
                 ELSE (SELECT wl.location_id
                       FROM   gen_work_location wl
                       ORDER  BY -ln(1 - random()) / (wl.weight + 0 * c.employee_id)
                       LIMIT  1)
               END AS location_id
    ) loc

    -- F1: planned end date = start + at least 210 days + an exponential
    --     random tenure scaled by company type and the employee's stay factor.
    CROSS  JOIN LATERAL (
        SELECT a.next_start
                 + LEAST(5500, round(210 + (-ln(1 - random()))
                                           * co.mean_months * 30.4
                                           * c.stay_factor))::int AS end_date
    ) f1

    -- F2: is the position still running on the as-of date? Could the person
    --     be promoted (a higher role exists and experience allows it)?
    CROSS  JOIN LATERAL (
        SELECT (f1.end_date >= gp.as_of_date) AS is_current,
               COALESCE(
                 (SELECT nl.next_level
                  FROM   gen_next_level nl
                  WHERE  nl.job_family = a.new_family
                    AND  nl.lvl        = ro.seniority_level), 99)
               <= LEAST(8, 2 + floor((f1.end_date - c.career_start) / 365.25 / 2.7))
                 AS promo_ok
    ) f2

    -- F3: how does this position end? Draw the random numbers used below.
    --     lay_p = layoff probability: company-type base x year multiplier
    --     (2020 pandemic, 2022-2024 tech slowdown peaking in 2023).
    CROSS  JOIN LATERAL (
        SELECT CASE WHEN f2.is_current                  THEN 'none'
                    WHEN f2.promo_ok AND random() < 0.38 THEN 'promote'
                    ELSE 'switch' END AS next_action,
               random() AS r_sep,
               random() AS r_gap,
               random() AS r_len,
               ( CASE co.company_type WHEN 'startup'      THEN 0.14
                                      WHEN 'product'      THEN 0.07
                                      WHEN 'big_tech'     THEN 0.05
                                      WHEN 'it_services'  THEN 0.05
                                      WHEN 'bank_finance' THEN 0.02
                                      WHEN 'consulting'   THEN 0.06
                                      ELSE                     0.03 END
                 * CASE EXTRACT(year FROM f1.end_date)::int
                       WHEN 2020 THEN 1.8
                       WHEN 2022 THEN 1.3
                       WHEN 2023 THEN 2.5
                       WHEN 2024 THEN 1.6
                       ELSE 1.0 END ) AS lay_p,
               CASE WHEN co.company_type = 'startup' THEN 0.05 ELSE 0.015 END AS ce_p
    ) f3

    -- F4: the separation reason
    CROSS  JOIN LATERAL (
        SELECT CASE f3.next_action
                 WHEN 'none'    THEN NULL
                 WHEN 'promote' THEN 'internal_move'
                 ELSE CASE WHEN f3.r_sep < f3.lay_p                     THEN 'laid_off'
                           WHEN f3.r_sep < f3.lay_p + 0.02              THEN 'terminated'
                           WHEN f3.r_sep < f3.lay_p + 0.02 + f3.ce_p    THEN 'contract_end'
                           ELSE 'resigned' END
               END AS sep_type
    ) f4

    -- F5: unemployment gap (days) before the NEXT position. Layoffs and
    --     terminations: 70% have a gap of 1-6 months or longer. Others:
    --     83% direct, 10% short, 5% medium, 1.5% long career break.
    CROSS  JOIN LATERAL (
        SELECT CASE
                 WHEN f3.next_action <> 'switch' THEN 0
                 WHEN f4.sep_type IN ('laid_off', 'terminated') THEN
                      CASE WHEN f3.r_gap < 0.30 THEN 0
                           WHEN f3.r_gap < 0.85 THEN 30  + floor(f3.r_len * 150)::int
                           ELSE                      180 + floor(f3.r_len * 300)::int END
                 ELSE CASE WHEN f3.r_gap < 0.83  THEN 0
                           WHEN f3.r_gap < 0.93  THEN 14  + floor(f3.r_len * 76)::int
                           WHEN f3.r_gap < 0.985 THEN 91  + floor(f3.r_len * 180)::int
                           ELSE                       271 + floor(f3.r_len * 460)::int END
               END AS gap_days
    ) f5

    -- Continue only from positions that ended before the as-of date, and only
    -- if the next one would start before it. If it would not, the employee is
    -- currently unemployed (their last position simply has an end_date).
    WHERE  c.next_action <> 'none'
      AND  a.next_start  <  gp.as_of_date
)
SELECT employee_id,
       company_id,
       role_id,
       location_id,
       start_date,
       CASE WHEN is_current THEN NULL ELSE end_date END,
       sep_type
FROM   career
WHERE  step > 0
ORDER  BY employee_id, step;


-- =============================================================================
-- 4. SALARY HISTORY
--    Built from the positions just inserted.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 4a. Positions with their neighbours (window functions: LAG / ROW_NUMBER).
--     base_growth is this position's typical yearly raise (5% to 11%).
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE gen_position AS
SELECT eh.employment_id,
       eh.employee_id,
       eh.company_id,
       eh.start_date,
       eh.end_date,
       row_number() OVER w                     AS rn,
       lag(eh.company_id) OVER w               AS prev_company_id,
       r.seniority_level                       AS lvl,
       lag(r.seniority_level) OVER w           AS prev_lvl,
       r.job_family                            AS family,
       co.company_type                         AS company_type,
       lag(co.company_type) OVER w             AS prev_company_type,
       l.city_tier                             AS city_tier,
       lag(l.city_tier) OVER w                 AS prev_city_tier,
       (0.05 + 0.06 * random())::numeric(6,4)  AS base_growth,
       -- "Market" joining salary for this exact role/company type/city/year:
       -- base by seniority x company-type pay x family x city tier x inflation
       -- x random noise. Used as the first salary and as a gravity pull later.
       (round(
          ( CASE r.seniority_level WHEN 1 THEN 320000  WHEN 2 THEN 500000
                                   WHEN 3 THEN 850000  WHEN 4 THEN 1300000
                                   WHEN 5 THEN 2000000 WHEN 6 THEN 3000000
                                   WHEN 7 THEN 4500000 ELSE 6500000 END
            * tp.entry_mult
            * CASE r.job_family WHEN 'Data'           THEN 1.05
                                WHEN 'Infrastructure' THEN 0.95
                                WHEN 'Product'        THEN 1.25
                                WHEN 'Finance'        THEN 0.95
                                WHEN 'Operations'     THEN 0.85
                                ELSE 1.0 END
            * CASE l.city_tier WHEN 1 THEN 1.0 ELSE 0.93 END
            * power(1.06, EXTRACT(year FROM eh.start_date) - 2020)
            * (0.85 + 0.35 * random())
          )::numeric / 1000) * 1000)::float8   AS benchmark_salary
FROM   employment_history eh
JOIN   job_roles    r  ON r.role_id      = eh.role_id
JOIN   companies    co ON co.company_id  = eh.company_id
JOIN   gen_type_pay tp ON tp.company_type = co.company_type
JOIN   locations    l  ON l.location_id  = eh.location_id
WINDOW w AS (PARTITION BY eh.employee_id ORDER BY eh.start_date);

-- -----------------------------------------------------------------------------
-- 4b. Yearly raises on each position anniversary that falls inside the
--     position. cum_mult is the cumulative growth since joining, computed as
--     exp(running sum of ln(factor)) = running product of the yearly factors.
--     About 7% of raises are off-cycle "market adjustments" with a bigger bump.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE gen_anniversary AS
WITH raw AS (
    SELECT p.employment_id,
           k.k,
           (p.start_date + make_interval(years => k.k))::date AS effective_date,
           random() AS r_inc,
           random() AS r_mkt,
           p.base_growth
    FROM   gen_position p
    CROSS  JOIN gen_params gp
    CROSS  JOIN LATERAL generate_series(
                   1, (COALESCE(p.end_date, gp.as_of_date) - p.start_date) / 365) AS k(k)
    WHERE  (p.start_date + make_interval(years => k.k))::date
             < COALESCE(p.end_date, gp.as_of_date + 1)
),
factored AS (
    SELECT employment_id, k, effective_date,
           1 + base_growth * (0.7 + 0.6 * r_inc)
             + CASE WHEN r_mkt < 0.07 THEN 0.05 ELSE 0 END      AS factor,
           CASE WHEN r_mkt < 0.07 THEN 'market_adjustment'
                ELSE 'annual_increment' END                      AS reason
    FROM   raw
)
SELECT employment_id, k, effective_date, reason,
       exp(sum(ln(factor)) OVER (PARTITION BY employment_id ORDER BY k)) AS cum_mult
FROM   factored;

-- Growth achieved by the end of each position (1.0 if it had no anniversary)
CREATE TEMP TABLE gen_position_mult AS
SELECT employment_id, max(cum_mult) AS final_mult
FROM   gen_anniversary
GROUP  BY employment_id;

-- -----------------------------------------------------------------------------
-- 4c. Joining salary of every position, chained through each career
--     (a second recursive CTE: position n starts from where position n-1
--     ended). Position 1 starts at its "market" benchmark. Later positions:
--       * the previous salary is multiplied by a raise:
--           - promotion (same company): +8% to +16%
--           - job change: +7% base, +8% per seniority level gained, plus the
--             pay premium of the new company type minus the old one, a city
--             adjustment and random noise; never worse than -15%
--       * then pulled 35% of the way toward the market benchmark of the new
--         role, so pay still tracks seniority and company type over a career.
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE gen_salary_chain AS
WITH RECURSIVE chain AS (
    SELECT p.employee_id,
           p.rn,
           p.employment_id,
           p.benchmark_salary                                  AS joining_salary,
           p.benchmark_salary * COALESCE(m.final_mult, 1)      AS final_salary
    FROM   gen_position p
    LEFT   JOIN gen_position_mult m ON m.employment_id = p.employment_id
    WHERE  p.rn = 1

    UNION ALL

    SELECT p.employee_id,
           p.rn,
           p.employment_id,
           j.joining_salary,
           j.joining_salary * COALESCE(m.final_mult, 1)
    FROM   chain c
    JOIN   gen_position p
           ON  p.employee_id = c.employee_id
           AND p.rn          = c.rn + 1
    JOIN   gen_type_pay tt ON tt.company_type = p.company_type
    JOIN   gen_type_pay tf ON tf.company_type = p.prev_company_type
    LEFT   JOIN gen_position_mult m ON m.employment_id = p.employment_id
    CROSS  JOIN LATERAL (
        SELECT round(
                 ( 0.65 * c.final_salary
                          * GREATEST(0.85,
                              CASE WHEN p.company_id = p.prev_company_id
                                   THEN 1.08 + 0.08 * random()                -- promotion
                                   ELSE 1.07 + 0.08 * (p.lvl - p.prev_lvl)    -- job change
                                        + (tt.premium - tf.premium)
                                        + 0.03 * (p.prev_city_tier - p.city_tier)
                                        + (random() + random() + random() - 1.5) * 0.12
                              END)
                 + 0.35 * p.benchmark_salary
                 ) / 100)::float8 * 100 AS joining_salary
    ) j
)
SELECT * FROM chain;

-- -----------------------------------------------------------------------------
-- 4d. Write salary_history: the joining/promotion row of each position, then
--     its yearly raises.
-- -----------------------------------------------------------------------------
INSERT INTO salary_history (employment_id, effective_date, annual_salary, change_reason)
SELECT p.employment_id,
       p.start_date,
       ch.joining_salary,
       CASE WHEN p.company_id = p.prev_company_id THEN 'promotion'
            ELSE 'joining' END
FROM   gen_position     p
JOIN   gen_salary_chain ch ON ch.employment_id = p.employment_id
UNION  ALL
SELECT a.employment_id,
       a.effective_date,
       round((ch.joining_salary * a.cum_mult)::numeric, -2),
       a.reason
FROM   gen_anniversary  a
JOIN   gen_salary_chain ch ON ch.employment_id = a.employment_id
ORDER  BY 1, 2;

COMMIT;


-- =============================================================================
-- 5. CLEAN UP TEMP TABLES
-- =============================================================================
DROP TABLE IF EXISTS gen_params, gen_company_weight, gen_type_affinity,
                     gen_family_fit, gen_entry_weight, gen_family_shift,
                     gen_next_level, gen_work_location, gen_type_pay,
                     gen_employee_profile, gen_position, gen_anniversary,
                     gen_position_mult, gen_salary_chain;


-- =============================================================================
-- 6. VERIFICATION
-- =============================================================================

-- Row counts
SELECT (SELECT count(*) FROM employees)          AS employees,
       (SELECT count(*) FROM employment_history) AS positions,
       (SELECT count(*) FROM salary_history)     AS salary_rows;

-- Positions per employee (every employee should have at least one)
SELECT positions, count(*) AS employees
FROM  (SELECT e.employee_id, count(eh.employment_id) AS positions
       FROM   employees e
       LEFT   JOIN employment_history eh USING (employee_id)
       GROUP  BY e.employee_id) t
GROUP  BY positions
ORDER  BY positions;

-- How positions ended (internal_move = promotion; NULL = current position)
SELECT coalesce(separation_type, 'current') AS how_it_ended,
       count(*)                             AS positions,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM   employment_history
GROUP  BY separation_type
ORDER  BY positions DESC;

-- Employment status as of 2026-10-24 (derived: no open position = unemployed)
SELECT CASE WHEN has_current THEN 'currently employed'
            ELSE 'currently unemployed' END AS status,
       count(*) AS employees
FROM  (SELECT employee_id,
              bool_or(end_date IS NULL) AS has_current
       FROM   employment_history
       GROUP  BY employee_id) t
GROUP  BY has_current
ORDER  BY employees DESC;

-- Layoff waves: layoffs per end year (expect peaks in 2020 and 2023)
SELECT EXTRACT(year FROM end_date)::int AS year,
       count(*) FILTER (WHERE separation_type = 'laid_off') AS layoffs,
       count(*) FILTER (WHERE separation_type IN ('resigned','laid_off','terminated','contract_end')) AS company_exits
FROM   employment_history
WHERE  end_date IS NOT NULL
GROUP  BY 1
ORDER  BY 1;

-- Integrity: salary rows outside their position's dates (expected: 0)
SELECT count(*) AS salary_rows_outside_position
FROM   salary_history s
JOIN   employment_history e USING (employment_id)
WHERE  s.effective_date <  e.start_date
   OR  s.effective_date >= COALESCE(e.end_date, DATE '2026-10-25');

-- Integrity: positions starting before the company existed (expected: 0)
SELECT count(*) AS positions_before_company_founded
FROM   employment_history e
JOIN   companies c USING (company_id)
WHERE  c.founded_year IS NOT NULL
  AND  EXTRACT(year FROM e.start_date) < c.founded_year;

-- Salary sanity by seniority level (INR per year)
SELECT r.seniority_level,
       count(*)                                         AS salary_rows,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY s.annual_salary)) AS median_salary
FROM   salary_history s
JOIN   employment_history e USING (employment_id)
JOIN   job_roles r USING (role_id)
GROUP  BY r.seniority_level
ORDER  BY r.seniority_level;

-- Preview: top 10 company-to-company transitions (full analysis comes in file 05)
SELECT fc.company_name AS from_company,
       tc.company_name AS to_company,
       count(*)        AS transitions
FROM  (SELECT employee_id, company_id,
              lag(company_id) OVER (PARTITION BY employee_id ORDER BY start_date) AS prev_company_id
       FROM   employment_history) t
JOIN   companies fc ON fc.company_id = t.prev_company_id
JOIN   companies tc ON tc.company_id = t.company_id
WHERE  t.prev_company_id <> t.company_id
GROUP  BY fc.company_name, tc.company_name
ORDER  BY transitions DESC
LIMIT  10;
