-- =====================================================================
--  File   : 10_demo_queries.sql
--  Purpose: LIVE DEMONSTRATION SCRIPT for the project evaluation / viva
--
--  HOW TO PRESENT
--   * Run ONE statement at a time: put the cursor on it and press
--     Ctrl+Enter (Windows) / Cmd+Enter (macOS). Explain the output, move on.
--   * PART A is read-only and can be shown any number of times.
--   * PART B changes data (new customer, booking, payments, returns) and
--     moves the business date forward to 29-Nov-2026.
--   * Statements marked "EXPECTED ERROR" must fail - that is the point.
--
--  RESET (before a second run of PART B)
--   Run sql/00_master_setup.sql again. WARNING: it DROPS and re-creates the
--   whole database construction_rental_db with the original seed data.
--   Nothing is ever deleted silently by this demo file.
-- =====================================================================

USE construction_rental_db;

-- Pre-flight check: is the database in its freshly-installed state?
SELECT CASE
         WHEN EXISTS (SELECT 1 FROM customers WHERE phone = '+919417012345')
           OR (SELECT business_date FROM system_settings) <> '2026-11-20'
         THEN 'PART B already executed - run 00_master_setup.sql to reset before repeating PART B'
         ELSE 'Ready: fresh demo data, business date 2026-11-20'
       END AS demo_status;

-- #####################################################################
--                     PART A - READ-ONLY DEMONSTRATIONS
-- #####################################################################

-- ---------------------------------------------------------------------
-- DEMO 1. What machines can we rent out right now?
-- Show: state is DERIVED from bookings + maintenance, not a stored flag.
-- ---------------------------------------------------------------------
SELECT asset_tag, category_name, CONCAT(manufacturer, ' ', model_name) AS machine,
       depot_name, current_daily_rate, next_reservation_start
FROM vw_equipment_inventory
WHERE current_state = 'AVAILABLE'
ORDER BY category_name, asset_tag;

SELECT current_state, COUNT(*) AS units
FROM vw_equipment_inventory
GROUP BY current_state;                       -- AVAILABLE 20, ON_RENT 8, IN_MAINTENANCE 2, RESERVED 1, RETIRED 1

-- ---------------------------------------------------------------------
-- DEMO 11. Maintenance records and service status
-- ---------------------------------------------------------------------
SELECT mr.maintenance_id, u.asset_tag, mr.maintenance_type, mr.maintenance_status,
       mr.scheduled_start, mr.scheduled_end, mr.actual_start, mr.actual_end, mr.maintenance_cost
FROM maintenance_records mr
JOIN equipment_units u ON u.equipment_id = mr.equipment_id
ORDER BY mr.scheduled_start DESC;

SELECT asset_tag, machine, usage_days_since_service, service_interval_rental_days, service_status
FROM vw_maintenance_summary
WHERE service_status <> 'OK';

-- ---------------------------------------------------------------------
-- DEMO 12. Revenue summary
-- ---------------------------------------------------------------------
SELECT c.category_name,
       SUM(r.times_rented)  AS rentals,
       SUM(r.total_revenue) AS revenue,
       SUM(r.maintenance_cost) AS maintenance_cost,
       SUM(r.net_contribution) AS net_contribution
FROM vw_equipment_revenue r
JOIN equipment_categories c ON c.category_name = r.category_name
GROUP BY c.category_name
ORDER BY revenue DESC;

SELECT SUM(total_charges) AS billed, SUM(amount_received) AS received, SUM(balance_due) AS receivable
FROM vw_booking_financial_summary;

-- ---------------------------------------------------------------------
-- DEMO 13. A view in action: overdue rentals and pending refunds
-- ---------------------------------------------------------------------
SELECT * FROM vw_overdue_rentals;            -- booking 18: excavator 4 days late, Rs 78,000 accrued
SELECT * FROM vw_pending_deposit_refunds;    -- bookings 15 and 16

-- #####################################################################
--                     PART B - LIVE BUSINESS TRANSACTIONS
--          (changes data; reset with 00_master_setup.sql afterwards)
-- #####################################################################

-- ---------------------------------------------------------------------
-- DEMO 2. Register a new customer
-- ---------------------------------------------------------------------
INSERT INTO customers (customer_type, full_name, organisation_name, phone, email,
                       address_line, city, state, pincode, registration_date)
