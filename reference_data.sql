-- =============================================================================
-- 02_reference_data.sql
-- Career Mobility & Employee Transition Analytics (100% PostgreSQL)
--
-- PURPOSE
--   Loads the REFERENCE (seed) data: industries, locations, colleges,
--   companies and job roles. This is stable lookup data. Employees and their
--   employment history are generated later (files 03 and 04).
--
-- RUN ORDER
--   Requires 01_schema.sql.   psql -d career_mobility -f 02_reference_data.sql
--   Safe to re-run: it empties the reference tables first (and, via CASCADE,
--   anything that points at them, so re-run files 03 and 04 afterwards).
--
-- DESIGN NOTES
--   * IDs are GENERATED ALWAYS identity columns, so they are never typed by
--     hand. Child rows find their parents BY NAME with LEFT JOINs. If a name
--     is misspelled, the parent id becomes NULL and the NOT NULL constraint
--     fails loudly, instead of a row being silently skipped.
--   * Real, publicly known organisations are used only as company names with
--     approximate public attributes (type, size, city). No real employee
--     information exists anywhere in this project.
--   * For multinationals, hq_location_id means the main INDIA hub used in this
--     dataset (e.g. Amazon -> Bengaluru), because every analysis is India-based.
--   * Startups and the "tier 3" colleges are FICTIONAL.
--   * college_tier is an illustrative selectivity grouping (1 = most selective),
--     not an official ranking.
-- =============================================================================


BEGIN;

-- Empty reference tables and restart their identity counters so ids are
-- predictable on every run. CASCADE also clears dependent tables.
TRUNCATE TABLE salary_history, employment_history, employees,
               companies, colleges, job_roles, locations, industries
    RESTART IDENTITY CASCADE;


-- =============================================================================
-- 1. INDUSTRIES (15)
-- =============================================================================
INSERT INTO industries (industry_name, sector_group) VALUES
    ('IT Services',                 'Technology'),
    ('Software Products',           'Technology'),
    ('Cloud & Internet',            'Technology'),
    ('Analytics & AI',              'Technology'),
    ('EdTech',                      'Technology'),
    ('Fintech',                     'Finance'),
    ('Banking',                     'Finance'),
    ('Management Consulting',       'Consulting'),
    ('Healthcare Services',         'Healthcare'),
    ('HealthTech',                  'Healthcare'),
    ('Automotive',                  'Manufacturing'),
    ('Engineering & Infrastructure','Manufacturing'),
    ('E-commerce',                  'Retail'),
    ('Food & Delivery Tech',        'Retail'),
    ('AgriTech',                    'Other');


-- =============================================================================
-- 2. LOCATIONS (27)  city_tier: 1 = metro, 2 = large city, 3 = smaller city
-- =============================================================================
INSERT INTO locations (city, state, city_tier) VALUES
    -- Tier 1: major metros / tech hubs
    ('Bengaluru',        'Karnataka',         1),
    ('Mumbai',           'Maharashtra',       1),
    ('Delhi',            'Delhi',             1),
    ('Hyderabad',        'Telangana',         1),
    ('Chennai',          'Tamil Nadu',        1),
    ('Pune',             'Maharashtra',       1),
    ('Kolkata',          'West Bengal',       1),
    ('Gurugram',         'Haryana',           1),
    ('Noida',            'Uttar Pradesh',     1),
    -- Tier 2: large cities
    ('Ahmedabad',        'Gujarat',           2),
    ('Kochi',            'Kerala',            2),
    ('Coimbatore',       'Tamil Nadu',        2),
    ('Jaipur',           'Rajasthan',         2),
    ('Chandigarh',       'Chandigarh',        2),
    ('Indore',           'Madhya Pradesh',    2),
    ('Nagpur',           'Maharashtra',       2),
    ('Thiruvananthapuram','Kerala',           2),
    ('Bhubaneswar',      'Odisha',            2),
    ('Bhopal',           'Madhya Pradesh',    2),
    ('Kanpur',           'Uttar Pradesh',     2),
    ('Tiruchirappalli',  'Tamil Nadu',        2),
    -- Tier 3: smaller cities and college towns
    ('Vellore',          'Tamil Nadu',        3),
    ('Kharagpur',        'West Bengal',       3),
    ('Pilani',           'Rajasthan',         3),
    ('Manipal',          'Karnataka',         3),
    ('Mangaluru',        'Karnataka',         3),
    ('Mysuru',           'Karnataka',         3);


