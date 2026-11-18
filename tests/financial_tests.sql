-- =====================================================================
--  File   : tests/financial_tests.sql
--  Purpose: Money rules - rental charge calculation, price snapshots,
--           payments (overpayment, negative, cancelled, status changes),
--           late fees, damage charges, deposit settlement (full refund,
--           partial retention, forfeiture) and reconciliation invariants.
--  Needs  : fresh 00_master_setup.sql, then tests/00_test_helpers.sql
--  Data   : test rows are marked 'TEST:' and removed at the end; the
--           business date is moved forward during the test and restored.
-- =====================================================================

USE construction_rental_db;
SET @saved_safe_updates = @@SESSION.sql_safe_updates;
SET SESSION sql_safe_updates = 0;
SET @saved_business_date = (SELECT business_date FROM system_settings WHERE settings_id = 1);

-- ---------- pre-clean (idempotent) ----------
DELETE mr FROM maintenance_records mr
 WHERE mr.description LIKE 'TEST:%'
    OR mr.related_return_id IN (SELECT r.return_id FROM equipment_returns r
                                JOIN booking_items bi ON bi.booking_item_id = r.booking_item_id
                                JOIN bookings b ON b.booking_id = bi.booking_id
                                WHERE b.site_address LIKE 'TEST:%');
DELETE r  FROM equipment_returns r JOIN booking_items bi ON bi.booking_item_id = r.booking_item_id
          JOIN bookings b ON b.booking_id = bi.booking_id WHERE b.site_address LIKE 'TEST:%';
DELETE p  FROM payments p JOIN bookings b ON b.booking_id = p.booking_id WHERE b.site_address LIKE 'TEST:%';
DELETE sd FROM security_deposits sd JOIN bookings b ON b.booking_id = sd.booking_id WHERE b.site_address LIKE 'TEST:%';
DELETE l  FROM booking_status_log l JOIN bookings b ON b.booking_id = l.booking_id WHERE b.site_address LIKE 'TEST:%';
DELETE bi FROM booking_items bi JOIN bookings b ON b.booking_id = bi.booking_id WHERE b.site_address LIKE 'TEST:%';
DELETE FROM bookings  WHERE site_address LIKE 'TEST:%';
DELETE FROM customers WHERE phone LIKE '+919000000%';

CALL test_init('financial');

INSERT INTO customers (customer_type, full_name, organisation_name, phone, address_line, city, state, pincode, registration_date)
VALUES ('COMPANY', 'Finance Test', 'TEST Money Builders', '+919000000002', 'Test address', 'Mohali', 'Punjab', '160071', '2026-11-20');
SET @fc = LAST_INSERT_ID();

-- =====================================================================
-- A. Charge calculation and price snapshot
-- =====================================================================
CALL sp_create_booking(@fc, 2, '2026-11-21', '2026-11-25', '7,27', 'TEST: F1 JCB + compactor', @f1);
CALL sp_create_booking(@fc, 2, '2026-11-21', '2026-11-22', '28', 'TEST: F2 compactor', @f2);

CALL test_assert_equals('FT01 rental = (5,500 + 900) x 5 inclusive days = 32,000',
  "SELECT fn_booking_rental_charge(@f1)", '32000.00');
CALL test_assert_equals('FT02 view and function agree on the rental charge',
  "SELECT rental_charge FROM vw_booking_financial_summary WHERE booking_id = @f1", '32000.00');
CALL test_assert_equals('FT03 deposit = 30,000 + 5,000',
  "SELECT required_amount FROM security_deposits WHERE booking_id = @f1", '35000.00');

UPDATE equipment_models SET daily_rate = 1000.00 WHERE model_id = 17;       -- list price rises
CALL test_assert_equals('FT04 later list-price change does not alter the agreed price',
  "SELECT agreed_daily_rate FROM booking_items WHERE booking_id = @f1 AND equipment_id = 27", '900.00');
UPDATE equipment_models SET daily_rate = 900.00 WHERE model_id = 17;        -- restore

