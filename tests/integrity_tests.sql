-- =====================================================================
--  File   : tests/integrity_tests.sql
--  Purpose: Prove that keys, CHECK constraints, NOT NULL, ENUM and
--           foreign keys reject bad data.
--  Needs  : 00_master_setup.sql, then tests/00_test_helpers.sql
--  Data   : every negative test fails, so nothing changes; the one
--           positive insert is deleted again at the end.
-- =====================================================================

USE construction_rental_db;
CALL test_init('integrity');
SET @it_customers_before = (SELECT COUNT(*) FROM customers);

-- ---------- Primary key / UNIQUE ----------
CALL test_expect_error('IT01 duplicate primary key (depot_id 1)',
  "INSERT INTO depots (depot_id, depot_name, city, state, phone) VALUES (1, 'Dup Yard', 'Mohali', 'Punjab', '+917087099999')",
  '1062');

CALL test_expect_error('IT02 duplicate equipment serial number',
  "INSERT INTO equipment_units (model_id, depot_id, asset_tag, serial_number, manufacture_year, purchase_date, purchase_cost)
   VALUES (1, 1, 'CER-EXC-099', 'CAT0320GKTW10231', 2025, '2025-01-01', 9000000)",
  'uq_units_serial');

CALL test_expect_error('IT03 duplicate asset tag',
  "INSERT INTO equipment_units (model_id, depot_id, asset_tag, serial_number, manufacture_year, purchase_date, purchase_cost)
   VALUES (1, 1, 'CER-EXC-001', 'NEW-SERIAL-0001', 2025, '2025-01-01', 9000000)",
  'uq_units_asset_tag');

CALL test_expect_error('IT04 duplicate customer phone',
  "INSERT INTO customers (customer_type, full_name, phone, address_line, city, state, pincode, registration_date)
   VALUES ('INDIVIDUAL', 'Copy Cat', '+919876501001', 'x', 'Mohali', 'Punjab', '160071', '2026-11-20')",
  'uq_customers_phone');

CALL test_expect_error('IT05 same unit twice in one booking (trigger fires before the UNIQUE key)',
  "INSERT INTO booking_items (booking_id, equipment_id, agreed_daily_rate) VALUES (22, 29, 15000)",
  'BOOKING_CONFLICT');

-- ---------- Foreign keys ----------
CALL test_expect_error('IT06 FK: unit with non-existent model',
  "INSERT INTO equipment_units (model_id, depot_id, asset_tag, serial_number, manufacture_year, purchase_date, purchase_cost)
   VALUES (999, 1, 'CER-XXX-001', 'SERIAL-X-1', 2025, '2025-01-01', 100000)",
  '1452');

CALL test_expect_error('IT07 FK: booking for non-existent customer',
  "INSERT INTO bookings (customer_id, created_by_staff_id, booking_date, start_date, expected_return_date, site_address)
   VALUES (9999, 2, '2026-11-20', '2026-12-10', '2026-12-12', 'x')",
  '1452');

CALL test_expect_error('IT08 FK RESTRICT: delete customer with booking history',
  "DELETE FROM customers WHERE customer_id = 1",
  '1451');

CALL test_expect_error('IT09 FK RESTRICT: delete retired unit that has rental history',
  "DELETE FROM equipment_units WHERE equipment_id = 30",
  '1451');

CALL test_expect_error('IT10 FK RESTRICT: delete a category that still has models',
  "DELETE FROM equipment_categories WHERE category_id = 1",
  '1451');

-- ---------- CHECK constraints ----------
CALL test_expect_error('IT11 CHECK: invalid Indian phone number',
  "INSERT INTO customers (customer_type, full_name, phone, address_line, city, state, pincode, registration_date)
   VALUES ('INDIVIDUAL', 'Bad Phone', '12345', 'x', 'Mohali', 'Punjab', '160071', '2026-11-20')",
  'chk_customers_phone');

CALL test_expect_error('IT12 CHECK: invalid pincode',
  "INSERT INTO customers (customer_type, full_name, phone, address_line, city, state, pincode, registration_date)
   VALUES ('INDIVIDUAL', 'Bad Pin', '+919000000099', 'x', 'Mohali', 'Punjab', '016007', '2026-11-20')",
  'chk_customers_pincode');

CALL test_expect_error('IT13 CHECK: company without organisation name',
  "INSERT INTO customers (customer_type, full_name, phone, address_line, city, state, pincode, registration_date)
   VALUES ('COMPANY', 'No Org', '+919000000098', 'x', 'Mohali', 'Punjab', '160071', '2026-11-20')",
  'chk_customers_org');

CALL test_expect_error('IT14 CHECK: negative daily rate',
  "UPDATE equipment_models SET daily_rate = -100 WHERE model_id = 1",
  'chk_models_rate');

CALL test_expect_error('IT15 CHECK: RETIRED unit must have retired_date',
  "UPDATE equipment_units SET lifecycle_status = 'RETIRED' WHERE equipment_id = 32",
  'chk_units_retired');

