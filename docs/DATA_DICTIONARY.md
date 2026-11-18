# Data Dictionary

Generated from `information_schema` of the installed `construction_rental_db` database (MySQL), so the types, keys, nullability and defaults below match the real schema. The *Meaning* column was written by the team.

**Key column:** PK = primary key, FK = foreign key (target shown), UQ = unique, IDX = part of a non-unique index.  
**Engine / charset:** every table is InnoDB with utf8mb4 / utf8mb4_0900_ai_ci. Money is `DECIMAL`, never FLOAT.

## Tables at a glance

| # | Table | Purpose | Columns |
|---|-------|---------|---------|
| 1 | [`system_settings`](#system_settings) | Single-row configuration: the business date used as 'today' by every view and procedure, the late-fee multiplier and the maximum rental length. | 4 |
| 2 | [`depots`](#depots) | Company yards where machines are parked when they are not on rent. | 5 |
| 3 | [`staff`](#staff) | Employees. `manager_id` points to another staff row (recursive relationship, used for the SELF JOIN demo). | 8 |
| 4 | [`customers`](#customers) | Individuals, companies and government bodies that rent machines. | 12 |
| 5 | [`equipment_categories`](#equipment_categories) | Broad machine families (Excavators, Cranes, ...). | 3 |
| 6 | [`equipment_models`](#equipment_models) | A type of machine from one manufacturer (e.g. JCB 3DX Super) with its current list price, deposit and service interval. | 10 |
| 7 | [`equipment_units`](#equipment_units) | One physical machine with its own asset tag and serial number. Availability is derived, not stored here. | 11 |
| 8 | [`bookings`](#bookings) | Rental agreement header: who rents, for which inclusive period, and the lifecycle status. | 10 |
| 9 | [`booking_items`](#booking_items) | Junction table resolving BOOKING M:N EQUIPMENT_UNIT; stores the agreed price snapshot. | 4 |
| 10 | [`security_deposits`](#security_deposits) | Refundable deposit for a booking (0 or 1 per booking) and how it was settled. | 10 |
| 11 | [`payments`](#payments) | Money received from customers against rental, late and damage charges. | 8 |
| 12 | [`equipment_returns`](#equipment_returns) | Return of one booking item (0 or 1 per item), which supports partial returns. Late and damage charges are fixed here. | 9 |
| 13 | [`maintenance_records`](#maintenance_records) | Planned and actual maintenance jobs; SCHEDULED and IN_PROGRESS jobs block bookings. | 12 |
| 14 | [`booking_status_log`](#booking_status_log) | Audit trail of booking status changes, written automatically by triggers. | 6 |

## system_settings

Single-row configuration: the business date used as 'today' by every view and procedure, the late-fee multiplier and the maximum rental length.

| Column | Data type | Key | Null? | Default | Meaning |
|---|---|---|---|---|---|
| `settings_id` | `tinyint` | PK | No | `1` | Always 1 (CHECK) - guarantees a single configuration row |
| `business_date` | `date` |  | Yes |  | Business 'today' (2026-11-20 in the demo); NULL = use the real CURDATE() |
| `late_fee_multiplier` | `decimal(4,2)` |  | No | `1.50` | Late fee per late day = agreed daily rate x this multiplier (1.50) |
| `max_rental_days` | `smallint` |  | No | `180` | Longest booking allowed, in days (180) |

**CHECK constraints**

| Constraint | Rule |
|---|---|
| `chk_settings_max_days` | `(max_rental_days between 1 and 730)` |
| `chk_settings_multiplier` | `((late_fee_multiplier >= 1.00) and (late_fee_multiplier <= 5.00))` |
| `chk_settings_single_row` | `(settings_id = 1)` |

## depots

Company yards where machines are parked when they are not on rent.

| Column | Data type | Key | Null? | Default | Meaning |
|---|---|---|---|---|---|
| `depot_id` | `int` | PK | No | `AUTO_INCREMENT` | Surrogate key of the yard |
| `depot_name` | `varchar(60)` | UQ | No |  | Unique yard name |
| `city` | `varchar(60)` |  | No |  | City of the yard |
| `state` | `varchar(60)` |  | No |  | State of the yard |
| `phone` | `varchar(13)` |  | No |  | Yard contact number, format +91XXXXXXXXXX |

**CHECK constraints**

| Constraint | Rule |
|---|---|
| `chk_depots_phone` | `regexp_like(phone,'^\\\\\\\\+91[6-9][0-9]{9}$')` |

## staff

Employees. `manager_id` points to another staff row (recursive relationship, used for the SELF JOIN demo).

| Column | Data type | Key | Null? | Default | Meaning |
|---|---|---|---|---|---|
| `staff_id` | `int` | PK | No | `AUTO_INCREMENT` | Surrogate key of the employee |
| `full_name` | `varchar(100)` |  | No |  | Employee name |
| `staff_role` | `enum('MANAGER','RENTAL_AGENT','TECHNICIAN','ACCOUNTANT')` |  | No |  | MANAGER, RENTAL_AGENT, TECHNICIAN or ACCOUNTANT - drives business permissions |
| `phone` | `varchar(13)` | UQ | No |  | Unique mobile number |
| `email` | `varchar(100)` | UQ | No |  | Unique work e-mail |
| `hire_date` | `date` |  | No |  | Date of joining |
| `manager_id` | `int` | FK → `staff.staff_id` | Yes |  | Staff member this person reports to (NULL for the top manager); SET NULL if the manager row is deleted |
| `is_active` | `tinyint(1)` |  | No | `1` | FALSE = left the company; kept for history instead of deleting |

**Foreign keys**

| Constraint | Column | References | ON DELETE | ON UPDATE |
|---|---|---|---|---|
| `fk_staff_manager` | `manager_id` | `staff` | SET NULL | CASCADE |

**CHECK constraints**

| Constraint | Rule |
|---|---|
| `chk_staff_email` | `(email like '%_@_%._%')` |
| `chk_staff_phone` | `regexp_like(phone,'^\\\\\\\\+91[6-9][0-9]{9}$')` |

## customers

Individuals, companies and government bodies that rent machines.

| Column | Data type | Key | Null? | Default | Meaning |
|---|---|---|---|---|---|
| `customer_id` | `int` | PK | No | `AUTO_INCREMENT` | Surrogate key of the customer |
| `customer_type` | `enum('INDIVIDUAL','COMPANY','GOVERNMENT')` |  | No |  | INDIVIDUAL, COMPANY or GOVERNMENT (government customers pay no deposit) |
| `full_name` | `varchar(100)` | IDX | No |  | Person's name, or contact person for an organisation |
| `organisation_name` | `varchar(150)` |  | Yes |  | Company / department name; mandatory unless INDIVIDUAL (CHECK) |
| `phone` | `varchar(13)` | UQ | No |  | Unique mobile number +91XXXXXXXXXX (CHECK with REGEXP) |
| `email` | `varchar(100)` | UQ | Yes |  | Unique e-mail (optional) |
| `address_line` | `varchar(200)` |  | No |  | Street address (atomic address parts = 1NF) |
| `city` | `varchar(60)` |  | No |  | City |
| `state` | `varchar(60)` |  | No |  | State / UT |
| `pincode` | `char(6)` |  | No |  | 6-digit Indian PIN code, cannot start with 0 |
| `registration_date` | `date` |  | No |  | Date the customer was registered |
| `is_active` | `tinyint(1)` |  | No | `1` | FALSE = blocked/deactivated; inactive customers cannot book |

**CHECK constraints**

| Constraint | Rule |
|---|---|
| `chk_customers_email` | `((email is null) or (email like '%_@_%._%'))` |
| `chk_customers_org` | `((customer_type = 'INDIVIDUAL') or (organisation_name is not null))` |
| `chk_customers_phone` | `regexp_like(phone,'^\\\\\\\\+91[6-9][0-9]{9}$')` |
| `chk_customers_pincode` | `regexp_like(pincode,'^[1-9][0-9]{5}$')` |

## equipment_categories

Broad machine families (Excavators, Cranes, ...).

| Column | Data type | Key | Null? | Default | Meaning |
|---|---|---|---|---|---|
| `category_id` | `int` | PK | No | `AUTO_INCREMENT` | Surrogate key of the category |
| `category_name` | `varchar(60)` | UQ | No |  | Unique category name |
| `description` | `varchar(255)` |  | Yes |  | What the category is used for |

## equipment_models

A type of machine from one manufacturer (e.g. JCB 3DX Super) with its current list price, deposit and service interval.

| Column | Data type | Key | Null? | Default | Meaning |
|---|---|---|---|---|---|
| `model_id` | `int` | PK | No | `AUTO_INCREMENT` | Surrogate key of the model |
| `category_id` | `int` | FK → `equipment_categories.category_id` | No |  | Category the model belongs to |
| `manufacturer` | `varchar(60)` | IDX | No |  | Maker (Caterpillar, JCB, ...); unique together with model_name |
| `model_name` | `varchar(60)` |  | No |  | Model designation |
| `capacity_spec` | `varchar(80)` |  | Yes |  | Key specification in words (weight, bucket size, kVA ...) |
| `engine_power_hp` | `smallint` |  | Yes |  | Engine power in horsepower |
| `fuel_type` | `enum('DIESEL','PETROL','ELECTRIC')` |  | No | `DIESEL` | DIESEL, PETROL or ELECTRIC |
| `daily_rate` | `decimal(10,2)` |  | No |  | CURRENT list price per day in INR (> 0) |
| `deposit_per_unit` | `decimal(10,2)` |  | No |  | Security deposit required per unit in INR |
| `service_interval_rental_days` | `smallint` |  | No | `30` | Preventive service due after this many rental days |

**Foreign keys**

| Constraint | Column | References | ON DELETE | ON UPDATE |
|---|---|---|---|---|
| `fk_models_category` | `category_id` | `equipment_categories` | RESTRICT | CASCADE |

**CHECK constraints**

| Constraint | Rule |
|---|---|
| `chk_models_deposit` | `(deposit_per_unit >= 0)` |
| `chk_models_hp` | `((engine_power_hp is null) or (engine_power_hp > 0))` |
| `chk_models_interval` | `(service_interval_rental_days > 0)` |
| `chk_models_rate` | `(daily_rate > 0)` |

## equipment_units

One physical machine with its own asset tag and serial number. Availability is derived, not stored here.

| Column | Data type | Key | Null? | Default | Meaning |
|---|---|---|---|---|---|
| `equipment_id` | `int` | PK | No | `AUTO_INCREMENT` | Surrogate key of the physical machine |
| `model_id` | `int` | FK → `equipment_models.model_id` | No |  | Which model this machine is |
| `depot_id` | `int` | FK → `depots.depot_id` | No |  | Home yard of the machine |
| `asset_tag` | `varchar(20)` | UQ | No |  | Company asset label, e.g. CER-EXC-001 (unique) |
| `serial_number` | `varchar(40)` | UQ | No |  | Manufacturer chassis/serial number (unique) |
| `manufacture_year` | `smallint` |  | No |  | Year of manufacture |
| `purchase_date` | `date` |  | No |  | Date bought; machine cannot be booked before it |
| `purchase_cost` | `decimal(12,2)` |  | No |  | Purchase price in INR |
| `condition_rating` | `enum('EXCELLENT','GOOD','FAIR','POOR')` |  | No | `GOOD` | EXCELLENT, GOOD, FAIR or POOR |
| `lifecycle_status` | `enum('ACTIVE','RETIRED')` | IDX | No | `ACTIVE` | ACTIVE or RETIRED; daily availability is derived, not stored |
| `retired_date` | `date` |  | Yes |  | Required when RETIRED, NULL when ACTIVE (CHECK) |

**Foreign keys**

| Constraint | Column | References | ON DELETE | ON UPDATE |
|---|---|---|---|---|
| `fk_units_depot` | `depot_id` | `depots` | RESTRICT | CASCADE |
| `fk_units_model` | `model_id` | `equipment_models` | RESTRICT | CASCADE |

**CHECK constraints**

| Constraint | Rule |
|---|---|
| `chk_units_cost` | `(purchase_cost > 0)` |
| `chk_units_retired` | `(((lifecycle_status = 'ACTIVE') and (retired_date is null)) or ((lifecycle_status = 'RETIRED') and (retired_date is not null) and (retired_date >= purchase_date)))` |
| `chk_units_year` | `(manufacture_year between 1990 and 2100)` |

## bookings

Rental agreement header: who rents, for which inclusive period, and the lifecycle status.

| Column | Data type | Key | Null? | Default | Meaning |
|---|---|---|---|---|---|
| `booking_id` | `int` | PK | No | `AUTO_INCREMENT` | Surrogate key of the booking |
| `customer_id` | `int` | FK → `customers.customer_id` | No |  | Customer who rents |
| `created_by_staff_id` | `int` | FK → `staff.staff_id` | No |  | Agent/manager who made the booking |
| `booking_date` | `date` |  | No |  | Date the booking was made (start_date >= booking_date) |
| `start_date` | `date` |  | No |  | First rental day (inclusive) |
| `expected_return_date` | `date` |  | No |  | Last rental day (inclusive); days = DATEDIFF + 1 |
| `booking_status` | `enum('RESERVED','ACTIVE','COMPLETED','CANCELLED')` | IDX | No | `RESERVED` | RESERVED -> ACTIVE -> COMPLETED, or RESERVED -> CANCELLED |
| `site_address` | `varchar(200)` |  | No |  | Construction site the machines go to |
| `cancelled_date` | `date` |  | Yes |  | Set only for CANCELLED bookings (CHECK) |
| `cancellation_reason` | `varchar(200)` |  | Yes |  | Mandatory when CANCELLED |

**Foreign keys**

| Constraint | Column | References | ON DELETE | ON UPDATE |
|---|---|---|---|---|
| `fk_bookings_customer` | `customer_id` | `customers` | RESTRICT | CASCADE |
| `fk_bookings_staff` | `created_by_staff_id` | `staff` | RESTRICT | CASCADE |

**CHECK constraints**

| Constraint | Rule |
|---|---|
| `chk_bookings_advance` | `(start_date >= booking_date)` |
| `chk_bookings_cancel` | `(((booking_status = 'CANCELLED') and (cancelled_date is not null) and (cancellation_reason is not null)) or ((booking_status <> 'CANCELLED') and (cancelled_date is null)))` |
| `chk_bookings_period` | `(expected_return_date >= start_date)` |

## booking_items

Junction table resolving BOOKING M:N EQUIPMENT_UNIT; stores the agreed price snapshot.

| Column | Data type | Key | Null? | Default | Meaning |
|---|---|---|---|---|---|
| `booking_item_id` | `int` | PK | No | `AUTO_INCREMENT` | Surrogate key of the booking line |
| `booking_id` | `int` | FK → `bookings.booking_id` | No |  | Booking this line belongs to |
| `equipment_id` | `int` | FK → `equipment_units.equipment_id` | No |  | Physical machine rented; (booking_id, equipment_id) is unique |
| `agreed_daily_rate` | `decimal(10,2)` |  | No |  | Price per day agreed at booking time (historical snapshot) |

**Foreign keys**

| Constraint | Column | References | ON DELETE | ON UPDATE |
|---|---|---|---|---|
| `fk_items_booking` | `booking_id` | `bookings` | RESTRICT | CASCADE |
| `fk_items_equipment` | `equipment_id` | `equipment_units` | RESTRICT | CASCADE |

**CHECK constraints**

| Constraint | Rule |
|---|---|
| `chk_items_rate` | `(agreed_daily_rate > 0)` |

## security_deposits

Refundable deposit for a booking (0 or 1 per booking) and how it was settled.

| Column | Data type | Key | Null? | Default | Meaning |
|---|---|---|---|---|---|
| `deposit_id` | `int` | PK | No | `AUTO_INCREMENT` | Surrogate key of the deposit |
| `booking_id` | `int` | FK → `bookings.booking_id`, UQ | No |  | Booking secured (UNIQUE -> at most one deposit per booking) |
| `required_amount` | `decimal(12,2)` |  | No |  | Sum of model deposits at booking time |
| `collected_amount` | `decimal(12,2)` |  | No | `0.00` | Money actually received (0 until collected) |
| `collected_date` | `date` |  | Yes |  | When it was collected |
| `refunded_amount` | `decimal(12,2)` |  | No | `0.00` | Returned to the customer |
| `retained_amount` | `decimal(12,2)` |  | No | `0.00` | Kept to cover late/damage/unpaid charges |
| `settled_date` | `date` |  | Yes |  | When the deposit was refunded/retained |
| `retention_reason` | `varchar(200)` |  | Yes |  | Why money was retained (mandatory if retained > 0) |
| `deposit_status` | `enum('PENDING','HELD','REFUNDED','PARTIALLY_REFUNDED','FORFEITED','CANCELLED')` | IDX | No | `PENDING` | PENDING, HELD, REFUNDED, PARTIALLY_REFUNDED, FORFEITED or CANCELLED - must match the amounts (CHECK) |

**Foreign keys**

| Constraint | Column | References | ON DELETE | ON UPDATE |
|---|---|---|---|---|
| `fk_deposits_booking` | `booking_id` | `bookings` | RESTRICT | CASCADE |

**CHECK constraints**

| Constraint | Rule |
|---|---|
| `chk_deposits_balance` | `((collected_amount <= required_amount) and ((refunded_amount + retained_amount) <= collected_amount))` |
| `chk_deposits_dates` | `((settled_date is null) or (collected_date is null) or (settled_date >= collected_date))` |
| `chk_deposits_nonneg` | `((required_amount > 0) and (collected_amount >= 0) and (refunded_amount >= 0) and (retained_amount >= 0))` |
| `chk_deposits_retention` | `((retained_amount = 0) or (retention_reason is not null))` |
| `chk_deposits_status` | `(((deposit_status = 'PENDING') and (collected_amount = 0) and (refunded_amount = 0) and (retained_amount = 0) and (settled_date is null)) or ((deposit_status = 'CANCELLED') and (collected_amount = 0) and (refunded_amount = 0) and (retained_amount = 0)) or (...` |

## payments

Money received from customers against rental, late and damage charges.

| Column | Data type | Key | Null? | Default | Meaning |
|---|---|---|---|---|---|
| `payment_id` | `int` | PK | No | `AUTO_INCREMENT` | Surrogate key of the payment |
| `booking_id` | `int` | FK → `bookings.booking_id` | No |  | Booking being paid for |
| `amount` | `decimal(12,2)` |  | No |  | Amount in INR (> 0) |
| `payment_date` | `date` | IDX | No |  | Date received |
| `payment_method` | `enum('CASH','UPI','CARD','BANK_TRANSFER','CHEQUE')` |  | No |  | CASH, UPI, CARD, BANK_TRANSFER or CHEQUE |
| `payment_type` | `enum('ADVANCE','BALANCE','LATE_FEE','DAMAGE')` |  | No |  | ADVANCE, BALANCE, LATE_FEE or DAMAGE (purpose) |
| `payment_status` | `enum('PENDING','COMPLETED','FAILED','REFUNDED')` |  | No | `COMPLETED` | PENDING, COMPLETED, FAILED or REFUNDED - only COMPLETED counts as received |
| `reference_no` | `varchar(40)` | UQ | Yes |  | UPI/NEFT/cheque reference; unique; required unless CASH |

**Foreign keys**

| Constraint | Column | References | ON DELETE | ON UPDATE |
|---|---|---|---|---|
| `fk_payments_booking` | `booking_id` | `bookings` | RESTRICT | CASCADE |

**CHECK constraints**

| Constraint | Rule |
|---|---|
| `chk_payments_amount` | `(amount > 0)` |
| `chk_payments_reference` | `((payment_method = 'CASH') or (reference_no is not null))` |

## equipment_returns

Return of one booking item (0 or 1 per item), which supports partial returns. Late and damage charges are fixed here.

| Column | Data type | Key | Null? | Default | Meaning |
|---|---|---|---|---|---|
| `return_id` | `int` | PK | No | `AUTO_INCREMENT` | Surrogate key of the return |
| `booking_item_id` | `int` | FK → `booking_items.booking_item_id`, UQ | No |  | Line returned (UNIQUE -> a machine is returned once per booking) |
| `return_date` | `date` | IDX | No |  | Actual return date |
| `received_by_staff_id` | `int` | FK → `staff.staff_id` | No |  | Staff member who inspected the machine |
| `return_condition` | `enum('GOOD','MINOR_DAMAGE','MAJOR_DAMAGE')` |  | No | `GOOD` | GOOD, MINOR_DAMAGE or MAJOR_DAMAGE |
| `late_charge` | `decimal(12,2)` |  | No | `0.00` | late days x agreed rate x multiplier, fixed at return time |
| `damage_charge` | `decimal(12,2)` |  | No | `0.00` | Repair cost charged to the customer (0 if GOOD) |
| `damage_description` | `varchar(255)` |  | Yes |  | What was damaged (required if not GOOD) |
| `return_notes` | `varchar(255)` |  | Yes |  | Free-text remarks |

**Foreign keys**

| Constraint | Column | References | ON DELETE | ON UPDATE |
|---|---|---|---|---|
| `fk_returns_item` | `booking_item_id` | `booking_items` | RESTRICT | CASCADE |
| `fk_returns_staff` | `received_by_staff_id` | `staff` | RESTRICT | CASCADE |

**CHECK constraints**

| Constraint | Rule |
|---|---|
| `chk_returns_charges` | `((late_charge >= 0) and (damage_charge >= 0))` |
| `chk_returns_damage` | `(((return_condition = 'GOOD') and (damage_charge = 0)) or ((return_condition <> 'GOOD') and (damage_description is not null)))` |

## maintenance_records

Planned and actual maintenance jobs; SCHEDULED and IN_PROGRESS jobs block bookings.

| Column | Data type | Key | Null? | Default | Meaning |
|---|---|---|---|---|---|
| `maintenance_id` | `int` | PK | No | `AUTO_INCREMENT` | Surrogate key of the job |
| `equipment_id` | `int` | FK → `equipment_units.equipment_id` | No |  | Machine being maintained |
| `technician_staff_id` | `int` | FK → `staff.staff_id` | Yes |  | In-house technician; NULL = external workshop |
| `related_return_id` | `int` | FK → `equipment_returns.return_id`, UQ | Yes |  | Return whose damage this job repairs (optional, unique) |
| `maintenance_type` | `enum('PREVENTIVE','CORRECTIVE','INSPECTION')` |  | No |  | PREVENTIVE, CORRECTIVE or INSPECTION |
| `maintenance_status` | `enum('SCHEDULED','IN_PROGRESS','COMPLETED','CANCELLED')` | IDX | No | `SCHEDULED` | SCHEDULED, IN_PROGRESS, COMPLETED or CANCELLED |
| `scheduled_start` | `date` |  | No |  | Planned first day |
| `scheduled_end` | `date` |  | No |  | Planned last day |
| `actual_start` | `date` |  | Yes |  | Real start (set when IN_PROGRESS) |
| `actual_end` | `date` |  | Yes |  | Real finish (set when COMPLETED) |
| `maintenance_cost` | `decimal(10,2)` |  | No | `0.00` | Cost to the company in INR |
| `description` | `varchar(255)` |  | No |  | Work done / planned |

**Foreign keys**

| Constraint | Column | References | ON DELETE | ON UPDATE |
|---|---|---|---|---|
| `fk_maint_equipment` | `equipment_id` | `equipment_units` | RESTRICT | CASCADE |
| `fk_maint_return` | `related_return_id` | `equipment_returns` | RESTRICT | CASCADE |
| `fk_maint_technician` | `technician_staff_id` | `staff` | SET NULL | CASCADE |

**CHECK constraints**

| Constraint | Rule |
|---|---|
| `chk_maint_actual_period` | `((actual_end is null) or (actual_end >= actual_start))` |
| `chk_maint_cost` | `(maintenance_cost >= 0)` |
| `chk_maint_sched_period` | `(scheduled_end >= scheduled_start)` |
| `chk_maint_status_dates` | `(((maintenance_status in ('SCHEDULED','CANCELLED')) and (actual_start is null) and (actual_end is null)) or ((maintenance_status = 'IN_PROGRESS') and (actual_start is not null) and (actual_end is null)) or ((maintenance_status = 'COMPLETED') and (actual_sta...` |

## booking_status_log

Audit trail of booking status changes, written automatically by triggers.

| Column | Data type | Key | Null? | Default | Meaning |
|---|---|---|---|---|---|
| `log_id` | `int` | PK | No | `AUTO_INCREMENT` | Surrogate key of the log entry |
| `booking_id` | `int` | FK → `bookings.booking_id` | No |  | Booking whose status changed |
| `old_status` | `varchar(20)` |  | Yes |  | Previous status (NULL for the first entry) |
| `new_status` | `varchar(20)` |  | No |  | New status |
| `changed_at` | `datetime` |  | No | `CURRENT_TIMESTAMP` | Timestamp of the change |
| `changed_by` | `varchar(100)` |  | No |  | MySQL account that made the change (CURRENT_USER()) |

**Foreign keys**

| Constraint | Column | References | ON DELETE | ON UPDATE |
|---|---|---|---|---|
| `fk_log_booking` | `booking_id` | `bookings` | RESTRICT | CASCADE |
