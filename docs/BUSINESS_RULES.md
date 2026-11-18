# Business Rules and Conventions

Each rule shows **where it is enforced**: CHECK = table constraint, FK = foreign key, UQ = unique key, TRG = trigger, SP = stored procedure, VIEW = derived in a view, FN = stored function.

## 1. Time conventions

| ID | Rule | Enforced by |
|---|---|---|
| T1 | "Today" is the **business date** in `system_settings.business_date` (2026-11-20 in the demo). If it is NULL, the real `CURDATE()` is used. Change it with `CALL sp_set_business_date('YYYY-MM-DD')`. | `fn_business_date()`, all views |
| T2 | Rental periods are **inclusive**. A booking from 10-Nov to 12-Nov is **3** rental days: `DATEDIFF(end, start) + 1`. | `fn_rental_days` |
| T3 | Two periods overlap when `start1 <= end2 AND start2 <= end1`. Because both ends are inclusive, a machine returned on day *d* can start a new rental on day *d + 1*. The return day is used for check-in and inspection. | `fn_unit_conflict` |
| T4 | A booking cannot start before today and cannot last more than `max_rental_days` (180). | SP + TRG `trg_bookings_bi` |
| T5 | Return dates and payment dates cannot be later than today. | TRG |

## 2. Equipment and availability

| ID | Rule | Enforced by |
|---|---|---|
| E1 | A **model** (e.g. JCB 3DX Super) and a **unit** (one physical JCB with serial number JCB3DXS-2310457) are different entities. Units are booked; models carry prices. | schema |
| E2 | Asset tags and serial numbers are unique. | UQ |
| E3 | A unit's stored `lifecycle_status` is only ACTIVE or RETIRED. RETIRED requires a `retired_date`. | CHECK |
| E4 | Day-to-day state (AVAILABLE, RESERVED, ON_RENT, IN_MAINTENANCE, RETIRED) is **derived** from bookings and maintenance, never stored, so it cannot get out of sync. | VIEW `vw_equipment_inventory` |
| E5 | A unit is **available for a period** only if it is ACTIVE, already purchased, and no live booking item or maintenance job overlaps the period. | FN `fn_unit_conflict`, SP `sp_check_availability` |
| E6 | How long a booking item blocks its unit: **returned** → start … return date; **ACTIVE and overdue** → start … indefinitely (until it is physically back); **otherwise** → start … expected return date. **CANCELLED** bookings block nothing. | FN |
| E7 | Retired units cannot be booked or scheduled for maintenance. Their history is kept. | FN, FK RESTRICT |

## 3. Bookings

| ID | Rule | Enforced by |
|---|---|---|
| B1 | **No double booking:** a unit cannot be in two overlapping live bookings. | TRG `trg_booking_items_bi` (+ row lock), SP |
| B2 | A booking with several machines is **all or nothing**: if one machine is unavailable, nothing is allocated. | SP transaction + EXIT HANDLER |
| B3 | Concurrent requests for the same unit are serialised by locking the unit row (`SELECT … FOR UPDATE`). Units are locked in ascending id order to avoid deadlocks. | SP + TRG |
| B4 | Only **active** customers can book. | SP + TRG |
| B5 | Only an active **RENTAL_AGENT** or **MANAGER** can create bookings through the procedure. | SP |
| B6 | Lifecycle: `RESERVED → ACTIVE → COMPLETED` or `RESERVED → CANCELLED`. No other transitions are allowed. | TRG `trg_bookings_bu` |
| B7 | A new booking must start as RESERVED. Machines can be added only while RESERVED. | TRG |
| B8 | Customer and dates are frozen after creation. To change a plan, cancel and re-book. | TRG |
| B9 | **Handover (→ ACTIVE)** requires at least one machine, today inside the rental period, and the deposit HELD (if a deposit is required). | TRG |
| B10 | **COMPLETED** only when every machine has been returned. The booking is set to COMPLETED automatically when the last machine comes back. | TRG `trg_equipment_returns_ai`, `trg_bookings_bu` |
| B11 | Only RESERVED bookings can be cancelled. Cancelling needs a reason and records the date. | SP `sp_cancel_booking`, TRG, CHECK |
| B12 | Every status change is written to `booking_status_log` with time and MySQL user. | TRG |
| B13 | The same unit cannot appear twice in one booking. | UQ (booking_id, equipment_id) |

## 4. Pricing and charges

| ID | Rule | Enforced by |
|---|---|---|
| P1 | **Daily pricing.** Rental charge = Σ(agreed daily rate of each unit) × rental days. Weekly/monthly tariffs are not modelled. | FN `fn_booking_rental_charge`, VIEW |
| P2 | The agreed rate is copied from the model's list price at booking time (`booking_items.agreed_daily_rate`). Later price changes do not affect existing bookings. | SP (snapshot) |
| P3 | **Early return** does not reduce the charge: the booked period is billed. | FN |
| P4 | **Late fee** = late days × agreed daily rate × `late_fee_multiplier` (1.5). Late days = `GREATEST(0, return_date − expected_return_date)`. | FN `fn_late_charge`, TRG validates the stored value |
| P5 | The late fee and damage charge are stored on the return record because they are financial facts fixed at that moment (the policy may change later). | schema |
| P6 | A GOOD return has a damage charge of 0. Any damage needs a description. | CHECK |
| P7 | A MAJOR_DAMAGE return automatically schedules a 7-day corrective repair from the next day, if the unit is free. Otherwise the clerk is told to schedule it manually. | SP `sp_return_equipment` |
| P8 | A machine can be returned only once per booking. | UQ + SP |
| P9 | Cancelled bookings carry no charge. | FN, VIEW |

