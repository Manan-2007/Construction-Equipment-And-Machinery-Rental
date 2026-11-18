-- =====================================================================
--  File   : 05_advanced_queries.sql
--  Purpose: The business questions the rental company asks every day.
--           Parameters are passed with user variables (SET @x = ...) so
--           each query can be re-run with different values.
--  Read-only: this file never changes data.
--  Date convention: "today" = business date in system_settings (2026-11-20);
--           rental periods are INCLUSIVE; overlap test = s1 <= e2 AND s2 <= e1.
-- =====================================================================

USE construction_rental_db;

SET @today = (SELECT COALESCE(business_date, CURDATE()) FROM system_settings WHERE settings_id = 1);
SELECT @today AS business_date;

-- ---------------------------------------------------------------------
-- B1. Display all equipment with its state today
-- Expected: 32 rows. 8 ON_RENT, 2 IN_MAINTENANCE, 1 RESERVED (pickup today),
--           1 RETIRED, 20 AVAILABLE.
-- Concept : querying a VIEW (vw_equipment_inventory) like a table.
-- ---------------------------------------------------------------------
SELECT asset_tag, category_name, manufacturer, model_name, depot_name,
       current_state, next_reservation_start, next_planned_maintenance
FROM vw_equipment_inventory
ORDER BY category_name, asset_tag;

-- ---------------------------------------------------------------------
-- B2. Equipment of one category, with counts by state
-- Expected (Excavators): 6 units; summary 3 AVAILABLE, 2 ON_RENT, 1 IN_MAINTENANCE.
-- Concept : parameter via user variable; GROUP BY ... WITH ROLLUP gives a grand total.
-- ---------------------------------------------------------------------
SET @category = 'Excavators';

SELECT asset_tag, manufacturer, model_name, current_state
FROM vw_equipment_inventory
WHERE category_name = @category;

SELECT COALESCE(current_state, '** TOTAL **') AS state, COUNT(*) AS units
FROM vw_equipment_inventory
WHERE category_name = @category
GROUP BY current_state WITH ROLLUP;

-- ---------------------------------------------------------------------
-- B3. Equipment available for EVERY day of a requested period (pure SQL)
-- Expected (2026-11-24 .. 2026-11-28): 17 units. Busy units are excluded, e.g.
--           CER-CRN-002 (inspection on 24-Nov), CER-BHL-004 (booked 25-28 Nov),
--           CER-EXC-003 (overdue - blocked until it comes back),
--           CER-CRN-003 (maintenance till 24-Nov).
-- Concept : NOT EXISTS with the interval-overlap condition.
--           A unit is free if no live booking item and no maintenance job
--           overlaps [@from, @to]. The stored procedure sp_check_availability
--           does the same through fn_unit_conflict (views cannot take parameters).
-- ---------------------------------------------------------------------
SET @from = '2026-11-24', @to = '2026-11-28';

SELECT u.equipment_id, u.asset_tag, m.manufacturer, m.model_name, m.daily_rate,
       m.daily_rate * (DATEDIFF(@to, @from) + 1) AS estimated_rental
FROM equipment_units u
JOIN equipment_models m ON m.model_id = u.model_id
WHERE u.lifecycle_status = 'ACTIVE'
  AND NOT EXISTS (                                   -- no overlapping booking
        SELECT 1
        FROM booking_items bi
        JOIN bookings b ON b.booking_id = bi.booking_id
        LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
        WHERE bi.equipment_id = u.equipment_id
          AND b.booking_status IN ('RESERVED','ACTIVE','COMPLETED')
          AND b.start_date <= @to
          AND (CASE WHEN r.return_id IS NOT NULL THEN r.return_date
                    WHEN b.booking_status = 'ACTIVE' AND b.expected_return_date < @today THEN '9999-12-31'
                    ELSE b.expected_return_date END) >= @from)
  AND NOT EXISTS (                                   -- no overlapping maintenance
        SELECT 1
        FROM maintenance_records mr
        WHERE mr.equipment_id = u.equipment_id
          AND mr.maintenance_status IN ('SCHEDULED','IN_PROGRESS','COMPLETED')
          AND COALESCE(mr.actual_start, mr.scheduled_start) <= @to
          AND (CASE mr.maintenance_status
                    WHEN 'COMPLETED' THEN mr.actual_end
                    WHEN 'IN_PROGRESS' THEN IF(mr.scheduled_end < @today, '9999-12-31', mr.scheduled_end)
                    ELSE mr.scheduled_end END) >= @from)
