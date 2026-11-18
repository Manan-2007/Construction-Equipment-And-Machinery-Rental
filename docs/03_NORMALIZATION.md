# 03 · Normalization

This document starts from the paper rental slip the company used before the database and normalises it step by step to 3NF and BCNF, using real values from our seed data.

## 1. Unnormalized form (UNF): the old rental slip

One row per rental agreement, with machines as a **repeating group**:

| slip_no | date | customer | cust_phone | cust_address | agent | start | end | machines (repeating) | deposit | payments (repeating) |
|---|---|---|---|---|---|---|---|---|---|---|
| 17 | 08-11-2026 | Gill Infrastructure Pvt Ltd, Harpreet Singh Gill | +919876501001 | SCO 45, Sector 70, Mohali 160071 | Neha Sharma | 10-11-2026 | 29-11-2026 | CER-EXC-001 Caterpillar CAT 320 Excavators ₹14,000; CER-BHL-001 JCB 3DX Super Backhoe ₹5,500; CER-DMP-001 Tata Signa tipper ₹7,500 | 1,45,000 held | 10-11 card ₹2,00,000 FAILED; 10-11 RTGS ₹2,00,000 OK |
| 18 | 01-11-2026 | Shivalik Constructions, Karan Thakur | +919876501005 | Plot 9, VIP Road, Zirakpur 140603 | Gurpreet Kaur | 03-11-2026 | 16-11-2026 | CER-EXC-003 Komatsu PC200-8 ₹13,000; CER-FRK-001 Godrej GX 300 ₹2,500 (returned 16-11) | 85,000 held | 03-11 UPI ₹1,00,000 |

Problems:
- `machines` and `payments` hold **lists** (not atomic). "How many times was CER-EXC-001 rented?" cannot be answered with SQL.
- Address is one composite text, so "customers in Mohali" needs string parsing.
- The customer name, phone and address are copied onto every slip of that customer.

## 2. First normal form (1NF)

Rule: every attribute holds **atomic** values, there are **no repeating groups**, and each row is identified by a key.

Flatten the machine list into one row per (slip, machine) and split composite attributes:

**RENTAL_1NF**(slip_no, machine_tag, booking_date, customer_name, organisation, cust_phone, address_line, city, pincode, agent_name, agent_role, start_date, end_date, model_name, manufacturer, category, list_rate, agreed_rate, deposit_per_unit, return_date, return_condition, late_charge, …)

| slip_no | machine_tag | customer_name | cust_phone | city | agent_name | start | end | model_name | manufacturer | category | agreed_rate | return_date |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 17 | CER-EXC-001 | Gill Infrastructure | +919876501001 | Mohali | Neha Sharma | 2026-11-10 | 2026-11-29 | CAT 320 | Caterpillar | Excavators | 14000 | NULL |
| 17 | CER-BHL-001 | Gill Infrastructure | +919876501001 | Mohali | Neha Sharma | 2026-11-10 | 2026-11-29 | 3DX Super | JCB | Backhoe Loaders | 5500 | NULL |
| 17 | CER-DMP-001 | Gill Infrastructure | +919876501001 | Mohali | Neha Sharma | 2026-11-10 | 2026-11-29 | Signa 2823.K | Tata Motors | Dump Trucks | 7500 | NULL |
| 18 | CER-EXC-003 | Shivalik Constructions | +919876501005 | Zirakpur | Gurpreet Kaur | 2026-11-03 | 2026-11-16 | PC200-8 | Komatsu | Excavators | 13000 | NULL |
| 18 | CER-FRK-001 | Shivalik Constructions | +919876501005 | Zirakpur | Gurpreet Kaur | 2026-11-03 | 2026-11-16 | GX 300 Diesel | Godrej | Forklifts | 2500 | 2026-11-16 |

Payments are moved to their own 1NF relation, because a slip has many payments independently of its machines (mixing them would multiply rows):
**PAYMENT_1NF**(slip_no, payment_no, amount, payment_date, method, status, reference_no)

**Candidate key of RENTAL_1NF:** {slip_no, machine_tag}. A machine appears at most once per slip.

### Functional dependencies in RENTAL_1NF

