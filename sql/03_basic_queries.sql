-- =====================================================================
--  File   : 03_basic_queries.sql
--  Purpose: Basic SQL - SELECT, filtering, sorting, aggregate functions,
--           GROUP BY / HAVING, and DML (INSERT / UPDATE / DELETE)
--  Safe to re-run: all DML examples are inside a transaction that is
--           ROLLED BACK at the end, so demo data is never changed.
--  Business "today" for the seed data = 2026-11-20.
--  Syllabus: Lectures 13-19, Labs 4-6 (DDL/DML, SELECT, aggregates)
-- =====================================================================

USE construction_rental_db;

-- =====================================================================
-- PART A - SELECT, WHERE, ORDER BY, DISTINCT, LIMIT, LIKE, IN, BETWEEN, IS NULL
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q1. List all customers alphabetically
-- Purpose : Basic projection and sorting.
-- Expected: 18 rows, from 'Anil Kumar Mehta' to 'Vikas Yadav'.
-- Concept : SELECT, column list, ORDER BY ASC.   RA: pi_{id,name,type,city}(customers)
-- ---------------------------------------------------------------------
SELECT customer_id, full_name, organisation_name, customer_type, city
FROM customers
ORDER BY full_name ASC;

-- ---------------------------------------------------------------------
-- Q2. Active company customers located in Punjab
-- Purpose : Filter rows with several conditions.
-- Expected: 7 rows - Bajwa Agro, Dhillon Road, Gill Infrastructure, Saini Brothers,
--           Sandhu Earthmovers, Sharma Builders, Shivalik (Bhatia is excluded: inactive).
-- Concept : WHERE with AND.   RA: sigma_{type='COMPANY' AND state='Punjab' AND active}(customers)
-- ---------------------------------------------------------------------
SELECT customer_id, organisation_name, full_name AS contact_person, city
FROM customers
WHERE customer_type = 'COMPANY'
  AND state = 'Punjab'
  AND is_active = TRUE
ORDER BY organisation_name;

-- ---------------------------------------------------------------------
-- Q3. Equipment models sorted by category, then most expensive first
-- Purpose : Multi-column ORDER BY with mixed directions.
-- Expected: 17 rows; within Excavators: CAT 320 (15000), PC200-8 (13000), EX 200LC (12000).
-- Concept : ORDER BY col1 ASC, col2 DESC.
-- ---------------------------------------------------------------------
SELECT category_id, manufacturer, model_name, daily_rate, deposit_per_unit
FROM equipment_models
ORDER BY category_id ASC, daily_rate DESC;

-- ---------------------------------------------------------------------
-- Q4. Which cities do our customers come from?
-- Purpose : Remove duplicate values.
-- Expected: 13 rows - each city once, although Mohali, Ludhiana, Gurugram and
--           Chandigarh each have 2+ customers.
-- Concept : DISTINCT.
-- ---------------------------------------------------------------------
SELECT DISTINCT city, state
FROM customers
ORDER BY state, city;

-- ---------------------------------------------------------------------
-- Q5. Top 5 most expensive machine models per day
-- Purpose : Return only the first N rows of a sorted result.
-- Expected: BEML BD80 (16000), CAT 320 (15000), PC200-8 (13000), EX 200LC (12000), ACE 14XW (9000).
-- Concept : ORDER BY + LIMIT.
-- ---------------------------------------------------------------------
SELECT manufacturer, model_name, daily_rate
FROM equipment_models
ORDER BY daily_rate DESC
LIMIT 5;

-- ---------------------------------------------------------------------
-- Q6. Customers whose organisation name contains "Construction"
-- Purpose : Pattern matching.
-- Expected: 2 rows - Shivalik Constructions, Saini Brothers Construction.
-- Concept : LIKE with % wildcard ( _ matches exactly one character).
-- ---------------------------------------------------------------------
SELECT customer_id, organisation_name, city
FROM customers
WHERE organisation_name LIKE '%Construction%';

-- ---------------------------------------------------------------------
-- Q7. Machines kept at the Mohali or Gurugram yard
-- Purpose : Match a column against a list of values.
-- Expected: 23 rows (13 at Mohali, 10 at Gurugram).
-- Concept : IN (list) - shorter than several ORs.
-- ---------------------------------------------------------------------
SELECT equipment_id, asset_tag, depot_id, lifecycle_status
FROM equipment_units
WHERE depot_id IN (1, 3)
ORDER BY depot_id, asset_tag;

-- ---------------------------------------------------------------------
-- Q8. Bookings whose rental starts in October or November 2026
-- Purpose : Range filter on dates.
-- Expected: 11 bookings (B14-B21, B23, B25, B26). B22 and B24 start in December.
-- Concept : BETWEEN (inclusive on both ends).
-- ---------------------------------------------------------------------
SELECT booking_id, customer_id, start_date, expected_return_date, booking_status
FROM bookings
WHERE start_date BETWEEN '2026-10-01' AND '2026-11-30'
ORDER BY start_date;

