-- =====================================================================
--  File   : 04_joins_and_subqueries.sql
--  Purpose: JOINs (inner, left, right, self, cross, full-outer emulation),
--           subqueries (scalar, IN, EXISTS, NOT EXISTS, correlated,
--           derived tables, ANY/ALL) and set operations
--           (UNION, UNION ALL, INTERSECT, EXCEPT)
--  Read-only: this file never changes data.
--  Syllabus: Lectures 10-12 (relational algebra), 20-24, Labs 6 & 9
-- =====================================================================

USE construction_rental_db;

-- =====================================================================
-- PART A - JOINS
-- =====================================================================

-- ---------------------------------------------------------------------
-- J1. Full equipment catalogue: unit + model + category + yard
-- Purpose : Combine four tables through their foreign keys.
-- Expected: 32 rows, one per physical machine.
-- Concept : INNER JOIN keeps only rows that match on both sides.
--           RA: units |X| models |X| categories |X| depots
-- ---------------------------------------------------------------------
SELECT u.asset_tag,
       c.category_name,
       m.manufacturer,
       m.model_name,
       d.depot_name,
       u.lifecycle_status
FROM equipment_units u
INNER JOIN equipment_models     m ON m.model_id    = u.model_id
INNER JOIN equipment_categories c ON c.category_id = m.category_id
INNER JOIN depots               d ON d.depot_id    = u.depot_id
ORDER BY c.category_name, u.asset_tag;

-- ---------------------------------------------------------------------
-- J2. Bookings with the customer's name and the staff member who made them
-- Purpose : Replace foreign-key numbers with readable names.
-- Expected: 26 rows.
-- Concept : INNER JOIN of a fact table with two parent tables.
-- ---------------------------------------------------------------------
SELECT b.booking_id,
       COALESCE(c.organisation_name, c.full_name) AS customer,
       s.full_name                                AS booked_by,
       b.start_date,
       b.expected_return_date,
       b.booking_status
FROM bookings b
INNER JOIN customers c ON c.customer_id = b.customer_id
INNER JOIN staff     s ON s.staff_id    = b.created_by_staff_id
ORDER BY b.booking_id;

-- ---------------------------------------------------------------------
-- J3. Every category with the number of models it contains
-- Purpose : Show categories even when they have no models.
-- Expected: 12 rows; "Tower Cranes" shows 0 models (an INNER JOIN would drop it).
-- Concept : LEFT JOIN preserves all rows of the LEFT table; unmatched
--           right-side columns become NULL, and COUNT(column) ignores NULLs.
-- ---------------------------------------------------------------------
SELECT c.category_name,
       COUNT(m.model_id) AS models
FROM equipment_categories c
LEFT JOIN equipment_models m ON m.category_id = c.category_id
GROUP BY c.category_id, c.category_name
ORDER BY models DESC, c.category_name;

-- ---------------------------------------------------------------------
-- J4. Machines that have never been rented
-- Purpose : Find rows with NO match ("anti-join").
-- Expected: 5 units - CER-EXC-005, CER-CRN-003, CER-FRK-002, CER-CMP-003, CER-GEN-005.
--           (Retired CER-BHL-005 is NOT listed: it was rented in booking 1.)
-- Concept : LEFT JOIN + WHERE right.key IS NULL.
-- ---------------------------------------------------------------------
SELECT u.equipment_id, u.asset_tag, u.purchase_date, u.lifecycle_status
FROM equipment_units u
LEFT JOIN booking_items bi ON bi.equipment_id = u.equipment_id
WHERE bi.booking_item_id IS NULL
ORDER BY u.equipment_id;

-- ---------------------------------------------------------------------
-- J5. All units with their booking count, written as a RIGHT JOIN
-- Purpose : Same idea as J4 but keeping the RIGHT table complete.
-- Expected: 32 rows; never-rented units show 0.
-- Concept : RIGHT JOIN preserves all rows of the RIGHT table.
--           A RIGHT JOIN B  ==  B LEFT JOIN A (most people write LEFT JOINs).
-- ---------------------------------------------------------------------
SELECT u.asset_tag,
       COUNT(bi.booking_item_id) AS times_booked
