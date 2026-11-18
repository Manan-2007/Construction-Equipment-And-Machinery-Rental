-- =====================================================================
--  File   : 06_views.sql
--  Purpose: Reusable virtual tables for reporting (8 views)
--  Run    : after 02_seed_data.sql (views use only tables, no routines)
-- ---------------------------------------------------------------------
--  Design notes
--  * A view cannot take parameters, so "which machines are free between
--    date X and date Y?" is answered by the procedure sp_check_availability
--    (07_procedures_functions.sql), not by a view. Views here answer
--    questions about "today" = the business date in system_settings.
--  * Financial views aggregate every child table in its OWN derived table
--    before joining. Joining payments and booking_items directly would
--    multiply rows (fan-out) and inflate totals - a classic SQL mistake.
-- =====================================================================

USE construction_rental_db;

-- ---------------------------------------------------------------------
-- V1. vw_equipment_inventory
--     Every physical unit with its model, category, yard and its state
--     TODAY, derived from bookings + maintenance (not stored anywhere).
--     State priority: RETIRED > IN_MAINTENANCE > ON_RENT > RESERVED > AVAILABLE
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_equipment_inventory AS
SELECT
    u.equipment_id,
    u.asset_tag,
    c.category_name,
    m.manufacturer,
    m.model_name,
    d.depot_name,
    u.condition_rating,
    u.lifecycle_status,
    m.daily_rate        AS current_daily_rate,
    m.deposit_per_unit,
    CASE
        WHEN u.lifecycle_status = 'RETIRED' THEN 'RETIRED'
        WHEN EXISTS (SELECT 1 FROM maintenance_records mr
                     WHERE mr.equipment_id = u.equipment_id
                       AND mr.maintenance_status = 'IN_PROGRESS') THEN 'IN_MAINTENANCE'
        WHEN EXISTS (SELECT 1 FROM booking_items bi
                     JOIN bookings b ON b.booking_id = bi.booking_id
                     LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
                     WHERE bi.equipment_id = u.equipment_id
                       AND b.booking_status = 'ACTIVE'
                       AND r.return_id IS NULL) THEN 'ON_RENT'
        WHEN EXISTS (SELECT 1 FROM booking_items bi
                     JOIN bookings b ON b.booking_id = bi.booking_id
                     WHERE bi.equipment_id = u.equipment_id
                       AND b.booking_status = 'RESERVED'
                       AND s.bd BETWEEN b.start_date AND b.expected_return_date) THEN 'RESERVED'
        ELSE 'AVAILABLE'
    END AS current_state,
    (SELECT MIN(b.start_date)
       FROM booking_items bi
       JOIN bookings b ON b.booking_id = bi.booking_id
      WHERE bi.equipment_id = u.equipment_id
        AND b.booking_status = 'RESERVED'
        AND b.start_date > s.bd)                       AS next_reservation_start,
    (SELECT MIN(mr.scheduled_start)
       FROM maintenance_records mr
      WHERE mr.equipment_id = u.equipment_id
        AND mr.maintenance_status = 'SCHEDULED'
        AND mr.scheduled_start >= s.bd)                AS next_planned_maintenance
FROM equipment_units u
JOIN equipment_models     m ON m.model_id    = u.model_id
JOIN equipment_categories c ON c.category_id = m.category_id
JOIN depots               d ON d.depot_id    = u.depot_id
CROSS JOIN (SELECT COALESCE(business_date, CURDATE()) AS bd
            FROM system_settings WHERE settings_id = 1) s;

-- ---------------------------------------------------------------------
-- V2. vw_active_rentals
--     Units currently out with customers (booking ACTIVE, unit not returned).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_active_rentals AS
SELECT
    b.booking_id,
    bi.booking_item_id,
    COALESCE(cu.organisation_name, cu.full_name)   AS customer_name,
    cu.phone                                        AS customer_phone,
    u.asset_tag,
    CONCAT(m.manufacturer, ' ', m.model_name)       AS machine,
    b.site_address,
    b.start_date,
    b.expected_return_date,
    DATEDIFF(s.bd, b.start_date) + 1                AS days_out_so_far,
    DATEDIFF(b.expected_return_date, s.bd)          AS days_until_due,     -- negative = overdue
    CASE WHEN b.expected_return_date < s.bd THEN 'OVERDUE' ELSE 'ON_TIME' END AS rental_status
FROM bookings b
JOIN customers       cu ON cu.customer_id   = b.customer_id
JOIN booking_items   bi ON bi.booking_id    = b.booking_id
JOIN equipment_units u  ON u.equipment_id   = bi.equipment_id
JOIN equipment_models m ON m.model_id       = u.model_id
LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
CROSS JOIN (SELECT COALESCE(business_date, CURDATE()) AS bd
            FROM system_settings WHERE settings_id = 1) s
