CREATE EXTENSION IF NOT EXISTS btree_gist;

DROP TABLE IF EXISTS salary_history CASCADE;
DROP TABLE IF EXISTS employment_history CASCADE;
DROP TABLE IF EXISTS employees CASCADE;
DROP TABLE IF EXISTS companies CASCADE;
DROP TABLE IF EXISTS colleges CASCADE;
DROP TABLE IF EXISTS job_roles CASCADE;
DROP TABLE IF EXISTS locations CASCADE;
DROP TABLE IF EXISTS industries CASCADE;


CREATE TABLE industries (
    industry_id integer GENERATED ALWAYS AS IDENTITY,
    industry_name text NOT NULL,
    sector_group text NOT NULL,

    CONSTRAINT pk_industries PRIMARY KEY (industry_id),
    CONSTRAINT uq_industries_name UNIQUE (industry_name),
    CONSTRAINT ck_industries_sector_group CHECK (
        sector_group IN (
            'Technology',
            'Finance',
            'Healthcare',
            'Manufacturing',
            'Consulting',
            'Retail',
            'Other'
        )
    )
);


CREATE TABLE locations (
    location_id integer GENERATED ALWAYS AS IDENTITY,
    city text NOT NULL,
    state text NOT NULL,
    country text NOT NULL DEFAULT 'India',
    city_tier smallint NOT NULL,

    CONSTRAINT pk_locations PRIMARY KEY (location_id),
    CONSTRAINT uq_locations_city UNIQUE (city, state, country),
    CONSTRAINT ck_locations_city_tier CHECK (city_tier BETWEEN 1 AND 3)
);


CREATE TABLE colleges (
    college_id integer GENERATED ALWAYS AS IDENTITY,
    college_name text NOT NULL,
    college_tier smallint NOT NULL,
    location_id integer NOT NULL,

    CONSTRAINT pk_colleges PRIMARY KEY (college_id),
    CONSTRAINT uq_colleges_name UNIQUE (college_name),
    CONSTRAINT ck_colleges_college_tier CHECK (college_tier BETWEEN 1 AND 3),
    CONSTRAINT fk_colleges_location
        FOREIGN KEY (location_id)
        REFERENCES locations(location_id)
);


CREATE TABLE companies (
    company_id integer GENERATED ALWAYS AS IDENTITY,
    company_name text NOT NULL,
    industry_id integer NOT NULL,
    hq_location_id integer NOT NULL,
    company_type text NOT NULL,
    size_band text NOT NULL,
    founded_year smallint,

    CONSTRAINT pk_companies PRIMARY KEY (company_id),
    CONSTRAINT uq_companies_name UNIQUE (company_name),

    CONSTRAINT fk_companies_industry
        FOREIGN KEY (industry_id)
        REFERENCES industries(industry_id),

    CONSTRAINT fk_companies_hq_location
        FOREIGN KEY (hq_location_id)
        REFERENCES locations(location_id),

    CONSTRAINT ck_companies_company_type CHECK (
        company_type IN (
            'startup',
            'it_services',
            'product',
            'big_tech',
            'bank_finance',
            'consulting',
            'other'
        )
    ),

    CONSTRAINT ck_companies_size_band CHECK (
        size_band IN (
            'small',
            'medium',
            'large',
            'enterprise'
        )
    ),

    CONSTRAINT ck_companies_founded_year CHECK (
        founded_year IS NULL
        OR founded_year BETWEEN 1850 AND 2026
    )
);


CREATE TABLE job_roles (
    role_id integer GENERATED ALWAYS AS IDENTITY,
    role_title text NOT NULL,
    job_family text NOT NULL,
    seniority_level smallint NOT NULL,

    CONSTRAINT pk_job_roles PRIMARY KEY (role_id),
    CONSTRAINT uq_job_roles_title UNIQUE (role_title),
    CONSTRAINT ck_job_roles_seniority_level
        CHECK (seniority_level BETWEEN 1 AND 8)
);


CREATE TABLE employees (
    employee_id integer GENERATED ALWAYS AS IDENTITY,
    employee_code text NOT NULL,
    college_id integer,
    graduation_year smallint,
    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_employees PRIMARY KEY (employee_id),
    CONSTRAINT uq_employees_code UNIQUE (employee_code),

    CONSTRAINT fk_employees_college
        FOREIGN KEY (college_id)
        REFERENCES colleges(college_id),

    CONSTRAINT ck_employees_graduation_year CHECK (
        graduation_year IS NULL
        OR graduation_year BETWEEN 1985 AND 2026
    )
);


CREATE TABLE employment_history (
    employment_id integer GENERATED ALWAYS AS IDENTITY,
    employee_id integer NOT NULL,
    company_id integer NOT NULL,
    role_id integer NOT NULL,
    location_id integer NOT NULL,
    start_date date NOT NULL,
    end_date date,
    separation_type text,
    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT pk_employment_history PRIMARY KEY (employment_id),

    CONSTRAINT fk_employment_employee
        FOREIGN KEY (employee_id)
        REFERENCES employees(employee_id)
        ON DELETE CASCADE,

    CONSTRAINT fk_employment_company
        FOREIGN KEY (company_id)
        REFERENCES companies(company_id),

    CONSTRAINT fk_employment_role
        FOREIGN KEY (role_id)
        REFERENCES job_roles(role_id),

    CONSTRAINT fk_employment_location
        FOREIGN KEY (location_id)
        REFERENCES locations(location_id),

    CONSTRAINT ck_employment_date_order CHECK (
        end_date IS NULL
        OR end_date > start_date
    ),

    CONSTRAINT ck_employment_separation_type CHECK (
        separation_type IS NULL
        OR separation_type IN (
            'resigned',
            'laid_off',
            'terminated',
            'contract_end',
            'retired',
            'internal_move'
        )
    ),

    CONSTRAINT ck_employment_end_vs_separation CHECK (
        (end_date IS NULL) = (separation_type IS NULL)
    ),

    CONSTRAINT ex_employment_no_overlap
        EXCLUDE USING gist (
            employee_id WITH =,
            (daterange(start_date, end_date, '[)')) WITH &&
        )
);


CREATE TABLE salary_history (
    salary_id integer GENERATED ALWAYS AS IDENTITY,
    employment_id integer NOT NULL,
    effective_date date NOT NULL,
    annual_salary numeric(12,2) NOT NULL,
    change_reason text NOT NULL,

    CONSTRAINT pk_salary_history PRIMARY KEY (salary_id),

    CONSTRAINT fk_salary_employment
        FOREIGN KEY (employment_id)
        REFERENCES employment_history(employment_id)
        ON DELETE CASCADE,

    CONSTRAINT uq_salary_employment_date
        UNIQUE (employment_id, effective_date),

    CONSTRAINT ck_salary_amount_positive
        CHECK (annual_salary > 0),

    CONSTRAINT ck_salary_change_reason CHECK (
        change_reason IN (
            'joining',
            'annual_increment',
            'promotion',
            'market_adjustment'
        )
    )
);