## 5. Security deposits

| ID | Rule | Enforced by |
|---|---|---|
| D1 | Every non-government booking gets one deposit = Σ(model deposit per unit). **Government customers are exempt.** | SP |
| D2 | At most one deposit per booking. | UQ |
| D3 | Money invariant: `refunded + retained ≤ collected ≤ required`, all ≥ 0. | CHECK |
| D4 | The status must agree with the amounts (PENDING: nothing collected; HELD: collected, nothing returned; REFUNDED: all returned; PARTIALLY_REFUNDED: some kept, rest returned; FORFEITED: all kept; CANCELLED: never collected). | CHECK `chk_deposits_status` |
| D5 | Retained money must have a reason and may not exceed what the customer owes. | CHECK + TRG |
| D6 | Settlement happens only after the booking is COMPLETED: retain `LEAST(collected, unpaid balance)`, refund the rest. | SP `sp_settle_deposit` |
| D7 | Cancelling a RESERVED booking: PENDING deposit → CANCELLED, HELD deposit → fully REFUNDED. | SP |
| D8 | Settled or cancelled deposit records are final. | TRG |
| D9 | A deposit is a **liability**, not revenue, so it is kept in its own table and not in `payments`. Only the retained part counts as money received against charges. | design |

## 6. Payments and balances

| ID | Rule | Enforced by |
|---|---|---|
| M1 | Amount > 0. Non-cash payments need a unique reference number. | CHECK, UQ |
| M2 | Only `COMPLETED` payments count as received. PENDING/FAILED/REFUNDED do not. | VIEW, FN |
| M3 | **No overpayment:** completed payments + retained deposit ≤ total charges. | SP + TRG (insert and status change) |
| M4 | No payments on cancelled bookings. Advance payments are marked REFUNDED when a booking is cancelled. | SP + TRG |
| M5 | Amount and booking of a payment cannot be edited. Status transitions: PENDING → COMPLETED/FAILED, COMPLETED → REFUNDED. | TRG |
| M6 | `total_charges = rental + late fees + damage`; `amount_received = completed payments + retained deposit`; `balance_due = total_charges − amount_received`. | VIEW `vw_booking_financial_summary` |

## 7. Maintenance

| ID | Rule | Enforced by |
|---|---|---|
| X1 | SCHEDULED jobs **block bookings** for their planned window, but the machine still counts as AVAILABLE today (planned ≠ unavailable now). | FN, VIEW |
| X2 | IN_PROGRESS jobs make the machine unavailable from `actual_start` to `scheduled_end`, or indefinitely if the job has overrun. | FN |
| X3 | Maintenance cannot overlap a live booking or another job on the same unit, and cannot be scheduled in the past. | SP + TRG |
| X4 | Lifecycle: SCHEDULED → IN_PROGRESS/CANCELLED, IN_PROGRESS → COMPLETED. The actual dates must match the status. | TRG + CHECK |
| X5 | Only staff with role TECHNICIAN can be assigned. NULL means an external workshop. | TRG |
| X6 | Preventive service is **usage-based**: due when the rental days since the last completed PREVENTIVE job reach the model's `service_interval_rental_days` (DUE_SOON within 5 days). | VIEW `vw_maintenance_summary` |

## 8. Data protection and history

| ID | Rule | Enforced by |
|---|---|---|
| H1 | Customers, units, bookings, payments, returns and maintenance records cannot be deleted while history refers to them (**ON DELETE RESTRICT**). Deactivate (`is_active = FALSE`) or retire instead. | FK |
| H2 | Optional staff references (manager, technician) become NULL if a staff row is ever deleted (**ON DELETE SET NULL**). | FK |
| H3 | Key changes propagate (**ON UPDATE CASCADE**), although surrogate keys are never changed in practice. | FK |
| H4 | Sensitive operations are meant to go through procedures. `12_dcl_security.sql` shows roles that get EXECUTE on procedures and SELECT on views, but no direct INSERT on bookings, payments or returns. | DCL (optional) |

## 9. Known MySQL-specific notes

- MySQL forbids a CHECK constraint on a column used by an `ON DELETE SET NULL` FK (error 3823). So "a staff member cannot be their own manager" is a documented rule, not a constraint.
- A trigger cannot lock a table that the triggering statement itself is reading (error 1442). So booking items must be inserted with `VALUES`, not `INSERT … SELECT FROM equipment_units`. The procedure inserts them row by row.
- In MySQL a failed statement inside a transaction does **not** roll back the transaction automatically. The procedures use `DECLARE EXIT HANDLER … ROLLBACK; RESIGNAL;`.