ORDER BY m.daily_rate DESC;

-- ---------------------------------------------------------------------
-- B4. Machines currently on rent
-- Expected: 8 rows; CER-EXC-003 (booking 18) is OVERDUE (days_until_due = -4), the rest ON_TIME.
-- Concept : view vw_active_rentals (booking ACTIVE and unit not returned).
-- ---------------------------------------------------------------------
SELECT booking_id, customer_name, asset_tag, machine, start_date, expected_return_date,
       days_out_so_far, days_until_due, rental_status
FROM vw_active_rentals
ORDER BY expected_return_date;

-- ---------------------------------------------------------------------
-- B5. Machines in the workshop right now
-- Expected: 2 rows - CER-CRN-003 (boom cylinder repair) and CER-EXC-005 (annual service).
-- Concept : INNER JOIN + filter on status; LEFT JOIN for optional technician.
-- ---------------------------------------------------------------------
SELECT u.asset_tag, CONCAT(m.manufacturer, ' ', m.model_name) AS machine,
       mr.maintenance_type, mr.actual_start, mr.scheduled_end AS expected_back,
       COALESCE(s.full_name, 'External workshop') AS technician, mr.description
FROM maintenance_records mr
JOIN equipment_units  u ON u.equipment_id = mr.equipment_id
JOIN equipment_models m ON m.model_id     = u.model_id
LEFT JOIN staff       s ON s.staff_id     = mr.technician_staff_id
WHERE mr.maintenance_status = 'IN_PROGRESS';

-- ---------------------------------------------------------------------
-- B6. All bookings of one customer
-- Expected (customer 1, Gill Infrastructure): 3 bookings - B2, B7 (completed), B17 (active).
-- ---------------------------------------------------------------------
SET @customer_id = 1;

SELECT b.booking_id, b.booking_date, b.start_date, b.expected_return_date, b.booking_status,
       f.unit_count, f.total_charges, f.balance_due
FROM bookings b
JOIN vw_booking_financial_summary f ON f.booking_id = b.booking_id
WHERE b.customer_id = @customer_id
ORDER BY b.start_date;

-- ---------------------------------------------------------------------
-- B7. Bookings that are "live" at any time inside a date window
-- Expected (1-30 Nov 2026, cancellations excluded): 7 bookings - B17, B18, B19, B20, B21,
--           B23, B26. B22/B24 start in December; B25 is cancelled.
-- Concept : interval OVERLAP test (start <= window_end AND end >= window_start),
--           which is different from "starts inside the window".
-- ---------------------------------------------------------------------
SET @w_from = '2026-11-01', @w_to = '2026-11-30';

SELECT booking_id, customer_id, start_date, expected_return_date, booking_status
FROM bookings
WHERE start_date <= @w_to
  AND expected_return_date >= @w_from
  AND booking_status <> 'CANCELLED'
ORDER BY start_date;

-- ---------------------------------------------------------------------
-- B8. Overdue rentals with the late fee accrued so far
-- Expected: 1 row - booking 18, CER-EXC-003, 4 days overdue, accrued Rs 78,000
--           (4 x 13,000 x 1.5).
-- Concept : date arithmetic, LEFT JOIN anti-join, join to settings table.
-- ---------------------------------------------------------------------
SELECT b.booking_id,
       COALESCE(c.organisation_name, c.full_name)                     AS customer,
       c.phone,
       u.asset_tag,
       b.expected_return_date,
       DATEDIFF(@today, b.expected_return_date)                       AS days_overdue,
       ROUND(DATEDIFF(@today, b.expected_return_date) * bi.agreed_daily_rate * s.late_fee_multiplier, 2) AS accrued_late_fee
FROM bookings b
JOIN customers c        ON c.customer_id  = b.customer_id
JOIN booking_items bi   ON bi.booking_id  = b.booking_id
JOIN equipment_units u  ON u.equipment_id = bi.equipment_id
LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
CROSS JOIN system_settings s
WHERE b.booking_status = 'ACTIVE'
  AND r.return_id IS NULL
  AND b.expected_return_date < @today;

-- ---------------------------------------------------------------------
-- B9. Rental bill for one booking, line by line with a total row
-- Expected (booking 17): 3 lines (14,000 + 5,500 + 7,500) x 20 days, total Rs 5,40,000.
-- Concept : GROUP BY ... WITH ROLLUP produces a subtotal/grand-total row (NULL key).
-- ---------------------------------------------------------------------
SET @booking_id = 17;