FROM booking_items bi
RIGHT JOIN equipment_units u ON u.equipment_id = bi.equipment_id
GROUP BY u.equipment_id, u.asset_tag
ORDER BY times_booked DESC, u.asset_tag;

-- ---------------------------------------------------------------------
-- J6. Staff reporting hierarchy
-- Purpose : Relate a table to itself (who reports to whom).
-- Expected: 8 rows; Rajinder Singh Gill has no manager (NULL);
--           Sukhwinder Pal and Harish Kumar report to Vikram Choudhary.
-- Concept : SELF JOIN using two aliases of the same table (recursive relationship).
-- ---------------------------------------------------------------------
SELECT e.staff_id,
       e.full_name  AS employee,
       e.staff_role,
       m.full_name  AS reports_to
FROM staff e
LEFT JOIN staff m ON m.staff_id = e.manager_id
ORDER BY m.full_name IS NULL DESC, m.full_name, e.full_name;

-- ---------------------------------------------------------------------
-- J7. Stock matrix: how many ACTIVE machines of each category are at each yard
-- Purpose : List EVERY depot x category combination, including zeros.
-- Expected: 3 depots x 12 categories = 36 rows; e.g. Tower Cranes = 0 everywhere.
-- Concept : CROSS JOIN (Cartesian product) builds all combinations;
--           LEFT JOIN then counts matching units.   RA: depots x categories
-- ---------------------------------------------------------------------
SELECT d.depot_name,
       c.category_name,
       COUNT(u.equipment_id) AS active_units
FROM depots d
CROSS JOIN equipment_categories c
LEFT JOIN equipment_models m ON m.category_id = c.category_id
LEFT JOIN equipment_units  u ON u.model_id = m.model_id
                            AND u.depot_id = d.depot_id
                            AND u.lifecycle_status = 'ACTIVE'
GROUP BY d.depot_id, d.depot_name, c.category_id, c.category_name
ORDER BY d.depot_name, c.category_name;

-- ---------------------------------------------------------------------
-- J8. Technicians and maintenance jobs - FULL OUTER JOIN (emulated)
-- Purpose : Show technicians with no jobs AND jobs with no in-house technician.
-- Expected: 15 jobs + 1 technician with no job (Harish Kumar) = 16 rows;
--           job #4 shows technician NULL (external workshop).
-- Concept : MySQL has no FULL OUTER JOIN. Emulate it as
--           (A LEFT JOIN B) UNION (A RIGHT JOIN B). UNION removes duplicates.
-- ---------------------------------------------------------------------
SELECT t.full_name AS technician, mr.maintenance_id, mr.maintenance_type, mr.maintenance_status
FROM (SELECT * FROM staff WHERE staff_role = 'TECHNICIAN') t
LEFT JOIN maintenance_records mr ON mr.technician_staff_id = t.staff_id
UNION
SELECT t.full_name, mr.maintenance_id, mr.maintenance_type, mr.maintenance_status
FROM (SELECT * FROM staff WHERE staff_role = 'TECHNICIAN') t
RIGHT JOIN maintenance_records mr ON mr.technician_staff_id = t.staff_id
ORDER BY technician, maintenance_id;

-- ---------------------------------------------------------------------
-- J9. Rental revenue per category (ACTIVE + COMPLETED bookings)
-- Purpose : Join + aggregate across five tables.
-- Expected: Excavators earn the most; Tower Cranes absent (never rented).
-- Concept : JOIN, GROUP BY, SUM of an expression.
-- ---------------------------------------------------------------------
SELECT c.category_name,
       COUNT(*)                                                                  AS rentals,
       SUM(bi.agreed_daily_rate * (DATEDIFF(b.expected_return_date, b.start_date) + 1)) AS rental_revenue
FROM booking_items bi
JOIN bookings             b ON b.booking_id   = bi.booking_id
JOIN equipment_units      u ON u.equipment_id = bi.equipment_id
JOIN equipment_models     m ON m.model_id     = u.model_id
JOIN equipment_categories c ON c.category_id  = m.category_id
WHERE b.booking_status IN ('ACTIVE','COMPLETED')
GROUP BY c.category_id, c.category_name
ORDER BY rental_revenue DESC;