WHERE b.booking_status = 'ACTIVE'
  AND r.return_id IS NULL;

-- ---------------------------------------------------------------------
-- V3. vw_overdue_rentals
--     Units past their expected return date and still not returned,
--     with the late fee accrued so far (late days x rate x multiplier).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_overdue_rentals AS
SELECT
    b.booking_id,
    bi.booking_item_id,
    COALESCE(cu.organisation_name, cu.full_name)   AS customer_name,
    cu.phone                                        AS customer_phone,
    u.asset_tag,
    CONCAT(m.manufacturer, ' ', m.model_name)       AS machine,
    b.expected_return_date,
    DATEDIFF(s.bd, b.expected_return_date)          AS days_overdue,
    bi.agreed_daily_rate,
    ROUND(DATEDIFF(s.bd, b.expected_return_date) * bi.agreed_daily_rate * s.late_fee_multiplier, 2)
                                                    AS accrued_late_charge
FROM bookings b
JOIN customers       cu ON cu.customer_id = b.customer_id
JOIN booking_items   bi ON bi.booking_id  = b.booking_id
JOIN equipment_units u  ON u.equipment_id = bi.equipment_id
JOIN equipment_models m ON m.model_id     = u.model_id
LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
CROSS JOIN (SELECT COALESCE(business_date, CURDATE()) AS bd, late_fee_multiplier
            FROM system_settings WHERE settings_id = 1) s
WHERE b.booking_status = 'ACTIVE'
  AND r.return_id IS NULL
  AND b.expected_return_date < s.bd;

-- ---------------------------------------------------------------------
-- V4. vw_customer_rental_history
--     One row per machine per booking (line-item level, so no double
--     counting): what each customer rented, for how long, at what price
--     and how it came back.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_customer_rental_history AS
SELECT
    cu.customer_id,
    COALESCE(cu.organisation_name, cu.full_name)   AS customer_name,
    cu.customer_type,
    b.booking_id,
    b.booking_status,
    b.start_date,
    b.expected_return_date,
    u.asset_tag,
    c.category_name,
    CONCAT(m.manufacturer, ' ', m.model_name)       AS machine,
    bi.agreed_daily_rate,
    DATEDIFF(b.expected_return_date, b.start_date) + 1 AS rental_days,
    CASE WHEN b.booking_status = 'CANCELLED' THEN 0.00
         ELSE bi.agreed_daily_rate * (DATEDIFF(b.expected_return_date, b.start_date) + 1)
    END                                             AS line_rental_charge,
    r.return_date,
    r.return_condition,
    COALESCE(r.late_charge, 0.00)                   AS late_charge,
    COALESCE(r.damage_charge, 0.00)                 AS damage_charge
FROM customers cu
JOIN bookings             b  ON b.customer_id   = cu.customer_id
JOIN booking_items        bi ON bi.booking_id   = b.booking_id
JOIN equipment_units      u  ON u.equipment_id  = bi.equipment_id
JOIN equipment_models     m  ON m.model_id      = u.model_id
JOIN equipment_categories c  ON c.category_id   = m.category_id
LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id;

-- ---------------------------------------------------------------------
-- V5. vw_booking_financial_summary
--     One row per booking. Each child table is aggregated separately
--     (derived tables it, rc, pay) and then joined 1:1 to the booking.
--       total_charges  = rental + late fees + damage charges
--       amount_received = completed payments + deposit retained
--       balance_due    = total_charges - amount_received
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_booking_financial_summary AS
SELECT
    b.booking_id,
    COALESCE(cu.organisation_name, cu.full_name)          AS customer_name,
    b.booking_status,
    b.start_date,
    b.expected_return_date,
    DATEDIFF(b.expected_return_date, b.start_date) + 1    AS rental_days,
    it.unit_count,
    CASE WHEN b.booking_status = 'CANCELLED' THEN 0.00
         ELSE it.sum_daily_rate * (DATEDIFF(b.expected_return_date, b.start_date) + 1)
    END                                                   AS rental_charge,
    COALESCE(rc.late_charges, 0.00)                       AS late_charges,
    COALESCE(rc.damage_charges, 0.00)                     AS damage_charges,
    CASE WHEN b.booking_status = 'CANCELLED' THEN 0.00
         ELSE it.sum_daily_rate * (DATEDIFF(b.expected_return_date, b.start_date) + 1)
    END + COALESCE(rc.late_charges, 0.00) + COALESCE(rc.damage_charges, 0.00)
                                                          AS total_charges,
    COALESCE(pay.paid_amount, 0.00)                       AS payments_received,
    COALESCE(sd.retained_amount, 0.00)                    AS deposit_retained,
    COALESCE(pay.paid_amount, 0.00) + COALESCE(sd.retained_amount, 0.00)
                                                          AS amount_received,
    CASE WHEN b.booking_status = 'CANCELLED' THEN 0.00
         ELSE it.sum_daily_rate * (DATEDIFF(b.expected_return_date, b.start_date) + 1)
    END + COALESCE(rc.late_charges, 0.00) + COALESCE(rc.damage_charges, 0.00)
        - COALESCE(pay.paid_amount, 0.00) - COALESCE(sd.retained_amount, 0.00)
                                                          AS balance_due,
    sd.required_amount                                    AS deposit_required,
    sd.collected_amount                                   AS deposit_collected,
    sd.refunded_amount                                    AS deposit_refunded,
    COALESCE(sd.deposit_status, 'NOT_REQUIRED')           AS deposit_status