SELECT COALESCE(u.asset_tag, '** BOOKING TOTAL **')                     AS machine,
       SUM(bi.agreed_daily_rate)                                         AS daily_rate,
       MAX(DATEDIFF(b.expected_return_date, b.start_date) + 1)           AS days,
       SUM(bi.agreed_daily_rate * (DATEDIFF(b.expected_return_date, b.start_date) + 1)) AS line_total
FROM booking_items bi
JOIN bookings b        ON b.booking_id   = bi.booking_id
JOIN equipment_units u ON u.equipment_id = bi.equipment_id
WHERE bi.booking_id = @booking_id
GROUP BY u.asset_tag WITH ROLLUP;

SELECT fn_booking_rental_charge(@booking_id) AS rental_charge_via_function;   -- same total, via stored function

-- ---------------------------------------------------------------------
-- B10. Rental income for a date range - two accounting views
-- Expected (Oct-Nov 2026): cash received Rs 6,66,800 from 10 completed payments;
--           rental value of the 7 ACTIVE/COMPLETED bookings starting in the range Rs 20,48,800.
-- Concept : SUM with date filters; cash basis vs accrual basis.
-- ---------------------------------------------------------------------
SET @r_from = '2026-10-01', @r_to = '2026-11-30';

SELECT 'Cash received (payments)' AS measure, COUNT(*) AS records, SUM(amount) AS amount
FROM payments
WHERE payment_status = 'COMPLETED' AND payment_date BETWEEN @r_from AND @r_to
UNION ALL
SELECT 'Rental value of bookings started', COUNT(*), SUM(rental_charge)
FROM vw_booking_financial_summary
WHERE booking_status IN ('ACTIVE','COMPLETED') AND start_date BETWEEN @r_from AND @r_to;

-- ---------------------------------------------------------------------
-- B11. Most frequently rented machine models
-- Expected: CAT 320, JCB 3DX Super and Tata Signa tipper tie at 5 rentals each,
--           then Kirloskar 62.5 kVA (4) and ACE 14XW (3).
-- Concept : JOIN + GROUP BY + COUNT + ORDER BY + LIMIT.
-- ---------------------------------------------------------------------
SELECT CONCAT(m.manufacturer, ' ', m.model_name) AS model,
       COUNT(*)                                  AS times_rented,
       COUNT(DISTINCT bi.equipment_id)           AS different_units_used
FROM booking_items bi
JOIN bookings b         ON b.booking_id   = bi.booking_id
JOIN equipment_units u  ON u.equipment_id = bi.equipment_id
JOIN equipment_models m ON m.model_id     = u.model_id
WHERE b.booking_status <> 'CANCELLED'
GROUP BY m.model_id, m.manufacturer, m.model_name
ORDER BY times_rented DESC, model
LIMIT 5;

-- ---------------------------------------------------------------------
-- B12. Highest-earning individual machines
-- Expected: CER-DOZ-001 (BEML dozer) first with Rs 7,70,000.
-- Concept : view vw_equipment_revenue (pre-aggregated, no fan-out).
-- ---------------------------------------------------------------------
SELECT asset_tag, machine, times_rented, days_billed, total_revenue, maintenance_cost, net_contribution
FROM vw_equipment_revenue
ORDER BY total_revenue DESC
LIMIT 5;

-- ---------------------------------------------------------------------
-- B13. Customers with the most completed bookings
-- Expected: Gill Infrastructure (2), Sandhu Earthmovers (2), Sharma Builders (2) at the top.
-- ---------------------------------------------------------------------
SELECT COALESCE(c.organisation_name, c.full_name) AS customer,
       COUNT(*)                                   AS completed_bookings
FROM bookings b
JOIN customers c ON c.customer_id = b.customer_id
WHERE b.booking_status = 'COMPLETED'
GROUP BY c.customer_id, customer
ORDER BY completed_bookings DESC, customer
LIMIT 5;

-- ---------------------------------------------------------------------
-- B14. Deposits waiting to be refunded
-- Expected: 2 rows - B15 refund Rs 70,000; B16 retain Rs 20,000 (unpaid) and refund Rs 15,000.
-- ---------------------------------------------------------------------
SELECT * FROM vw_pending_deposit_refunds;

-- ---------------------------------------------------------------------
-- B15. Maintenance spending by type and month
-- Expected: CORRECTIVE costs most (Rs 89,500 over 3 jobs); grand total Rs 1,59,000.
-- Concept : GROUP BY two columns + WITH ROLLUP; DATE_FORMAT for the month.
-- ---------------------------------------------------------------------
SELECT COALESCE(maintenance_type, '** ALL TYPES **') AS maintenance_type,
       COUNT(*)                                      AS jobs,
       SUM(maintenance_cost)                         AS total_cost