-- ---------------------------------------------------------------------
-- J10. Damaged returns with who received them and what the repair cost
-- Purpose : Follow a chain of relationships return -> item -> booking -> customer
--           and return -> maintenance (optional link, so LEFT JOIN).
-- Expected: 2 rows - CER-CRN-001 (minor, repair Rs 9,500) and CER-DMP-002 (major, Rs 38,000).
-- Concept : multi-table join mixing INNER and LEFT joins.
-- ---------------------------------------------------------------------
SELECT r.return_id,
       u.asset_tag,
       COALESCE(c.organisation_name, c.full_name) AS customer,
       r.return_condition,
       r.damage_charge,
       s.full_name                                AS received_by,
       mr.maintenance_id                          AS repair_job,
       mr.maintenance_cost                        AS repair_cost
FROM equipment_returns r
JOIN booking_items   bi ON bi.booking_item_id = r.booking_item_id
JOIN bookings        b  ON b.booking_id       = bi.booking_id
JOIN customers       c  ON c.customer_id      = b.customer_id
JOIN equipment_units u  ON u.equipment_id     = bi.equipment_id
JOIN staff           s  ON s.staff_id         = r.received_by_staff_id
LEFT JOIN maintenance_records mr ON mr.related_return_id = r.return_id
WHERE r.return_condition <> 'GOOD';

-- =====================================================================
-- PART B - SUBQUERIES
-- =====================================================================

-- ---------------------------------------------------------------------
-- S1. Models whose daily rate is above the average daily rate
-- Purpose : Compare each row with one computed value.
-- Expected: 8 models (average daily rate = Rs 7,747.06).
-- Concept : SCALAR subquery (returns exactly one value).
-- ---------------------------------------------------------------------
SELECT manufacturer, model_name, daily_rate
FROM equipment_models
WHERE daily_rate > (SELECT AVG(daily_rate) FROM equipment_models)
ORDER BY daily_rate DESC;

-- ---------------------------------------------------------------------
-- S2. Each customer with the number of bookings they made
-- Purpose : Scalar subquery in the SELECT list, re-evaluated per customer.
-- Expected: 18 rows; Bajwa Agro Farms and Arjun Verma show 0.
-- Concept : CORRELATED scalar subquery (refers to c.customer_id of the outer row).
-- ---------------------------------------------------------------------
SELECT c.customer_id,
       COALESCE(c.organisation_name, c.full_name) AS customer,
       (SELECT COUNT(*) FROM bookings b WHERE b.customer_id = c.customer_id) AS bookings_made
FROM customers c
ORDER BY bookings_made DESC, customer;

-- ---------------------------------------------------------------------
-- S3. Customers who have rented an excavator (any booking that was not cancelled)
-- Purpose : Filter by membership in a set produced by a subquery.
-- Expected: 6 customers - Bhatia, Gill Infra, Shivalik, Sandhu, Metro Height, Aggarwal Realty.
-- Concept : IN (subquery) with nested subqueries.
-- ---------------------------------------------------------------------
SELECT customer_id, COALESCE(organisation_name, full_name) AS customer
FROM customers
WHERE customer_id IN (
    SELECT b.customer_id
    FROM bookings b
    JOIN booking_items bi ON bi.booking_id = b.booking_id
    WHERE b.booking_status <> 'CANCELLED'
      AND bi.equipment_id IN (
          SELECT u.equipment_id
          FROM equipment_units u
          JOIN equipment_models m ON m.model_id = u.model_id
          WHERE m.category_id = (SELECT category_id FROM equipment_categories WHERE category_name = 'Excavators')))
ORDER BY customer;

-- ---------------------------------------------------------------------
-- S4. Machines that have never had any maintenance record
-- Purpose : Exclude a set.
-- Expected: 17 units.
-- Concept : NOT IN (subquery). Safe here because equipment_id is NOT NULL;
--           if the subquery could return NULL, NOT IN would return no rows -
--           NOT EXISTS (S6) is the NULL-safe alternative.
-- ---------------------------------------------------------------------
SELECT equipment_id, asset_tag
FROM equipment_units
WHERE equipment_id NOT IN (SELECT equipment_id FROM maintenance_records)
ORDER BY equipment_id;