-- =============================================================================
-- 3. COLLEGES (26)  -- depends on locations
--    Tier 1 and 2 use well-known institution names; tier 3 are fictional.
-- =============================================================================
INSERT INTO colleges (college_name, college_tier, location_id)
SELECT v.college_name, v.college_tier, l.location_id
FROM (VALUES
    -- Tier 1
    ('IIT Madras',                              1, 'Chennai'),
    ('IIT Bombay',                              1, 'Mumbai'),
    ('IIT Delhi',                               1, 'Delhi'),
    ('IIT Kanpur',                              1, 'Kanpur'),
    ('IIT Kharagpur',                           1, 'Kharagpur'),
    ('BITS Pilani',                             1, 'Pilani'),
    ('IIIT Hyderabad',                          1, 'Hyderabad'),
    -- Tier 2
    ('NIT Tiruchirappalli',                     2, 'Tiruchirappalli'),
    ('NIT Karnataka Surathkal',                 2, 'Mangaluru'),
    ('VIT Vellore',                             2, 'Vellore'),
    ('SRM Institute of Science and Technology', 2, 'Chennai'),
    ('Anna University',                         2, 'Chennai'),
    ('PSG College of Technology',               2, 'Coimbatore'),
    ('College of Engineering Pune',             2, 'Pune'),
    ('Jadavpur University',                     2, 'Kolkata'),
    ('Delhi Technological University',          2, 'Delhi'),
    ('Manipal Institute of Technology',         2, 'Manipal'),
    ('Amity University Noida',                  2, 'Noida'),
    -- Tier 3 (fictional)
    ('Sunrise Institute of Technology',         3, 'Indore'),
    ('Lakeview College of Engineering',         3, 'Bhopal'),
    ('Northern Valley Engineering College',     3, 'Jaipur'),
    ('Coastal Institute of Technology',         3, 'Kochi'),
    ('Heritage College of Engineering',         3, 'Nagpur'),
    ('Greenfield Technical University',         3, 'Bhubaneswar'),
    ('Riverside Institute of Engineering',      3, 'Thiruvananthapuram'),
    ('Central Plains Engineering College',      3, 'Ahmedabad')
) AS v(college_name, college_tier, city)
LEFT JOIN locations l ON l.city = v.city;


-- =============================================================================
-- 4. COMPANIES (53)  -- depends on industries and locations
--    company_type drives archetype path analysis (startup -> product -> big_tech)
-- =============================================================================
INSERT INTO companies (company_name, industry_id, hq_location_id,
                       company_type, size_band, founded_year)
SELECT v.company_name, i.industry_id, l.location_id,
       v.company_type, v.size_band, v.founded_year
