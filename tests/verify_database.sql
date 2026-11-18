-- =====================================================================
--  File   : tests/verify_database.sql
--  Purpose: One-click health check of the installed database.
--           Read-only (uses only a session TEMPORARY table).
--           Does NOT need the test helpers. Run any time:
--           right after 00_master_setup.sql, after the demo, after tests.
--  Output : one row per check with PASS / FAIL, then a summary.
-- =====================================================================

USE construction_rental_db;

DROP TEMPORARY TABLE IF EXISTS tmp_verify;
CREATE TEMPORARY TABLE tmp_verify (
    check_no   INT AUTO_INCREMENT PRIMARY KEY,
    area       VARCHAR(30),
    check_name VARCHAR(120),
    expected   VARCHAR(60),
    actual     VARCHAR(60),
    result     VARCHAR(4)
);

-- ---------------------------------------------------------------------
-- 1. Schema objects
-- ---------------------------------------------------------------------
INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'schema', 'all 14 base tables exist', '14', COUNT(*), IF(COUNT(*) = 14, 'PASS', 'FAIL')
FROM information_schema.tables
WHERE table_schema = 'construction_rental_db' AND table_type = 'BASE TABLE'
  AND table_name IN ('system_settings','depots','staff','customers','equipment_categories','equipment_models',
                     'equipment_units','bookings','booking_items','security_deposits','payments',
                     'equipment_returns','maintenance_records','booking_status_log');

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'schema', 'all tables use InnoDB', '0 non-InnoDB', COUNT(*), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM information_schema.tables
WHERE table_schema = 'construction_rental_db' AND table_type = 'BASE TABLE' AND engine <> 'InnoDB';

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'schema', 'foreign keys defined', '16', COUNT(*), IF(COUNT(*) = 16, 'PASS', 'FAIL')
FROM information_schema.referential_constraints
WHERE constraint_schema = 'construction_rental_db';

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'schema', 'named CHECK constraints defined', '34', COUNT(*), IF(COUNT(*) = 34, 'PASS', 'FAIL')
FROM information_schema.check_constraints
WHERE constraint_schema = 'construction_rental_db';

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'schema', 'views exist', '8', COUNT(*), IF(COUNT(*) = 8, 'PASS', 'FAIL')
FROM information_schema.views
WHERE table_schema = 'construction_rental_db'
  AND table_name IN ('vw_equipment_inventory','vw_active_rentals','vw_overdue_rentals','vw_customer_rental_history',
                     'vw_booking_financial_summary','vw_maintenance_summary','vw_equipment_revenue',
                     'vw_pending_deposit_refunds');

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'schema', 'stored functions exist', '7', COUNT(*), IF(COUNT(*) = 7, 'PASS', 'FAIL')
FROM information_schema.routines
WHERE routine_schema = 'construction_rental_db' AND routine_type = 'FUNCTION' AND routine_name LIKE 'fn\_%';

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'schema', 'stored procedures exist', '14', COUNT(*), IF(COUNT(*) = 14, 'PASS', 'FAIL')
FROM information_schema.routines
WHERE routine_schema = 'construction_rental_db' AND routine_type = 'PROCEDURE' AND routine_name LIKE 'sp\_%';

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'schema', 'triggers exist', '12', COUNT(*), IF(COUNT(*) = 12, 'PASS', 'FAIL')
FROM information_schema.triggers
WHERE trigger_schema = 'construction_rental_db';

-- ---------------------------------------------------------------------
-- 2. Seed data volume (lower bounds, so the check still passes after the demo)
-- ---------------------------------------------------------------------
INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'data', CONCAT('row count: ', t.tbl), CONCAT('>= ', t.min_rows), t.cnt, IF(t.cnt >= t.min_rows, 'PASS', 'FAIL')
FROM (
          SELECT 'customers' AS tbl, 15 AS min_rows, (SELECT COUNT(*) FROM customers) AS cnt
UNION ALL SELECT 'equipment_categories', 8,  (SELECT COUNT(*) FROM equipment_categories)
UNION ALL SELECT 'equipment_models',     12, (SELECT COUNT(*) FROM equipment_models)
UNION ALL SELECT 'equipment_units',      25, (SELECT COUNT(*) FROM equipment_units)
UNION ALL SELECT 'bookings',             20, (SELECT COUNT(*) FROM bookings)
UNION ALL SELECT 'booking_items',        30, (SELECT COUNT(*) FROM booking_items)
UNION ALL SELECT 'payments',             25, (SELECT COUNT(*) FROM payments)
UNION ALL SELECT 'security_deposits',    15, (SELECT COUNT(*) FROM security_deposits)
UNION ALL SELECT 'equipment_returns',    10, (SELECT COUNT(*) FROM equipment_returns)
UNION ALL SELECT 'maintenance_records',  10, (SELECT COUNT(*) FROM maintenance_records)
) t;

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'data', 'system_settings has exactly one row', '1', COUNT(*), IF(COUNT(*) = 1, 'PASS', 'FAIL')
FROM system_settings;