-- ---------------------------------------------------------------------
-- S5. Customers who currently have machines on rent
-- Purpose : Test whether at least one related row exists.
-- Expected: 4 customers - Gill Infra, Shivalik, Dhillon Road, PWD Mohali.
-- Concept : EXISTS (correlated) - stops at the first match.
-- ---------------------------------------------------------------------
SELECT c.customer_id, COALESCE(c.organisation_name, c.full_name) AS customer, c.phone
FROM customers c
WHERE EXISTS (SELECT 1 FROM bookings b
              WHERE b.customer_id = c.customer_id
                AND b.booking_status = 'ACTIVE');

-- ---------------------------------------------------------------------
-- S6. Registered customers who have never booked anything
-- Purpose : Find customers to follow up with.
-- Expected: 2 rows - Bajwa Agro Farms (14), Arjun Verma (17).
-- Concept : NOT EXISTS (correlated anti-join; NULL-safe).
-- ---------------------------------------------------------------------
SELECT c.customer_id, COALESCE(c.organisation_name, c.full_name) AS customer, c.registration_date
FROM customers c
WHERE NOT EXISTS (SELECT 1 FROM bookings b WHERE b.customer_id = c.customer_id);

-- ---------------------------------------------------------------------
-- S7. Bookings worth more than that same customer's average booking
-- Purpose : Compare each booking with an aggregate of ITS OWN customer.
-- Expected: 7 rows - e.g. B17 (Gill Infra, Rs 5,40,000), B20 (PWD, Rs 9,30,000),
--           B6 (Sandhu, Rs 6,00,000).
-- Concept : CORRELATED subquery in WHERE (inner query uses outer b1.customer_id).
-- ---------------------------------------------------------------------
SELECT b1.booking_id,
       b1.customer_id,
       f1.rental_charge
FROM bookings b1
JOIN vw_booking_financial_summary f1 ON f1.booking_id = b1.booking_id
WHERE b1.booking_status <> 'CANCELLED'
  AND f1.rental_charge > (
        SELECT AVG(f2.rental_charge)
        FROM bookings b2
        JOIN vw_booking_financial_summary f2 ON f2.booking_id = b2.booking_id
        WHERE b2.customer_id = b1.customer_id          -- <- correlation with the outer row
          AND b2.booking_status <> 'CANCELLED')
ORDER BY b1.customer_id, b1.booking_id;

-- ---------------------------------------------------------------------
-- S8. Most expensive model in each category
-- Purpose : "Top 1 per group" without window functions.
-- Expected: 11 rows (Tower Cranes has no models).
-- Concept : correlated subquery with MAX per group.
-- ---------------------------------------------------------------------
SELECT c.category_name, m.manufacturer, m.model_name, m.daily_rate
FROM equipment_models m
JOIN equipment_categories c ON c.category_id = m.category_id
WHERE m.daily_rate = (SELECT MAX(m2.daily_rate)
                      FROM equipment_models m2
                      WHERE m2.category_id = m.category_id)
ORDER BY m.daily_rate DESC;

-- ---------------------------------------------------------------------
-- S9. Average booking value by customer type
-- Purpose : Aggregate the result of another query.
-- Expected: 3 rows - GOVERNMENT has the highest average booking value.
-- Concept : DERIVED TABLE (subquery in FROM, must have an alias).
-- ---------------------------------------------------------------------
SELECT t.customer_type,
       COUNT(*)                     AS bookings,
       ROUND(AVG(t.total_value), 2) AS avg_booking_value
FROM (SELECT c.customer_type, f.total_charges AS total_value
      FROM vw_booking_financial_summary f
      JOIN bookings  b ON b.booking_id  = f.booking_id
      JOIN customers c ON c.customer_id = b.customer_id
      WHERE f.booking_status <> 'CANCELLED') AS t
GROUP BY t.customer_type
ORDER BY avg_booking_value DESC;

-- ---------------------------------------------------------------------
-- S10. Machines that cost more than EVERY diesel generator
-- Purpose : Compare against all values of a set.
-- Expected: 22 units (the costliest generator is Rs 15.2 lakh; forklifts,
--           compactors and generators are excluded).
-- Concept : > ALL (subquery);  > ANY would mean "more than at least one".
-- ---------------------------------------------------------------------
SELECT u.asset_tag, u.purchase_cost
FROM equipment_units u
WHERE u.purchase_cost > ALL (
    SELECT u2.purchase_cost
    FROM equipment_units u2
    JOIN equipment_models m2 ON m2.model_id = u2.model_id
    WHERE m2.category_id = 9)
