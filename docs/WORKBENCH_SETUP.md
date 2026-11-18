# MySQL Workbench Setup Guide (macOS)

For students with basic Workbench experience. You need **MySQL Server 8.0.16 or newer** (8.0.31+ for the INTERSECT/EXCEPT demos) and **MySQL Workbench 8.0**.

---

## 1. Open MySQL Workbench
1. Make sure the server is running: **System Settings → MySQL** (bottom of the sidebar) → the status should be *"active / running"*. If not, click **Start MySQL Server**.
2. Open **MySQL Workbench** from Applications or Launchpad.

## 2. Connect to the local server
1. On the home screen, click the tile **Local instance 3306** (or click **⊕** next to *MySQL Connections* and create one: hostname `127.0.0.1`, port `3306`, user `root`).
2. Enter your MySQL root password when asked (tick *Save password in keychain* if you like).
3. A SQL editor tab opens. The left sidebar has a **Navigator** with a **Schemas** tab.

## 3. Create / select the database
You do **not** create the database by hand: the setup script does it. After setup, double-click `construction_rental_db` in the Schemas list (it turns **bold** = default schema), or run:
```sql
USE construction_rental_db;
```

## 4. Execute the SQL files

### Option A (recommended): one file
1. **File → Open SQL Script…** → choose `sql/00_master_setup.sql`.
2. Click the **lightning bolt** ("Execute the selected portion of the script or everything") or press **Cmd + Shift + Enter**.
3. Wait a few seconds. The last result grid shows:
   `construction_rental_db installed successfully | 14 | 8 | 21 | 12` (tables, views, routines, triggers).

> ⚠ `00_master_setup.sql` **drops and re-creates** `construction_rental_db`. Running it again is the official way to **reset** the project to the original demo data.

### Option B: individual files in this exact order
| Order | File | What it does |
|---|---|---|
| 1 | `sql/01_create_database.sql` | drops/creates the database and 14 tables |
| 2 | `sql/02_seed_data.sql` | loads the demo data |
| 3 | `sql/06_views.sql` | 8 views |
| 4 | `sql/07_procedures_functions.sql` | 7 functions + 14 procedures |
| 5 | `sql/08_triggers.sql` | 12 triggers (must come after the seed data and the functions) |

Open each with **File → Open SQL Script**, then execute it with the lightning bolt.

The query and demo files (`03`, `04`, `05`, `09`, `10`, `11`, `12`) are **not** part of the setup. Run them afterwards.

> `SOURCE file.sql` is a command of the *mysql command-line client*, not of the Workbench SQL editor. This project therefore never relies on `SOURCE`; the master file contains all statements itself.

> `DELIMITER $$ … DELIMITER ;` lines (used around procedures and triggers) are understood by both Workbench and the mysql client. Do not delete them.

## 5. Refresh schemas
In the Navigator → **Schemas**, click the **↻ refresh** icon (or right-click → *Refresh All*). `construction_rental_db` appears with folders **Tables, Views, Stored Procedures, Functions**.

## 6. View all tables
Expand **construction_rental_db → Tables**. Hover a table and click the small **grid icon** to see its rows, or run:
```sql
SHOW TABLES;
SELECT * FROM equipment_units;
```
Click the **wrench icon** next to a table to open the table editor (columns, indexes, foreign keys, triggers tabs). Use it only for looking: do not change the structure there.

## 7. View relationships
- In the table editor (wrench icon) → **Foreign Keys** tab: lists each FK, the referenced table and ON DELETE/ON UPDATE rules.
- Or as a query:
```sql
SELECT table_name, constraint_name, referenced_table_name, delete_rule, update_rule
FROM information_schema.referential_constraints
WHERE constraint_schema = 'construction_rental_db';
```
- For a picture, see §11 (EER diagram) or `diagrams/ER_Diagram.png`.

## 8. Execute stored procedures
Type and run (Cmd + Enter executes the statement under the cursor):
```sql
CALL sp_check_availability('2026-11-23', '2026-11-27', NULL);   -- all free machines
CALL sp_overdue_report();
CALL sp_customer_statement(1);
CALL sp_create_booking(17, 2, '2026-12-01', '2026-12-03', '32', 'Test site', @id);
SELECT @id;                                                      -- OUT parameter
```
You can also right-click a procedure in the Navigator → **Execute Stored Procedure…**, and Workbench prompts for the parameters.

## 9. Run the demo
1. Open `sql/10_demo_queries.sql`.
2. Run **one statement at a time**: click inside the statement, press **Cmd + Enter**, explain the output, move on.
3. Lines marked **EXPECTED ERROR** must fail. The red error in the *Output* panel at the bottom is the demonstration.
4. PART B changes data. To repeat it, re-run `00_master_setup.sql` first. The first query of the demo tells you whether a reset is needed.

> **Running a whole file that contains expected errors:** Workbench normally stops at the first error. In the SQL editor toolbar there is a toggle "*Toggle whether execution of SQL script should continue after failed statements*". Switch it on before using the lightning bolt on `09_transactions.sql` or `10_demo_queries.sql`. The automated test files (`tests/*.sql`) do not need this: they catch errors themselves.

