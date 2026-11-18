# Test Results

## ✅ Run 2: the team's own MySQL server (2026-11-18, 14:56–14:57)

| Item | Value |
|---|---|
| Server | the team's local MySQL server on this Mac (`/usr/local/mysql`, port 3306), version **9.7.1**, binary logging ON, default `sql_mode`, REPEATABLE READ |
| Connection | `mysql` client 9.7.1 as `root` through a `mysql_config_editor` login path, with `sql_safe_updates = 1` (Workbench default) |
| Before the run | no `construction_rental_db` existed; the team's other databases were not touched |

| Step | Result |
|---|---|
| `sql/00_master_setup.sql` | ✅ 14 tables, 8 views, 21 routines, 12 triggers |
| `tests/verify_database.sql` | ✅ 41 / 41, `DATABASE OK` |
| `sql/03`, `04`, `05`, `11` query files | ✅ all ran to the end, 0 errors |
| `tests/integrity_tests.sql` | ✅ 31 passed, 0 failed |
| `tests/business_rule_tests.sql` | ✅ 68 passed, 0 failed (re-run: 68 / 68) |
| `tests/financial_tests.sql` | ✅ 44 passed, 0 failed (re-run: 44 / 44) |
| `tests/concurrency_test.sh` | ✅ C1: Session B started 14:57:11.85, waited for A's lock until A committed at 14:57:14.84, then got `BOOKING_CONFLICT`; C3: a booking for another unit took 8 ms while unit 8 was locked; C2: the stale-snapshot manual INSERT was rejected with `BOOKING_CONFLICT` |
| `sql/09_transactions.sql` | ✅ exactly the 5 *EXPECTED ERROR* statements failed |
| reset + `sql/10_demo_queries.sql` | ✅ exactly the 5 *EXPECTED ERROR* statements failed; late fee ₹16,500, deposit retained ₹16,500 / refunded ₹18,500, balance ₹0, overdue report 2 machines / ₹3,25,500 |
| `tests/verify_database.sql` after every stage | ✅ 41 / 41 each time |
| final reset | ✅ database left in the original seed state (business date 2026-11-20, no test helpers) |

Not covered in Run 2: `sql/12_dcl_security.sql` (it creates server-wide users/roles; it was tested in Run 1 only) and clicking through the Workbench GUI itself. The SQL is exactly what Workbench sends; only the client program differs.

---

## Run 1: development run on a private test instance

## Environment actually used

| Item | Value |
|---|---|
| Date of run | 2026-11-18 (system clock); business date inside the database 2026-11-20 |
| Server | MySQL **9.7.1** (Enterprise, macOS arm64), a private throw-away instance started only for testing (port 3399), InnoDB, default `sql_mode` of MySQL 8.0/9.x (`ONLY_FULL_GROUP_BY, STRICT_TRANS_TABLES, …`) |
| Client | `mysql` command-line client 9.7.1, with `sql_safe_updates = 1` forced on every session to imitate MySQL Workbench's default *Safe Updates* mode |
| Not used | the team's own MySQL server (its root password was not available) and the MySQL Workbench GUI itself |

> **Version note.** The project targets MySQL **8.0.16+**; every feature used exists in 8.0 (CHECK enforcement 8.0.16, `FOR SHARE` 8.0.1, `EXPLAIN ANALYZE` 8.0.18, INTERSECT/EXCEPT 8.0.31). Both runs used 9.7.1 because that is the version installed on the team's Mac. If the evaluation happens on a lab machine with an older 8.0, run `tests/verify_database.sql` there first (and use the commented fallbacks for INTERSECT/EXCEPT below 8.0.31).

## Sequence executed (fresh install → everything → reset)

| # | Step | Result |
|---|---|---|
| 1 | `sql/00_master_setup.sql` on an empty server | ✅ 14 tables, 8 views, 21 routines, 12 triggers created |
| 2 | `tests/verify_database.sql` | ✅ **41 / 41 checks passed**, verdict `DATABASE OK` |
| 3 | `sql/03_basic_queries.sql` | ✅ ran to the end, 0 errors (DML part rolled back) |
| 4 | `sql/04_joins_and_subqueries.sql` | ✅ 0 errors |
| 5 | `sql/05_advanced_queries.sql` | ✅ 0 errors |
| 6 | `sql/11_indexing_and_explain.sql` | ✅ 0 errors |
| 7 | `tests/00_test_helpers.sql` | ✅ helpers installed |
| 8 | `tests/integrity_tests.sql` | ✅ **31 passed, 0 failed** |
| 9 | `tests/business_rule_tests.sql` | ✅ **68 passed, 0 failed** |
| 10 | `tests/financial_tests.sql` | ✅ **44 passed, 0 failed** |
| 11 | `tests/verify_database.sql` (after tests: clean-up worked) | ✅ 41 / 41 |
| 12 | `tests/concurrency_test.sh` (real parallel sessions) | ✅ C1, C2, C3 behaved as expected (details in `concurrency_tests.md`) |
| 13 | `sql/09_transactions.sql` (all statements, errors allowed) | ✅ exactly the 5 marked *EXPECTED ERROR* statements failed, with the expected messages |
| 14 | `tests/verify_database.sql` | ✅ 41 / 41 |
| 15 | reset (`00_master_setup.sql`) + `sql/10_demo_queries.sql` | ✅ exactly the 5 marked *EXPECTED ERROR* statements failed; all other demo steps produced the documented values (late fee ₹16,500, deposit retained ₹16,500 / refunded ₹18,500, balance ₹0) |
| 16 | `tests/verify_database.sql` (after demo) | ✅ 41 / 41 |
| 17 | final reset | ✅ database back to the original seed state |