FROM (VALUES
    -- IT services -------------------------------------------------------------
    ('Tata Consultancy Services', 'IT Services', 'Mumbai',    'it_services', 'enterprise', 1968),
    ('Infosys',                   'IT Services', 'Bengaluru', 'it_services', 'enterprise', 1981),
    ('Wipro',                     'IT Services', 'Bengaluru', 'it_services', 'enterprise', 1945),
    ('HCLTech',                   'IT Services', 'Noida',     'it_services', 'enterprise', 1976),
    ('Tech Mahindra',             'IT Services', 'Pune',      'it_services', 'enterprise', 1986),
    ('Cognizant',                 'IT Services', 'Chennai',   'it_services', 'enterprise', 1994),
    ('Capgemini',                 'IT Services', 'Mumbai',    'it_services', 'enterprise', 1967),
    ('LTIMindtree',               'IT Services', 'Mumbai',    'it_services', 'large',      2022),
    ('Mphasis',                   'IT Services', 'Bengaluru', 'it_services', 'large',      1998),
    ('Persistent Systems',        'IT Services', 'Pune',      'it_services', 'large',      1990),
    -- Big tech ----------------------------------------------------------------
    ('Amazon',                    'Cloud & Internet', 'Bengaluru', 'big_tech', 'enterprise', 1994),
    ('Microsoft',                 'Cloud & Internet', 'Hyderabad', 'big_tech', 'enterprise', 1975),
    ('Google',                    'Cloud & Internet', 'Bengaluru', 'big_tech', 'enterprise', 1998),
    -- Product companies -------------------------------------------------------
    ('Flipkart',                  'E-commerce',           'Bengaluru', 'product', 'large',      2007),
    ('Myntra',                    'E-commerce',           'Bengaluru', 'product', 'large',      2007),
    ('BigBasket',                 'E-commerce',           'Bengaluru', 'product', 'medium',     2011),
    ('Zoho',                      'Software Products',    'Chennai',   'product', 'large',      1996),
    ('Freshworks',                'Software Products',    'Chennai',   'product', 'large',      2010),
    ('Oracle',                    'Software Products',    'Hyderabad', 'product', 'enterprise', 1977),
    ('Adobe',                     'Software Products',    'Noida',     'product', 'enterprise', 1982),
    ('SAP',                       'Software Products',    'Bengaluru', 'product', 'enterprise', 1972),
    ('Swiggy',                    'Food & Delivery Tech', 'Bengaluru', 'product', 'large',      2014),
    ('Zomato',                    'Food & Delivery Tech', 'Gurugram',  'product', 'large',      2008),
    ('Razorpay',                  'Fintech',              'Bengaluru', 'product', 'large',      2014),
    ('PhonePe',                   'Fintech',              'Bengaluru', 'product', 'large',      2015),
    ('Paytm',                     'Fintech',              'Noida',     'product', 'large',      2010),
    ('CRED',                      'Fintech',              'Bengaluru', 'product', 'medium',     2018),
    ('Practo',                    'HealthTech',           'Bengaluru', 'product', 'medium',     2008),
    -- Banks and financial institutions -----------------------------------------
    ('HDFC Bank',                 'Banking', 'Mumbai',    'bank_finance', 'enterprise', 1994),
    ('ICICI Bank',                'Banking', 'Mumbai',    'bank_finance', 'enterprise', 1994),
    ('State Bank of India',       'Banking', 'Mumbai',    'bank_finance', 'enterprise', 1955),
    ('Axis Bank',                 'Banking', 'Mumbai',    'bank_finance', 'enterprise', 1993),
    ('Goldman Sachs',             'Banking', 'Bengaluru', 'bank_finance', 'enterprise', 1869),
    ('JPMorgan Chase',            'Banking', 'Mumbai',    'bank_finance', 'enterprise', NULL),
    -- Consulting ----------------------------------------------------------------
    ('Deloitte',                  'Management Consulting', 'Mumbai',    'consulting', 'enterprise', NULL),
    ('EY',                        'Management Consulting', 'Gurugram',  'consulting', 'enterprise', 1989),
    ('PwC',                       'Management Consulting', 'Gurugram',  'consulting', 'enterprise', 1998),
    ('KPMG',                      'Management Consulting', 'Gurugram',  'consulting', 'enterprise', 1987),
    ('McKinsey & Company',        'Management Consulting', 'Gurugram',  'consulting', 'large',      1926),
    ('Accenture',                 'Management Consulting', 'Bengaluru', 'consulting', 'enterprise', 1989),
    -- Other established employers ---------------------------------------------------
    ('Apollo Hospitals',          'Healthcare Services',          'Chennai', 'other', 'large',      1983),
    ('Tata Motors',               'Automotive',                   'Mumbai',  'other', 'enterprise', 1945),
    ('Mahindra & Mahindra',       'Automotive',                   'Mumbai',  'other', 'enterprise', 1945),
    ('Larsen & Toubro',           'Engineering & Infrastructure', 'Mumbai',  'other', 'enterprise', 1938),
    -- Startups (fictional) ---------------------------------------------------------
    ('Nimbus Labs',               'Analytics & AI',    'Bengaluru', 'startup', 'small',  2020),
    ('Quantro Systems',           'Software Products', 'Hyderabad', 'startup', 'small',  2019),
    ('Greenleaf Agritech',        'AgriTech',          'Pune',      'startup', 'small',  2021),
    ('LearnLoop',                 'EdTech',            'Chennai',   'startup', 'small',  2020),
    ('MediSync Health',           'HealthTech',        'Bengaluru', 'startup', 'medium', 2018),
    ('PayWave Labs',              'Fintech',           'Mumbai',    'startup', 'medium', 2019),
    ('CartNest',                  'E-commerce',        'Gurugram',  'startup', 'small',  2021),
    ('DataForge Analytics',       'Analytics & AI',    'Pune',      'startup', 'small',  2022),
    ('CloudCrest Technologies',   'Cloud & Internet',  'Hyderabad', 'startup', 'small',  2018)
) AS v(company_name, industry_name, hq_city, company_type, size_band, founded_year)
LEFT JOIN industries i ON i.industry_name = v.industry_name
LEFT JOIN locations  l ON l.city          = v.hq_city;