FROM maintenance_records
WHERE maintenance_status = 'COMPLETED'
GROUP BY maintenance_type WITH ROLLUP;

SELECT DATE_FORMAT(actual_end, '%Y-%m') AS month, SUM(maintenance_cost) AS cost
FROM maintenance_records
WHERE maintenance_status = 'COMPLETED'
GROUP BY DATE_FORMAT(actual_end, '%Y-%m')
ORDER BY month;

-- ---------------------------------------------------------------------
-- B16. Equipment that has never been rented (active fleet only)
-- Expected: 5 rows - CER-EXC-005, CER-CRN-003, CER-FRK-002, CER-CMP-003, CER-GEN-005.
-- ---------------------------------------------------------------------
SELECT u.asset_tag, CONCAT(m.manufacturer, ' ', m.model_name) AS machine, u.purchase_date
FROM equipment_units u
JOIN equipment_models m ON m.model_id = u.model_id
WHERE u.lifecycle_status = 'ACTIVE'
  AND NOT EXISTS (SELECT 1 FROM booking_items bi WHERE bi.equipment_id = u.equipment_id);

-- ---------------------------------------------------------------------
-- B17. Customers who have never booked
-- Expected: 2 rows - Bajwa Agro Farms, Arjun Verma.
-- ---------------------------------------------------------------------
SELECT c.customer_id, COALESCE(c.organisation_name, c.full_name) AS customer, c.phone, c.registration_date
FROM customers c
LEFT JOIN bookings b ON b.customer_id = c.customer_id
WHERE b.booking_id IS NULL;

-- ---------------------------------------------------------------------
-- B18. Equipment due for preventive maintenance (usage-based)
-- Expected: CER-EXC-004 OVERDUE (33/30 days), CER-CRN-002 OVERDUE (30/30),
--           CER-DMP-001 SERVICE_SCHEDULED (40/30, job planned 1-Dec),
--           CER-GEN-001 DUE_SOON (12/15).
-- ---------------------------------------------------------------------
SELECT asset_tag, machine, last_preventive_service, usage_days_since_service,
       service_interval_rental_days, next_scheduled_job, service_status
FROM vw_maintenance_summary
WHERE service_status <> 'OK'
ORDER BY usage_days_since_service DESC;

-- ---------------------------------------------------------------------
-- B19. Completed rentals that were returned late
-- Expected: 2 rows - booking 4 (JCB, 3 days, Rs 24,750) and booking 10 (PC200, 3 days, Rs 58,500).
-- ---------------------------------------------------------------------
SELECT b.booking_id,
       COALESCE(c.organisation_name, c.full_name)       AS customer,
       u.asset_tag,
       b.expected_return_date,
       r.return_date,
       DATEDIFF(r.return_date, b.expected_return_date)  AS days_late,
       r.late_charge
FROM equipment_returns r
JOIN booking_items bi   ON bi.booking_item_id = r.booking_item_id
JOIN bookings b         ON b.booking_id       = bi.booking_id
JOIN customers c        ON c.customer_id      = b.customer_id
JOIN equipment_units u  ON u.equipment_id     = bi.equipment_id
WHERE b.booking_status = 'COMPLETED'
  AND r.late_charge > 0
ORDER BY r.late_charge DESC;

-- ---------------------------------------------------------------------
-- B20. Detailed rental history of one customer
-- Expected (customer 5, Shivalik Constructions): 3 lines - crane (B5, minor damage
--           Rs 12,000), excavator still out (B18), forklift returned (B18).
-- ---------------------------------------------------------------------
SET @customer_id = 5;

SELECT booking_id, booking_status, start_date, expected_return_date, asset_tag, machine,
       agreed_daily_rate, rental_days, line_rental_charge, return_date, return_condition,
       late_charge, damage_charge
FROM vw_customer_rental_history
WHERE customer_id = @customer_id
ORDER BY start_date, asset_tag;

-- =====================================================================
-- Additional analytical queries
-- =====================================================================

-- ---------------------------------------------------------------------
-- B21. Monthly booking value trend for 2026
-- Expected: 11 rows (Jan-Nov); November (Rs 17,76,000) and July (Rs 7,42,500) are the biggest.
-- ---------------------------------------------------------------------
SELECT DATE_FORMAT(start_date, '%Y-%m') AS month,
       COUNT(*)                         AS bookings,
       SUM(total_charges)               AS booking_value
