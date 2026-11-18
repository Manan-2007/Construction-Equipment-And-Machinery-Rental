-- =====================================================================
--  File   : 11_indexing_and_explain.sql
--  Purpose: Show which indexes exist, why, and how the optimizer uses
--           them (EXPLAIN). Schema is left unchanged: the one index
--           created for the before/after demo is dropped again.
--  Note   : our tables are small (tens of rows). For tiny tables MySQL may
--           legitimately prefer a full scan because reading one page is
--           cheaper than using an index - EXPLAIN output must be read with
--           that in mind. No timing numbers are claimed.
--  Syllabus: Lectures 33-35 (indexing, B-tree), Lab 8 (indexes)
-- =====================================================================

USE construction_rental_db;

-- ---------------------------------------------------------------------
-- I1. Every index in the schema
--     PRIMARY = clustered index (InnoDB stores the row inside the PK B-tree)
--     others  = secondary indexes (store key + primary key)
--     FK columns are indexed automatically by InnoDB if no index exists.
-- ---------------------------------------------------------------------
SELECT table_name, index_name, non_unique,
       GROUP_CONCAT(column_name ORDER BY seq_in_index) AS columns_in_index
FROM information_schema.statistics
WHERE table_schema = 'construction_rental_db'
GROUP BY table_name, index_name, non_unique
ORDER BY table_name, index_name;

SHOW INDEX FROM booking_items;

-- ---------------------------------------------------------------------
-- I2. The most frequent query in the system: "is unit X busy?"
--     (fn_unit_conflict runs it for every availability check / booking)
--     Expected: access type 'ref' on idx_items_equipment_booking for
--     booking_items, then eq_ref on PRIMARY for bookings.
-- ---------------------------------------------------------------------
EXPLAIN
SELECT COUNT(*)
FROM booking_items bi
JOIN bookings b ON b.booking_id = bi.booking_id
LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
WHERE bi.equipment_id = 7
  AND b.booking_status IN ('RESERVED','ACTIVE','COMPLETED')
  AND b.start_date <= '2026-11-27'
  AND COALESCE(r.return_date, b.expected_return_date) >= '2026-11-23';

-- ---------------------------------------------------------------------
-- I3. Lookup by primary key -> type 'const' (at most one row)
-- ---------------------------------------------------------------------
EXPLAIN SELECT * FROM bookings WHERE booking_id = 17;

-- ---------------------------------------------------------------------
-- I4. Lookup by a UNIQUE secondary key -> type 'const'
-- ---------------------------------------------------------------------
EXPLAIN SELECT * FROM equipment_units WHERE serial_number = 'CAT0320GKTW10231';

-- ---------------------------------------------------------------------
-- I5. Status filter on bookings uses the composite index
--     idx_bookings_status_period (booking_status, start_date, expected_return_date)
--     Leftmost-prefix rule: the index helps when the query filters on
--     booking_status (optionally + start_date), not on start_date alone.
-- ---------------------------------------------------------------------
EXPLAIN SELECT booking_id FROM bookings
WHERE booking_status = 'ACTIVE' AND start_date <= '2026-11-20';

EXPLAIN SELECT booking_id FROM bookings
WHERE start_date <= '2026-11-20';            -- leftmost column missing: no seek; MySQL reads the WHOLE index
                                             -- (type 'index') only because it happens to cover the query

-- ---------------------------------------------------------------------
-- I6. Date-range report on payments uses idx_payments_date (type 'range')
--     ... but wrapping the column in a function prevents index use.
-- ---------------------------------------------------------------------
EXPLAIN SELECT SUM(amount) FROM payments
WHERE payment_date BETWEEN '2026-10-01' AND '2026-11-30';

EXPLAIN SELECT SUM(amount) FROM payments
WHERE YEAR(payment_date) = 2026 AND MONTH(payment_date) >= 10;   -- function on column -> full scan (type ALL)

-- ---------------------------------------------------------------------
-- I7. LIKE with a leading wildcard cannot use a B-tree index;
--     a prefix pattern can.
-- ---------------------------------------------------------------------
EXPLAIN SELECT customer_id FROM customers WHERE full_name LIKE 'Ra%';     -- can use idx_customers_name (range)
EXPLAIN SELECT customer_id FROM customers WHERE full_name LIKE '%Singh%'; -- no seek: full scan of the index (type 'index')

-- ---------------------------------------------------------------------
-- I8. Before / after: adding an index for a new frequent filter
--     Scenario: staff often filter customers by city.
-- ---------------------------------------------------------------------
EXPLAIN SELECT customer_id, full_name FROM customers WHERE city = 'Mohali';   -- before: type ALL

CREATE INDEX idx_customers_city ON customers (city);
EXPLAIN SELECT customer_id, full_name FROM customers WHERE city = 'Mohali';   -- after: type ref, key idx_customers_city

DROP INDEX idx_customers_city ON customers;   -- keep the official schema unchanged

-- ---------------------------------------------------------------------
-- I9. Tree-style plan with actual row counts (MySQL 8.0.18+)
--     EXPLAIN ANALYZE really executes the query and reports measured rows.
-- ---------------------------------------------------------------------
EXPLAIN ANALYZE
SELECT c.category_name, COUNT(*) AS rentals
FROM booking_items bi
JOIN equipment_units u      ON u.equipment_id = bi.equipment_id
JOIN equipment_models m     ON m.model_id     = u.model_id
JOIN equipment_categories c ON c.category_id  = m.category_id
GROUP BY c.category_name;
