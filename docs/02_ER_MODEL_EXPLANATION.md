# 02 · ER Model Explanation

Diagram: [`diagrams/ER_Diagram.png`](../diagrams/ER_Diagram.png) (also `.pdf` and `.svg`). Notation: **Crow's Foot**.

| Symbol at a line end | Meaning |
|---|---|
| `‖` (two bars) | exactly one (mandatory) |
| `o|` (circle + bar) | zero or one (optional) |
| `|<` (bar + crow's foot) | one or many |
| `o<` (circle + crow's foot) | zero or many |

## 1. Conceptual model: entities

| Entity | Type | Identifier | Description |
|---|---|---|---|
| CUSTOMER | strong | customer_id | Individual, company or government department that rents machines |
| STAFF | strong | staff_id | Employee (manager, rental agent, technician, accountant) |
| DEPOT | strong | depot_id | Yard where machines are parked |
| EQUIPMENT_CATEGORY | strong | category_id | Machine family |
| EQUIPMENT_MODEL | strong | model_id (candidate key: manufacturer + model_name) | Type of machine with list price |
| EQUIPMENT_UNIT | strong | equipment_id (candidates: asset_tag, serial_number) | One physical machine |
| BOOKING | strong | booking_id | Rental agreement |
| BOOKING_ITEM | associative entity | booking_item_id (candidate: booking_id + equipment_id) | One machine inside one booking |
| SECURITY_DEPOSIT | dependent on BOOKING | deposit_id (candidate: booking_id) | Refundable money held for a booking |
| PAYMENT | dependent on BOOKING | payment_id | Money received |
| EQUIPMENT_RETURN | dependent on BOOKING_ITEM | return_id (candidate: booking_item_id) | Check-in of one machine |
| MAINTENANCE_RECORD | strong | maintenance_id | Service or repair job |
| BOOKING_STATUS_LOG | dependent on BOOKING | log_id | Audit entry |
| SYSTEM_SETTINGS | configuration (1 row) | settings_id | Business date and policy values; no relationships |

**Weak entities?** SECURITY_DEPOSIT, PAYMENT, EQUIPMENT_RETURN and BOOKING_STATUS_LOG cannot exist without their owner (total participation, existence dependency). A textbook design could model them as *weak entities* with partial keys, e.g. (booking_id, payment_no). We gave each one a **surrogate primary key** instead (`payment_id`, …) and kept the owner as a NOT NULL foreign key with `ON DELETE RESTRICT`. This is simpler to reference from other tables and is the usual MySQL practice. The existence dependency is still enforced by the NOT NULL FK.

## 2. Relationships, cardinality and participation

| # | Relationship | Cardinality | Participation | Implemented by |
|---|---|---|---|---|
| R1 | CATEGORY *classifies* MODEL | 1 : N | every model has exactly one category; a category may have none (Tower Cranes) | `equipment_models.category_id` NOT NULL FK |
| R2 | MODEL *is type of* UNIT | 1 : N | unit → exactly one model; model → zero or more units | `equipment_units.model_id` |
| R3 | DEPOT *parks* UNIT | 1 : N | unit → exactly one home depot | `equipment_units.depot_id` |
| R4 | CUSTOMER *places* BOOKING | 1 : N | booking → exactly one customer; customer → zero or more | `bookings.customer_id` |
| R5 | STAFF *creates* BOOKING | 1 : N | booking → exactly one staff member | `bookings.created_by_staff_id` |
| R6 | BOOKING *contains* UNIT | **M : N** | a booking has ≥ 1 unit; a unit appears in 0..N bookings over time | resolved by **BOOKING_ITEM** (two 1:N relationships) |
| R7 | BOOKING *secured by* SECURITY_DEPOSIT | **1 : 0..1** | government bookings have none | `security_deposits.booking_id` **UNIQUE** FK |
| R8 | BOOKING *paid by* PAYMENT | 1 : N | 0..N payments (advance, balance, failed attempts) | `payments.booking_id` |
| R9 | BOOKING_ITEM *returned via* EQUIPMENT_RETURN | **1 : 0..1** | no return yet = machine still out | `equipment_returns.booking_item_id` **UNIQUE** FK |
| R10 | STAFF *receives* EQUIPMENT_RETURN | 1 : N | every return has an inspecting staff member | `equipment_returns.received_by_staff_id` |
| R11 | UNIT *undergoes* MAINTENANCE_RECORD | 1 : N | 0..N jobs per unit | `maintenance_records.equipment_id` |
| R12 | STAFF *services* MAINTENANCE_RECORD | 0..1 : N | optional: NULL = external workshop | `technician_staff_id` NULL FK, ON DELETE SET NULL |
| R13 | EQUIPMENT_RETURN *repaired by* MAINTENANCE_RECORD | 0..1 : 0..1 | a damaged return may lead to one repair job | `maintenance_records.related_return_id` NULL **UNIQUE** FK |
| R14 | STAFF *manages* STAFF | 1 : N recursive | top manager has no manager | `staff.manager_id` NULL self-FK |
| R15 | BOOKING *audited in* BOOKING_STATUS_LOG | 1 : N | every booking has ≥ 1 log row | `booking_status_log.booking_id` |

## 3. The design decisions that matter

### 3.1 Model vs unit
A company can own three JCB 3DX Super machines. They share a price and specification (MODEL) but have different serial numbers, yards, condition and **availability** (UNIT). Booking a *model* would make it impossible to stop two customers from getting the same physical machine. So bookings point at **units**.

### 3.2 Why BOOKING_ITEM exists (the most important relationship)
BOOKING ↔ EQUIPMENT_UNIT is many-to-many: one booking can hold several machines, and over the year one machine is booked many times. A relational table cannot store a list in one column (1NF), so the M:N is resolved by the associative entity BOOKING_ITEM. It also stores facts that belong to the *pair* (booking, unit):
- `agreed_daily_rate`, the price for **this** unit in **this** booking;
- the anchor for EQUIPMENT_RETURN, so each machine can come back on a different day (**partial returns**);
- the row the double-booking check scans.

### 3.3 Where the deposit hangs
Options considered:
1. Deposit columns inside BOOKING. Rejected: about 40 % of the columns would be NULL for government bookings, and deposit settlement has its own lifecycle.
2. Deposit as a kind of PAYMENT. Rejected: a deposit is refundable money that belongs to the customer (a liability), while payments are revenue. Mixing them makes "income for October" wrong.
3. **Chosen:** separate SECURITY_DEPOSIT with a UNIQUE booking_id (1 : 0..1). It holds required, collected, refunded and retained amounts with CHECK constraints that keep them consistent.

Deposits are **not** linked to RETURNS or PAYMENTS directly. They relate only to the booking, and settlement is computed from the booking's totals. Linking them directly would create a cycle (deposit → return → item → booking → deposit) and redundant paths.

### 3.4 Availability is derived, not stored
There is no "status = RENTED" column on units. The state is computed from BOOKING_ITEM, EQUIPMENT_RETURN and MAINTENANCE_RECORD. A stored flag would need updating at every booking, return, cancellation and job, and one missed update would make it lie. A **future** booking also does not make a machine unavailable *today*, which a single flag cannot express.

### 3.5 Optional references use SET NULL; history uses RESTRICT
Deleting a customer who has bookings would destroy financial history, so FKs from history tables are `ON DELETE RESTRICT`. Records are deactivated (`is_active`) or retired (`lifecycle_status`) instead. Only optional "who did it" links (manager, technician) use `ON DELETE SET NULL`.

## 4. Logical (relational) schema

Underlined = PK, *italic* = FK. Full detail is in `DATA_DICTIONARY.md`.

- SYSTEM_SETTINGS(<u>settings_id</u>, business_date, late_fee_multiplier, max_rental_days)
- DEPOTS(<u>depot_id</u>, depot_name, city, state, phone)
- STAFF(<u>staff_id</u>, full_name, staff_role, phone, email, hire_date, *manager_id*, is_active)
- CUSTOMERS(<u>customer_id</u>, customer_type, full_name, organisation_name, phone, email, address_line, city, state, pincode, registration_date, is_active)
- EQUIPMENT_CATEGORIES(<u>category_id</u>, category_name, description)
- EQUIPMENT_MODELS(<u>model_id</u>, *category_id*, manufacturer, model_name, capacity_spec, engine_power_hp, fuel_type, daily_rate, deposit_per_unit, service_interval_rental_days)
- EQUIPMENT_UNITS(<u>equipment_id</u>, *model_id*, *depot_id*, asset_tag, serial_number, manufacture_year, purchase_date, purchase_cost, condition_rating, lifecycle_status, retired_date)
- BOOKINGS(<u>booking_id</u>, *customer_id*, *created_by_staff_id*, booking_date, start_date, expected_return_date, booking_status, site_address, cancelled_date, cancellation_reason)
- BOOKING_ITEMS(<u>booking_item_id</u>, *booking_id*, *equipment_id*, agreed_daily_rate)
- SECURITY_DEPOSITS(<u>deposit_id</u>, *booking_id*, required_amount, collected_amount, collected_date, refunded_amount, retained_amount, settled_date, retention_reason, deposit_status)
- PAYMENTS(<u>payment_id</u>, *booking_id*, amount, payment_date, payment_method, payment_type, payment_status, reference_no)
- EQUIPMENT_RETURNS(<u>return_id</u>, *booking_item_id*, return_date, *received_by_staff_id*, return_condition, late_charge, damage_charge, damage_description, return_notes)
- MAINTENANCE_RECORDS(<u>maintenance_id</u>, *equipment_id*, *technician_staff_id*, *related_return_id*, maintenance_type, maintenance_status, scheduled_start, scheduled_end, actual_start, actual_end, maintenance_cost, description)
- BOOKING_STATUS_LOG(<u>log_id</u>, *booking_id*, old_status, new_status, changed_at, changed_by)

## 5. ER-to-relational mapping steps used

| Mapping rule | Applied to |
|---|---|
| Strong entity → table with its PK | all entities |
| 1:N → FK on the "many" side | R1–R5, R8, R10–R12, R14, R15 |
| 1:1 / 1:0..1 → FK + UNIQUE on the optional side | R7 (deposit), R9 (return), R13 (repair) |
| M:N → new relation with FKs to both sides | R6 → booking_items |
| Recursive 1:N → self-referencing FK | R14 (staff.manager_id) |
| Multivalued / composite attributes → atomic columns | address → address_line, city, state, pincode |
| Derived attributes → not stored (computed in views) | rental days, line total, availability, balance due |

## 6. Inspecting the model in MySQL Workbench

No native `.mwb` file is shipped. Producing one would mean scripting the Workbench GUI, and a hand-made `.mwb` is not something we would fabricate. To get Workbench's own EER diagram from the installed database: **Database → Reverse Engineer… → choose your connection → select `construction_rental_db` → Execute → Finish**. Workbench draws all 14 tables with the 16 relationships. Save it with **File → Save Model** to get a `.mwb`. Step-by-step instructions, including what each screen should show, are in `WORKBENCH_SETUP.md` §11.