The business-rule and financial test files were each also run **twice in a row**. The second run gave the same pass counts, which shows the clean-up section works.

## Summary

| Category | Passed | Failed | Not executed |
|---|---:|---:|---:|
| Integrity tests (PK, FK, UNIQUE, CHECK, NOT NULL, ENUM, DATE) | 31 | 0 | 0 |
| Business-rule tests (booking, overlap, cancellation, handover, returns, maintenance, audit, functions) | 68 | 0 | 0 |
| Financial tests (charges, snapshot prices, payments, late fees, damage, deposit settlement, reconciliation) | 44 | 0 | 0 |
| Verification checks (schema objects, seed volume, orphans, conflicts, lifecycle, finance) | 41 | 0 | 0 |
| Concurrency tests (2–3 parallel sessions) | 3 | 0 | 0 |
| Transactions script expected-error checkpoints | 5 | 0 | 0 |
| Demo script expected-error checkpoints | 5 | 0 | 0 |
| DCL privilege check (`12_dcl_security.sql` as user `neha_agent`) | 4 | 0 | 0 |
| **Total** | **201** | **0** | **0** |

DCL details: as `neha_agent`, the view query succeeded, `sp_check_availability` succeeded, a direct `INSERT INTO bookings` was refused (ERROR 1142), `SELECT * FROM payments` was refused (ERROR 1142), and the revoked `sp_cancel_booking` was refused (ERROR 1370). The demo users and roles were dropped afterwards.

## Requirement → test mapping

| Required test | Where |
|---|---|
| Primary key violations | IT01 |
| Foreign key violations | IT06–IT10 |
| Duplicate equipment serial numbers | IT02 (and asset tag IT03) |
| Invalid rental periods | IT16, BR17, BR18, BR19 |
| Overlapping bookings | BR05, BR06, BR08, BR15; concurrency C1/C2 |
| Invalid maintenance overlap | BR50, BR51, BR53, BR57, BR58 |
| Negative payments | IT17, FT06 |
| Invalid deposit refunds | IT19, FT18, FT19, FT20 |
| Duplicate equipment returns | IT22, BR43 |
| Cancelling bookings | BR23–BR28 |
| Booking equipment under maintenance | BR11, BR12 |
| Booking retired equipment | BR14 |
| Partial equipment returns | BR41, BR42, FT27 |
| Rental charge calculations | FT01–FT05, BR04, BR64 |
| Late return charges | FT28–FT30, BR49 |
| Financial reconciliation | FT31–FT44; verify "finance" checks |
| Transaction rollback | BR09/BR10 (multi-unit all-or-nothing); `09_transactions.sql` scenario 2 |
| Concurrent booking attempts | `concurrency_tests.md` C1–C3 |

## Failures found during development (and fixed)

They are listed because they show what the tests are for:

1. **Error 1442.** The booking procedure first used `INSERT … SELECT FROM equipment_units`, but the item trigger locks `equipment_units`, which MySQL forbids. Fixed by inserting items row by row inside the cursor loop.
2. **Masked FK error.** A payment for a non-existent booking was reported as "Overpayment". Added an explicit *Booking does not exist* check to `trg_payments_bi`.
3. **Error 1175 under Workbench safe-update mode** in demo step 15 (`UPDATE` without WHERE). Fixed with `WHERE model_id > 0`; every script was then re-run with safe updates on.
4. **Error 3823.** MySQL rejects a CHECK on `staff.manager_id` because that column has an `ON DELETE SET NULL` FK. The rule was documented instead.
5. Test-design mistakes, where the database was right and the test expectation was wrong: starting a February maintenance job "early" overlapped January bookings and was correctly refused (now test BR58); the verification script's expected FK/CHECK counts were miscounted (corrected to 16 and 34).