FROM bookings b
JOIN customers cu ON cu.customer_id = b.customer_id
JOIN (SELECT booking_id, COUNT(*) AS unit_count, SUM(agreed_daily_rate) AS sum_daily_rate
      FROM booking_items GROUP BY booking_id) it
     ON it.booking_id = b.booking_id
LEFT JOIN (SELECT bi.booking_id,
                  SUM(r.late_charge)   AS late_charges,
                  SUM(r.damage_charge) AS damage_charges
           FROM equipment_returns r
           JOIN booking_items bi ON bi.booking_item_id = r.booking_item_id
           GROUP BY bi.booking_id) rc
     ON rc.booking_id = b.booking_id
LEFT JOIN (SELECT booking_id, SUM(amount) AS paid_amount
           FROM payments WHERE payment_status = 'COMPLETED'
           GROUP BY booking_id) pay
     ON pay.booking_id = b.booking_id
LEFT JOIN security_deposits sd ON sd.booking_id = b.booking_id;

-- ---------------------------------------------------------------------
-- V6. vw_maintenance_summary
--     Per active unit: maintenance history, cost, and usage-based service
--     status. usage_days_since_service = rental days the unit has been out
--     since its last COMPLETED preventive service (or since purchase).
--       OVERDUE   usage >= service interval
--       DUE_SOON  usage >= interval - 5
--       SERVICE_SCHEDULED  due/overdue but a preventive job is already planned
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_maintenance_summary AS
SELECT
    x.equipment_id,
    x.asset_tag,
    x.machine,
    x.total_jobs,
    x.completed_jobs,
    x.total_maintenance_cost,
    x.last_preventive_service,
    x.usage_days_since_service,
    x.service_interval_rental_days,
    x.currently_in_maintenance,
    x.next_scheduled_job,
    CASE
        WHEN x.usage_days_since_service >= x.service_interval_rental_days - 5
             AND x.next_preventive_planned IS NOT NULL                       THEN 'SERVICE_SCHEDULED'
        WHEN x.usage_days_since_service >= x.service_interval_rental_days     THEN 'OVERDUE'
        WHEN x.usage_days_since_service >= x.service_interval_rental_days - 5 THEN 'DUE_SOON'
        ELSE 'OK'
    END AS service_status
FROM (
    SELECT
        u.equipment_id,
        u.asset_tag,
        CONCAT(m.manufacturer, ' ', m.model_name)              AS machine,
        m.service_interval_rental_days,
        COALESCE(mh.total_jobs, 0)                             AS total_jobs,
        COALESCE(mh.completed_jobs, 0)                         AS completed_jobs,
        COALESCE(mh.total_cost, 0.00)                          AS total_maintenance_cost,
        mh.last_preventive_service,
        mh.next_scheduled_job,
        mh.next_preventive_planned,
        CASE WHEN mh.in_progress_jobs > 0 THEN 'YES' ELSE 'NO' END AS currently_in_maintenance,
        COALESCE((
            SELECT SUM(GREATEST(0,
                     DATEDIFF(LEAST(COALESCE(r.return_date, s.bd), s.bd),
                              GREATEST(b.start_date,
                                       DATE_ADD(COALESCE(mh.last_preventive_service, u.purchase_date), INTERVAL 1 DAY))) + 1))
            FROM booking_items bi
            JOIN bookings b ON b.booking_id = bi.booking_id
            LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
            WHERE bi.equipment_id = u.equipment_id
              AND b.booking_status IN ('ACTIVE','COMPLETED')
        ), 0)                                                  AS usage_days_since_service
    FROM equipment_units u
    JOIN equipment_models m ON m.model_id = u.model_id
    CROSS JOIN (SELECT COALESCE(business_date, CURDATE()) AS bd
                FROM system_settings WHERE settings_id = 1) s
    LEFT JOIN (
        SELECT equipment_id,
               COUNT(*)                                                       AS total_jobs,
               SUM(maintenance_status = 'COMPLETED')                          AS completed_jobs,
               SUM(maintenance_status = 'IN_PROGRESS')                        AS in_progress_jobs,
               SUM(CASE WHEN maintenance_status = 'COMPLETED' THEN maintenance_cost ELSE 0 END) AS total_cost,
               MAX(CASE WHEN maintenance_type = 'PREVENTIVE' AND maintenance_status = 'COMPLETED'
                        THEN actual_end END)                                  AS last_preventive_service,
               MIN(CASE WHEN maintenance_status = 'SCHEDULED' THEN scheduled_start END) AS next_scheduled_job,
               MIN(CASE WHEN maintenance_status = 'SCHEDULED' AND maintenance_type = 'PREVENTIVE'
                        THEN scheduled_start END)                             AS next_preventive_planned
        FROM maintenance_records
        GROUP BY equipment_id
    ) mh ON mh.equipment_id = u.equipment_id
    WHERE u.lifecycle_status = 'ACTIVE'
) x;