VALUES ('COMPANY', 'Mehar Singh Brar', 'Brar Constructions', '+919417012345', 'mehar@brarconstructions.in',
        'Near Bus Stand, Kharar Road', 'Kurali', 'Punjab', '140103', '2026-11-20');
SET @cust = LAST_INSERT_ID();
SELECT * FROM customers WHERE customer_id = @cust;

-- ---------------------------------------------------------------------
-- DEMO 3. Search for a free backhoe loader for 23-27 Nov 2026
-- Expected: CER-BHL-002 and CER-BHL-003 only
--   (CER-BHL-001 is on rent, CER-BHL-004 is booked 25-28 Nov, CER-BHL-005 is retired)
-- ---------------------------------------------------------------------
CALL sp_check_availability('2026-11-23', '2026-11-27', 2);

-- ---------------------------------------------------------------------
-- DEMO 4. Create the booking: JCB 3DX (unit 7) + plate compactor (unit 27)
-- One CALL = one atomic transaction (booking + 2 items + deposit).
-- ---------------------------------------------------------------------
CALL sp_create_booking(@cust, 2, '2026-11-23', '2026-11-27', '7,27',
                       'Brar Residency, Kurali', @bk);
SELECT @bk AS new_booking_id;

-- ---------------------------------------------------------------------
-- DEMO 5. The booking with customer and equipment details (JOIN)
-- ---------------------------------------------------------------------
SELECT b.booking_id, c.organisation_name AS customer, s.full_name AS booked_by,
       u.asset_tag, CONCAT(m.manufacturer, ' ', m.model_name) AS machine,
       bi.agreed_daily_rate, b.start_date, b.expected_return_date, b.booking_status
FROM bookings b
JOIN customers c        ON c.customer_id  = b.customer_id
JOIN staff s            ON s.staff_id     = b.created_by_staff_id
JOIN booking_items bi   ON bi.booking_id  = b.booking_id
JOIN equipment_units u  ON u.equipment_id = bi.equipment_id
JOIN equipment_models m ON m.model_id     = u.model_id
WHERE b.booking_id = @bk;

-- ---------------------------------------------------------------------
-- DEMO 6. Rental charges: (5,500 + 900) x 5 days = Rs 32,000; deposit Rs 35,000
-- ---------------------------------------------------------------------
SELECT fn_rental_days('2026-11-23', '2026-11-27') AS rental_days,
       fn_booking_rental_charge(@bk)              AS rental_charge;
SELECT booking_id, rental_charge, total_charges, deposit_required, deposit_status
FROM vw_booking_financial_summary WHERE booking_id = @bk;

-- ---------------------------------------------------------------------
-- DEMO 7. Collect the security deposit and an advance payment
-- ---------------------------------------------------------------------
CALL sp_collect_deposit(@bk);                                            -- PENDING -> HELD
CALL sp_record_payment(@bk, 10000, 'UPI', 'ADVANCE', CONCAT('UPI-DEMO-', @bk), @pay);   -- balance 22,000

-- ---------------------------------------------------------------------
-- DEMO 8. Another customer tries to book the SAME JCB for 25-26 Nov
-- EXPECTED ERROR 1644: Equipment CER-BHL-002 is not available ... (BOOKING_CONFLICT)
-- ---------------------------------------------------------------------
CALL sp_create_booking(4, 3, '2026-11-25', '2026-11-26', '7', 'Panchkula', @bk2);

SELECT @bk2 AS second_booking_id;            -- NULL: nothing was created (rolled back)

-- Booking a machine that is in the workshop / retired is refused too:
-- EXPECTED ERROR 1644: ... CER-CRN-003 ... (MAINTENANCE_CONFLICT)
CALL sp_create_booking(4, 3, '2026-11-21', '2026-11-22', '13', 'Panchkula', @bk3);
-- EXPECTED ERROR 1644: ... CER-BHL-005 ... (UNIT_RETIRED)
CALL sp_create_booking(4, 3, '2026-11-21', '2026-11-22', '30', 'Panchkula', @bk3);

-- ---------------------------------------------------------------------
-- DEMO 9. Hand over on 23-Nov, then a PARTIAL RETURN on 25-Nov
-- ---------------------------------------------------------------------
CALL sp_set_business_date('2026-11-23');
CALL sp_start_rental(@bk);                                               -- RESERVED -> ACTIVE