FROM vw_booking_financial_summary
WHERE booking_status IN ('ACTIVE','COMPLETED') AND YEAR(start_date) = 2026
GROUP BY DATE_FORMAT(start_date, '%Y-%m')
ORDER BY month;

-- ---------------------------------------------------------------------
-- B22. Fleet utilisation from 1 to 20 November 2026
-- Purpose : % of available machine-days that were actually on rent.
-- Expected: 11 rows; Dump Trucks (37.5 %) and Forklifts (35.0 %) are the busiest;
--           cranes, mixers, generators and the wheel loader were idle (0 %).
-- Concept : interval INTERSECTION length = LEAST(ends) - GREATEST(starts) + 1,
--           combined with GROUP BY and a derived table.
-- ---------------------------------------------------------------------
SET @u_from = '2026-11-01', @u_to = @today;

SELECT c.category_name,
       COUNT(DISTINCT u.equipment_id)                                         AS units,
       COUNT(DISTINCT u.equipment_id) * (DATEDIFF(@u_to, @u_from) + 1)        AS available_days,
       COALESCE(SUM(x.rented_days), 0)                                        AS rented_days,
       ROUND(100 * COALESCE(SUM(x.rented_days), 0)
             / (COUNT(DISTINCT u.equipment_id) * (DATEDIFF(@u_to, @u_from) + 1)), 1) AS utilisation_pct
FROM equipment_units u
JOIN equipment_models m     ON m.model_id    = u.model_id
JOIN equipment_categories c ON c.category_id = m.category_id
LEFT JOIN (
    SELECT bi.equipment_id,
           GREATEST(0, DATEDIFF(LEAST(COALESCE(r.return_date, @u_to), @u_to),
                                GREATEST(b.start_date, @u_from)) + 1) AS rented_days
    FROM booking_items bi
    JOIN bookings b ON b.booking_id = bi.booking_id
    LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
    WHERE b.booking_status IN ('ACTIVE','COMPLETED')
      AND b.start_date <= @u_to
      AND COALESCE(r.return_date, @u_to) >= @u_from
) x ON x.equipment_id = u.equipment_id
WHERE u.lifecycle_status = 'ACTIVE'
GROUP BY c.category_id, c.category_name
ORDER BY utilisation_pct DESC;

-- ---------------------------------------------------------------------
-- B23. Outstanding receivables (money customers still owe)
-- Expected: 9 customers; PWD Mohali (Rs 9,30,000, government bill pending) is the largest.
-- ---------------------------------------------------------------------
SELECT COALESCE(c.organisation_name, c.full_name) AS customer,
       COUNT(*)                                   AS open_bookings,
       SUM(f.balance_due)                         AS amount_owed
FROM vw_booking_financial_summary f
JOIN bookings  b ON b.booking_id  = f.booking_id
JOIN customers c ON c.customer_id = b.customer_id
WHERE f.balance_due > 0
GROUP BY c.customer_id, customer
ORDER BY amount_owed DESC;

-- ---------------------------------------------------------------------
-- B24. Fleet value and size per yard
-- Expected: 3 rows - Mohali 13 units, Gurugram 10 (1 retired), Ludhiana 9 (but the
--           highest fleet value, Rs 5.17 crore, because the dozer and two excavators are there).
-- ---------------------------------------------------------------------
SELECT d.depot_name,
       COUNT(*)                                      AS units,
       SUM(u.lifecycle_status = 'ACTIVE')            AS active_units,
       SUM(u.purchase_cost)                          AS fleet_value,
       ROUND(AVG(YEAR(@today) - u.manufacture_year), 1) AS avg_age_years
FROM equipment_units u
JOIN depots d ON d.depot_id = u.depot_id
GROUP BY d.depot_id, d.depot_name
ORDER BY units DESC;

-- ---------------------------------------------------------------------
-- B25. (Beyond syllabus, optional) Rank machines by revenue inside each category
-- Concept : window function RANK() OVER (PARTITION BY ... ORDER BY ...), MySQL 8.0+.
--           Shown only as an extension; every report above uses syllabus SQL.
-- ---------------------------------------------------------------------
SELECT category_name, asset_tag, total_revenue,
       RANK() OVER (PARTITION BY category_name ORDER BY total_revenue DESC) AS rank_in_category
FROM vw_equipment_revenue
WHERE total_revenue > 0
ORDER BY category_name, rank_in_category;