CALL sp_create_booking(9, 3, '2027-03-01', '2027-03-03', '28', 'TEST: F3 government', @f3);
CALL test_assert_equals('FT05 government customer: no security deposit row',
  "SELECT COUNT(*) FROM security_deposits WHERE booking_id = @f3", '0');

-- =====================================================================
-- B. Payments
-- =====================================================================
CALL test_expect_error('FT06 zero / negative payment refused (procedure)',
  "CALL sp_record_payment(@f1, -100, 'CASH', 'ADVANCE', NULL, @x)", 'greater than zero');
CALL test_expect_error('FT07 overpayment refused (procedure)',
  "CALL sp_record_payment(@f1, 40000, 'CASH', 'ADVANCE', NULL, @x)", 'exceeds the balance');
CALL test_expect_error('FT08 overpayment refused (direct INSERT, trigger)',
  "INSERT INTO payments (booking_id, amount, payment_date, payment_method, payment_type) VALUES (@f1, 40000, '2026-11-20', 'CASH', 'ADVANCE')",
  'Overpayment');
CALL test_expect_error('FT09 payment on a cancelled booking refused',
  "CALL sp_record_payment(12, 1000, 'CASH', 'ADVANCE', NULL, @x)", 'cancelled');
CALL test_expect_error('FT10 future-dated payment refused',
  "INSERT INTO payments (booking_id, amount, payment_date, payment_method, payment_type) VALUES (@f1, 100, '2026-12-01', 'CASH', 'ADVANCE')",
  'between the booking date and today');
CALL test_expect_ok('FT11 valid advance payment of 10,000',
  "CALL sp_record_payment(@f1, 10000, 'UPI', 'ADVANCE', 'UPI-TEST-F1-ADV', @p1)");
CALL test_assert_equals('FT12 balance due after advance = 22,000',
  "SELECT balance_due FROM vw_booking_financial_summary WHERE booking_id = @f1", '22000.00');
CALL test_expect_error('FT13 payment amount cannot be edited afterwards',
  "UPDATE payments SET amount = 1 WHERE payment_id = @p1", 'cannot be changed');
CALL test_expect_error('FT14 FAILED payment cannot become COMPLETED',
  "UPDATE payments SET payment_status = 'COMPLETED' WHERE payment_id = 20", 'Invalid payment status transition');
INSERT INTO payments (booking_id, amount, payment_date, payment_method, payment_type, payment_status, reference_no)
VALUES (@f1, 30000, '2026-11-20', 'CHEQUE', 'BALANCE', 'PENDING', 'CHQ-TEST-F1');
SET @p_pending = LAST_INSERT_ID();
CALL test_expect_error('FT15 confirming a PENDING cheque that would overpay is refused',
  "UPDATE payments SET payment_status = 'COMPLETED' WHERE payment_id = @p_pending", 'Overpayment');
CALL test_expect_ok('FT16 PENDING cheque can be marked FAILED',
  "UPDATE payments SET payment_status = 'FAILED' WHERE payment_id = @p_pending");
CALL test_expect_ok('FT17 pay booking F2 in full (1,800)',
  "CALL sp_record_payment(@f2, 1800, 'CASH', 'BALANCE', NULL, @p2)");

-- =====================================================================
-- C. Deposits - invalid operations on seed data
-- =====================================================================
CALL test_expect_error('FT18 refund larger than deposit collected (CHECK)',
  "UPDATE security_deposits SET refunded_amount = 999999 WHERE booking_id = 15", 'chk_deposits_balance');
CALL test_expect_error('FT19 cannot retain deposit when nothing is owed (trigger)',
  "UPDATE security_deposits SET retained_amount = 1000, refunded_amount = 69000, settled_date = '2026-11-20',
          retention_reason = 'TEST', deposit_status = 'PARTIALLY_REFUNDED' WHERE booking_id = 15",
  'Cannot retain more');
CALL test_expect_error('FT20 settled deposit is final',
  "UPDATE security_deposits SET refunded_amount = 0 WHERE booking_id = 1", 'final');
CALL test_expect_error('FT21 deposit cannot be settled while machines are out',
  "CALL sp_settle_deposit(17)", 'only after all machines are returned');