-- ---------------------------------------------------------------------
-- Q9. Maintenance jobs done by an external workshop (no in-house technician)
-- Purpose : Find missing (unknown / not applicable) values.
-- Expected: 1 row - maintenance #4 on the retired JCB (CER-BHL-005 = unit 30).
-- Concept : IS NULL  (note: "= NULL" never matches anything).
-- ---------------------------------------------------------------------
SELECT maintenance_id, equipment_id, maintenance_type, description
FROM maintenance_records
WHERE technician_staff_id IS NULL;

-- ---------------------------------------------------------------------
-- Q10. Rental length of every booking (calculated column)
-- Purpose : Expressions and column aliases in SELECT.
-- Expected: 26 rows; e.g. B10 = 30 days, B14 = 2 days (dates are inclusive).
-- Concept : DATEDIFF, arithmetic expression, alias.
-- ---------------------------------------------------------------------
SELECT booking_id,
       start_date,
       expected_return_date,
       DATEDIFF(expected_return_date, start_date) + 1 AS rental_days
FROM bookings
ORDER BY rental_days DESC;

-- =====================================================================
-- PART B - AGGREGATE FUNCTIONS, GROUP BY, HAVING
-- =====================================================================

-- ---------------------------------------------------------------------
-- Q11. Fleet size
-- Purpose : Count rows and distinct values.
-- Expected: total_units = 32, active_units = 31, distinct_models = 17.
-- Concept : COUNT(*), COUNT(DISTINCT), SUM of a boolean condition.
-- ---------------------------------------------------------------------
SELECT COUNT(*)                         AS total_units,
       SUM(lifecycle_status = 'ACTIVE') AS active_units,
       COUNT(DISTINCT model_id)         AS distinct_models
FROM equipment_units;

-- ---------------------------------------------------------------------
-- Q12. Statistics of successful payments
-- Purpose : Summarise a numeric column.
-- Expected: 25 completed payments, total Rs 33,85,300.00, average Rs 1,35,412.00.
-- Concept : COUNT, SUM, AVG, MIN, MAX with WHERE.
-- ---------------------------------------------------------------------
SELECT COUNT(*)              AS completed_payments,
       SUM(amount)           AS total_received,
       ROUND(AVG(amount), 2) AS average_payment,
       MIN(amount)           AS smallest_payment,
       MAX(amount)           AS largest_payment
FROM payments
WHERE payment_status = 'COMPLETED';

-- ---------------------------------------------------------------------
-- Q13. Money received per payment method
-- Purpose : One summary row per group.
-- Expected: 5 rows; BANK_TRANSFER is by far the largest.
-- Concept : GROUP BY.
-- ---------------------------------------------------------------------
SELECT payment_method,
       COUNT(*)    AS payments,
       SUM(amount) AS total_amount
FROM payments
WHERE payment_status = 'COMPLETED'
GROUP BY payment_method
ORDER BY total_amount DESC;

-- ---------------------------------------------------------------------
-- Q14. Customers who have made more than two bookings
-- Purpose : Filter GROUPS (not rows).
-- Expected: 1 row - customer 1 (Gill Infrastructure) with 3 bookings.
-- Concept : HAVING is applied after GROUP BY; WHERE is applied before.
-- ---------------------------------------------------------------------
SELECT customer_id, COUNT(*) AS total_bookings
FROM bookings
GROUP BY customer_id
HAVING COUNT(*) > 2;

-- ---------------------------------------------------------------------
-- Q15. Number of bookings in each status
-- Purpose : Business status overview.
-- Expected: COMPLETED 15, RESERVED 5, ACTIVE 4, CANCELLED 2.
-- Concept : GROUP BY on an ENUM column, ORDER BY aggregate.
-- ---------------------------------------------------------------------
SELECT booking_status, COUNT(*) AS bookings
FROM bookings
GROUP BY booking_status
ORDER BY bookings DESC;

-- ---------------------------------------------------------------------
-- Q16. Models in which the company has invested more than Rs 1 crore
-- Purpose : HAVING on a SUM.
-- Expected: 4 models - CAT 320 (3 units), PC200-8, JCB 3DX Super and BEML BD80.
-- Concept : GROUP BY + HAVING SUM(...) > value.
-- ---------------------------------------------------------------------
SELECT model_id,
       COUNT(*)           AS units_owned,
       SUM(purchase_cost) AS total_investment
FROM equipment_units
GROUP BY model_id
HAVING SUM(purchase_cost) > 10000000
ORDER BY total_investment DESC;