-- ---------------------------------------------------------------------
-- V7. vw_equipment_revenue
--     Revenue earned by each physical unit from ACTIVE and COMPLETED
--     bookings (reserved = not yet earned, cancelled = no revenue),
--     compared with what was spent maintaining it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_equipment_revenue AS
SELECT
    u.equipment_id,
    u.asset_tag,
    c.category_name,
    CONCAT(m.manufacturer, ' ', m.model_name)                 AS machine,
    u.lifecycle_status,
    COALESCE(rv.times_rented, 0)                              AS times_rented,
    COALESCE(rv.days_billed, 0)                               AS days_billed,
    COALESCE(rv.rental_revenue, 0.00)                         AS rental_revenue,
    COALESCE(rv.late_fees, 0.00)                              AS late_fees,
    COALESCE(rv.damage_recovered, 0.00)                       AS damage_recovered,
    COALESCE(rv.rental_revenue, 0) + COALESCE(rv.late_fees, 0) + COALESCE(rv.damage_recovered, 0)
                                                              AS total_revenue,
    COALESCE(mc.maintenance_cost, 0.00)                       AS maintenance_cost,
    COALESCE(rv.rental_revenue, 0) + COALESCE(rv.late_fees, 0) + COALESCE(rv.damage_recovered, 0)
        - COALESCE(mc.maintenance_cost, 0)                    AS net_contribution
FROM equipment_units u
JOIN equipment_models     m ON m.model_id    = u.model_id
JOIN equipment_categories c ON c.category_id = m.category_id
LEFT JOIN (
    SELECT bi.equipment_id,
           COUNT(*)                                                         AS times_rented,
           SUM(DATEDIFF(b.expected_return_date, b.start_date) + 1)          AS days_billed,
           SUM(bi.agreed_daily_rate * (DATEDIFF(b.expected_return_date, b.start_date) + 1)) AS rental_revenue,
           SUM(COALESCE(r.late_charge, 0))                                  AS late_fees,
           SUM(COALESCE(r.damage_charge, 0))                                AS damage_recovered
    FROM booking_items bi
    JOIN bookings b ON b.booking_id = bi.booking_id
    LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id   -- at most 1 per item: no fan-out
    WHERE b.booking_status IN ('ACTIVE','COMPLETED')
    GROUP BY bi.equipment_id
) rv ON rv.equipment_id = u.equipment_id
LEFT JOIN (
    SELECT equipment_id, SUM(maintenance_cost) AS maintenance_cost
    FROM maintenance_records
    WHERE maintenance_status = 'COMPLETED'
    GROUP BY equipment_id
) mc ON mc.equipment_id = u.equipment_id;

-- ---------------------------------------------------------------------
-- V8. vw_pending_deposit_refunds
--     Deposits still HELD although the rental is over. Shows how much
--     should be retained (to clear unpaid charges) and how much refunded.
--     Built on top of V5 (a view can query another view).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_pending_deposit_refunds AS
SELECT
    f.booking_id,
    f.customer_name,
    f.booking_status,
    f.expected_return_date,
    f.deposit_collected,
    f.balance_due                                              AS unpaid_charges,
    LEAST(f.deposit_collected, GREATEST(f.balance_due, 0))     AS amount_to_retain,
    f.deposit_collected - LEAST(f.deposit_collected, GREATEST(f.balance_due, 0)) AS amount_to_refund
FROM vw_booking_financial_summary f
WHERE f.deposit_status = 'HELD'
  AND f.booking_status IN ('COMPLETED','CANCELLED');

-- List the views that now exist
SELECT table_name AS view_name
FROM information_schema.views
WHERE table_schema = 'construction_rental_db'
ORDER BY table_name;