CALL test_expect_error('FT22 deposit cannot be collected twice',
  "CALL sp_collect_deposit(21)", 'already been collected');

-- =====================================================================
-- D. Full rental cycles with the business date moving forward
-- =====================================================================
CALL sp_collect_deposit(@f1);
CALL sp_collect_deposit(@f2);
CALL sp_set_business_date('2026-11-21');
CALL sp_start_rental(@f1);
CALL sp_start_rental(@f2);

-- D1. On-time return -> full refund
CALL sp_set_business_date('2026-11-22');
SET @f2_item = (SELECT booking_item_id FROM booking_items WHERE booking_id = @f2);
CALL test_expect_ok('FT23 on-time return of F2', "CALL sp_return_equipment(@f2_item, NULL, 'GOOD', 0, NULL, 4, @r)");
CALL test_assert_equals('FT24 on-time return: late charge 0',
  "SELECT late_charge FROM equipment_returns WHERE booking_item_id = @f2_item", '0.00');
CALL test_expect_ok('FT25 settle F2 deposit', "CALL sp_settle_deposit(@f2)");
CALL test_assert_equals('FT26 fully paid booking -> deposit fully REFUNDED',
  "SELECT CONCAT(deposit_status, '/', refunded_amount, '/', retained_amount) FROM security_deposits WHERE booking_id = @f2",
  'REFUNDED/5000.00/0.00');

-- D2. Partial return, then late return -> deposit partially retained
CALL sp_set_business_date('2026-11-23');
SET @f1_cmp = (SELECT booking_item_id FROM booking_items WHERE booking_id = @f1 AND equipment_id = 27);
SET @f1_jcb = (SELECT booking_item_id FROM booking_items WHERE booking_id = @f1 AND equipment_id = 7);
CALL sp_return_equipment(@f1_cmp, NULL, 'GOOD', 0, NULL, 4, @r);
CALL test_assert_equals('FT27 early partial return does not reduce the rental charge',
  "SELECT rental_charge FROM vw_booking_financial_summary WHERE booking_id = @f1", '32000.00');

CALL sp_set_business_date('2026-11-27');               -- due 25-Nov -> 2 days late
CALL test_assert_equals('FT28 overdue view: accrued late fee 2 x 5,500 x 1.5 = 16,500',
  "SELECT accrued_late_charge FROM vw_overdue_rentals WHERE booking_item_id = @f1_jcb", '16500.00');
CALL test_expect_ok('FT29 late return of the JCB', "CALL sp_return_equipment(@f1_jcb, NULL, 'GOOD', 0, NULL, 5, @r)");
CALL test_assert_equals('FT30 stored late charge = 16,500',
  "SELECT late_charge FROM equipment_returns WHERE booking_item_id = @f1_jcb", '16500.00');
CALL test_assert_equals('FT31 total charges = 32,000 + 16,500',
  "SELECT total_charges FROM vw_booking_financial_summary WHERE booking_id = @f1", '48500.00');
CALL test_expect_ok('FT32 customer pays the remaining rent (22,000)',
  "CALL sp_record_payment(@f1, 22000, 'UPI', 'BALANCE', 'UPI-TEST-F1-BAL', @p3)");
CALL test_expect_ok('FT33 settle F1 deposit', "CALL sp_settle_deposit(@f1)");
CALL test_assert_equals('FT34 late fee retained from deposit, rest refunded',
  "SELECT CONCAT(deposit_status, '/', retained_amount, '/', refunded_amount) FROM security_deposits WHERE booking_id = @f1",
  'PARTIALLY_REFUNDED/16500.00/18500.00');
CALL test_assert_equals('FT35 booking fully reconciled: balance 0',
  "SELECT balance_due = 0 FROM vw_booking_financial_summary WHERE booking_id = @f1", '1');   -- 1 = TRUE

-- D3. Damage larger than the deposit -> deposit FORFEITED, customer still owes
CALL sp_create_booking(@fc, 2, '2026-11-27', '2026-11-28', '23', 'TEST: F4 generator', @f4);   -- 2 x 3,000; deposit 15,000
CALL sp_collect_deposit(@f4);
CALL sp_start_rental(@f4);
CALL sp_set_business_date('2026-11-28');
SET @f4_item = (SELECT booking_item_id FROM booking_items WHERE booking_id = @f4);
CALL test_expect_ok('FT36 return with MAJOR damage charge 20,000',
  "CALL sp_return_equipment(@f4_item, NULL, 'MAJOR_DAMAGE', 20000, 'TEST: alternator burnt', 4, @r)");