-- ---------------------------------------------------------------------
-- 3. Orphan records (should be impossible because of the FKs - verified anyway)
-- ---------------------------------------------------------------------
INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'orphans', o.what, '0', o.cnt, IF(o.cnt = 0, 'PASS', 'FAIL')
FROM (
          SELECT 'booking_items without booking' AS what,
                 (SELECT COUNT(*) FROM booking_items bi LEFT JOIN bookings b ON b.booking_id = bi.booking_id WHERE b.booking_id IS NULL) AS cnt
UNION ALL SELECT 'booking_items without equipment unit',
                 (SELECT COUNT(*) FROM booking_items bi LEFT JOIN equipment_units u ON u.equipment_id = bi.equipment_id WHERE u.equipment_id IS NULL)
UNION ALL SELECT 'bookings without customer',
                 (SELECT COUNT(*) FROM bookings b LEFT JOIN customers c ON c.customer_id = b.customer_id WHERE c.customer_id IS NULL)
UNION ALL SELECT 'payments without booking',
                 (SELECT COUNT(*) FROM payments p LEFT JOIN bookings b ON b.booking_id = p.booking_id WHERE b.booking_id IS NULL)
UNION ALL SELECT 'returns without booking item',
                 (SELECT COUNT(*) FROM equipment_returns r LEFT JOIN booking_items bi ON bi.booking_item_id = r.booking_item_id WHERE bi.booking_item_id IS NULL)
UNION ALL SELECT 'maintenance without equipment unit',
                 (SELECT COUNT(*) FROM maintenance_records m LEFT JOIN equipment_units u ON u.equipment_id = m.equipment_id WHERE u.equipment_id IS NULL)
UNION ALL SELECT 'bookings with no machines',
                 (SELECT COUNT(*) FROM bookings b WHERE NOT EXISTS (SELECT 1 FROM booking_items bi WHERE bi.booking_id = b.booking_id))
) o;

-- ---------------------------------------------------------------------
-- 4. No double booking / no maintenance clash
--    (CTE = WITH clause, MySQL 8.0+; used here because the same interval
--     list is needed twice in a self-join)
-- ---------------------------------------------------------------------
INSERT INTO tmp_verify (area, check_name, expected, actual, result)
WITH bd AS (SELECT COALESCE(business_date, CURDATE()) AS today FROM system_settings WHERE settings_id = 1),
iv AS (
    SELECT bi.booking_item_id, bi.equipment_id, b.start_date AS s,
           CASE WHEN r.return_id IS NOT NULL THEN r.return_date
                WHEN b.booking_status = 'ACTIVE' THEN GREATEST(b.expected_return_date, bd.today)
                ELSE b.expected_return_date END AS e
    FROM booking_items bi
    JOIN bookings b ON b.booking_id = bi.booking_id
    LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
    CROSS JOIN bd
    WHERE b.booking_status <> 'CANCELLED')
SELECT 'conflicts', 'overlapping bookings of the same unit', '0', COUNT(*), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM iv a JOIN iv b2
  ON a.equipment_id = b2.equipment_id AND a.booking_item_id < b2.booking_item_id
 AND a.s <= b2.e AND b2.s <= a.e;

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
WITH iv AS (
    SELECT bi.equipment_id, b.start_date AS s, COALESCE(r.return_date, b.expected_return_date) AS e
    FROM booking_items bi
    JOIN bookings b ON b.booking_id = bi.booking_id
    LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
    WHERE b.booking_status <> 'CANCELLED'),
mv AS (
    SELECT equipment_id, COALESCE(actual_start, scheduled_start) AS s,
           CASE WHEN maintenance_status = 'COMPLETED' THEN actual_end ELSE scheduled_end END AS e
    FROM maintenance_records WHERE maintenance_status <> 'CANCELLED')
SELECT 'conflicts', 'maintenance overlapping a rental of the same unit', '0', COUNT(*), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM iv JOIN mv ON iv.equipment_id = mv.equipment_id AND iv.s <= mv.e AND mv.s <= iv.e;

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
WITH mv AS (
    SELECT maintenance_id, equipment_id, COALESCE(actual_start, scheduled_start) AS s,
           CASE WHEN maintenance_status = 'COMPLETED' THEN actual_end ELSE scheduled_end END AS e
    FROM maintenance_records WHERE maintenance_status <> 'CANCELLED')