-- ---------------------------------------------------------------------
-- Q17. Average daily rate per category, only categories with 2+ models
-- Purpose : WHERE + GROUP BY + HAVING + ORDER BY in one query
--           (logical order: FROM -> WHERE -> GROUP BY -> HAVING -> SELECT -> ORDER BY).
-- Expected: 5 rows - categories 1 Excavators, 4 Mobile Cranes, 6 Road Rollers,
--           2 Backhoe Loaders, 9 Diesel Generators (highest average first).
-- Concept : full SELECT clause order.
-- ---------------------------------------------------------------------
SELECT category_id,
       COUNT(*)                  AS models,
       ROUND(AVG(daily_rate), 2) AS avg_daily_rate,
       MAX(daily_rate)           AS max_daily_rate
FROM equipment_models
WHERE fuel_type = 'DIESEL'
GROUP BY category_id
HAVING COUNT(*) >= 2
ORDER BY avg_daily_rate DESC;

-- =====================================================================
-- PART C - DML: INSERT, UPDATE, DELETE  (rolled back at the end)
-- =====================================================================
START TRANSACTION;

-- ---------------------------------------------------------------------
-- Q18. Register a new customer
-- Purpose : Add a row; AUTO_INCREMENT generates customer_id.
-- Expected: 1 row affected; the SELECT shows the new customer.
-- Concept : INSERT INTO ... (column list) VALUES (...).
-- ---------------------------------------------------------------------
INSERT INTO customers (customer_type, full_name, organisation_name, phone, email,
                       address_line, city, state, pincode, registration_date)
VALUES ('COMPANY', 'Simran Kaur', 'Kaur Infra Projects', '+919988776655', 'simran@kaurinfra.in',
        'Sector 115, Landran', 'Mohali', 'Punjab', '140307', '2026-11-20');

SELECT * FROM customers WHERE phone = '+919988776655';

-- ---------------------------------------------------------------------
-- Q19. Update a customer's e-mail address
-- Purpose : Modify existing rows (always with a WHERE clause!).
-- Expected: 1 row affected.
-- Concept : UPDATE ... SET ... WHERE.
-- ---------------------------------------------------------------------
UPDATE customers
SET email = 'accounts@kaurinfra.in'
WHERE phone = '+919988776655';

-- ---------------------------------------------------------------------
-- Q20. Increase all generator daily rates by 10 %
-- Purpose : Set-based UPDATE using a subquery; booked prices are NOT affected
--           because bookings store their own agreed_daily_rate.
-- Expected: 2 rows affected (Kirloskar 3000 -> 3300, Cummins 4500 -> 4950).
-- Concept : UPDATE with expression and IN-subquery.
-- ---------------------------------------------------------------------
UPDATE equipment_models
SET daily_rate = ROUND(daily_rate * 1.10, 2)
WHERE category_id IN (SELECT category_id FROM equipment_categories WHERE category_name = 'Diesel Generators');

SELECT model_name, daily_rate FROM equipment_models WHERE category_id = 9;

-- ---------------------------------------------------------------------
-- Q21. Delete a customer who has never made a booking
-- Purpose : Remove rows safely.
-- Expected: 1 row affected (the customer inserted in Q18).
-- Concept : DELETE ... WHERE. A customer WITH bookings cannot be deleted
--           because fk_bookings_customer is ON DELETE RESTRICT - history
--           is protected. To try it, run the commented statement below; it
--           fails with ERROR 1451 (Cannot delete or update a parent row).
-- ---------------------------------------------------------------------
DELETE FROM customers
WHERE phone = '+919988776655'
  AND customer_id NOT IN (SELECT customer_id FROM bookings);

-- DELETE FROM customers WHERE customer_id = 1;      -- ERROR 1451: FK RESTRICT protects booking history
-- The correct way to "remove" such a customer is deactivation:
UPDATE customers SET is_active = FALSE WHERE customer_id = 17;   -- Arjun Verma (never booked)

-- ---------------------------------------------------------------------
-- Q22. Constraint examples (commented because they are meant to FAIL;
--      tests/integrity_tests.sql runs them safely)
-- ---------------------------------------------------------------------
-- INSERT INTO customers (customer_type, full_name, phone, address_line, city, state, pincode, registration_date)
-- VALUES ('INDIVIDUAL', 'Test', '12345', 'x', 'Mohali', 'Punjab', '160071', '2026-11-20');   -- ERROR 3819 chk_customers_phone
-- UPDATE equipment_models SET daily_rate = -100 WHERE model_id = 1;                         -- ERROR 3819 chk_models_rate

-- Undo every change made in Part C
ROLLBACK;

SELECT COUNT(*) AS customers_after_rollback FROM customers;   -- Expected: 18 (nothing changed)
