# 04 · Indexing and Query Optimization

Script: [`sql/11_indexing_and_explain.sql`](../sql/11_indexing_and_explain.sql) (read-only; it creates one temporary index and drops it again).

> **Honesty note.** The tables hold tens of rows, so no meaningful timing difference can be measured and **no speed-up figures are claimed**. The point is to show (a) which indexes exist and why, and (b) how `EXPLAIN` reveals whether the optimizer uses them. The EXPLAIN rows below were **actually produced** on the project database during development (MySQL 9.7.1 server, `EXPLAIN FORMAT=TRADITIONAL`). MySQL 8.0 Workbench shows the same table format by default. Row estimates may differ slightly on another installation.

## 1. Background (syllabus L33–35)

- **InnoDB stores each table as a B+-tree ordered by the PRIMARY KEY.** That index is *clustered*: the leaf pages contain the rows themselves.
- Every other index is a **secondary index**: a separate B+-tree holding the indexed columns plus the primary key, used to find the row.
- InnoDB **automatically creates an index on every FOREIGN KEY column** that does not already have one, because the FK check needs it.
- A composite index (a, b, c) can be used for filters on `a`, `a,b` or `a,b,c` (**leftmost-prefix rule**), but not for a filter on `b` alone.
- An index is **covering** when it contains every column a query needs. Then MySQL never touches the table rows (`Using index` in EXPLAIN).

## 2. Indexes in the schema and why they exist

| Table | Index | Columns | Kind | Reason (which query needs it) |
|---|---|---|---|---|
| every table | PRIMARY | surrogate id | clustered, unique | row identity, joins |
| equipment_units | uq_units_asset_tag / uq_units_serial | asset_tag / serial_number | unique | business identifiers; lookup by tag or serial |
| equipment_units | fk_units_model, fk_units_depot | model_id / depot_id | FK (auto) | join to models, depot reports |
| equipment_units | idx_units_lifecycle | lifecycle_status | secondary | "active fleet" filters |
| equipment_models | uq_models_make_name | manufacturer, model_name | unique | candidate key |
| customers | uq_customers_phone / email | phone / email | unique | lookup of a caller by phone |
| customers | idx_customers_name | full_name | secondary | name search (prefix LIKE) |
| bookings | idx_bookings_status_period | booking_status, start_date, expected_return_date | composite | "ACTIVE bookings", "overdue", date-window reports; covering for many of them |
| bookings | idx_bookings_customer_date | customer_id, booking_date | composite | customer history (also serves the FK) |
| booking_items | **idx_items_equipment_booking** | equipment_id, booking_id | composite | **the double-booking / availability check** ("all bookings of unit X"), run on every booking, every availability search and inside the trigger |
| booking_items | uq_booking_items_unit | booking_id, equipment_id | unique | same unit not twice in a booking; also "items of booking X" |
| equipment_returns | uq_returns_item | booking_item_id | unique | 1:0..1 rule; "was this item returned?" (the LEFT JOIN anti-join) |
| equipment_returns | idx_returns_date | return_date | secondary | returns-by-date reports |
| payments | idx_payments_booking_status | booking_id, payment_status | composite | "completed payments of booking X" (all financial functions) |
| payments | idx_payments_date | payment_date | secondary | income-for-a-period report |
| security_deposits | uq_deposits_booking / idx_deposits_status | booking_id / deposit_status | unique / secondary | 1:0..1 rule; "deposits HELD" |
| maintenance_records | idx_maint_unit_status | equipment_id, maintenance_status, scheduled_start | composite | maintenance conflict check for one unit |
| maintenance_records | idx_maint_status_start | maintenance_status, scheduled_start | composite | "jobs in progress", "upcoming jobs" |

**Indexes deliberately not created:** `customers.city`, `equipment_models.daily_rate`, `bookings.site_address`. No frequent query filters on them, and every extra index slows down INSERT/UPDATE and uses space. Section 4.8 shows how to add one when a real need appears.

## 3. The most important query: "is unit X busy?"

```sql
EXPLAIN
SELECT COUNT(*)
FROM booking_items bi
JOIN bookings b ON b.booking_id = bi.booking_id
LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
WHERE bi.equipment_id = 7
  AND b.booking_status IN ('RESERVED','ACTIVE','COMPLETED')
  AND b.start_date <= '2026-11-27'
  AND COALESCE(r.return_date, b.expected_return_date) >= '2026-11-23';
```

Observed plan:

| table | type | key | ref | rows | Extra |
|---|---|---|---|---|---|
| bi | **ref** | idx_items_equipment_booking | const | 1 | Using index |
| b | **eq_ref** | PRIMARY | bi.booking_id | 1 | Using where |
| r | **eq_ref** | uq_returns_item | bi.booking_item_id | 1 | Using where |

