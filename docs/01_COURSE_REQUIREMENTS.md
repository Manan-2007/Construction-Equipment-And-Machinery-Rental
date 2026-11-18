# 01 · Course Requirements Analysis

**Course:** Database Management System (24CSE0209), B.E. CSE (AI & ML), Semester 3, Session July–Dec 2026, Chitkara University Institute of Engineering and Technology
**Project:** Construction Equipment & Machinery Rental Management System
**Team:** Arshpreet Kaur (2510992817), Manan Kochhar (2510993803), Atharv Bains (2510993832)

---

## 1. Sources inspected

| Source | Location | What was done |
|---|---|---|
| Course Handout (CHO) | `Downloads/Make Notes/DBMS/DBMS_CHO_SEM3.pdf` (10 pages) | Read completely: objectives, CLOs, theory plan, lab plan, evaluation scheme, syllabus |
| Official project description | Screenshot supplied with the brief | Used as the binding project scope |
| DBMS Reference Drive (faculty) | `DBMS/DBMS(hostel)/DBMS REFERENCE DRIVE/` | Read the "README BEFORE USING THIS DRIVE" PDF; skimmed `12. views handson.sql`, the *MySQL Stored Programs till Cursor* and *Database Normalization* slide decks for style and terminology; listed every other file |
| Personal slide decks | `DBMS/DBMS(my_pdfs)/` (3 × .pptx) | Listed only |
| Exam-preparation notes | `EXAM_PREPARATION_MASTER_NOTES/01_DBMS/` (concept notes D01–D13, cheat-sheets, mock tests) | Listed only. File names confirm the same topic sequence as the CHO |

No original resource was modified, moved or deleted. Everything for this project was created in its own folder.

**Limitation:** apart from the files named above, the study materials were not read page by page. Every statement in this document marked *(CHO)* comes from the handout itself.

## 2. What the CHO actually says about the project

- The lab plan ends with **"Mini Project Development"** followed by **"Project Based Evaluation"** *(CHO §6b)*.
- Evaluation scheme: **Component 2, Project Based Evaluation, 10 % weight, 10 marks, offline**, mapped to **CLO01–CLO06** *(CHO §11)*.
- Syllabus unit 3, "Mini project", is 3 lectures and 5 % weight *(CHO §12)*.
- **The CHO does not prescribe a report format, page count, diagram tool, list of SQL features or submission files.** The deliverable list in this project comes from the team's brief, not from the CHO.

### Conflict noted

CHO §5 lists **"SQL Server Express Edition 2022, SQL Server Management Studio 2022"** as recommended tools. However, the lab plan, lab web references (w3schools MySQL pages, `dev.mysql.com/doc/refman/8.4`) and the theory topics ("Introduction to MySQL", "Triggers in MySQL", "Cursor in MySQL") all use **MySQL**. The project brief also requires **MySQL 8.0+ with MySQL Workbench**. We therefore follow the explicit project instruction and the lab practice, and use MySQL. No SQL Server-only syntax is used.

## 3. Course topics relevant to the project (from the CHO)

| CHO topic (lectures / lab) | CLO | Relevance |
|---|---|---|
| DBMS vs file system, architecture, schema/instance/metadata (L1–3) | CLO01 | Report: problem statement, manual-system limitations |
| Entities, attributes, keys, relationships (L4–5) | CLO01 | ER model |
| Strong/weak entities, cardinality, participation, EER (L6–7) | CLO01 | ER model, Crow's Foot diagram |
| ER-to-relational mapping, domains, tuples, constraints (L8–9) | CLO01/02 | Relational schema, CHECK/FK/UNIQUE |
| Relational algebra: σ, π, set ops, ×, ⋈, ÷ (L10–12) | CLO02 | RA expressions next to SQL queries |
| DDL: CREATE, ALTER, DROP, TRUNCATE (L13–14, Lab 1) | CLO02 | `01_create_database.sql` |
| Constraints (Lab 2) | CLO06 | PK, FK, UNIQUE, NOT NULL, CHECK, DEFAULT |
| DML, SELECT, WHERE, ORDER BY, DISTINCT, LIMIT (L15–17, Labs 4–5) | CLO02 | `03_basic_queries.sql` |
| Aggregates, GROUP BY, HAVING (L18–19, Labs 5–6) | CLO02 | `03_basic_queries.sql`, reports |
| Joins: INNER, LEFT, RIGHT, FULL OUTER (L20–21, Lab 9) | CLO02 | `04_joins_and_subqueries.sql` |
| Nested and correlated subqueries (L22–24, Lab 6) | CLO02 | `04_joins_and_subqueries.sql` |
| Set operations UNION, INTERSECT, MINUS (L22–24) | CLO02 | `04_…sql` part C |
| DCL: GRANT, REVOKE (L22–24) | CLO02 | `12_dcl_security.sql` |
| Views (L25, Lab 8) | CLO02/06 | `06_views.sql` (8 views) |
| Functional dependencies, decomposition, lossless join, dependency preservation (L26–27) | CLO03 | `03_NORMALIZATION.md` |
| 1NF, 2NF, 3NF, BCNF (L28–32) | CLO03 | `03_NORMALIZATION.md` |
| File organisation, indexing, B-tree, hashing (L33–35, Lab 8) | CLO05 | Indexes + `11_indexing_and_explain.sql` |
| MySQL stored programs: variables, data types, control flow (L36–37, Lab 10) | CLO04 | IF/ELSEIF, WHILE, LOOP in procedures |
| Cursors, error handling, procedures, functions (L38–40, Lab 11) | CLO04 | `07_procedures_functions.sql` (cursor, handlers, SIGNAL/RESIGNAL) |
| Triggers, transactions, ACID (L41–42, Lab 11) | CLO04/05 | `08_triggers.sql`, `09_transactions.sql` |
| Concurrency problems, serializability, lock-based protocols, deadlocks (L43–44) | CLO05 | Row locking for double-booking prevention, lock ordering, two-session tests |
| Recovery (L45) | CLO05 | Durability discussion (redo log) |
| Objective: "sequence, triggers, cursor, function, procedure" *(CHO §1)* | CLO04 | MySQL has no SEQUENCE object; `AUTO_INCREMENT` plays that role (explained in viva notes) |