-- =============================================================================
-- 5. JOB ROLES (45)
--    seniority_level: 1 = most junior ... 8 = most senior.
--    Comparing levels between consecutive positions classifies a move as a
--    promotion (level up), lateral (same) or step down (level down).
-- =============================================================================
INSERT INTO job_roles (role_title, job_family, seniority_level) VALUES
    -- Engineering
    ('Graduate Engineer Trainee',          'Engineering', 1),
    ('Software Engineer',                  'Engineering', 2),
    ('Software Development Engineer',      'Engineering', 2),
    ('Senior Software Engineer',           'Engineering', 3),
    ('Senior Software Development Engineer','Engineering', 3),
    ('Technical Lead',                     'Engineering', 4),
    ('Engineering Manager',                'Engineering', 5),
    ('Senior Engineering Manager',         'Engineering', 6),
    ('Director of Engineering',            'Engineering', 7),
    ('VP of Engineering',                  'Engineering', 8),
    -- Data
    ('Data Analyst',                       'Data', 2),
    ('Senior Data Analyst',                'Data', 3),
    ('Data Engineer',                      'Data', 3),
    ('Senior Data Engineer',               'Data', 4),
    ('Data Scientist',                     'Data', 3),
    ('Senior Data Scientist',              'Data', 4),
    ('Analytics Manager',                  'Data', 5),
    ('Director of Data',                   'Data', 7),
    -- Infrastructure and quality
    ('QA Engineer',                        'Infrastructure', 2),
    ('Senior QA Engineer',                 'Infrastructure', 3),
    ('DevOps Engineer',                    'Infrastructure', 3),
    ('Senior DevOps Engineer',             'Infrastructure', 4),
    ('Cloud Architect',                    'Infrastructure', 5),
    ('Principal Architect',                'Infrastructure', 6),
    -- Product
    ('Associate Product Manager',          'Product', 2),
    ('Product Manager',                    'Product', 4),
    ('Senior Product Manager',             'Product', 5),
    ('Group Product Manager',              'Product', 6),
    ('Director of Product',                'Product', 7),
    -- Consulting
    ('Business Analyst',                   'Consulting', 2),
    ('Consultant',                         'Consulting', 3),
    ('Senior Consultant',                  'Consulting', 4),
    ('Consulting Manager',                 'Consulting', 5),
    ('Principal Consultant',               'Consulting', 6),
    ('Partner',                            'Consulting', 8),
    -- Finance
    ('Financial Analyst',                  'Finance', 2),
    ('Senior Financial Analyst',           'Finance', 3),
    ('Relationship Manager',               'Finance', 3),
    ('Finance Manager',                    'Finance', 5),
    ('Vice President - Finance',           'Finance', 7),
    -- Management and operations
    ('Operations Executive',               'Operations', 1),
    ('Operations Manager',                 'Operations', 4),
    ('Project Manager',                    'Operations', 5),
    ('Program Manager',                    'Operations', 6),
    ('Head of Operations',                 'Operations', 7);


COMMIT;


-- =============================================================================
-- 6. VERIFICATION
-- =============================================================================

-- Row counts (expected: 15, 27, 26, 53, 45)
SELECT 'industries' AS table_name, count(*) AS row_count FROM industries
UNION ALL SELECT 'locations', count(*) FROM locations
UNION ALL SELECT 'colleges',  count(*) FROM colleges
UNION ALL SELECT 'companies', count(*) FROM companies
UNION ALL SELECT 'job_roles', count(*) FROM job_roles;

-- Companies by type and size
SELECT company_type,
       count(*)                                           AS companies,
       count(*) FILTER (WHERE size_band = 'enterprise')   AS enterprise,
       count(*) FILTER (WHERE size_band = 'large')        AS large,
       count(*) FILTER (WHERE size_band IN ('medium','small')) AS small_or_medium
FROM   companies
GROUP  BY company_type
ORDER  BY companies DESC;

-- Companies per sector (checks the industry join worked for every company)
SELECT i.sector_group, count(*) AS companies
FROM   companies  c
JOIN   industries i USING (industry_id)
GROUP  BY i.sector_group
ORDER  BY companies DESC;

-- Roles per seniority level
SELECT seniority_level, count(*) AS roles
FROM   job_roles
GROUP  BY seniority_level
ORDER  BY seniority_level;
