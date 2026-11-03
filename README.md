# Career Mobility & Employee Transition Analytics

A PostgreSQL-based database analytics project designed to analyze employee career mobility, company transitions, job roles, industries, locations, and salary progression.

## 📌 Project Overview

This project models employee career history and analyzes how employees move between companies, roles, industries, and locations.

The database was designed as a relational PostgreSQL system with interconnected entities for employees, companies, employment history, job roles, industries, locations, colleges, and salary history.

## 🗄️ Database Architecture

The database contains the following core tables:

- `employees` — Employee information
- `companies` — Company information
- `employment_history` — Employee career and company transitions
- `job_roles` — Job roles and seniority information
- `industries` — Industry classifications
- `locations` — Geographic information
- `colleges` — Employee educational background
- `salary_history` — Historical salary information

### ER Diagram

The database relationships are visualized using PostgreSQL's ERD tool.

The central `employment_history` table connects employees with companies, job roles, and locations, while salary history tracks compensation over time.

## 🔍 Analytics

The project includes SQL analysis for:

- Employee distribution across industries
- Company and employee transitions
- Career progression
- Salary progression
- Employee mobility patterns
- Company sources and destinations
- Attrition analysis
- Advanced employee and company analytics

## ⚙️ Database Features

### Views
Created reusable SQL views for frequently required analytical queries.

### Materialized Views
Implemented materialized views for analytical workloads where precomputed results can improve query performance.

### Indexes
Added indexes to improve query performance and demonstrated query optimization using execution plans.

### Functions
Implemented PostgreSQL functions for reusable analytical operations, including:

- Employee career history
- Company destinations
- Company sources
- Salary lookup
- Attrition rate

### Triggers
Implemented triggers for database validation and data integrity, including:

- Salary date validation
- Position date validation
- Company founding-year validation

### Stored Procedures
Implemented procedures for refreshing analytics materialized views.

### Transactions
Used transactions and rollback mechanisms to test database operations while maintaining data integrity.

## 📁 Project Structure

```text
career_mobility/
│
├── schema.sql
├── reference_data.sql
├── employee_data.sql
├── employment_history.sql
├── basic_analysis.sql
├── advanced_analysis.sql
├── views.sql
├── materialized_views.sql
├── indexes.sql
└── functions_triggers.sql
```

## 🛠️ Tech Stack

- PostgreSQL
- SQL
- pgAdmin 4
- Visual Studio Code
- Git
- GitHub

## 🚀 How to Run

1. Install PostgreSQL.
2. Create a database named `career_mobility`.
3. Execute the SQL files in the following order:

```text
1. schema.sql
2. reference_data.sql
3. employee_data.sql
4. employment_history.sql
5. basic_analysis.sql
6. advanced_analysis.sql
7. views.sql
8. materialized_views.sql
9. indexes.sql
10. functions_triggers.sql
```

4. Execute the analytical queries and explore the generated views, functions, procedures, and database relationships.

## 🎯 Key Learning Outcomes

This project strengthened practical understanding of:

- Relational database design
- PostgreSQL
- Advanced SQL
- Joins and analytical queries
- Views and materialized views
- Query optimization and indexing
- Functions and stored procedures
- Triggers and data validation
- Transactions
- Database analytics

## 👨‍💻 Author

**Kiran**

B.Tech Computer Science Engineering

---

⭐ If you find this project useful, feel free to explore the SQL implementation in the repository.