CALL test_expect_ok('FT37 settle F4 deposit', "CALL sp_settle_deposit(@f4)");
CALL test_assert_equals('FT38 whole deposit retained -> FORFEITED',
  "SELECT CONCAT(deposit_status, '/', retained_amount, '/', refunded_amount) FROM security_deposits WHERE booking_id = @f4",
  'FORFEITED/15000.00/0.00');
CALL test_assert_equals('FT39 customer still owes 6,000 + 20,000 - 15,000 = 11,000',
  "SELECT balance_due FROM vw_booking_financial_summary WHERE booking_id = @f4", '11000.00');

-- =====================================================================
-- E. Reconciliation invariants over ALL bookings
-- =====================================================================
CALL test_assert_equals('FT40 no booking has received more than its charges',
  "SELECT COUNT(*) FROM vw_booking_financial_summary WHERE amount_received > total_charges", '0');
CALL test_assert_equals('FT41 no deposit refunds+retains more than collected',
  "SELECT COUNT(*) FROM security_deposits WHERE refunded_amount + retained_amount > collected_amount", '0');
CALL test_assert_equals('FT42 every stored late charge matches the policy formula',
  "SELECT COUNT(*) FROM equipment_returns r WHERE r.late_charge <> fn_late_charge(r.booking_item_id, r.return_date)", '0');
CALL test_assert_equals('FT43 cancelled bookings carry no charges and no completed payments',
  "SELECT COUNT(*) FROM vw_booking_financial_summary WHERE booking_status = 'CANCELLED' AND (total_charges <> 0 OR payments_received <> 0)", '0');
CALL test_assert_equals('FT44 view total = function total for every booking',
  "SELECT COUNT(*) FROM vw_booking_financial_summary f WHERE f.total_charges <> fn_booking_total_charges(f.booking_id)", '0');

CALL test_summary();

-- =====================================================================
-- CLEAN-UP
-- =====================================================================
DELETE mr FROM maintenance_records mr
 WHERE mr.description LIKE 'TEST:%'
    OR mr.related_return_id IN (SELECT r.return_id FROM equipment_returns r
                                JOIN booking_items bi ON bi.booking_item_id = r.booking_item_id
                                JOIN bookings b ON b.booking_id = bi.booking_id
                                WHERE b.site_address LIKE 'TEST:%');
DELETE r  FROM equipment_returns r JOIN booking_items bi ON bi.booking_item_id = r.booking_item_id
          JOIN bookings b ON b.booking_id = bi.booking_id WHERE b.site_address LIKE 'TEST:%';
DELETE p  FROM payments p JOIN bookings b ON b.booking_id = p.booking_id WHERE b.site_address LIKE 'TEST:%';
DELETE sd FROM security_deposits sd JOIN bookings b ON b.booking_id = sd.booking_id WHERE b.site_address LIKE 'TEST:%';
DELETE l  FROM booking_status_log l JOIN bookings b ON b.booking_id = l.booking_id WHERE b.site_address LIKE 'TEST:%';
DELETE bi FROM booking_items bi JOIN bookings b ON b.booking_id = bi.booking_id WHERE b.site_address LIKE 'TEST:%';
DELETE FROM bookings  WHERE site_address LIKE 'TEST:%';
DELETE FROM customers WHERE phone LIKE '+919000000%';
UPDATE equipment_models SET daily_rate = 900.00 WHERE model_id = 17;
UPDATE system_settings SET business_date = @saved_business_date WHERE settings_id = 1;
SET SESSION sql_safe_updates = @saved_safe_updates;

SELECT 'clean-up done' AS status, fn_business_date() AS business_date_restored,
       (SELECT COUNT(*) FROM bookings WHERE site_address LIKE 'TEST:%') AS test_bookings_left;
