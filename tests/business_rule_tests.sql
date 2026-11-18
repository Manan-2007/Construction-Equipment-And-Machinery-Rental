-- =====================================================================
--  File   : tests/business_rule_tests.sql
--  Purpose: Test triggers + stored procedures: booking rules, double
--           booking, cancellation, maintenance conflicts, handover,
--           partial / duplicate returns, audit log.
--  Needs  : fresh 00_master_setup.sql, then tests/00_test_helpers.sql
--  Data   : creates test rows marked with site_address / description
--           starting 'TEST:' and test customers with phone +919000000xxx;
--           ALL of them are deleted in the CLEAN-UP section at the end
--           (and at the start, in case an earlier run was interrupted).
--           The business date is restored to its original value.
-- =====================================================================

USE construction_rental_db;
SET @saved_safe_updates = @@SESSION.sql_safe_updates;
SET SESSION sql_safe_updates = 0;          -- clean-up uses DELETE ... JOIN on non-key columns
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

CALL test_init('business_rules');

-- ---------- set-up: a test customer ----------
INSERT INTO customers (customer_type, full_name, organisation_name, phone, address_line, city, state, pincode, registration_date)
VALUES ('COMPANY', 'Test Contact', 'TEST Builders', '+919000000001', 'Test address', 'Mohali', 'Punjab', '160071', '2026-11-20');
SET @tc = LAST_INSERT_ID();

-- =====================================================================
-- A. Creating bookings
-- =====================================================================
CALL test_expect_ok('BR01 valid booking through sp_create_booking',
  "CALL sp_create_booking(@tc, 2, '2027-01-10', '2027-01-12', '32', 'TEST: BR01', @t1)");
CALL test_assert_equals('BR02 new booking is RESERVED',
  "SELECT booking_status FROM bookings WHERE booking_id = @t1", 'RESERVED');
CALL test_assert_equals('BR03 deposit created from model deposit (Rs 15,000)',
  "SELECT required_amount FROM security_deposits WHERE booking_id = @t1", '15000.00');
CALL test_assert_equals('BR04 agreed rate copied from list price',
  "SELECT agreed_daily_rate FROM booking_items WHERE booking_id = @t1", '3000.00');

CALL test_expect_error('BR05 overlapping booking of same unit refused (shares 12-Jan)',
  "CALL sp_create_booking(@tc, 2, '2027-01-12', '2027-01-14', '32', 'TEST: BR05', @x)",
  'BOOKING_CONFLICT');
CALL test_expect_error('BR06 booking fully inside an existing booking refused',
  "CALL sp_create_booking(@tc, 2, '2027-01-11', '2027-01-11', '32', 'TEST: BR06', @x)",
  'BOOKING_CONFLICT');
CALL test_expect_ok('BR07 back-to-back booking (starts the day after) allowed',
  "CALL sp_create_booking(@tc, 2, '2027-01-13', '2027-01-15', '32', 'TEST: BR07', @t2)");

-- direct SQL cannot bypass the rule: the trigger on booking_items checks too
INSERT INTO bookings (customer_id, created_by_staff_id, booking_date, start_date, expected_return_date, site_address)
VALUES (@tc, 2, '2026-11-20', '2027-01-11', '2027-01-11', 'TEST: BR08 direct');
SET @t3 = LAST_INSERT_ID();
CALL test_expect_error('BR08 direct INSERT into booking_items cannot double-book',
  "INSERT INTO booking_items (booking_id, equipment_id, agreed_daily_rate) VALUES (@t3, 32, 3000)",
  'BOOKING_CONFLICT');

CALL test_expect_error('BR09 multi-unit request with one busy unit is refused',
  "CALL sp_create_booking(@tc, 2, '2027-01-11', '2027-01-12', '31,32', 'TEST: BR09', @x)",
  'CER-GEN-005');