CALL sp_set_business_date('2026-11-25');
SET @item_compactor = (SELECT booking_item_id FROM booking_items WHERE booking_id = @bk AND equipment_id = 27);
CALL sp_return_equipment(@item_compactor, NULL, 'GOOD', 0, NULL, 4, @ret1);
-- result: late_days 0, machines_still_out 1, booking still ACTIVE

-- Trying to return the same machine twice:
-- EXPECTED ERROR 1644: This machine has already been returned (duplicate return refused)
CALL sp_return_equipment(@item_compactor, NULL, 'GOOD', 0, NULL, 4, @ret_dup);

-- ---------------------------------------------------------------------
-- DEMO 10. LATE RETURN: the JCB comes back on 29-Nov (due 27-Nov)
-- late fee = 2 days x 5,500 x 1.5 = Rs 16,500
-- ---------------------------------------------------------------------
CALL sp_set_business_date('2026-11-29');
SELECT * FROM vw_overdue_rentals WHERE booking_id = @bk;                -- 2 days overdue, Rs 16,500 accrued

SET @item_jcb = (SELECT booking_item_id FROM booking_items WHERE booking_id = @bk AND equipment_id = 7);
CALL sp_return_equipment(@item_jcb, NULL, 'GOOD', 0, NULL, 5, @ret2);
-- result: late_charge 16500, booking_status_now COMPLETED (set by trigger)

-- Customer pays the remaining rental; the late fee is taken from the deposit
CALL sp_record_payment(@bk, 22000, 'UPI', 'BALANCE', CONCAT('UPI-DEMO-BAL-', @bk), @pay2);
CALL sp_settle_deposit(@bk);                 -- retain 16,500, refund 18,500 -> PARTIALLY_REFUNDED

SELECT booking_id, booking_status, rental_charge, late_charges, total_charges,
       payments_received, deposit_retained, balance_due, deposit_status
FROM vw_booking_financial_summary WHERE booking_id = @bk;               -- balance_due 0.00

-- Audit trail written automatically by triggers
SELECT * FROM booking_status_log WHERE booking_id = @bk ORDER BY log_id;

-- ---------------------------------------------------------------------
-- DEMO 11 (part B). Maintenance cannot clash with a booking
-- CER-EXC-006 (unit 29) is booked 1-15 Dec by booking 22.
-- EXPECTED ERROR 1644: Cannot schedule maintenance for CER-EXC-006: BOOKING_CONFLICT
-- ---------------------------------------------------------------------
CALL sp_schedule_maintenance(29, 'PREVENTIVE', '2026-12-05', '2026-12-06', 5, 'Mid-rental service', @m1);

-- The JCB just returned gets a service on 30-Nov instead (allowed)
CALL sp_schedule_maintenance(7, 'PREVENTIVE', '2026-11-30', '2026-11-30', 5, 'Post-rental service', @m2);

-- ---------------------------------------------------------------------
-- DEMO 14. Stored procedure with a CURSOR: overdue report as of 29-Nov
-- Expected: CER-EXC-003 13 days (HIGH, Rs 2,53,500), CER-RLR-002 6 days (MEDIUM, Rs 72,000)
-- ---------------------------------------------------------------------
CALL sp_overdue_report();
CALL sp_customer_statement(@cust);

-- ---------------------------------------------------------------------
-- DEMO 15. Transaction ROLLBACK
-- ---------------------------------------------------------------------
START TRANSACTION;
UPDATE equipment_models SET daily_rate = daily_rate * 2 WHERE model_id > 0;  -- a costly mistake! (WHERE on the key keeps Workbench safe-update mode happy)
SELECT model_name, daily_rate FROM equipment_models WHERE model_id IN (1, 4);  -- 30000, 11000
ROLLBACK;
SELECT model_name, daily_rate FROM equipment_models WHERE model_id IN (1, 4);  -- back to 15000, 5500

-- ---------------------------------------------------------------------
-- END OF DEMO. The business date is now 2026-11-29.
-- To start again from the original data: run sql/00_master_setup.sql.
-- ---------------------------------------------------------------------
SELECT fn_business_date() AS business_date_now;