ORDER BY u.purchase_cost DESC;

-- =====================================================================
-- PART C - SET OPERATIONS
-- (both queries must return the same number of columns with compatible types)
-- =====================================================================

-- ---------------------------------------------------------------------
-- U1. One phone directory of customers and staff
-- Purpose : Stack two result sets, removing duplicates.
-- Expected: 26 rows (18 customers + 8 staff).
-- Concept : UNION (distinct).   RA: R U S
-- ---------------------------------------------------------------------
SELECT COALESCE(organisation_name, full_name) AS name, phone, 'CUSTOMER' AS contact_type FROM customers
UNION
SELECT full_name, phone, CONCAT('STAFF - ', staff_role) FROM staff
ORDER BY contact_type, name;

-- ---------------------------------------------------------------------
-- U2. Complete money trail of booking 4 (late return example)
-- Purpose : Combine rows from different tables into one ledger.
-- Expected: 4 rows - deposit collected 30,000; payment 38,500;
--           deposit retained 24,750; deposit refunded 5,250.
-- Concept : UNION ALL keeps duplicates and is faster (no sort/dedup step).
-- ---------------------------------------------------------------------
SELECT payment_date AS txn_date, 'PAYMENT RECEIVED' AS entry, amount
FROM payments WHERE booking_id = 4 AND payment_status = 'COMPLETED'
UNION ALL
SELECT collected_date, 'DEPOSIT COLLECTED', collected_amount
FROM security_deposits WHERE booking_id = 4 AND collected_amount > 0
UNION ALL
SELECT settled_date, 'DEPOSIT RETAINED (late fee)', retained_amount
FROM security_deposits WHERE booking_id = 4 AND retained_amount > 0
UNION ALL
SELECT settled_date, 'DEPOSIT REFUNDED', refunded_amount
FROM security_deposits WHERE booking_id = 4 AND refunded_amount > 0
ORDER BY txn_date, entry;

-- ---------------------------------------------------------------------
-- U3. Machines that were rented in 2026 AND also maintained in 2026
-- Purpose : Rows common to both queries.
-- Expected: 9 units - ids 3, 6, 11, 12, 16, 18, 19, 24, 25.
-- Concept : INTERSECT (supported from MySQL 8.0.31).   RA: R n S
--           Older MySQL: rewrite with IN / EXISTS (shown in the comment).
-- ---------------------------------------------------------------------
SELECT bi.equipment_id
FROM booking_items bi JOIN bookings b ON b.booking_id = bi.booking_id
WHERE YEAR(b.start_date) = 2026 AND b.booking_status <> 'CANCELLED'
INTERSECT
SELECT equipment_id
FROM maintenance_records
WHERE YEAR(scheduled_start) = 2026 AND maintenance_status <> 'CANCELLED'
ORDER BY equipment_id;
-- Pre-8.0.31 equivalent:
-- SELECT DISTINCT bi.equipment_id FROM booking_items bi JOIN bookings b ON b.booking_id = bi.booking_id
-- WHERE YEAR(b.start_date) = 2026 AND b.booking_status <> 'CANCELLED'
--   AND bi.equipment_id IN (SELECT equipment_id FROM maintenance_records
--                           WHERE YEAR(scheduled_start) = 2026 AND maintenance_status <> 'CANCELLED');

-- ---------------------------------------------------------------------
-- U4. Active machines that have never been booked
-- Purpose : Rows of the first query that are not in the second.
-- Expected: 5 units: 5, 13, 21, 28, 32 (unit 30 is retired so it is excluded).
-- Concept : EXCEPT = relational-algebra difference R - S (MySQL 8.0.31+;
--           the syllabus calls it MINUS, the Oracle name). J4 and S6 show the
--           LEFT JOIN / NOT EXISTS way that works in every MySQL version.
-- ---------------------------------------------------------------------
SELECT equipment_id FROM equipment_units WHERE lifecycle_status = 'ACTIVE'
EXCEPT
SELECT equipment_id FROM booking_items
ORDER BY equipment_id;