## 10. Inspect stored procedures, functions and triggers
- Navigator → **Stored Procedures / Functions** → right-click → **Alter Stored Procedure…** shows the source code (just close the tab without applying).
- Triggers: open a table with the wrench icon → **Triggers** tab, or:
```sql
SHOW TRIGGERS FROM construction_rental_db;
SHOW CREATE PROCEDURE sp_create_booking;
SHOW CREATE TRIGGER trg_booking_items_bi;
SELECT routine_type, routine_name FROM information_schema.routines WHERE routine_schema = 'construction_rental_db';
```

## 11. Generate an EER diagram (reverse engineering)
1. Menu **Database → Reverse Engineer…** (Cmd + R).
2. *Set Parameters for Connecting*: choose your stored connection → **Continue**, then enter the password if asked.
3. *Connect to DBMS and Fetch Information*: wait for the green ticks → **Continue**.
4. *Select Schemas*: tick **construction_rental_db** → **Continue**.
5. *Retrieve and Reverse Engineer Schema Objects*: **Continue**.
6. *Select Objects to Reverse Engineer*: keep **Import MySQL Table Objects** (and Views/Routines/Triggers if you want them listed) → **Execute** → **Continue** → **Close**.
7. A model tab opens with an **EER Diagram**: 14 tables connected by 16 relationship lines (Workbench uses crow's-foot style connectors). Drag the tables to tidy the layout, or use **Arrange → Autolayout**.
8. **File → Save Model As…** → e.g. `diagrams/construction_rental_db.mwb` if you want a native Workbench model file. **File → Export → Export as PNG/PDF** saves an image.

## 12. Export the database (backup / submission)
1. Menu **Server → Data Export**.
2. Tick `construction_rental_db`; in the right panel make sure all tables are ticked.
3. Under *Objects to Export*, tick **Dump Stored Procedures and Functions**, **Dump Events** and **Dump Triggers**.
4. Choose **Export to Self-Contained File** → pick a path, e.g. `construction_rental_db_backup.sql`.
5. Tick **Include Create Schema** → **Start Export**.

To restore: **Server → Data Import → Import from Self-Contained File**.

## 13. Run the tests
1. Fresh install: run `sql/00_master_setup.sql`.
2. `tests/00_test_helpers.sql` (installs the small test framework, once).
3. `tests/integrity_tests.sql`, `tests/business_rule_tests.sql`, `tests/financial_tests.sql`. Each can be run with the lightning bolt. The last result grid shows *passed / failed / executed*.
4. `tests/verify_database.sql` (health check; verdict `DATABASE OK`).
5. Concurrency: follow `tests/concurrency_tests.md` with two query tabs.

## 14. Troubleshooting

| Error / symptom | Cause | Fix |
|---|---|---|
| `Error Code: 1175. You are using safe update mode…` | Workbench's *Safe Updates* blocks UPDATE/DELETE without a key in WHERE | All project scripts already handle this. For your own experiments run `SET SQL_SAFE_UPDATES = 0;` (back to 1 afterwards), or turn it off under Workbench **Settings → SQL Editor → Safe Updates** and reconnect |
| `Error Code: 1046. No database selected` | default schema not set | `USE construction_rental_db;` or double-click the schema |
| `Error Code: 1305. PROCEDURE … does not exist` | setup not run, or wrong database selected | run `00_master_setup.sql`; check `USE` |
| `Error Code: 1644. …` with our message | a **business rule** refused the operation (e.g. double booking) | expected behaviour. Read the message |
| `Error Code: 3819. Check constraint '…' is violated` | data breaks a CHECK constraint | expected for invalid data |
| `Error Code: 1451 / 1452` | foreign key protects history / parent row missing | expected; deactivate instead of delete |
| `Error Code: 1064` near `INTERSECT` / `EXCEPT` | MySQL older than 8.0.31 | use the commented alternative below each query |
| `Error Code: 1419 … SUPER privilege and binary logging is enabled` | creating functions/triggers as a non-root user | run setup as `root`, or as root: `SET GLOBAL log_bin_trust_function_creators = 1;` |
| `Error Code: 2013. Lost connection to MySQL server during query` | long script hit the read timeout | Workbench **Settings → SQL Editor → DBMS connection read timeout** → 600 s, reconnect |
| `Error Code: 1205. Lock wait timeout exceeded` | another tab holds a lock (e.g. an unfinished concurrency test) | finish that tab with `COMMIT;` or `ROLLBACK;` |
| `Access denied for user 'root'@'localhost' (1045)` | wrong password | re-enter it in the connection settings |
| Cannot connect (2003) | server stopped | System Settings → MySQL → **Start MySQL Server** |
| CHECK constraints are ignored | MySQL older than 8.0.16 parses but does not enforce them | upgrade to 8.0.16+ |
| Results show only 1000 rows | Workbench's automatic `LIMIT 1000` | not an issue for this data; change it in the editor toolbar's *Limit to* drop-down |