## 4. Concept → project component mapping

| Concept | Where it is demonstrated |
|---|---|
| ER modelling (entities, attributes, 1:1, 1:N, M:N, recursive, optional participation) | `diagrams/ER_Diagram.png/.pdf`, `docs/02_ER_MODEL_EXPLANATION.md` |
| M:N resolved by junction table | `booking_items` (bookings ↔ equipment_units) |
| Recursive relationship / SELF JOIN | `staff.manager_id` → `staff`, query J6 |
| 1 : 0..1 relationships | bookings–security_deposits, booking_items–equipment_returns |
| Keys: PK, candidate, composite unique, FK | every table; `uq_booking_items_unit`, `uq_models_make_name` |
| Domain constraints | ENUM statuses, CHECK with REGEXP on phone/pincode, DECIMAL money |
| Referential actions | RESTRICT (history protection), SET NULL (optional staff refs), CASCADE on update |
| Normalisation to 3NF/BCNF | `docs/03_NORMALIZATION.md` |
| Basic SQL + aggregates | `sql/03_basic_queries.sql` (22 items) |
| Joins, subqueries, set ops | `sql/04_joins_and_subqueries.sql` (24 queries) |
| Business reports | `sql/05_advanced_queries.sql` (25 queries) |
| Relational algebra | RA expressions in query comments (J1, J7, Q1, Q2, U1, U3, U4) and in `PROJECT_REPORT.md` |
| Views | `sql/06_views.sql` (8 views, incl. a view built on another view) |
| Functions & procedures, IN/OUT params, cursor, handlers | `sql/07_procedures_functions.sql` (7 functions, 14 procedures) |
| Triggers (BEFORE/AFTER, INSERT/UPDATE) | `sql/08_triggers.sql` (12 triggers) |
| Transactions, ACID, SAVEPOINT, ROLLBACK | `sql/09_transactions.sql` |
| Concurrency / locking / deadlock avoidance | `FOR UPDATE` / `FOR SHARE`, ordered locking, `tests/concurrency_tests.md` |
| Indexing + EXPLAIN | `sql/11_indexing_and_explain.sql`, `docs/04_INDEXING_AND_OPTIMIZATION.md` |
| DCL | `sql/12_dcl_security.sql` (roles, GRANT, REVOKE) |

## 5. Topics kept optional (outside or at the edge of the syllabus)

- **Window functions** (`RANK() OVER`): one optional query (B25), clearly labelled.
- **CTE (`WITH`)**: used only inside `tests/verify_database.sql`, where the same interval list is needed twice. All teaching queries use derived tables instead.
- **INTERSECT / EXCEPT**: these are in the syllabus (as INTERSECT/MINUS) but need MySQL **8.0.31+**. Each one has a commented equivalent for older versions.
- **Dynamic SQL (PREPARE/EXECUTE)**: used only by the test helper procedures, never in the business logic.
- **NoSQL, RAID, query-processing internals**: mentioned in CHO objectives or "beyond syllabus"; not implemented, because they do not fit a relational rental system.
- **Frontend application**: not built. Listed as a future enhancement.

## 6. Assumptions

1. MySQL **8.0.16 or newer** is installed (CHECK constraints are only enforced from 8.0.16). INTERSECT/EXCEPT demos need 8.0.31+.
2. The evaluator runs the scripts in MySQL Workbench as a user that may create databases, routines and triggers (normally `root`).
3. Rentals are charged **per day on inclusive dates**. Weekly/monthly tariffs, GST and fuel/operator charges are out of scope (see Limitations in the report).
4. The business "today" is fixed at **2026-11-20** in `system_settings`, so the demo scenarios stay valid whenever the scripts are run.
5. All people, companies, phone numbers and e-mail addresses in the seed data are fictional. Manufacturer and model names are real products, used only as realistic catalogue entries.
