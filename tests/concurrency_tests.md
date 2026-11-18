# Concurrency tests: preventing double booking

## Why this needs a test of its own

The rule "one machine cannot be rented twice on the same day" cannot be written as a CHECK or UNIQUE constraint: it compares **date ranges** across many rows, and MySQL has no exclusion constraint like PostgreSQL's. A naive implementation is:

```sql
-- check
SELECT COUNT(*) FROM booking_items ... WHERE equipment_id = 7 AND <dates overlap>;   -- 0 -> looks free
-- then write
INSERT INTO booking_items (...) VALUES (..., 7, ...);
```

This breaks when two users act at almost the same time:

| time | Session A (Neha)                 | Session B (Gurpreet)             |
|------|----------------------------------|----------------------------------|
| t1   | SELECT … unit 7 free? → **yes**  |                                  |
| t2   |                                  | SELECT … unit 7 free? → **yes**  |
| t3   | INSERT booking item (unit 7)     |                                  |
| t4   |                                  | INSERT booking item (unit 7) → **double booking** |

A plain `SELECT` takes no locks, so neither session can see that the other is about to write.

## The solution used in this project

1. **Lock the parent row.** Before checking a unit, the code runs
   `SELECT … FROM equipment_units WHERE equipment_id = ? FOR UPDATE`.
   A second transaction asking for the *same* unit must wait until the first one commits or rolls back. Requests for *other* units are not blocked.
2. **Re-check with fresh data.** The overlap check (`fn_unit_conflict`) uses locking reads (`FOR SHARE`), which always read the latest committed rows, never an old snapshot. `sp_create_booking` also runs in `READ COMMITTED`.
3. **Deadlock-safe ordering.** A multi-machine booking locks its units in ascending `equipment_id` order, so two sessions can never wait for each other in a circle.
4. **The trigger does the same.** `trg_booking_items_bi` repeats steps 1–2, so hand-written `INSERT`s are protected as well as procedure calls.

## Workbench procedure (two query tabs = two sessions)

Start from a fresh install (`sql/00_master_setup.sql`). In Workbench, open two SQL tabs with **File → New Query Tab**. Each tab has its own connection, so each is a separate session. Execute one statement at a time with Ctrl/Cmd+Enter.

### Test C1: same machine, overlapping dates

| Step | Tab A | Tab B |
|------|-------|-------|
| 1 | `USE construction_rental_db;` | `USE construction_rental_db;` |
| 2 | `SET TRANSACTION ISOLATION LEVEL READ COMMITTED;` | |
| 3 | `START TRANSACTION;` | |
| 4 | `INSERT INTO bookings (customer_id, created_by_staff_id, booking_date, start_date, expected_return_date, booking_status, site_address) VALUES (4, 2, '2026-11-20', '2026-11-26', '2026-11-28', 'RESERVED', 'TEST: Session A');` | |
| 5 | `INSERT INTO booking_items (booking_id, equipment_id, agreed_daily_rate) VALUES (LAST_INSERT_ID(), 7, 5500);` → A now holds the lock on unit 7 | |
| 6 | | `CALL sp_create_booking(10, 3, '2026-11-27', '2026-11-30', '7', 'TEST: Session B', @b);` → **the tab keeps spinning (waiting)** |
| 7 | `COMMIT;` | → immediately: `Error Code: 1644. Equipment CER-BHL-002 is not available for the requested period (BOOKING_CONFLICT)` |

Variation: run `ROLLBACK;` in step 7 instead of `COMMIT;`. Tab B then succeeds, because the unit really is free.

> If Tab B waits longer than `innodb_lock_wait_timeout` (50 s by default), it fails with error 1205 *Lock wait timeout exceeded*. That is also safe, since no double booking is created. Do step 7 within ~50 seconds.

### Test C2: an old snapshot cannot fool the trigger