CALL test_assert_equals('BR10 ...and the free unit (31) was NOT partially allocated',
  "SELECT COUNT(*) FROM booking_items bi JOIN bookings b ON b.booking_id = bi.booking_id
   WHERE bi.equipment_id = 31 AND b.site_address LIKE 'TEST:%'", '0');

CALL test_expect_error('BR11 unit IN_PROGRESS in workshop cannot be booked',
  "CALL sp_create_booking(@tc, 2, '2026-11-21', '2026-11-22', '13', 'TEST: BR11', @x)",
  'MAINTENANCE_CONFLICT');
CALL test_expect_error('BR12 unit with SCHEDULED maintenance in the period cannot be booked',
  "CALL sp_create_booking(@tc, 2, '2026-11-26', '2026-11-27', '21', 'TEST: BR12', @x)",
  'MAINTENANCE_CONFLICT');
CALL test_expect_ok('BR13 same unit is bookable outside the maintenance window',
  "CALL sp_create_booking(@tc, 2, '2026-11-28', '2026-11-29', '21', 'TEST: BR13', @t13)");
CALL test_expect_error('BR14 retired unit cannot be booked',
  "CALL sp_create_booking(@tc, 2, '2026-12-01', '2026-12-02', '30', 'TEST: BR14', @x)",
  'UNIT_RETIRED');
CALL test_expect_error('BR15 overdue unit (not yet returned) blocks future bookings',
  "CALL sp_create_booking(@tc, 2, '2026-12-20', '2026-12-21', '3', 'TEST: BR15', @x)",
  'BOOKING_CONFLICT');
CALL test_expect_error('BR16 inactive customer cannot book',
  "CALL sp_create_booking(18, 2, '2026-12-01', '2026-12-02', '28', 'TEST: BR16', @x)",
  'inactive');
CALL test_expect_error('BR17 return date before start date refused',
  "CALL sp_create_booking(@tc, 2, '2026-12-05', '2026-12-01', '28', 'TEST: BR17', @x)",
  'Invalid rental period');
CALL test_expect_error('BR18 rental starting in the past refused',
  "CALL sp_create_booking(@tc, 2, '2026-11-10', '2026-11-12', '28', 'TEST: BR18', @x)",
  'past');
CALL test_expect_error('BR19 rental longer than max_rental_days refused',
  "CALL sp_create_booking(@tc, 2, '2027-01-01', '2027-12-31', '28', 'TEST: BR19', @x)",
  'maximum');
CALL test_expect_error('BR20 technician cannot create a booking',
  "CALL sp_create_booking(@tc, 4, '2026-12-01', '2026-12-02', '28', 'TEST: BR20', @x)",
  'rental agent');
CALL test_expect_error('BR21 same unit listed twice refused',
  "CALL sp_create_booking(@tc, 2, '2026-12-01', '2026-12-02', '28,28', 'TEST: BR21', @x)",
  'more than once');
CALL test_expect_error('BR22 non-existent equipment id refused',
  "CALL sp_create_booking(@tc, 2, '2026-12-01', '2026-12-02', '999', 'TEST: BR22', @x)",
  'do not exist');

-- =====================================================================
-- B. Cancellation
-- =====================================================================
CALL test_expect_ok('BR23 cancelled booking (B25, unit 2) does not block the unit',
  "CALL sp_create_booking(@tc, 2, '2026-11-21', '2026-11-22', '2', 'TEST: BR23', @t4)");
CALL test_expect_ok('BR24 cancel a RESERVED booking',
  "CALL sp_cancel_booking(@t4, 'TEST: customer changed plans')");
CALL test_assert_equals('BR25 cancelled booking: status CANCELLED, deposit CANCELLED',
  "SELECT CONCAT(b.booking_status, '/', sd.deposit_status) FROM bookings b
   JOIN security_deposits sd ON sd.booking_id = b.booking_id WHERE b.booking_id = @t4", 'CANCELLED/CANCELLED');
CALL test_expect_ok('BR26 unit is free again after cancellation',
  "CALL sp_create_booking(@tc, 2, '2026-11-21', '2026-11-22', '2', 'TEST: BR26', @t5)");
CALL test_expect_error('BR27 cannot cancel twice',
  "CALL sp_cancel_booking(@t4, 'again')", 'Only RESERVED');
CALL test_expect_error('BR28 cannot cancel an ACTIVE booking',
  "CALL sp_cancel_booking(17, 'TEST')", 'Only RESERVED');

-- =====================================================================
-- C. Handover and status transitions
-- =====================================================================
CALL test_expect_ok('BR29 booking starting today (unit 28)',
  "CALL sp_create_booking(@tc, 2, '2026-11-20', '2026-11-21', '28', 'TEST: BR29', @t6)");
CALL test_expect_error('BR30 handover refused while deposit is PENDING',
  "CALL sp_start_rental(@t6)", 'deposit must be collected');
CALL test_expect_ok('BR31 collect deposit', "CALL sp_collect_deposit(@t6)");
CALL test_expect_ok('BR32 handover after deposit collected', "CALL sp_start_rental(@t6)");
CALL test_expect_error('BR33 handover refused before the rental start date',
  "UPDATE bookings SET booking_status = 'ACTIVE' WHERE booking_id = @t1", 'during the booked rental period');
CALL test_expect_error('BR34 invalid transition ACTIVE -> RESERVED',
  "UPDATE bookings SET booking_status = 'RESERVED' WHERE booking_id = @t6", 'Invalid booking status transition');
CALL test_expect_error('BR35 booking dates are frozen',
  "UPDATE bookings SET expected_return_date = '2026-11-25' WHERE booking_id = @t6", 'cannot be changed');
CALL test_expect_error('BR36 cannot mark COMPLETED while machines are out',
  "UPDATE bookings SET booking_status = 'COMPLETED' WHERE booking_id = 17", 'still out');
CALL test_expect_error('BR37 new booking must start as RESERVED',
  "INSERT INTO bookings (customer_id, created_by_staff_id, booking_date, start_date, expected_return_date, booking_status, site_address)
   VALUES (@tc, 2, '2026-11-20', '2026-12-01', '2026-12-02', 'ACTIVE', 'TEST: BR37')", 'RESERVED status');
CALL test_expect_error('BR38 machines can only be added to RESERVED bookings',
  "INSERT INTO booking_items (booking_id, equipment_id, agreed_daily_rate) VALUES (17, 28, 900)", 'RESERVED booking');

-- =====================================================================
-- D. Returns (partial, duplicate, damage)
-- =====================================================================
CALL test_expect_ok('BR39 two-unit booking starting today (units 20, 23)',
  "CALL sp_create_booking(@tc, 2, '2026-11-20', '2026-11-21', '20,23', 'TEST: BR39', @t7)");
CALL sp_collect_deposit(@t7);
CALL sp_start_rental(@t7);
SET @t7_item20 = (SELECT booking_item_id FROM booking_items WHERE booking_id = @t7 AND equipment_id = 20);
SET @t7_item23 = (SELECT booking_item_id FROM booking_items WHERE booking_id = @t7 AND equipment_id = 23);

CALL test_expect_error('BR40 return dated in the future refused',
  "CALL sp_return_equipment(@t7_item20, '2026-11-22', 'GOOD', 0, NULL, 4, @x)", 'between the rental start date and today');
CALL test_expect_ok('BR41 partial return of one unit',
  "CALL sp_return_equipment(@t7_item20, NULL, 'GOOD', 0, NULL, 4, @r1)");
CALL test_assert_equals('BR42 booking stays ACTIVE after a partial return',
  "SELECT booking_status FROM bookings WHERE booking_id = @t7", 'ACTIVE');
CALL test_expect_error('BR43 duplicate return refused',
  "CALL sp_return_equipment(@t7_item20, NULL, 'GOOD', 0, NULL, 4, @x)", 'already been returned');
CALL test_expect_error('BR44 GOOD condition with a damage charge refused',
  "CALL sp_return_equipment(@t7_item23, NULL, 'GOOD', 500, NULL, 4, @x)", 'cannot carry a damage charge');
CALL test_expect_ok('BR45 last unit returned with MAJOR damage',
  "CALL sp_return_equipment(@t7_item23, NULL, 'MAJOR_DAMAGE', 5000, 'TEST: cracked canopy', 4, @r2)");
CALL test_assert_equals('BR46 booking auto-COMPLETED by trigger when last unit returns',
  "SELECT booking_status FROM bookings WHERE booking_id = @t7", 'COMPLETED');
CALL test_assert_equals('BR47 MAJOR damage auto-schedules a corrective repair',
  "SELECT COUNT(*) FROM maintenance_records WHERE related_return_id = @r2 AND maintenance_type = 'CORRECTIVE'", '1');
CALL test_expect_error('BR48 cannot return a machine of a RESERVED booking',
  "CALL sp_return_equipment((SELECT booking_item_id FROM booking_items WHERE booking_id = @t1), NULL, 'GOOD', 0, NULL, 4, @x)",
  'ACTIVE booking');
CALL test_expect_error('BR49 direct INSERT with a wrong late charge refused',
  "INSERT INTO equipment_returns (booking_item_id, return_date, received_by_staff_id, return_condition, late_charge, damage_charge)
   VALUES (31, '2026-11-20', 4, 'GOOD', 0, 0)", 'late-fee policy');

-- =====================================================================
-- E. Maintenance scheduling
-- =====================================================================
CALL test_expect_error('BR50 maintenance overlapping a booking refused',
  "CALL sp_schedule_maintenance(32, 'PREVENTIVE', '2027-01-11', '2027-01-11', 5, 'TEST: BR50', @x)", 'BOOKING_CONFLICT');
CALL test_expect_error('BR51 maintenance overlapping another maintenance job refused',
  "CALL sp_schedule_maintenance(21, 'INSPECTION', '2026-11-27', '2026-11-27', 5, 'TEST: BR51', @x)", 'MAINTENANCE_CONFLICT');
CALL test_expect_ok('BR52 maintenance on free dates accepted',
  "CALL sp_schedule_maintenance(32, 'PREVENTIVE', '2027-02-01', '2027-02-02', 5, 'TEST: BR52', @m1)");
CALL test_expect_error('BR53 booking during planned maintenance refused',
  "CALL sp_create_booking(@tc, 2, '2027-02-02', '2027-02-03', '32', 'TEST: BR53', @x)", 'MAINTENANCE_CONFLICT');
CALL test_expect_error('BR54 maintenance in the past refused',
  "CALL sp_schedule_maintenance(32, 'PREVENTIVE', '2026-11-01', '2026-11-02', 5, 'TEST: BR54', @x)", 'past');
CALL test_expect_error('BR55 maintenance can only be assigned to a TECHNICIAN',
  "INSERT INTO maintenance_records (equipment_id, technician_staff_id, maintenance_type, scheduled_start, scheduled_end, description)
   VALUES (32, 2, 'INSPECTION', '2027-03-01', '2027-03-01', 'TEST: BR55')", 'TECHNICIAN');
CALL test_expect_error('BR56 invalid maintenance transition COMPLETED -> SCHEDULED',
  "UPDATE maintenance_records SET maintenance_status = 'SCHEDULED', actual_start = NULL, actual_end = NULL WHERE maintenance_id = 1",
  'Invalid maintenance status transition');
CALL test_expect_error('BR57 cannot start maintenance on a unit that is out on rent',
  "UPDATE maintenance_records SET maintenance_status = 'IN_PROGRESS', actual_start = '2026-11-20' WHERE maintenance_id = 15",
  'BOOKING_CONFLICT');
CALL test_expect_error('BR58 starting a Feb job early (today) would overlap January bookings - refused',
  "CALL sp_start_maintenance(@m1)", 'BOOKING_CONFLICT');
CALL test_expect_ok('BR59 schedule maintenance today on a free unit (31)',
  "CALL sp_schedule_maintenance(31, 'INSPECTION', '2026-11-20', '2026-11-21', 4, 'TEST: BR59', @m2)");
CALL test_expect_ok('BR60 start maintenance (SCHEDULED -> IN_PROGRESS)', "CALL sp_start_maintenance(@m2)");
CALL test_assert_equals('BR61 unit shows IN_MAINTENANCE in the inventory view',
  "SELECT current_state FROM vw_equipment_inventory WHERE equipment_id = 31", 'IN_MAINTENANCE');
CALL test_expect_ok('BR62 complete maintenance with cost', "CALL sp_complete_maintenance(@m2, 4500)");
CALL test_assert_equals('BR63 completed maintenance has actual dates and cost',
  "SELECT CONCAT(maintenance_status, '/', actual_end, '/', maintenance_cost) FROM maintenance_records WHERE maintenance_id = @m2",
  'COMPLETED/2026-11-20/4500.00');

-- =====================================================================
-- F. Functions, audit trail, cursor procedure
-- =====================================================================
CALL test_assert_equals('BR64 inclusive day count: same-day rental = 1 day',
  "SELECT fn_rental_days('2026-11-20', '2026-11-20')", '1');
CALL test_assert_equals('BR65 fn_unit_conflict returns NULL for a free unit/period',
  "SELECT COALESCE(fn_unit_conflict(28, '2027-06-01', '2027-06-05', NULL, NULL), 'FREE')", 'FREE');
CALL test_assert_equals('BR66 audit log has RESERVED, ACTIVE, COMPLETED for the returned booking',
  "SELECT GROUP_CONCAT(new_status ORDER BY log_id) FROM booking_status_log WHERE booking_id = @t7",
  'RESERVED,ACTIVE,COMPLETED');
CALL test_expect_ok('BR67 cursor-based overdue report runs', "CALL sp_overdue_report()");
CALL test_assert_equals('BR68 availability procedure excludes busy units (unit 32 on 11-Jan-2027)',
  "SELECT COUNT(*) FROM equipment_units WHERE equipment_id = 32 AND fn_unit_conflict(32, '2027-01-11', '2027-01-11', NULL, NULL) IS NULL",
  '0');

CALL test_summary();

-- =====================================================================
-- CLEAN-UP: remove every TEST row and restore settings
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
UPDATE system_settings SET business_date = @saved_business_date WHERE settings_id = 1;
SET SESSION sql_safe_updates = @saved_safe_updates;

SELECT 'clean-up done' AS status,
       (SELECT COUNT(*) FROM bookings WHERE site_address LIKE 'TEST:%') AS test_bookings_left;