| FD | Meaning |
|---|---|
| FD1 slip_no → booking_date, customer_phone, agent_name, start_date, end_date, site_address | facts of the agreement |
| FD2 customer_phone → customer_name, organisation, address_line, city, pincode | facts of the customer (phone is unique) |
| FD3 agent_name → agent_role (in practice staff_id → name, role) | facts of the employee |
| FD4 machine_tag → model_name, manufacturer, serial_number, purchase_date, depot | facts of the physical unit |
| FD5 {manufacturer, model_name} → category, list_rate, deposit_per_unit | facts of the model |
| FD6 category → category_description | facts of the category |
| FD7 {slip_no, machine_tag} → agreed_rate, return_date, return_condition, late_charge, damage_charge | facts of *this machine in this rental* |

### Anomalies still present in 1NF

| Anomaly | Example from our data |
|---|---|
| **Insertion** | The new generator CER-GEN-005 (bought 01-Oct-2026) cannot be recorded until someone rents it, because slip_no is part of the key and cannot be NULL. The empty category *Tower Cranes* cannot be stored at all. |
| **Update** | When the CAT 320 list price rose from ₹14,000 to ₹15,000, every row with model CAT 320 would need updating, and a missed row leaves two "current prices". If Gill Infrastructure changes its phone number, all its rows across many slips must change. |
| **Deletion** | Deleting slip 18 (say it was entered by mistake) deletes the only row that says CER-FRK-001 is a *Godrej GX 300 Diesel at Mohali yard*. The machine's existence is lost with the rental. |
| **Redundancy** | Gill Infrastructure's name/phone/address is repeated 3 times in slip 17 alone. |

## 3. Second normal form (2NF)

Rule: 1NF **and** no non-key attribute depends on only **part** of a composite candidate key.

The key is {slip_no, machine_tag}, and FD1 and FD4 are **partial dependencies**:
- `booking_date, customer…, agent…, start_date, end_date` depend on **slip_no alone**;
- `model_name, manufacturer, …` depend on **machine_tag alone**.

Decompose:

| Relation | Key | Holds |
|---|---|---|
| BOOKING_2NF(slip_no, booking_date, customer_phone, customer_name, organisation, address_line, city, pincode, agent_name, agent_role, start_date, end_date, site_address) | slip_no | FD1 (+ FD2, FD3 still inside) |
| UNIT_2NF(machine_tag, serial_number, manufacturer, model_name, category, category_description, list_rate, deposit_per_unit, purchase_date, depot) | machine_tag | FD4 (+ FD5, FD6 still inside) |
| BOOKING_ITEM_2NF(slip_no, machine_tag, agreed_rate, return_date, return_condition, late_charge, damage_charge) | {slip_no, machine_tag} | FD7 only: every attribute depends on the **whole** key |

The decomposition is **lossless**: each split shares a key of one side (`slip_no` is the key of BOOKING_2NF, `machine_tag` is the key of UNIT_2NF), so joining back on that attribute reproduces exactly the original rows.

Fixed by 2NF: a new machine can now be inserted into UNIT_2NF without a rental, and deleting a booking no longer deletes the machine's description.

## 4. Third normal form (3NF)

Rule: 2NF **and** no **transitive dependency**, i.e. no non-key attribute determines another non-key attribute. (Equivalently, for every FD X → A, either X is a superkey or A is a prime attribute.)

Remaining transitive dependencies:

| Relation | Transitive chain | Fix |
|---|---|---|
| BOOKING_2NF | slip_no → customer_phone → customer_name, address… | move customer facts to **CUSTOMERS**; keep `customer_id` FK |
| BOOKING_2NF | slip_no → agent → agent_role | move to **STAFF**; keep `created_by_staff_id` FK |
| UNIT_2NF | machine_tag → (manufacturer, model_name) → category, list_rate, deposit | move to **EQUIPMENT_MODELS**; keep `model_id` FK |
| UNIT_2NF | … → category → category_description | move to **EQUIPMENT_CATEGORIES** |
| UNIT_2NF | machine_tag → depot → depot city/phone | move to **DEPOTS** |
| BOOKING_ITEM_2NF | {slip, machine} → return_date, condition, charges exist only after return; mixing them leaves NULL-heavy rows for future bookings | separate **EQUIPMENT_RETURNS** (1 : 0..1); not strictly a 3NF violation, but it removes NULL columns and lets the UNIQUE key stop duplicate returns |

Surrogate keys (`customer_id`, `staff_id`, `model_id`, `equipment_id`, `booking_id`, `booking_item_id`) replace the natural keys. The natural keys remain as **UNIQUE** candidate keys: `customers.phone`, `equipment_units.serial_number` and `asset_tag`, (`manufacturer`, `model_name`), (`booking_id`, `equipment_id`).

