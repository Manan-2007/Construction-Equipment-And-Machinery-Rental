# Viva Preparation: 60 Questions and Answers

Answers are short enough to say aloud. Examples use **our** database so you can point at real tables. ★ = likely follow-up after the live demo.

---

## A. DBMS fundamentals

**1. What is a DBMS?**
Software that stores, retrieves and manages data in databases while enforcing integrity, security, concurrent access and recovery. Examples: MySQL, Oracle, SQL Server.

**2. What is an RDBMS?**
A DBMS based on the relational model: data is kept in tables (relations), and tables are linked through keys. It uses SQL. MySQL is an RDBMS.

**3. Why not just use Excel / files for the rental company?**
Files cause redundancy (the customer's address copied on every slip), inconsistency, no concurrent-access control (two clerks could book the same JCB), no integrity rules, weak security and no transactions. A DBMS solves these with constraints, locking, transactions and access control.

**4. Why MySQL?**
It is the RDBMS used in our labs. It is free (Community Edition), runs on macOS, and its InnoDB engine gives ACID transactions, row-level locking and foreign keys. It also supports stored procedures, triggers and views, and MySQL Workbench offers a GUI and EER diagrams.

**5. What is a relation, tuple, attribute and domain?**
A relation is a table. A tuple is one row (one booking). An attribute is a column (`start_date`). A domain is the set of allowed values for an attribute, e.g. `booking_status ∈ {RESERVED, ACTIVE, COMPLETED, CANCELLED}` or `pincode` = 6 digits not starting with 0.

**6. Schema vs instance?**
The schema is the structure (CREATE TABLE definitions). It changes rarely. The instance is the data at a given moment. It changes with every booking.

**7. What is metadata? Where is it in MySQL?**
Data about data: table names, column types, constraints. MySQL keeps it in `information_schema`. Our `verify_database.sql` and data dictionary read it from there.

## B. Keys and constraints

**8. What is a primary key?**
A minimal set of columns that uniquely identifies each row. It is NOT NULL and UNIQUE. Example: `bookings.booking_id`.

**9. What is a candidate key? Give one from the project.**
Any minimal unique identifier. `equipment_units` has three: `equipment_id` (chosen as PK), `asset_tag` and `serial_number`. The non-chosen ones are *alternate keys*, enforced with UNIQUE.

**10. What is a composite key?**
A key made of more than one column. `(booking_id, equipment_id)` in `booking_items` is a composite unique key: the same machine cannot appear twice in one booking.

**11. What is a foreign key?**
A column whose values must exist in another table's primary/unique key. Example: `bookings.customer_id → customers.customer_id`. It enforces **referential integrity**.

**12. Why surrogate keys (`AUTO_INCREMENT` ids) instead of natural keys like phone number?**
Natural values can change (a customer changes phone) and are long. Surrogate keys never change and are small and fast to join. The natural keys are still protected with UNIQUE.

**13. What does `ON DELETE RESTRICT` do and why did you use it?** ★
It refuses to delete a parent row that still has children. Deleting customer 1 fails with error 1451 because their bookings and payments exist. Financial history must never disappear, so we deactivate (`is_active = FALSE`) instead of deleting.

**14. Where did you use `ON DELETE SET NULL`?**
For optional "who" links: `staff.manager_id` and `maintenance_records.technician_staff_id`. If a staff row were deleted, the job record stays and just loses the technician reference.

**15. What CHECK constraints do you have? Name an interesting one.**
34 in total, for example: phone must match `^\+91[6-9][0-9]{9}$`; `expected_return_date >= start_date`; deposit `refunded + retained <= collected <= required`; and `chk_deposits_status`, which forces the deposit status to agree with the amounts (HELD means collected > 0 and nothing refunded yet). CHECK works in MySQL from 8.0.16.

**16. What is the difference between UNIQUE and PRIMARY KEY?**
A table has one PK (NOT NULL). It can have many UNIQUE keys, and in MySQL a UNIQUE column may contain several NULLs (e.g. `customers.email`).

## C. ER model

**17. What is an ER diagram?**
A conceptual picture of entities, their attributes and relationships, drawn before tables are created. Ours uses Crow's Foot notation.

**18. What is cardinality? Give 1:N, M:N and 1:1 examples.**
The number of instances on each side of a relationship. 1:N: customer–bookings. M:N: bookings–equipment units, resolved by `booking_items`. 1:0..1: booking–security deposit (government bookings have none).

**19. What is participation (total vs partial)?**
Total: every instance must take part (every booking must have a customer). Partial: participation is optional (a customer may have no bookings: Bajwa Agro Farms).

**20. What is a weak entity? Do you have any?**
An entity that cannot be identified without its owner. Payments, deposits and returns depend on their booking or booking item. We gave them surrogate PKs plus NOT NULL FKs instead of partial keys, so they behave like weak entities (existence dependency) but are simpler to reference.

**21. What is a recursive relationship?**
An entity related to itself: `staff.manager_id → staff.staff_id`. Query J6 uses a SELF JOIN to show who reports to whom.

**22. Why are equipment *model* and equipment *unit* separate entities?** ★
A model (JCB 3DX Super) has the price and specification. A unit is one physical machine with a serial number and its own availability. We own four JCB 3DX units, and only units can be double-booked, so bookings reference units.

**23. What is the most important relationship in the database?** ★
BOOKING ↔ EQUIPMENT_UNIT through `booking_items`. It resolves the M:N relationship, stores the agreed price, supports partial returns (each item can be returned separately), and it is where double booking is prevented.

## D. Normalization

**24. What is normalization and why do it?**
Decomposing tables using functional dependencies to remove redundancy and the insertion, update and deletion anomalies, without losing information.

**25. What is a functional dependency?**
X → Y means equal X values always give equal Y values. Example: `model_id → daily_rate`; `{booking_id, equipment_id} → agreed_daily_rate`.

**26. Explain 1NF with your project.**
Atomic values, no repeating groups. The old rental slip listed several machines in one cell. 1NF puts one row per (slip, machine) and splits the address into address_line, city, state and pincode.

**27. Explain 2NF.**
1NF plus no partial dependency on part of a composite key. With key {slip_no, machine_tag}, customer details depend only on slip_no and model details only on machine_tag, so they move to BOOKING and UNIT tables.

**28. Explain 3NF.**
2NF plus no transitive dependency. In UNIT, machine_tag → model → daily_rate is transitive, so model facts move to `equipment_models`. In BOOKING, booking → customer_phone → address, so customer facts move to `customers`.

**29. Is your schema in BCNF?**
Yes. In every table, every determinant is a candidate key (PK or a UNIQUE key such as phone, serial_number, or (booking_id, equipment_id)).

**30. `agreed_daily_rate` duplicates `equipment_models.daily_rate`. Isn't that a normalization violation?** ★
No. It is a different fact: the price agreed on the booking date. The CAT 320 list price is now ₹15,000, but bookings 1, 6, 13 and 17 were agreed at ₹14,000. Without the snapshot, a price change would rewrite old invoices. Its FD is {booking, unit} → agreed rate, which is fine in BCNF.

**31. Lossless join and dependency preservation?**
Lossless: joining the decomposed tables gives back exactly the original rows. It is guaranteed because each split shares a key of one side. Dependency preserving: every FD can still be checked inside one table.

## E. SQL

**32. DDL vs DML vs DCL vs TCL?**
DDL defines structure (CREATE, ALTER, DROP, TRUNCATE). DML changes data (INSERT, UPDATE, DELETE). DQL is SELECT. DCL handles privileges (GRANT, REVOKE). TCL handles transactions (COMMIT, ROLLBACK, SAVEPOINT).

**33. WHERE vs HAVING?**
WHERE filters rows before grouping. HAVING filters groups after GROUP BY, so it can use aggregates: `HAVING COUNT(*) > 2` (Q14: customers with more than two bookings).

**34. What are joins? Types?**
Joins combine rows of tables on a condition. INNER keeps only matches. LEFT keeps all rows of the left table. RIGHT keeps all of the right. FULL keeps all of both (MySQL emulates it with LEFT UNION RIGHT, query J8). CROSS gives every combination (J7, depot × category stock matrix). SELF joins a table to itself (J6).

**35. Which outer joins preserve unmatched rows in your queries?**
J3 (LEFT): Tower Cranes appears with 0 models. J4 (LEFT … IS NULL): units never rented. J5 (RIGHT): all units, even unbooked ones. J8 (FULL emulation): technician Harish Kumar with no jobs, and job #4 with no technician.

**36. What is a subquery? A correlated subquery?**
A query inside another query. A correlated subquery refers to the outer row and is logically evaluated once per outer row. S7 compares each booking with *that customer's* average booking value.

**37. EXISTS vs IN; why prefer NOT EXISTS over NOT IN?**
EXISTS checks whether any row exists and stops at the first match. NOT IN returns no rows at all if the subquery returns a NULL. NOT EXISTS is NULL-safe.

**38. UNION vs UNION ALL?**
UNION removes duplicates (it needs a sort/dedup step). UNION ALL keeps all rows and is faster. U2 uses UNION ALL to build a money ledger.

**39. Does MySQL support INTERSECT and MINUS?**
INTERSECT and EXCEPT (the standard name for MINUS) exist from MySQL 8.0.31. Queries U3 and U4 use them, with IN / NOT EXISTS versions for older servers.

**40. What does relational algebra have to do with SQL?**
SQL is built on it. σ = WHERE, π = SELECT column list, ⋈ = JOIN, × = CROSS JOIN, ∪ / ∩ / − = UNION / INTERSECT / EXCEPT. For example, "machines never rented" is π_id(units) − π_id(booking_items).

## F. Views, procedures, functions, triggers

**41. What is a view? Why use views here?**
A stored SELECT that acts like a virtual table. We have 8. `vw_booking_financial_summary` hides complex money calculations, and `vw_equipment_inventory` derives the current state of every machine. Views can also restrict access (the DCL role gets SELECT on views only).

**42. Why is "available between date X and Y" a procedure, not a view?** ★
A view cannot take parameters. Availability depends on the requested dates, so `sp_check_availability(start, end, category)` does it. Query B3 shows the same logic as plain SQL with variables.

**43. Why don't you get wrong totals when joining payments and booking items?**
Joining two child tables multiplies rows (fan-out). Our financial view first aggregates each child table in its own derived table (one row per booking) and then joins them 1:1.

**44. Stored procedure vs function?**
A procedure is run with CALL. It can return result sets and OUT parameters and can manage transactions. A function returns one value, is used inside expressions, cannot COMMIT, and is used for formulas like `fn_late_charge` or `fn_rental_days`.

**45. Explain `sp_create_booking`.**
It validates inputs, parses the comma-separated unit list into a temporary table (WHILE loop), starts a READ COMMITTED transaction, checks the customer, and opens a **cursor** over the units in ascending id order. For each unit it locks the row `FOR UPDATE`, checks for conflicts and inserts the item, then creates the deposit and COMMITs. Any error triggers the EXIT HANDLER: ROLLBACK, then RESIGNAL. So it is all or nothing.

**46. Where did you use a cursor? Why?**
In `sp_create_booking` (lock units one by one in a fixed order) and `sp_overdue_report` (walk through overdue machines, compute fee and priority with IF/ELSEIF, store rows). A cursor processes a result set row by row; it needs a `NOT FOUND` handler to stop the loop.

**47. What is a trigger? Give your best example.** ★
SQL that runs automatically BEFORE/AFTER INSERT/UPDATE/DELETE on a table. `trg_booking_items_bi` locks the machine row and refuses any item that overlaps an existing booking or maintenance job. So even a hand-typed INSERT cannot double-book.

**48. Don't the triggers duplicate the procedures?**
The shared rule lives in one function, `fn_unit_conflict`, which both call. The procedure checks early to give a friendly error and to control locking order. The trigger is the last line of defence for direct SQL.

**49. What does `SIGNAL SQLSTATE '45000'` do?**
It raises a user-defined error with our message, e.g. *"Equipment CER-BHL-002 is not available … (BOOKING_CONFLICT)"*. The statement fails and nothing is written.

**50. Can a trigger update its own table?**
No. MySQL forbids modifying the table that fired the trigger. Our `trg_equipment_returns_ai` updates a *different* table (`bookings`, to COMPLETED). We also hit error 1442: a trigger cannot lock `equipment_units` if the INSERT itself selects from it, so items are inserted row by row.

## G. Transactions and concurrency

**51. What is a transaction? What are ACID properties?** ★
A unit of work that succeeds or fails as a whole. **Atomicity**: the booking, its items and its deposit are all written or none are (scenario 2 rollback). **Consistency**: constraints and triggers keep rules true (no overpayment). **Isolation**: concurrent transactions do not see each other's uncommitted data (two-session test). **Durability**: after COMMIT the data survives a crash (InnoDB redo log).

**52. If a statement fails inside START TRANSACTION, is everything rolled back?**
No. In MySQL only that statement fails and the transaction stays open. You must ROLLBACK (scenario 2a shows this). Our procedures do it in the EXIT HANDLER.

**53. How do you prevent double booking?** ★
(1) Lock the machine's row with `SELECT … FOR UPDATE`, so a second session for the same machine waits. (2) Re-check overlaps with locking reads (`FOR SHARE`) that see the latest committed data. (3) Lock multiple machines in ascending id order to avoid deadlocks. (4) The same logic is in the trigger. We tested it with two real sessions: B waited about 3 s for A and was then rejected.

**54. Why is "SELECT to check, then INSERT" not enough?**
A plain SELECT takes no locks. Two sessions can both see the machine as free and both insert. Locking forces the second session to wait and then see the first one's booking.

**55. What isolation levels exist? Which do you use?**
READ UNCOMMITTED, READ COMMITTED, REPEATABLE READ (MySQL's default), SERIALIZABLE. The booking procedure uses READ COMMITTED so each read sees the latest committed data. Test C2 showed that a REPEATABLE READ snapshot can be stale, which is why the check uses locking reads.

**56. What is a deadlock and how do you avoid it?**
Two transactions each wait for a lock the other holds. InnoDB detects it and rolls one back (error 1213). We avoid it by always locking units in ascending equipment_id order.

**57. What is SAVEPOINT?**
A marker inside a transaction. `ROLLBACK TO SAVEPOINT x` undoes only the work after it. Scenario 3 undoes a payment but keeps the deposit collection.

## H. Project-specific (likely after the demo)

**58. How does equipment availability work?** ★
Nothing is stored. A unit is available for a period if it is ACTIVE, already purchased, and no live booking item or maintenance job overlaps. Returned items block only until their return date. Overdue unreturned items block indefinitely. Cancelled bookings block nothing.

**59. How are late fees calculated? Show me for booking 18.** ★
Late days × agreed daily rate × 1.5 (from `system_settings`). Booking 18's excavator was due 16-Nov, and today is 20-Nov, so 4 × ₹13,000 × 1.5 = ₹78,000 accrued (`vw_overdue_rentals`). The fee is fixed into `equipment_returns.late_charge` when the machine comes back, and a trigger verifies it against the formula.

**60. How are deposits handled?** ★
Required deposit = sum of model deposits (government customers are exempt). It is collected before handover (the trigger blocks ACTIVE otherwise). After the booking is COMPLETED, `sp_settle_deposit` retains `LEAST(collected, unpaid balance)` and refunds the rest, giving REFUNDED, PARTIALLY_REFUNDED or FORFEITED. A CHECK constraint keeps status and amounts consistent.

### More follow-ups examiners like

- **What happens when a rental is cancelled?** Only RESERVED bookings can be cancelled. The status becomes CANCELLED with a date and reason, the deposit becomes CANCELLED (or REFUNDED if collected), advance payments become REFUNDED, and the machines become free immediately (booking 25 / unit 2 demo).
- **How does maintenance affect availability?** SCHEDULED jobs block bookings in their window, but the machine still shows AVAILABLE today. IN_PROGRESS jobs make it IN_MAINTENANCE. Maintenance cannot overlap bookings either (Demo 11 error).
- **Partial returns?** Each booking item is returned separately (1:0..1). The booking stays ACTIVE until the last machine returns, then the trigger sets COMPLETED.
- **Early return?** The booked period is still billed (rule P3).
- **What is the most complex query?** `vw_maintenance_summary`'s usage calculation: for every unit, the sum of rental days since its last preventive service, intersecting each rental period with [last service + 1, today] using `GREATEST`/`LEAST`. Close second: `fn_unit_conflict`'s overlap test with CASE-based blocking end dates.
- **Why a fixed business date?** So "overdue", "today's pickup" and "future booking" demos stay true whenever the scripts are run. `sp_set_business_date` moves time forward in the demo.
- **What is AUTO_INCREMENT? Is it a sequence?** MySQL's way to generate surrogate keys (the CHO objective mentions sequences; MySQL has no separate SEQUENCE object). Gaps appear after rolled-back inserts, which is normal.
- **Why DECIMAL for money?** FLOAT/DOUBLE are binary approximations (0.1 + 0.2 ≠ 0.3). DECIMAL stores exact base-10 values.
- **What does `GRANT EXECUTE` give the agent?** The right to run a procedure. The procedure runs with the definer's rights, so the agent can create bookings without having INSERT on the bookings table. We tested this: a direct INSERT gave error 1142, and a revoked procedure gave error 1370.
- **What index matters most?** `idx_items_equipment_booking (equipment_id, booking_id)`. EXPLAIN shows a `ref` lookup plus covering index for the availability check.
- **Limitations?** Daily pricing only, no GST/invoices, no operator or transport charges, a single currency, and no frontend.
