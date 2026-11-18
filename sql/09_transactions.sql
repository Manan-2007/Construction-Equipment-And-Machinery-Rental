-- =====================================================================
--  File   : 09_transactions.sql
--  Purpose: Demonstrate transactions and the ACID properties with real
--           rental scenarios.
--  HOW TO RUN: execute ONE statement at a time in Workbench
--           (cursor on the statement, then Ctrl+Enter / Cmd+Enter).
--           Statements marked "EXPECTED ERROR" are supposed to fail -
--           that failure IS the demonstration. (If you prefer "run all",
--           first enable "Continue SQL script execution on errors" from the
--           Query menu / editor toolbar.)
--  DATA EFFECT: Scenario 1 commits a booking and then cancels it, so each
--           run leaves one CANCELLED booking as audit history (cancelled
--           bookings never block equipment, so the file can be re-run).
--           Everything else is rolled back or restored.
--  Syllabus: Lectures 41-44 (transactions, ACID, concurrency, locking)
-- =====================================================================

USE construction_rental_db;

-- MySQL Workbench / mysql client start in autocommit mode: every single
-- statement is its own transaction. START TRANSACTION switches that off
-- until COMMIT or ROLLBACK.
SELECT @@autocommit AS autocommit_on, @@transaction_isolation AS isolation_level;

-- =====================================================================
-- SCENARIO 1 - SUCCESSFUL BOOKING (Atomicity: all steps succeed -> COMMIT)
-- A customer (Priya Nair, id 7) rents the brand-new Kirloskar generator
-- CER-GEN-005 (unit 32) for 10-12 Dec 2026. Three tables must change
-- together: bookings, booking_items, security_deposits.
-- =====================================================================
START TRANSACTION;

INSERT INTO bookings (customer_id, created_by_staff_id, booking_date, start_date,
                      expected_return_date, booking_status, site_address)
VALUES (7, 7, '2026-11-20', '2026-12-10', '2026-12-12', 'RESERVED', 'Farmhouse function, Mullanpur');
SET @s1_booking = LAST_INSERT_ID();

INSERT INTO booking_items (booking_id, equipment_id, agreed_daily_rate)
VALUES (@s1_booking, 32, 3000.00);          -- trigger locks unit 32 and checks for overlaps

INSERT INTO security_deposits (booking_id, required_amount, deposit_status)
VALUES (@s1_booking, 15000.00, 'PENDING');

-- Inside the transaction we can already see our own changes:
SELECT b.booking_id, b.booking_status, bi.equipment_id, sd.required_amount
FROM bookings b
JOIN booking_items bi ON bi.booking_id = b.booking_id
JOIN security_deposits sd ON sd.booking_id = b.booking_id
WHERE b.booking_id = @s1_booking;

COMMIT;                                     -- all three rows become permanent together

-- Clean-up the business way: cancel (history kept, unit freed again)
CALL sp_cancel_booking(@s1_booking, 'Demo booking from 09_transactions.sql');

-- =====================================================================
-- SCENARIO 2 - ROLLBACK WHEN ONE MACHINE IS UNAVAILABLE (Atomicity)
-- A customer wants TWO machines for 22-24 Nov: generator 32 (free) and
-- crane CER-CRN-003 (unit 13), which is in the workshop until 24-Nov.
-- Business rule: book both or nothing.
-- =====================================================================

-- 2a. Manual transaction
SELECT COUNT(*) AS bookings_before FROM bookings;

START TRANSACTION;
INSERT INTO bookings (customer_id, created_by_staff_id, booking_date, start_date,
                      expected_return_date, booking_status, site_address)
VALUES (4, 2, '2026-11-20', '2026-11-22', '2026-11-24', 'RESERVED', 'House 233, Sector 12, Panchkula');
SET @s2_booking = LAST_INSERT_ID();

INSERT INTO booking_items (booking_id, equipment_id, agreed_daily_rate)
VALUES (@s2_booking, 32, 3000.00);          -- succeeds

-- EXPECTED ERROR 1644: Equipment CER-CRN-003 is not available ... (MAINTENANCE_CONFLICT)
INSERT INTO booking_items (booking_id, equipment_id, agreed_daily_rate)
VALUES (@s2_booking, 13, 8000.00);

-- IMPORTANT: in MySQL a failed statement does NOT end the transaction.
-- The booking and the generator item are still pending - visible here:
SELECT booking_id, equipment_id FROM booking_items WHERE booking_id = @s2_booking;

ROLLBACK;                                   -- undo EVERYTHING since START TRANSACTION

SELECT COUNT(*) AS bookings_after_rollback FROM bookings;          -- same as before
SELECT COUNT(*) AS generator_items_left FROM booking_items WHERE booking_id = @s2_booking;  -- 0

-- 2b. The same request through the stored procedure: its EXIT HANDLER
--     performs the ROLLBACK automatically.
-- EXPECTED ERROR 1644: Equipment CER-CRN-003 is not available ... (MAINTENANCE_CONFLICT)
CALL sp_create_booking(4, 2, '2026-11-22', '2026-11-24', '32,13', 'House 233, Sector 12, Panchkula', @s2b_booking);

SELECT @s2b_booking AS new_booking_id,                              -- NULL: nothing created
       (SELECT COUNT(*) FROM bookings) AS bookings_now;              -- unchanged