Result: the final schema of 14 tables (see `02_ER_MODEL_EXPLANATION.md` §4).

## 5. BCNF check

BCNF: for **every** non-trivial FD X → Y, X must be a superkey.

| Table | Determinants (left sides of FDs) | Superkey? |
|---|---|---|
| customers | customer_id; phone (UNIQUE); email (UNIQUE) | all candidate keys ✔ |
| equipment_models | model_id; {manufacturer, model_name} (UNIQUE) | ✔ |
| equipment_units | equipment_id; asset_tag; serial_number | ✔ |
| booking_items | booking_item_id; {booking_id, equipment_id} (UNIQUE) | ✔ |
| security_deposits | deposit_id; booking_id (UNIQUE) | ✔ |
| equipment_returns | return_id; booking_item_id (UNIQUE) | ✔ |
| depots, staff, categories, bookings, payments, maintenance_records, booking_status_log | their PK (+ unique phone/email/name/reference) | ✔ |

No table has a dependency whose left side is not a candidate key, so the schema is in **BCNF**, which implies 3NF. The decomposition also **preserves dependencies**: every FD in §2 can be checked inside a single table (FD2 in customers, FD5 in equipment_models, FD7 in booking_items/equipment_returns, …).

**About `system_settings`:** a single-row table (CHECK settings_id = 1). Its attributes are policy values of the whole system, not facts about any entity, so it does not violate any normal form.

## 6. Values that look redundant but are not normalisation errors

| Stored value | Why it is correct to store it |
|---|---|
| `booking_items.agreed_daily_rate` (copy of `equipment_models.daily_rate`) | It is a **different fact**: the price agreed *on the booking date*, not the current list price. The FD is {booking_id, equipment_id} → agreed_daily_rate, not model_id → agreed_daily_rate. Our seed data proves the difference: the CAT 320 list price is now ₹15,000, but bookings 1, 6, 13 and 17 were agreed at ₹14,000, and the government contract (booking 20) got the dozer at ₹15,000 against a ₹16,000 list price. Without the snapshot, a price change would rewrite past invoices. |
| `security_deposits.required_amount` | Snapshot of the deposits agreed at booking time (models' deposits may change). |
| `equipment_returns.late_charge` | A financial fact fixed at return time. The late-fee multiplier in `system_settings` can change later; the bill already issued must not. (A trigger checks that it matches the formula when inserted.) |
| `equipment_returns.damage_charge` | Decided by the inspecting staff member, so it cannot be derived from other data. |
| Manufacturer name repeated in several models ("JCB" twice, "Caterpillar" in one model) | Repetition of a **value** is not redundancy of a **fact**. "JCB" has no further attributes in our design, so there is no FD manufacturer → X to violate. If we later stored a dealer phone per manufacturer, a MANUFACTURERS table would become necessary. |
| City "Mohali" repeated in customers, depots | Same reasoning: city is an attribute value. A CITIES table would only be needed if cities carried their own facts. |

## 7. Values deliberately NOT stored (derived)

| Derived value | Computed by |
|---|---|
| rental days | `DATEDIFF(expected_return_date, start_date) + 1` / `fn_rental_days` |
| line total, booking rental charge | `vw_booking_financial_summary`, `fn_booking_rental_charge` |
| amount paid, balance due | view + `fn_booking_amount_received` |
| current equipment state (available/rented/…) | `vw_equipment_inventory` |
| days overdue, accrued late fee | `vw_overdue_rentals` |
| last service date, usage since service | `vw_maintenance_summary` |

Storing any of these would create an **update anomaly**: for example a stored "line_total" would be wrong the moment someone corrected a rate. The usual reason to denormalise, performance, does not apply at this data volume.

## 8. Summary

| Stage | Relations | Problem removed |
|---|---|---|
| UNF | 1 slip with repeating groups | — |
| 1NF | RENTAL_1NF, PAYMENT_1NF | repeating groups, composite address |
| 2NF | BOOKING, UNIT, BOOKING_ITEM, PAYMENT | partial dependencies on {slip_no, machine_tag} |
| 3NF / BCNF | 14 tables | transitive dependencies (customer, staff, model, category, depot) |

The final design is in **BCNF**. The only repeated monetary values are intentional historical snapshots, and derived values are computed rather than stored.