SELECT 'conflicts', 'overlapping maintenance jobs on the same unit', '0', COUNT(*), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM mv a JOIN mv b ON a.equipment_id = b.equipment_id AND a.maintenance_id < b.maintenance_id
 AND a.s <= b.e AND b.s <= a.e;

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'conflicts', 'retired units in live (RESERVED/ACTIVE) bookings', '0', COUNT(*), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM booking_items bi
JOIN bookings b ON b.booking_id = bi.booking_id
JOIN equipment_units u ON u.equipment_id = bi.equipment_id
WHERE u.lifecycle_status = 'RETIRED' AND b.booking_status IN ('RESERVED','ACTIVE');

-- ---------------------------------------------------------------------
-- 5. Lifecycle consistency
-- ---------------------------------------------------------------------
INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'lifecycle', 'COMPLETED bookings with a machine not returned', '0', COUNT(*), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM bookings b JOIN booking_items bi ON bi.booking_id = b.booking_id
LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
WHERE b.booking_status = 'COMPLETED' AND r.return_id IS NULL;

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'lifecycle', 'returns recorded for RESERVED or CANCELLED bookings', '0', COUNT(*), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM equipment_returns r JOIN booking_items bi ON bi.booking_item_id = r.booking_item_id
JOIN bookings b ON b.booking_id = bi.booking_id
WHERE b.booking_status IN ('RESERVED','CANCELLED');

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'lifecycle', 'ACTIVE bookings whose deposit is not HELD', '0', COUNT(*), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM bookings b JOIN security_deposits sd ON sd.booking_id = b.booking_id
WHERE b.booking_status = 'ACTIVE' AND sd.deposit_status <> 'HELD';

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'lifecycle', 'return dates before rental start', '0', COUNT(*), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM equipment_returns r JOIN booking_items bi ON bi.booking_item_id = r.booking_item_id
JOIN bookings b ON b.booking_id = bi.booking_id
WHERE r.return_date < b.start_date;

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'lifecycle', 'government bookings with a deposit row', '0', COUNT(*), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM bookings b JOIN customers c ON c.customer_id = b.customer_id
JOIN security_deposits sd ON sd.booking_id = b.booking_id
WHERE c.customer_type = 'GOVERNMENT';

-- ---------------------------------------------------------------------
-- 6. Financial invariants
-- ---------------------------------------------------------------------
INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'finance', 'bookings where received > charges (overpaid)', '0', COUNT(*), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM vw_booking_financial_summary WHERE amount_received > total_charges;

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'finance', 'deposits with refunded + retained > collected', '0', COUNT(*), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM security_deposits WHERE refunded_amount + retained_amount > collected_amount;

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'finance', 'late charges not matching the policy formula', '0', COUNT(*), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM equipment_returns r
JOIN booking_items bi ON bi.booking_item_id = r.booking_item_id
JOIN bookings b ON b.booking_id = bi.booking_id
WHERE r.late_charge <> ROUND(GREATEST(0, DATEDIFF(r.return_date, b.expected_return_date)) * bi.agreed_daily_rate * 1.50, 2);

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'finance', 'cancelled bookings with completed payments or charges', '0', COUNT(*), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM vw_booking_financial_summary
WHERE booking_status = 'CANCELLED' AND (payments_received <> 0 OR total_charges <> 0);

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'finance', 'view totals equal stored-function totals', '0 differences', COUNT(*), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM vw_booking_financial_summary f
WHERE f.total_charges <> fn_booking_total_charges(f.booking_id)
   OR f.amount_received <> fn_booking_amount_received(f.booking_id);

INSERT INTO tmp_verify (area, check_name, expected, actual, result)
SELECT 'finance', 'payments dated before their booking', '0', COUNT(*), IF(COUNT(*) = 0, 'PASS', 'FAIL')
FROM payments p JOIN bookings b ON b.booking_id = p.booking_id
WHERE p.payment_date < b.booking_date;

-- ---------------------------------------------------------------------
-- Report
-- ---------------------------------------------------------------------
SELECT area, check_name, expected, actual, result FROM tmp_verify ORDER BY check_no;

SELECT SUM(result = 'PASS') AS passed,
       SUM(result = 'FAIL') AS failed,
       COUNT(*)             AS total_checks,
       IF(SUM(result = 'FAIL') = 0, 'DATABASE OK', 'PROBLEMS FOUND - see FAIL rows') AS verdict
FROM tmp_verify;