Reading it:
- `bi`: **ref** on the composite index with `equipment_id = const`. Only the items of unit 7 are read, and `Using index` means the index alone answers it (covering), because it contains equipment_id and booking_id.
- `b` and `r`: **eq_ref**, which is one row per item via a unique key. This is the best possible join type.
- So the cost grows with the number of bookings **of that one machine**, not with the size of the whole booking history. Without `idx_items_equipment_booking`, MySQL would have to scan every booking item for every check.

## 4. More EXPLAIN examples (all observed)

| # | Query | type | key | rows | Extra | Lesson |
|---|---|---|---|---|---|---|
| 4.1 | `SELECT * FROM bookings WHERE booking_id = 17` | **const** | PRIMARY | 1 | — | PK equality: at most one row, read once |
| 4.2 | `SELECT * FROM equipment_units WHERE serial_number = 'CAT0320GKTW10231'` | **const** | uq_units_serial | 1 | — | a UNIQUE secondary key behaves like the PK |
| 4.3 | `… FROM bookings WHERE booking_status = 'ACTIVE' AND start_date <= '2026-11-20'` | **range** | idx_bookings_status_period | 4 | Using where; Using index | leftmost columns used, covering index |
| 4.4 | `… FROM bookings WHERE start_date <= '2026-11-20'` | **index** | idx_bookings_status_period | 26 | Using where; Using index | leftmost column missing → **no seek**; MySQL scans the whole (small, covering) index |
| 4.5 | `SUM(amount) … WHERE payment_date BETWEEN '2026-10-01' AND '2026-11-30'` | **range** | idx_payments_date | 13 | Using index condition | range on an indexed date |
| 4.6 | `SUM(amount) … WHERE YEAR(payment_date) = 2026 AND MONTH(payment_date) >= 10` | **ALL** | NULL | 28 | Using where | **a function on the column hides it from the index** → full table scan. Rewrite as a range (4.5) |
| 4.7a | `… WHERE full_name LIKE 'Ra%'` | **range** | idx_customers_name | 1 | Using where; Using index | prefix pattern = range on the B-tree |
| 4.7b | `… WHERE full_name LIKE '%Singh%'` | **index** | idx_customers_name | 18 | Using where; Using index | leading `%` → no seek possible; full index scan |
| 4.8 before | `… FROM customers WHERE city = 'Mohali'` | **ALL** | NULL | 18 | Using where | no index on city |
| 4.8 after `CREATE INDEX idx_customers_city` | same query | **ref** | idx_customers_city | 3 | — | index lookup; the script then drops the index again |

Join types from best to worst: `const` → `eq_ref` → `ref` → `range` → `index` (full index scan) → `ALL` (full table scan).

## 5. When an index is NOT used (even if it exists)

1. **Function or expression on the column:** `YEAR(payment_date) = 2026` (4.6). Use `payment_date BETWEEN '2026-01-01' AND '2026-12-31'`.
2. **Leading wildcard:** `LIKE '%Singh%'` (4.7b).
3. **Leftmost prefix missing** in a composite index (4.4).
4. **Very small tables or low selectivity:** if a filter matches a large share of rows (e.g. `lifecycle_status = 'ACTIVE'` matches 31 of 32 units), a full scan is cheaper and the optimizer correctly ignores the index.
5. **Type mismatch:** comparing an INT column with a string, or using a different collation, can prevent index use.
6. **OR across different columns** often prevents a single index range (MySQL may use index-merge or fall back to a scan).

## 6. Optimizations applied in the SQL

| Technique | Where |
|---|---|
| Aggregate each child table in its own derived table **before** joining (avoids row multiplication and needless work) | `vw_booking_financial_summary`, `vw_equipment_revenue` |
| `EXISTS` / `NOT EXISTS` instead of `COUNT(*) > 0`. They stop at the first match | availability (B3), inventory view |
| `UNION ALL` instead of `UNION` when duplicates are impossible (no sort/dedup step) | U2 ledger, verification script |
| Date ranges written as `col BETWEEN x AND y`, never `YEAR(col)` | reports B10, B21 |
| Business date read once into a variable / derived table, not per row | views (`CROSS JOIN (SELECT business_date …) s`), procedures |
| Row-level locks on exactly one unit (`FOR UPDATE` by primary key) instead of table locks | `sp_create_booking`, triggers |

## 7. Trying it in Workbench

- Put the cursor on any `SELECT` and choose **Query → Explain Current Statement** (or the magnifying-glass "Explain" icon on the editor toolbar) to get **Visual Explain**: a diagram with boxes coloured by cost.
- `EXPLAIN ANALYZE <query>` (MySQL 8.0.18+) really runs the query and prints the measured rows and loops per step (section I9 of the script).
- `SHOW INDEX FROM booking_items;` lists the index cardinality estimates.