-- =====================================================================
-- SCENARIO 3 - PAYMENT CONSISTENCY (Consistency + SAVEPOINT)
-- Booking 23 (Vikas Yadav): rental Rs 19,200, deposit Rs 25,000 PENDING.
-- Collecting the deposit and taking the payment must not leave a partial
-- financial state, and no rule (constraint/trigger) may be broken.
-- =====================================================================
SELECT * FROM vw_booking_financial_summary WHERE booking_id = 23;

START TRANSACTION;

UPDATE security_deposits
   SET collected_amount = required_amount, collected_date = '2026-11-20', deposit_status = 'HELD'
 WHERE booking_id = 23;

SAVEPOINT deposit_collected;                -- a point we can roll back to

-- EXPECTED ERROR 1644: Overpayment ... (customer tries to pay 25,000 against a 19,200 bill)
INSERT INTO payments (booking_id, amount, payment_date, payment_method, payment_type, payment_status, reference_no)
VALUES (23, 25000.00, '2026-11-20', 'UPI', 'ADVANCE', 'COMPLETED', 'UPI-TXN-DEMO-0023A');

-- Pay the correct advance instead
INSERT INTO payments (booking_id, amount, payment_date, payment_method, payment_type, payment_status, reference_no)
VALUES (23, 5000.00, '2026-11-20', 'UPI', 'ADVANCE', 'COMPLETED', 'UPI-TXN-DEMO-0023B');

SELECT deposit_status, payments_received, balance_due
FROM vw_booking_financial_summary WHERE booking_id = 23;           -- HELD, 5000, 14200

ROLLBACK TO SAVEPOINT deposit_collected;    -- undo only the payment

SELECT deposit_status, payments_received
FROM vw_booking_financial_summary WHERE booking_id = 23;           -- HELD, 0 (deposit change kept)

ROLLBACK;                                   -- undo the rest (keep demo data unchanged)

SELECT deposit_status FROM security_deposits WHERE booking_id = 23; -- PENDING again

-- Consistency is also guaranteed by CHECK constraints. Booking 15's deposit (Rs 70,000) is HELD.
-- EXPECTED ERROR 3819 (Check constraint ... is violated): refunding more than was collected is impossible.
UPDATE security_deposits SET refunded_amount = 999999 WHERE booking_id = 15;
-- And a settled deposit is final (trigger trg_security_deposits_bu). EXPECTED ERROR 1644:
UPDATE security_deposits SET refunded_amount = 0 WHERE booking_id = 14;

-- =====================================================================
-- SCENARIO 4 - ISOLATION: two sessions (open TWO Workbench query tabs;
-- each tab is a separate connection = separate session)
-- =====================================================================
-- 4a. No dirty reads (default level REPEATABLE READ)
--   Session A:  START TRANSACTION;
--               UPDATE equipment_models SET daily_rate = 99999 WHERE model_id = 4;
--   Session B:  SELECT daily_rate FROM equipment_models WHERE model_id = 4;
--               -> still 5500.00 (A has not committed: B never sees uncommitted data)
--   Session A:  ROLLBACK;
--
-- 4b. Competing bookings for the SAME machine and overlapping dates
--   Session A:  SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
--               START TRANSACTION;
--               INSERT INTO bookings (customer_id, created_by_staff_id, booking_date, start_date,
--                                     expected_return_date, booking_status, site_address)
--               VALUES (4, 2, '2026-11-20', '2026-12-20', '2026-12-22', 'RESERVED', 'Session A');
--               INSERT INTO booking_items (booking_id, equipment_id, agreed_daily_rate)
--               VALUES (LAST_INSERT_ID(), 28, 900);       -- A now holds a lock on unit 28
--   Session B:  CALL sp_create_booking(10, 3, '2026-12-21', '2026-12-23', '28', 'Session B', @b);
--               -> B WAITS (spinner) because unit 28's row is locked by A
--   Session A:  COMMIT;
--   Session B:  -> immediately fails: "Equipment CER-CMP-003 is not available ... (BOOKING_CONFLICT)"
--   If A had done ROLLBACK instead, B would have succeeded.
--   Full write-up and recorded results: tests/concurrency_tests.md
--
-- Why a simple "SELECT to check, then INSERT" is NOT enough:
--   time  Session A                      Session B
--   t1    SELECT ... unit 28 free? yes
--   t2                                   SELECT ... unit 28 free? yes
--   t3    INSERT booking item
--   t4                                   INSERT booking item   <- DOUBLE BOOKING
--   Plain SELECTs take no locks, so both sessions see the unit as free.
--   Locking the unit row (SELECT ... FOR UPDATE) forces t2 to wait until A
--   finishes, and the locking re-check then sees A's committed booking.

-- =====================================================================
-- SCENARIO 5 - DURABILITY
-- Once COMMIT returns, InnoDB has written the change to its redo log on
-- disk, so it survives a crash or restart.
-- =====================================================================
START TRANSACTION;
UPDATE system_settings SET late_fee_multiplier = 1.75 WHERE settings_id = 1;
COMMIT;

SELECT late_fee_multiplier FROM system_settings;   -- 1.75
-- Optional proof: stop and start the MySQL server (macOS System Settings ->
-- MySQL -> Stop/Start, or Workbench -> Server -> Startup/Shutdown), reconnect
-- and run the SELECT again: the value is still 1.75.

-- Restore the original policy value (another committed transaction)
UPDATE system_settings SET late_fee_multiplier = 1.50 WHERE settings_id = 1;
SELECT late_fee_multiplier AS restored_multiplier FROM system_settings;   -- 1.50