| Step | Tab A | Tab B |
|------|-------|-------|
| 1 | | `SET TRANSACTION ISOLATION LEVEL REPEATABLE READ; START TRANSACTION;` |
| 2 | | `SELECT COUNT(*) FROM booking_items WHERE equipment_id = 8;` → snapshot taken (1) |
| 3 | `START TRANSACTION;` then insert a booking + item for **unit 8**, 26–28 Dec, and `COMMIT;` | |
| 4 | | `SELECT COUNT(*) FROM booking_items WHERE equipment_id = 8;` → **still 1** (REPEATABLE READ shows the old snapshot) |
| 5 | | insert a booking for 27–30 Dec, then `INSERT INTO booking_items (booking_id, equipment_id, agreed_daily_rate) VALUES (LAST_INSERT_ID(), 8, 5500);` → **rejected: BOOKING_CONFLICT** |
| 6 | | `ROLLBACK;` |

Step 4 shows why a plain `SELECT` check is not enough. Step 5 shows that the trigger's locking read sees A's committed row even though B's snapshot does not.

### Test C3: different machines do not block each other

While Tab A holds unit 7 (C1 step 5, before COMMIT), run in Tab B:
`CALL sp_create_booking(10, 3, '2026-11-27', '2026-11-30', '8', 'TEST: other unit', @c);` It completes immediately.

### Clean-up after the Workbench tests

```sql
SET SQL_SAFE_UPDATES = 0;
DELETE sd FROM security_deposits sd JOIN bookings b ON b.booking_id = sd.booking_id WHERE b.site_address LIKE 'TEST:%';
DELETE l  FROM booking_status_log l JOIN bookings b ON b.booking_id = l.booking_id WHERE b.site_address LIKE 'TEST:%';
DELETE bi FROM booking_items bi JOIN bookings b ON b.booking_id = bi.booking_id WHERE b.site_address LIKE 'TEST:%';
DELETE FROM bookings WHERE site_address LIKE 'TEST:%';
SET SQL_SAFE_UPDATES = 1;
```

Re-running `sql/00_master_setup.sql` also resets everything.

## Recorded results

These tests were **actually executed** during development with `tests/concurrency_test.sh`, using real parallel `mysql` client sessions against a local MySQL server (version 9.7.1, InnoDB, default REPEATABLE READ). The output below is trimmed but not edited:

```
=== TEST C1
Session A   a_locked_unit_7  2026-11-18 10:33:36.184984      (A holds unit 7, sleeps 4 s)
Session B   b_started        2026-11-18 10:33:37.194517
Session A   a_committed      2026-11-18 10:33:40.196351
Session B   ERROR 1644 (45000): Equipment CER-BHL-002 is not available for the requested period (BOOKING_CONFLICT)
Session B   b_finished       2026-11-18 10:33:40.227290      (B waited ~3 s for A's lock, then was rejected)

=== TEST C2 / C3
Session C (unit 20)  c_start 10:33:40.780128  ->  booking 30 created  ->  c_end 10:33:40.783722   (not blocked)
Session B   b_snapshot_items_unit8   = 1
Session B   b_plain_read_still_sees  = 1     (old snapshot)
Session B   ERROR 1644 (45000): Equipment CER-BHL-003 is not available for the requested period (BOOKING_CONFLICT)

=== Result: only Session A's booking (unit 7), Session A2's booking (unit 8) and Session C's booking (unit 20) exist.
```

| Test | Expected | Observed | Status |
|------|----------|----------|--------|
| C1 same unit, procedure path | B waits, then BOOKING_CONFLICT | waited ~3.0 s, then BOOKING_CONFLICT | **Passed** |
| C2 old snapshot, direct INSERT path | plain read stale, INSERT rejected | stale count 1, INSERT rejected | **Passed** |
| C3 different unit | not blocked | finished in ~4 ms while unit 7 was locked | **Passed** |

The same script was then run again on the team's own MySQL 9.7.1 server (port 3306) with identical outcomes: B waited from 14:57:11.85 until A committed at 14:57:14.84 and was rejected; the other-unit booking took 8 ms; the stale-snapshot INSERT was rejected. `FOR UPDATE`, `FOR SHARE` and `SET TRANSACTION ISOLATION LEVEL` behave the same in MySQL 8.0.