CALL test_expect_error('IT16 CHECK/trigger: return date before start date (invalid rental period)',
  "INSERT INTO bookings (customer_id, created_by_staff_id, booking_date, start_date, expected_return_date, site_address)
   VALUES (4, 2, '2026-11-20', '2026-12-10', '2026-12-05', 'x')",
  'period');

CALL test_expect_error('IT17 CHECK: negative payment amount',
  "INSERT INTO payments (booking_id, amount, payment_date, payment_method, payment_type, reference_no)
   VALUES (17, -500, '2026-11-20', 'UPI', 'BALANCE', 'UPI-NEG-TEST')",
  'chk_payments_amount');

CALL test_expect_error('IT18 CHECK: non-cash payment needs a reference number',
  "INSERT INTO payments (booking_id, amount, payment_date, payment_method, payment_type)
   VALUES (17, 500, '2026-11-20', 'UPI', 'BALANCE')",
  'chk_payments_reference');

CALL test_expect_error('IT19 CHECK: deposit refund larger than amount collected',
  "UPDATE security_deposits SET refunded_amount = 999999 WHERE booking_id = 15",
  'chk_deposits_balance');

CALL test_expect_error('IT20 CHECK: deposit status HELD with nothing collected',
  "UPDATE security_deposits SET deposit_status = 'HELD' WHERE booking_id = 22",
  'chk_deposits_status');

CALL test_expect_error('IT21 CHECK: GOOD return cannot carry a damage charge',
  "INSERT INTO equipment_returns (booking_item_id, return_date, received_by_staff_id, return_condition, late_charge, damage_charge)
   VALUES (33, '2026-11-20', 4, 'GOOD', 0, 500)",
  'chk_returns_damage');

CALL test_expect_error('IT22 UNIQUE: second return record for the same booking item',
  "INSERT INTO equipment_returns (booking_item_id, return_date, received_by_staff_id, return_condition, late_charge, damage_charge)
   VALUES (32, '2026-11-20', 4, 'GOOD', 15000, 0)",
  'uq_returns_item');

CALL test_expect_error('IT23 CHECK: maintenance actual_end before actual_start',
  "INSERT INTO maintenance_records (equipment_id, maintenance_type, maintenance_status, scheduled_start, scheduled_end, actual_start, actual_end, description)
   VALUES (32, 'INSPECTION', 'COMPLETED', '2027-05-01', '2027-05-02', '2027-05-02', '2027-05-01', 'bad dates')",
  'chk_maint_actual_period');

CALL test_expect_error('IT24 CHECK: COMPLETED maintenance without actual dates',
  "INSERT INTO maintenance_records (equipment_id, maintenance_type, maintenance_status, scheduled_start, scheduled_end, description)
   VALUES (32, 'INSPECTION', 'COMPLETED', '2027-05-01', '2027-05-02', 'no actual dates')",
  'chk_maint_status_dates');

CALL test_expect_error('IT25 CHECK: only one row allowed in system_settings',
  "INSERT INTO system_settings (settings_id, business_date) VALUES (2, '2026-11-20')",
  'chk_settings_single_row');

-- ---------- NOT NULL / ENUM / data types ----------
CALL test_expect_error('IT26 NOT NULL: customer without city',
  "INSERT INTO customers (customer_type, full_name, phone, address_line, city, state, pincode, registration_date)
   VALUES ('INDIVIDUAL', 'No City', '+919000000097', 'x', NULL, 'Punjab', '160071', '2026-11-20')",
  '1048');

CALL test_expect_error('IT27 ENUM: unknown customer type',
  "INSERT INTO customers (customer_type, full_name, phone, address_line, city, state, pincode, registration_date)
   VALUES ('NGO', 'Bad Type', '+919000000096', 'x', 'Mohali', 'Punjab', '160071', '2026-11-20')",
  '1265');

CALL test_expect_error('IT28 DATE type: impossible date 2026-02-30',
  "INSERT INTO customers (customer_type, full_name, phone, address_line, city, state, pincode, registration_date)
   VALUES ('INDIVIDUAL', 'Bad Date', '+919000000095', 'x', 'Mohali', 'Punjab', '160071', '2026-02-30')",
  '1292');

-- ---------- Positive control: valid data IS accepted ----------
CALL test_expect_ok('IT29 valid customer is accepted',
  "INSERT INTO customers (customer_type, full_name, phone, address_line, city, state, pincode, registration_date)
   VALUES ('INDIVIDUAL', 'Integrity Test User', '+919000000094', 'Test address', 'Mohali', 'Punjab', '160071', '2026-11-20')");

CALL test_expect_ok('IT30 customer without bookings can be deleted',
  "DELETE FROM customers WHERE phone = '+919000000094'");

CALL test_assert_equals('IT31 nothing was changed by the negative tests (customer count)',
  "SELECT COUNT(*) FROM customers", CAST(@it_customers_before AS CHAR));

CALL test_summary();
