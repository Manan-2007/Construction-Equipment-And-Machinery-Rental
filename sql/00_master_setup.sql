-- =====================================================================
--  CONSTRUCTION EQUIPMENT & MACHINERY RENTAL MANAGEMENT SYSTEM
--  File   : 00_master_setup.sql   (GENERATED - do not edit by hand)
--  Purpose: ONE file that installs the complete project in MySQL 8.0+.
--           It is the concatenation of, in this order:
--             01_create_database.sql   schema (DROPS + recreates the DB)
--             02_seed_data.sql         demo data
--             06_views.sql             8 views
--             07_procedures_functions.sql  7 functions + 14 procedures
--             08_triggers.sql          12 triggers (last, so the historical
--                                      seed data is loaded before them)
--  How    : MySQL Workbench -> File -> Open SQL Script -> this file ->
--           Execute (lightning icon). Takes a few seconds.
--  WARNING: running this file DELETES the existing construction_rental_db
--           database and everything in it, then rebuilds it from scratch.
--           That is also the official way to RESET the demo.
--  No SOURCE commands are used, so it works in the Workbench SQL editor
--  as well as in the mysql command-line client.
-- =====================================================================


-- #####################################################################
-- ##### BEGIN 01_create_database.sql
-- #####################################################################
-- =====================================================================
--  CONSTRUCTION EQUIPMENT & MACHINERY RENTAL MANAGEMENT SYSTEM
--  File   : 01_create_database.sql
--  Purpose: Create the database, all 14 tables, keys, constraints, indexes
--  Target : MySQL Server 8.0.16+ (CHECK constraints are enforced from 8.0.16)
--  Team   : Arshpreet Kaur (2510992817), Manan Kochhar (2510993803),
--           Atharv Bains (2510993832) - Chitkara University, DBMS 24CSE0209
-- ---------------------------------------------------------------------
--  WARNING: this script DROPS and re-creates `construction_rental_db`.
--  Run it only when you intend a clean (re)install of the project.
-- =====================================================================

DROP DATABASE IF EXISTS construction_rental_db;
CREATE DATABASE construction_rental_db
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_0900_ai_ci;

USE construction_rental_db;

-- ---------------------------------------------------------------------
-- 1. SYSTEM_SETTINGS  (single-row configuration table)
--    business_date = the "today" used by every report, view and procedure.
--    Fixing it (2026-11-20 in the seed) keeps demo scenarios such as
--    "overdue" or "future booking" correct no matter when the scripts run.
--    Set it to NULL to fall back to the real CURDATE().
-- ---------------------------------------------------------------------
CREATE TABLE system_settings (
    settings_id          TINYINT       NOT NULL DEFAULT 1,
    business_date        DATE          NULL,
    late_fee_multiplier  DECIMAL(4,2)  NOT NULL DEFAULT 1.50,
    max_rental_days      SMALLINT      NOT NULL DEFAULT 180,
    CONSTRAINT pk_system_settings PRIMARY KEY (settings_id),
    CONSTRAINT chk_settings_single_row CHECK (settings_id = 1),
    CONSTRAINT chk_settings_multiplier CHECK (late_fee_multiplier >= 1.00 AND late_fee_multiplier <= 5.00),
    CONSTRAINT chk_settings_max_days   CHECK (max_rental_days BETWEEN 1 AND 730)
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- 2. DEPOTS  (yards where machines are parked when not on rent)
-- ---------------------------------------------------------------------
CREATE TABLE depots (
    depot_id     INT          NOT NULL AUTO_INCREMENT,
    depot_name   VARCHAR(60)  NOT NULL,
    city         VARCHAR(60)  NOT NULL,
    state        VARCHAR(60)  NOT NULL,
    phone        VARCHAR(13)  NOT NULL,
    CONSTRAINT pk_depots PRIMARY KEY (depot_id),
    CONSTRAINT uq_depots_name UNIQUE (depot_name),
    CONSTRAINT chk_depots_phone CHECK (phone REGEXP '^\\+91[6-9][0-9]{9}$')
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- 3. STAFF  (employees; manager_id is a recursive / self relationship)
-- ---------------------------------------------------------------------
CREATE TABLE staff (
    staff_id     INT          NOT NULL AUTO_INCREMENT,
    full_name    VARCHAR(100) NOT NULL,
    staff_role   ENUM('MANAGER','RENTAL_AGENT','TECHNICIAN','ACCOUNTANT') NOT NULL,
    phone        VARCHAR(13)  NOT NULL,
    email        VARCHAR(100) NOT NULL,
    hire_date    DATE         NOT NULL,
    manager_id   INT          NULL,
    is_active    BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT pk_staff PRIMARY KEY (staff_id),
    CONSTRAINT uq_staff_phone UNIQUE (phone),
    CONSTRAINT uq_staff_email UNIQUE (email),
    CONSTRAINT chk_staff_phone CHECK (phone REGEXP '^\\+91[6-9][0-9]{9}$'),
    CONSTRAINT chk_staff_email CHECK (email LIKE '%_@_%._%'),
    -- Note: "manager_id <> staff_id" cannot be a CHECK here because MySQL forbids
    -- CHECK constraints on columns used by an ON DELETE SET NULL foreign key (error 3823).
    CONSTRAINT fk_staff_manager FOREIGN KEY (manager_id)
        REFERENCES staff (staff_id)
        ON DELETE SET NULL ON UPDATE CASCADE
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- 4. CUSTOMERS
--    Address is stored as atomic columns (1NF). Government customers are
--    exempt from security deposits (business rule BR-D1).
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    customer_id        INT          NOT NULL AUTO_INCREMENT,
    customer_type      ENUM('INDIVIDUAL','COMPANY','GOVERNMENT') NOT NULL,
    full_name          VARCHAR(100) NOT NULL,          -- person / contact person
    organisation_name  VARCHAR(150) NULL,              -- required for COMPANY / GOVERNMENT
    phone              VARCHAR(13)  NOT NULL,
    email              VARCHAR(100) NULL,
    address_line       VARCHAR(200) NOT NULL,
    city               VARCHAR(60)  NOT NULL,
    state              VARCHAR(60)  NOT NULL,
    pincode            CHAR(6)      NOT NULL,
    registration_date  DATE         NOT NULL,
    is_active          BOOLEAN      NOT NULL DEFAULT TRUE,
    CONSTRAINT pk_customers PRIMARY KEY (customer_id),
    CONSTRAINT uq_customers_phone UNIQUE (phone),
    CONSTRAINT uq_customers_email UNIQUE (email),
    CONSTRAINT chk_customers_phone   CHECK (phone REGEXP '^\\+91[6-9][0-9]{9}$'),
    CONSTRAINT chk_customers_email   CHECK (email IS NULL OR email LIKE '%_@_%._%'),
    CONSTRAINT chk_customers_pincode CHECK (pincode REGEXP '^[1-9][0-9]{5}$'),
    CONSTRAINT chk_customers_org     CHECK (customer_type = 'INDIVIDUAL' OR organisation_name IS NOT NULL)
) ENGINE = InnoDB;

CREATE INDEX idx_customers_name ON customers (full_name);

-- ---------------------------------------------------------------------
-- 5. EQUIPMENT_CATEGORIES
-- ---------------------------------------------------------------------
CREATE TABLE equipment_categories (
    category_id    INT          NOT NULL AUTO_INCREMENT,
    category_name  VARCHAR(60)  NOT NULL,
    description    VARCHAR(255) NULL,
    CONSTRAINT pk_equipment_categories PRIMARY KEY (category_id),
    CONSTRAINT uq_categories_name UNIQUE (category_name)
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- 6. EQUIPMENT_MODELS  (a TYPE of machine, e.g. "JCB 3DX Super")
--    daily_rate / deposit_per_unit are the CURRENT list prices; the price a
--    customer actually agreed to is copied into booking_items.
--    service_interval_rental_days: preventive service is due after this many
--    days of rental usage (usage-based servicing, like an hour meter).
-- ---------------------------------------------------------------------
CREATE TABLE equipment_models (
    model_id                      INT           NOT NULL AUTO_INCREMENT,
    category_id                   INT           NOT NULL,
    manufacturer                  VARCHAR(60)   NOT NULL,
    model_name                    VARCHAR(60)   NOT NULL,
    capacity_spec                 VARCHAR(80)   NULL,     -- e.g. '20 t operating weight, 1.0 m3 bucket'
    engine_power_hp               SMALLINT      NULL,
    fuel_type                     ENUM('DIESEL','PETROL','ELECTRIC') NOT NULL DEFAULT 'DIESEL',
    daily_rate                    DECIMAL(10,2) NOT NULL,
    deposit_per_unit              DECIMAL(10,2) NOT NULL,
    service_interval_rental_days  SMALLINT      NOT NULL DEFAULT 30,
    CONSTRAINT pk_equipment_models PRIMARY KEY (model_id),
    CONSTRAINT uq_models_make_name UNIQUE (manufacturer, model_name),
    CONSTRAINT chk_models_rate     CHECK (daily_rate > 0),
    CONSTRAINT chk_models_deposit  CHECK (deposit_per_unit >= 0),
    CONSTRAINT chk_models_hp       CHECK (engine_power_hp IS NULL OR engine_power_hp > 0),
    CONSTRAINT chk_models_interval CHECK (service_interval_rental_days > 0),
    CONSTRAINT fk_models_category FOREIGN KEY (category_id)
        REFERENCES equipment_categories (category_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

-- ---------------------------------------------------------------------
-- 7. EQUIPMENT_UNITS  (an individual PHYSICAL machine)
--    lifecycle_status only says whether the company still owns/operates the
--    unit. Day-to-day availability (available / reserved / on rent /
--    in maintenance) is NOT stored - it is DERIVED from bookings and
--    maintenance records, so it can never drift out of sync.
-- ---------------------------------------------------------------------
CREATE TABLE equipment_units (
    equipment_id      INT           NOT NULL AUTO_INCREMENT,
    model_id          INT           NOT NULL,
    depot_id          INT           NOT NULL,
    asset_tag         VARCHAR(20)   NOT NULL,     -- company label painted on the machine
    serial_number     VARCHAR(40)   NOT NULL,     -- manufacturer chassis / serial number
    manufacture_year  SMALLINT      NOT NULL,
    purchase_date     DATE          NOT NULL,
    purchase_cost     DECIMAL(12,2) NOT NULL,
    condition_rating  ENUM('EXCELLENT','GOOD','FAIR','POOR') NOT NULL DEFAULT 'GOOD',
    lifecycle_status  ENUM('ACTIVE','RETIRED') NOT NULL DEFAULT 'ACTIVE',
    retired_date      DATE          NULL,
    CONSTRAINT pk_equipment_units PRIMARY KEY (equipment_id),
    CONSTRAINT uq_units_asset_tag UNIQUE (asset_tag),
    CONSTRAINT uq_units_serial    UNIQUE (serial_number),
    CONSTRAINT chk_units_cost     CHECK (purchase_cost > 0),
    CONSTRAINT chk_units_year     CHECK (manufacture_year BETWEEN 1990 AND 2100),
    CONSTRAINT chk_units_retired  CHECK (
        (lifecycle_status = 'ACTIVE'  AND retired_date IS NULL) OR
        (lifecycle_status = 'RETIRED' AND retired_date IS NOT NULL AND retired_date >= purchase_date)),
    CONSTRAINT fk_units_model FOREIGN KEY (model_id)
        REFERENCES equipment_models (model_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_units_depot FOREIGN KEY (depot_id)
        REFERENCES depots (depot_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

CREATE INDEX idx_units_lifecycle ON equipment_units (lifecycle_status);

-- ---------------------------------------------------------------------
-- 8. BOOKINGS  (rental agreement header)
--    Rental period convention: INCLUSIVE dates. A booking from start_date to
--    expected_return_date is billed for DATEDIFF(end, start) + 1 days.
--    Lifecycle: RESERVED -> ACTIVE -> COMPLETED, or RESERVED -> CANCELLED.
-- ---------------------------------------------------------------------
CREATE TABLE bookings (
    booking_id            INT           NOT NULL AUTO_INCREMENT,
    customer_id           INT           NOT NULL,
    created_by_staff_id   INT           NOT NULL,
    booking_date          DATE          NOT NULL,
    start_date            DATE          NOT NULL,
    expected_return_date  DATE          NOT NULL,
    booking_status        ENUM('RESERVED','ACTIVE','COMPLETED','CANCELLED') NOT NULL DEFAULT 'RESERVED',
    site_address          VARCHAR(200)  NOT NULL,     -- construction site where machines go
    cancelled_date        DATE          NULL,
    cancellation_reason   VARCHAR(200)  NULL,
    CONSTRAINT pk_bookings PRIMARY KEY (booking_id),
    CONSTRAINT chk_bookings_period     CHECK (expected_return_date >= start_date),
    CONSTRAINT chk_bookings_advance    CHECK (start_date >= booking_date),
    CONSTRAINT chk_bookings_cancel     CHECK (
        (booking_status =  'CANCELLED' AND cancelled_date IS NOT NULL AND cancellation_reason IS NOT NULL) OR
        (booking_status <> 'CANCELLED' AND cancelled_date IS NULL)),
    CONSTRAINT fk_bookings_customer FOREIGN KEY (customer_id)
        REFERENCES customers (customer_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_bookings_staff FOREIGN KEY (created_by_staff_id)
        REFERENCES staff (staff_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

-- reports filter by status + period; also supports overlap searches
CREATE INDEX idx_bookings_status_period ON bookings (booking_status, start_date, expected_return_date);
CREATE INDEX idx_bookings_customer_date ON bookings (customer_id, booking_date);

-- ---------------------------------------------------------------------
-- 9. BOOKING_ITEMS  (junction: which physical units are in which booking)
--    Resolves the M:N relationship BOOKING <-> EQUIPMENT_UNIT.
--    agreed_daily_rate is a deliberate historical snapshot of the price.
-- ---------------------------------------------------------------------
CREATE TABLE booking_items (
    booking_item_id    INT           NOT NULL AUTO_INCREMENT,
    booking_id         INT           NOT NULL,
    equipment_id       INT           NOT NULL,
    agreed_daily_rate  DECIMAL(10,2) NOT NULL,
    CONSTRAINT pk_booking_items PRIMARY KEY (booking_item_id),
    CONSTRAINT uq_booking_items_unit UNIQUE (booking_id, equipment_id),  -- same unit twice in one booking is meaningless
    CONSTRAINT chk_items_rate CHECK (agreed_daily_rate > 0),
    CONSTRAINT fk_items_booking FOREIGN KEY (booking_id)
        REFERENCES bookings (booking_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_items_equipment FOREIGN KEY (equipment_id)
        REFERENCES equipment_units (equipment_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

-- availability / double-booking check looks up all items of one unit
CREATE INDEX idx_items_equipment_booking ON booking_items (equipment_id, booking_id);

-- ---------------------------------------------------------------------
-- 10. SECURITY_DEPOSITS  (0..1 per booking - refundable money held)
--     A deposit is a liability, not revenue, so it is kept separate from
--     PAYMENTS. On settlement part of it may be RETAINED to cover late or
--     damage charges; the rest is REFUNDED.
--     Money invariant: refunded + retained <= collected <= required.
-- ---------------------------------------------------------------------
CREATE TABLE security_deposits (
    deposit_id        INT           NOT NULL AUTO_INCREMENT,
    booking_id        INT           NOT NULL,
    required_amount   DECIMAL(12,2) NOT NULL,
    collected_amount  DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    collected_date    DATE          NULL,
    refunded_amount   DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    retained_amount   DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    settled_date      DATE          NULL,
    retention_reason  VARCHAR(200)  NULL,
    deposit_status    ENUM('PENDING','HELD','REFUNDED','PARTIALLY_REFUNDED','FORFEITED','CANCELLED')
                      NOT NULL DEFAULT 'PENDING',
    CONSTRAINT pk_security_deposits PRIMARY KEY (deposit_id),
    CONSTRAINT uq_deposits_booking UNIQUE (booking_id),           -- enforces the 1:0..1 relationship
    CONSTRAINT chk_deposits_nonneg CHECK (required_amount > 0 AND collected_amount >= 0
                                          AND refunded_amount >= 0 AND retained_amount >= 0),
    CONSTRAINT chk_deposits_balance CHECK (collected_amount <= required_amount
                                          AND refunded_amount + retained_amount <= collected_amount),
    CONSTRAINT chk_deposits_retention CHECK (retained_amount = 0 OR retention_reason IS NOT NULL),
    -- every status must agree with the money columns
    CONSTRAINT chk_deposits_status CHECK (
        (deposit_status = 'PENDING'   AND collected_amount = 0 AND refunded_amount = 0 AND retained_amount = 0 AND settled_date IS NULL)
     OR (deposit_status = 'CANCELLED' AND collected_amount = 0 AND refunded_amount = 0 AND retained_amount = 0)
     OR (deposit_status = 'HELD'      AND collected_amount > 0 AND collected_date IS NOT NULL
                                       AND refunded_amount = 0 AND retained_amount = 0 AND settled_date IS NULL)
     OR (deposit_status = 'REFUNDED'  AND collected_amount > 0 AND refunded_amount = collected_amount
                                       AND retained_amount = 0 AND settled_date IS NOT NULL)
     OR (deposit_status = 'PARTIALLY_REFUNDED' AND refunded_amount > 0 AND retained_amount > 0
                                       AND refunded_amount + retained_amount = collected_amount AND settled_date IS NOT NULL)
     OR (deposit_status = 'FORFEITED' AND collected_amount > 0 AND retained_amount = collected_amount
                                       AND refunded_amount = 0 AND settled_date IS NOT NULL)),
    CONSTRAINT chk_deposits_dates CHECK (settled_date IS NULL OR collected_date IS NULL OR settled_date >= collected_date),
    CONSTRAINT fk_deposits_booking FOREIGN KEY (booking_id)
        REFERENCES bookings (booking_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

CREATE INDEX idx_deposits_status ON security_deposits (deposit_status);

-- ---------------------------------------------------------------------
-- 11. PAYMENTS  (money received from the customer against rental charges)
--     Only payment_status = 'COMPLETED' counts towards the amount paid.
--     'REFUNDED' = an advance that was returned (e.g. booking cancelled).
-- ---------------------------------------------------------------------
CREATE TABLE payments (
    payment_id      INT           NOT NULL AUTO_INCREMENT,
    booking_id      INT           NOT NULL,
    amount          DECIMAL(12,2) NOT NULL,
    payment_date    DATE          NOT NULL,
    payment_method  ENUM('CASH','UPI','CARD','BANK_TRANSFER','CHEQUE') NOT NULL,
    payment_type    ENUM('ADVANCE','BALANCE','LATE_FEE','DAMAGE') NOT NULL,
    payment_status  ENUM('PENDING','COMPLETED','FAILED','REFUNDED') NOT NULL DEFAULT 'COMPLETED',
    reference_no    VARCHAR(40)   NULL,     -- UPI / NEFT / cheque number
    CONSTRAINT pk_payments PRIMARY KEY (payment_id),
    CONSTRAINT uq_payments_reference UNIQUE (reference_no),
    CONSTRAINT chk_payments_amount CHECK (amount > 0),
    CONSTRAINT chk_payments_reference CHECK (payment_method = 'CASH' OR reference_no IS NOT NULL),
    CONSTRAINT fk_payments_booking FOREIGN KEY (booking_id)
        REFERENCES bookings (booking_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

CREATE INDEX idx_payments_booking_status ON payments (booking_id, payment_status);
CREATE INDEX idx_payments_date ON payments (payment_date);

-- ---------------------------------------------------------------------
-- 12. EQUIPMENT_RETURNS  (0..1 per booking item -> supports partial returns)
--     late_charge and damage_charge are stored because they are financial
--     facts fixed at the moment of return (the late-fee policy may change).
-- ---------------------------------------------------------------------
CREATE TABLE equipment_returns (
    return_id             INT           NOT NULL AUTO_INCREMENT,
    booking_item_id       INT           NOT NULL,
    return_date           DATE          NOT NULL,
    received_by_staff_id  INT           NOT NULL,
    return_condition      ENUM('GOOD','MINOR_DAMAGE','MAJOR_DAMAGE') NOT NULL DEFAULT 'GOOD',
    late_charge           DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    damage_charge         DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    damage_description    VARCHAR(255)  NULL,
    return_notes          VARCHAR(255)  NULL,
    CONSTRAINT pk_equipment_returns PRIMARY KEY (return_id),
    CONSTRAINT uq_returns_item UNIQUE (booking_item_id),      -- a unit can be returned only once per booking
    CONSTRAINT chk_returns_charges CHECK (late_charge >= 0 AND damage_charge >= 0),
    CONSTRAINT chk_returns_damage CHECK (
        (return_condition = 'GOOD' AND damage_charge = 0) OR
        (return_condition <> 'GOOD' AND damage_description IS NOT NULL)),
    CONSTRAINT fk_returns_item FOREIGN KEY (booking_item_id)
        REFERENCES booking_items (booking_item_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_returns_staff FOREIGN KEY (received_by_staff_id)
        REFERENCES staff (staff_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

CREATE INDEX idx_returns_date ON equipment_returns (return_date);

-- ---------------------------------------------------------------------
-- 13. MAINTENANCE_RECORDS
--     SCHEDULED   = planned; blocks bookings for [scheduled_start, scheduled_end]
--                   but the machine is still physically available today.
--     IN_PROGRESS = machine is actually out of service (actual_start set).
--     COMPLETED   = finished (actual_start and actual_end set).
--     CANCELLED   = plan dropped; blocks nothing.
-- ---------------------------------------------------------------------
CREATE TABLE maintenance_records (
    maintenance_id         INT           NOT NULL AUTO_INCREMENT,
    equipment_id           INT           NOT NULL,
    technician_staff_id    INT           NULL,          -- NULL = external workshop / dealer
    related_return_id      INT           NULL,          -- set when repairing damage found on return
    maintenance_type       ENUM('PREVENTIVE','CORRECTIVE','INSPECTION') NOT NULL,
    maintenance_status     ENUM('SCHEDULED','IN_PROGRESS','COMPLETED','CANCELLED') NOT NULL DEFAULT 'SCHEDULED',
    scheduled_start        DATE          NOT NULL,
    scheduled_end          DATE          NOT NULL,
    actual_start           DATE          NULL,
    actual_end             DATE          NULL,
    maintenance_cost       DECIMAL(10,2) NOT NULL DEFAULT 0.00,
    description            VARCHAR(255)  NOT NULL,
    CONSTRAINT pk_maintenance_records PRIMARY KEY (maintenance_id),
    CONSTRAINT uq_maintenance_return UNIQUE (related_return_id),
    CONSTRAINT chk_maint_sched_period CHECK (scheduled_end >= scheduled_start),
    CONSTRAINT chk_maint_actual_period CHECK (actual_end IS NULL OR actual_end >= actual_start),
    CONSTRAINT chk_maint_cost CHECK (maintenance_cost >= 0),
    CONSTRAINT chk_maint_status_dates CHECK (
        (maintenance_status IN ('SCHEDULED','CANCELLED') AND actual_start IS NULL AND actual_end IS NULL) OR
        (maintenance_status = 'IN_PROGRESS' AND actual_start IS NOT NULL AND actual_end IS NULL) OR
        (maintenance_status = 'COMPLETED'   AND actual_start IS NOT NULL AND actual_end IS NOT NULL)),
    CONSTRAINT fk_maint_equipment FOREIGN KEY (equipment_id)
        REFERENCES equipment_units (equipment_id)
        ON DELETE RESTRICT ON UPDATE CASCADE,
    CONSTRAINT fk_maint_technician FOREIGN KEY (technician_staff_id)
        REFERENCES staff (staff_id)
        ON DELETE SET NULL ON UPDATE CASCADE,
    CONSTRAINT fk_maint_return FOREIGN KEY (related_return_id)
        REFERENCES equipment_returns (return_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

CREATE INDEX idx_maint_unit_status ON maintenance_records (equipment_id, maintenance_status, scheduled_start);
CREATE INDEX idx_maint_status_start ON maintenance_records (maintenance_status, scheduled_start);

-- ---------------------------------------------------------------------
-- 14. BOOKING_STATUS_LOG  (audit trail, written only by triggers)
-- ---------------------------------------------------------------------
CREATE TABLE booking_status_log (
    log_id       INT          NOT NULL AUTO_INCREMENT,
    booking_id   INT          NOT NULL,
    old_status   VARCHAR(20)  NULL,          -- NULL for the very first status
    new_status   VARCHAR(20)  NOT NULL,
    changed_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    changed_by   VARCHAR(100) NOT NULL,      -- MySQL account that made the change
    CONSTRAINT pk_booking_status_log PRIMARY KEY (log_id),
    CONSTRAINT fk_log_booking FOREIGN KEY (booking_id)
        REFERENCES bookings (booking_id)
        ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE = InnoDB;

-- Quick confirmation
SELECT table_name AS created_table
FROM information_schema.tables
WHERE table_schema = 'construction_rental_db'
ORDER BY table_name;

DELIMITER ;
-- ##### END 01_create_database.sql

-- #####################################################################
-- ##### BEGIN 02_seed_data.sql
-- #####################################################################
-- =====================================================================
--  File   : 02_seed_data.sql
--  Purpose: Realistic (fictional) demo data for an equipment rental company
--           operating yards in Mohali, Ludhiana and Gurugram.
--  Run    : after 01_create_database.sql, BEFORE 08_triggers.sql
-- ---------------------------------------------------------------------
--  DEMO DATE CONVENTION
--  The business "today" is fixed at 2026-11-20 (system_settings.business_date).
--  All views, procedures and reports use fn_business_date() / this setting,
--  so scenarios (overdue, future booking, etc.) stay correct whenever the
--  scripts are executed.
--
--  WHY SEED BEFORE TRIGGERS?
--  The seed represents historical data migrated from the old paper/Excel
--  system: it contains COMPLETED bookings and past returns that the
--  "live" triggers would (correctly) refuse to accept today, e.g. adding an
--  item to an already-completed booking. Consistency of this data is instead
--  proven by tests/verify_database.sql (no overlaps, no orphan rows,
--  every money invariant satisfied).
--
--  SCENARIO MAP (booking id -> scenario)
--   B1  completed; includes unit 30 which was RETIRED later (history kept)
--   B2  completed, multi-machine, fully refunded deposit
--   B3  government customer (no deposit), three machines
--   B4  LATE RETURN (3 days) -> late fee recovered from deposit (partially retained)
--   B5  MINOR DAMAGE charge -> deposit partially retained -> repair record M3
--   B10 one unit returned late -> late fee retained from deposit
--   B11 MAJOR DAMAGE on tipper -> corrective maintenance M8
--   B12 CANCELLED booking; same unit then rented by B13 for overlapping dates
--   B15 completed, deposit still HELD -> pending refund
--   B16 completed, deposit HELD and Rs 20,000 balance still unpaid
--   B17 ACTIVE (currently rented), three machines
--   B18 ACTIVE & OVERDUE (due 2026-11-16) and PARTIALLY RETURNED
--   B19 ACTIVE, one unit returned early (partial return, not overdue)
--   B20 ACTIVE government contract with negotiated (discounted) rate
--   B21 RESERVED, starts today (ready for pickup demo)
--   B22-B24, B26 future RESERVED bookings
--   B25 CANCELLED after deposit + advance were collected (both refunded)
-- =====================================================================

USE construction_rental_db;

SET FOREIGN_KEY_CHECKS = 1;   -- keep RI checks ON: seed must satisfy every FK

-- ---------------------------------------------------------------------
-- System settings: fixed business date for a reproducible demo
-- ---------------------------------------------------------------------
INSERT INTO system_settings (settings_id, business_date, late_fee_multiplier, max_rental_days)
VALUES (1, '2026-11-20', 1.50, 180);

-- ---------------------------------------------------------------------
-- Depots
-- ---------------------------------------------------------------------
INSERT INTO depots (depot_id, depot_name, city, state, phone) VALUES
(1, 'Mohali Main Yard',   'Mohali',   'Punjab',  '+917087012345'),
(2, 'Ludhiana Yard',      'Ludhiana', 'Punjab',  '+917087023456'),
(3, 'Gurugram Yard',      'Gurugram', 'Haryana', '+917087034567');
-- Depot phones are the yard managers' mobile numbers (format +91 followed by 10 digits).

-- ---------------------------------------------------------------------
-- Staff (manager_id builds the reporting hierarchy -> SELF JOIN demo)
-- ---------------------------------------------------------------------
INSERT INTO staff (staff_id, full_name, staff_role, phone, email, hire_date, manager_id, is_active) VALUES
(1, 'Rajinder Singh Gill', 'MANAGER',      '+919814000101', 'rajinder.gill@cer-rentals.in',  '2018-04-02', NULL, TRUE),
(2, 'Neha Sharma',         'RENTAL_AGENT', '+919814000102', 'neha.sharma@cer-rentals.in',    '2020-07-15', 1,    TRUE),
(3, 'Gurpreet Kaur',       'RENTAL_AGENT', '+919814000103', 'gurpreet.kaur@cer-rentals.in',  '2021-01-11', 1,    TRUE),
(4, 'Vikram Choudhary',    'TECHNICIAN',   '+919814000104', 'vikram.c@cer-rentals.in',       '2019-03-20', 1,    TRUE),
(5, 'Sukhwinder Pal',      'TECHNICIAN',   '+919814000105', 'sukhwinder.pal@cer-rentals.in', '2022-06-01', 4,    TRUE),
(6, 'Amit Bansal',         'ACCOUNTANT',   '+919814000106', 'amit.bansal@cer-rentals.in',    '2019-09-09', 1,    TRUE),
(7, 'Pooja Arora',         'RENTAL_AGENT', '+919814000107', 'pooja.arora@cer-rentals.in',    '2023-02-13', 1,    TRUE),
(8, 'Harish Kumar',        'TECHNICIAN',   '+919814000108', 'harish.kumar@cer-rentals.in',   '2020-10-05', 4,    FALSE);

-- ---------------------------------------------------------------------
-- Customers (fictional people and organisations)
-- ---------------------------------------------------------------------
INSERT INTO customers (customer_id, customer_type, full_name, organisation_name, phone, email,
                       address_line, city, state, pincode, registration_date, is_active) VALUES
(1,  'COMPANY',    'Harpreet Singh Gill', 'Gill Infrastructure Pvt Ltd',      '+919876501001', 'projects@gillinfra.in',     'SCO 45, Sector 70',            'Mohali',      'Punjab',     '160071', '2025-12-15', TRUE),
(2,  'COMPANY',    'Rohit Sharma',        'Sharma Builders & Developers',     '+919876501002', 'rohit@sharmabuilders.in',   '112 Ferozepur Road',           'Ludhiana',    'Punjab',     '141001', '2026-02-20', TRUE),
(3,  'GOVERNMENT', 'Er. Balwinder Singh', 'Public Works Dept - Mohali Circle','+919876501003', 'ee.mohali@pwd-demo.in',     'PWD Complex, Phase 1',         'Mohali',      'Punjab',     '160055', '2026-01-20', TRUE),
(4,  'INDIVIDUAL', 'Anil Kumar Mehta',    NULL,                               '+919876501004', 'anil.mehta@gmail.com',      'House 233, Sector 12',         'Panchkula',   'Haryana',    '134112', '2026-06-28', TRUE),
(5,  'COMPANY',    'Karan Thakur',        'Shivalik Constructions',           '+919876501005', 'karan@shivalikcons.in',     'Plot 9, VIP Road',             'Zirakpur',    'Punjab',     '140603', '2026-04-01', TRUE),
(6,  'COMPANY',    'Jaspreet Sandhu',     'Sandhu Earthmovers',               '+919876501006', 'sandhu.earth@yahoo.in',     'Rajpura Road, Near Bus Stand', 'Patiala',     'Punjab',     '147001', '2026-04-25', TRUE),
(7,  'INDIVIDUAL', 'Priya Nair',          NULL,                               '+919876501007', 'priya.nair@outlook.com',    'House 1520, Sector 36-D',      'Chandigarh',  'Chandigarh', '160036', '2026-11-19', TRUE),
(8,  'COMPANY',    'Deepak Aggarwal',     'Aggarwal Realty LLP',              '+919876501008', 'deepak@aggarwalrealty.in',  'Tower B, Golf Course Road',    'Gurugram',    'Haryana',    '122002', '2026-08-25', TRUE),
(9,  'GOVERNMENT', 'Smt. Kavita Rani',    'Municipal Works Dept - Ambala',    '+919876501009', 'works.ambala@mc-demo.in',   'Municipal Office, Mall Road',  'Ambala',      'Haryana',    '133001', '2026-11-10', TRUE),
(10, 'INDIVIDUAL', 'Vikas Yadav',         NULL,                               '+919876501010', 'vikas.yadav@gmail.com',     'Village Sohna Road',           'Gurugram',    'Haryana',    '122018', '2026-11-18', TRUE),
(11, 'COMPANY',    'Manpreet Dhillon',    'Dhillon Road Contractors',         '+919876501011', 'dhillon.roads@gmail.com',   'Ganpati Enclave, Mansa Road',  'Bathinda',    'Punjab',     '151001', '2026-08-10', TRUE),
(12, 'COMPANY',    'Sanjay Gupta',        'Metro Height Developers',          '+919876501012', 'sanjay@metroheight.in',     'A-14, Okhla Phase II',         'New Delhi',   'Delhi',      '110020', '2026-07-05', TRUE),
(13, 'INDIVIDUAL', 'Ritu Malhotra',       NULL,                               '+919876501013', 'ritu.malhotra@gmail.com',   '45-B Model Town',              'Ludhiana',    'Punjab',     '141002', '2026-09-28', TRUE),
(14, 'COMPANY',    'Gurdeep Bajwa',       'Bajwa Agro Farms',                 '+919876501014', NULL,                        'Village Kartarpur',            'Jalandhar',   'Punjab',     '144801', '2026-10-30', TRUE),
(15, 'COMPANY',    'Nikhil Kapoor',       'Kapoor Event Services',            '+919876501015', 'bookings@kapoorevents.in',  'SCO 210, Sector 34-A',         'Chandigarh',  'Chandigarh', '160022', '2026-06-15', TRUE),
(16, 'COMPANY',    'Ravinder Saini',      'Saini Brothers Construction',      '+919876501016', 'sainibros@gmail.com',       'Landran Road',                 'Kharar',      'Punjab',     '140301', '2026-10-12', TRUE),
(17, 'INDIVIDUAL', 'Arjun Verma',         NULL,                               '+919876501017', 'arjun.verma@gmail.com',     'Flat 302, Sector 88',          'Mohali',      'Punjab',     '140308', '2026-11-02', TRUE),
(18, 'COMPANY',    'Sunil Bhatia',        'Bhatia Contractors',               '+919876501018', 'bhatia.contractors@gmail.com','Ranjit Avenue',              'Amritsar',    'Punjab',     '143001', '2024-06-12', FALSE);

-- ---------------------------------------------------------------------
-- Equipment categories (Tower Cranes has no models yet -> outer-join demo)
-- ---------------------------------------------------------------------
INSERT INTO equipment_categories (category_id, category_name, description) VALUES
(1,  'Excavators',        'Tracked hydraulic excavators for digging, trenching and demolition'),
(2,  'Backhoe Loaders',   'Wheeled loader at front with backhoe at rear; versatile site machine'),
(3,  'Bulldozers',        'Tracked dozers for pushing earth, grading and land clearing'),
(4,  'Mobile Cranes',     'Pick-and-carry and hydraulic mobile cranes for lifting loads'),
(5,  'Concrete Mixers',   'Self-loading concrete mixers for on-site batching'),
(6,  'Road Rollers',      'Soil and asphalt compactors for road construction'),
(7,  'Dump Trucks',       'Tipper trucks for hauling excavated material and aggregates'),
(8,  'Forklifts',         'Diesel forklifts for material handling at site stores'),
(9,  'Diesel Generators', 'Silent DG sets for site power and events'),
(10, 'Wheel Loaders',     'Front-end loaders for loading trucks and stockpiling'),
(11, 'Plate Compactors',  'Walk-behind vibratory plate compactors for small areas'),
(12, 'Tower Cranes',      'Planned category - no machines purchased yet');

-- ---------------------------------------------------------------------
-- Equipment models (list prices in INR per day)
-- CAT 320 list price was revised from 14,000 to 15,000 in Nov 2026:
-- old bookings keep 14,000 in booking_items.agreed_daily_rate.
-- ---------------------------------------------------------------------
INSERT INTO equipment_models (model_id, category_id, manufacturer, model_name, capacity_spec, engine_power_hp,
                              fuel_type, daily_rate, deposit_per_unit, service_interval_rental_days) VALUES
(1,  1,  'Caterpillar',     'CAT 320',             '20 t operating weight, 1.0 m3 bucket',  160, 'DIESEL', 15000.00, 75000.00, 30),
(2,  1,  'Komatsu',         'PC200-8',             '20 t operating weight, 0.8 m3 bucket',  148, 'DIESEL', 13000.00, 70000.00, 30),
(3,  1,  'Tata Hitachi',    'EX 200LC Super+',     '20 t operating weight, 0.9 m3 bucket',  140, 'DIESEL', 12000.00, 65000.00, 30),
(4,  2,  'JCB',             '3DX Super',           '1.1 m3 loader, 0.26 m3 backhoe',          76, 'DIESEL',  5500.00, 30000.00, 30),
(5,  2,  'Mahindra',        'EarthMaster SX',      '1.0 m3 loader, 0.24 m3 backhoe',          74, 'DIESEL',  4800.00, 25000.00, 30),
(6,  3,  'BEML',            'BD80',                '15 t class crawler dozer',               180, 'DIESEL', 16000.00, 80000.00, 30),
(7,  4,  'ACE',             '14XW',                '14 t pick-and-carry crane',               76, 'DIESEL',  9000.00, 50000.00, 30),
(8,  4,  'Escorts',         'Hydra 12',            '12 t hydraulic mobile crane',             75, 'DIESEL',  8000.00, 45000.00, 30),
(9,  5,  'Ajax Fiori',      'ARGO 4000',           '4.0 m3 self-loading concrete mixer',      99, 'DIESEL',  6500.00, 30000.00, 20),
(10, 6,  'Volvo',           'SD110',               '11 t single-drum soil compactor',        130, 'DIESEL',  8500.00, 45000.00, 30),
(11, 6,  'CASE',            '1107 EX',             '11 t single-drum soil compactor',        110, 'DIESEL',  8000.00, 45000.00, 30),
(12, 7,  'Tata Motors',     'Signa 2823.K',        '16 m3 tipper body, 28 t GVW',            250, 'DIESEL',  7500.00, 40000.00, 30),
(13, 8,  'Godrej',          'GX 300 Diesel',       '3 t lifting capacity, 4.5 m mast',        48, 'DIESEL',  2500.00, 15000.00, 20),
(14, 9,  'Kirloskar',       'KG1-62.5AS',          '62.5 kVA silent DG set',                  85, 'DIESEL',  3000.00, 15000.00, 15),
(15, 9,  'Cummins',         'C125D5',              '125 kVA silent DG set',                  160, 'DIESEL',  4500.00, 20000.00, 15),
(16, 10, 'JCB',             '432ZX',               '2.3 m3 bucket wheel loader',             130, 'DIESEL',  7000.00, 35000.00, 30),
(17, 11, 'Wacker Neuson',   'VP1550',              '15 kN centrifugal force, 50 cm plate',     4, 'PETROL',   900.00,  5000.00, 20);

-- ---------------------------------------------------------------------
-- Equipment units (32 physical machines)
-- ---------------------------------------------------------------------
INSERT INTO equipment_units (equipment_id, model_id, depot_id, asset_tag, serial_number, manufacture_year,
                             purchase_date, purchase_cost, condition_rating, lifecycle_status, retired_date) VALUES
(1,  1,  1, 'CER-EXC-001', 'CAT0320GKTW10231',  2021, '2021-03-18', 9800000.00, 'GOOD',      'ACTIVE',  NULL),
(2,  1,  2, 'CER-EXC-002', 'CAT0320GKTW10577',  2022, '2022-01-10', 10200000.00,'EXCELLENT', 'ACTIVE',  NULL),
(3,  2,  1, 'CER-EXC-003', 'KMTPC200-8-A41290', 2020, '2020-08-25', 8700000.00, 'GOOD',      'ACTIVE',  NULL),
(4,  2,  3, 'CER-EXC-004', 'KMTPC200-8-A43815', 2022, '2022-11-02', 9100000.00, 'GOOD',      'ACTIVE',  NULL),
(5,  3,  2, 'CER-EXC-005', 'THEX200LC-3J10442', 2023, '2023-05-14', 8200000.00, 'EXCELLENT', 'ACTIVE',  NULL),
(6,  4,  1, 'CER-BHL-001', 'JCB3DXS-2310457',   2021, '2021-07-01', 3100000.00, 'GOOD',      'ACTIVE',  NULL),
(7,  4,  1, 'CER-BHL-002', 'JCB3DXS-2324981',   2023, '2023-02-15', 3350000.00, 'EXCELLENT', 'ACTIVE',  NULL),
(8,  4,  2, 'CER-BHL-003', 'JCB3DXS-2219035',   2022, '2022-04-20', 3200000.00, 'GOOD',      'ACTIVE',  NULL),
(9,  5,  3, 'CER-BHL-004', 'MHESX-22A07731',    2022, '2022-09-12', 2750000.00, 'FAIR',      'ACTIVE',  NULL),
(10, 6,  2, 'CER-DOZ-001', 'BEMLBD80-11872',    2020, '2020-12-05', 11500000.00,'FAIR',      'ACTIVE',  NULL),
(11, 7,  1, 'CER-CRN-001', 'ACE14XW-2108814',   2021, '2021-10-30', 2900000.00, 'GOOD',      'ACTIVE',  NULL),
(12, 7,  3, 'CER-CRN-002', 'ACE14XW-2301276',   2023, '2023-03-08', 3150000.00, 'EXCELLENT', 'ACTIVE',  NULL),
(13, 8,  2, 'CER-CRN-003', 'ESCHYD12-1907453',  2019, '2019-06-17', 2400000.00, 'FAIR',      'ACTIVE',  NULL),
(14, 9,  1, 'CER-MIX-001', 'AJXARGO4K-21C318',  2021, '2021-05-22', 2600000.00, 'GOOD',      'ACTIVE',  NULL),
(15, 9,  3, 'CER-MIX-002', 'AJXARGO4K-24C902',  2024, '2024-01-29', 2950000.00, 'EXCELLENT', 'ACTIVE',  NULL),
(16, 10, 2, 'CER-RLR-001', 'VOLSD110-B200381',  2020, '2020-02-11', 5400000.00, 'GOOD',      'ACTIVE',  NULL),
(17, 11, 1, 'CER-RLR-002', 'CASE1107EX-NB4471', 2022, '2022-07-07', 4900000.00, 'GOOD',      'ACTIVE',  NULL),
(18, 12, 1, 'CER-DMP-001', 'MAT448123NKP71520', 2021, '2021-09-03', 4300000.00, 'GOOD',      'ACTIVE',  NULL),
(19, 12, 2, 'CER-DMP-002', 'MAT448123NKP80933', 2022, '2022-03-28', 4450000.00, 'FAIR',      'ACTIVE',  NULL),
(20, 13, 1, 'CER-FRK-001', 'GDJGX300D-210744',  2021, '2021-11-19', 1250000.00, 'GOOD',      'ACTIVE',  NULL),
(21, 13, 3, 'CER-FRK-002', 'GDJGX300D-230158',  2023, '2023-08-01', 1340000.00, 'EXCELLENT', 'ACTIVE',  NULL),
(22, 14, 1, 'CER-GEN-001', 'KOELKG1625-81124',  2020, '2020-04-10',  720000.00, 'GOOD',      'ACTIVE',  NULL),
(23, 14, 2, 'CER-GEN-002', 'KOELKG1625-90377',  2022, '2022-02-14',  760000.00, 'GOOD',      'ACTIVE',  NULL),
(24, 15, 3, 'CER-GEN-003', 'CMSC125D5-7731205', 2021, '2021-12-20', 1450000.00, 'GOOD',      'ACTIVE',  NULL),
(25, 16, 2, 'CER-WLD-001', 'JCB432ZX-2205519',  2022, '2022-05-30', 5600000.00, 'GOOD',      'ACTIVE',  NULL),
(26, 17, 1, 'CER-CMP-001', 'WNVP1550-31104578', 2023, '2023-04-03',   95000.00, 'GOOD',      'ACTIVE',  NULL),
(27, 17, 1, 'CER-CMP-002', 'WNVP1550-31104611', 2023, '2023-04-03',   95000.00, 'GOOD',      'ACTIVE',  NULL),
(28, 17, 3, 'CER-CMP-003', 'WNVP1550-31209932', 2024, '2024-03-15',   98000.00, 'EXCELLENT', 'ACTIVE',  NULL),
(29, 1,  3, 'CER-EXC-006', 'CAT0320GKTW11904',  2024, '2024-06-21', 10900000.00,'EXCELLENT', 'ACTIVE',  NULL),
(30, 4,  3, 'CER-BHL-005', 'JCB3DXS-1802264',   2018, '2019-02-10', 2700000.00, 'POOR',      'RETIRED', '2026-06-30'),
(31, 15, 1, 'CER-GEN-004', 'CMSC125D5-8810433', 2024, '2024-09-09', 1520000.00, 'EXCELLENT', 'ACTIVE',  NULL),
(32, 14, 3, 'CER-GEN-005', 'KOELKG1625-A0912',  2026, '2026-10-01',  810000.00, 'EXCELLENT', 'ACTIVE',  NULL);

-- ---------------------------------------------------------------------
-- Bookings (26). Dates are INCLUSIVE.
-- ---------------------------------------------------------------------
INSERT INTO bookings (booking_id, customer_id, created_by_staff_id, booking_date, start_date, expected_return_date,
                      booking_status, site_address, cancelled_date, cancellation_reason) VALUES
(1,  18, 2, '2025-11-03', '2025-11-05', '2025-11-14', 'COMPLETED', 'Commercial complex, GT Road, Amritsar',          NULL, NULL),
(2,  1,  2, '2026-01-08', '2026-01-10', '2026-01-24', 'COMPLETED', 'Housing project, Sector 82, Mohali',             NULL, NULL),
(3,  3,  3, '2026-02-02', '2026-02-05', '2026-02-18', 'COMPLETED', 'Airport Road widening, Mohali',                  NULL, NULL),
(4,  2,  7, '2026-03-01', '2026-03-02', '2026-03-08', 'COMPLETED', 'Villa plots, Pakhowal Road, Ludhiana',           NULL, NULL),
(5,  5,  2, '2026-04-10', '2026-04-12', '2026-04-21', 'COMPLETED', 'Shivalik Heights tower, Zirakpur',               NULL, NULL),
(6,  6,  3, '2026-05-04', '2026-05-05', '2026-05-24', 'COMPLETED', 'Canal bank levelling, Patiala',                  NULL, NULL),
(7,  1,  2, '2026-06-01', '2026-06-03', '2026-06-12', 'COMPLETED', 'Housing project, Sector 82, Mohali',             NULL, NULL),
(8,  15, 7, '2026-06-20', '2026-06-25', '2026-06-27', 'COMPLETED', 'Wedding venue, Zirakpur-Patiala Highway',        NULL, NULL),
(9,  4,  7, '2026-07-01', '2026-07-03', '2026-07-07', 'COMPLETED', 'House 233, Sector 12, Panchkula',                NULL, NULL),
(10, 12, 1, '2026-07-10', '2026-07-15', '2026-08-13', 'COMPLETED', 'Metro Heights residency, Sector 113, Gurugram',  NULL, NULL),
(11, 11, 3, '2026-08-18', '2026-08-20', '2026-09-03', 'COMPLETED', 'Link road, Bathinda-Mansa',                      NULL, NULL),
(12, 8,  2, '2026-09-01', '2026-09-15', '2026-09-20', 'CANCELLED', 'Aggarwal Greens, Sector 65, Gurugram',           '2026-09-10', 'Project start postponed by client'),
(13, 6,  3, '2026-09-12', '2026-09-16', '2026-09-25', 'COMPLETED', 'Farmhouse pond excavation, Rajpura',             NULL, NULL),
(14, 13, 7, '2026-10-01', '2026-10-03', '2026-10-04', 'COMPLETED', '45-B Model Town, Ludhiana',                      NULL, NULL),
(15, 2,  7, '2026-10-05', '2026-10-06', '2026-10-20', 'COMPLETED', 'Sharma Enclave, Ludhiana',                       NULL, NULL),
(16, 16, 2, '2026-10-15', '2026-10-18', '2026-10-27', 'COMPLETED', 'Warehouse site, Landran Road, Kharar',           NULL, NULL),
(17, 1,  2, '2026-11-08', '2026-11-10', '2026-11-29', 'ACTIVE',    'Gill Business Park, Sector 74, Mohali',          NULL, NULL),
(18, 5,  3, '2026-11-01', '2026-11-03', '2026-11-16', 'ACTIVE',    'Shivalik Heights phase 2, Zirakpur',             NULL, NULL),
(19, 11, 3, '2026-11-12', '2026-11-14', '2026-11-23', 'ACTIVE',    'Village road, Talwandi Sabo',                    NULL, NULL),
(20, 3,  1, '2026-11-15', '2026-11-17', '2026-12-16', 'ACTIVE',    'Kharar-Landran road four-laning',                NULL, NULL),
(21, 7,  7, '2026-11-19', '2026-11-20', '2026-11-22', 'RESERVED',  'House 1520, Sector 36-D, Chandigarh',            NULL, NULL),
(22, 8,  2, '2026-11-18', '2026-12-01', '2026-12-15', 'RESERVED',  'Aggarwal Greens, Sector 65, Gurugram',           NULL, NULL),
(23, 10, 7, '2026-11-19', '2026-11-25', '2026-11-28', 'RESERVED',  'Plot 17, Sohna Road, Gurugram',                  NULL, NULL),
(24, 15, 7, '2026-11-16', '2026-12-05', '2026-12-07', 'RESERVED',  'Exhibition ground, Sector 34, Chandigarh',       NULL, NULL),
(25, 12, 1, '2026-11-05', '2026-11-20', '2026-11-30', 'CANCELLED', 'Metro Heights tower B, Gurugram',                '2026-11-12', 'Site environmental permit delayed'),
(26, 9,  3, '2026-11-18', '2026-11-24', '2026-12-03', 'RESERVED',  'Drain lining work, Ambala Cantt',                NULL, NULL);

-- ---------------------------------------------------------------------
-- Booking items (47). agreed_daily_rate = price agreed on booking_date.
-- ---------------------------------------------------------------------
INSERT INTO booking_items (booking_item_id, booking_id, equipment_id, agreed_daily_rate) VALUES
(1,  1,  1,  14000.00), (2,  1,  30,  5500.00),
(3,  2,  3,  13000.00), (4,  2,  6,   5500.00),
(5,  3,  16,  8500.00), (6,  3,  17,  8000.00), (7,  3,  18,  7500.00),
(8,  4,  8,   5500.00),
(9,  5,  11,  9000.00),
(10, 6,  10, 16000.00), (11, 6,  2,  14000.00),
(12, 7,  14,  6500.00), (13, 7,  22,  3000.00),
(14, 8,  23,  3000.00), (15, 8,  24,  4500.00),
(16, 9,  9,   4800.00),
(17, 10, 12,  9000.00), (18, 10, 4,  13000.00),
(19, 11, 16,  8500.00), (20, 11, 19,  7500.00),
(21, 12, 29, 14000.00),
(22, 13, 29, 14000.00),
(23, 14, 26,   900.00), (24, 14, 22,  3000.00),
(25, 15, 7,   5500.00), (26, 15, 18,  7500.00),
(27, 16, 25,  7000.00),
(28, 17, 1,  14000.00), (29, 17, 6,   5500.00), (30, 17, 18,  7500.00),
(31, 18, 3,  13000.00), (32, 18, 20,  2500.00),
(33, 19, 17,  8000.00), (34, 19, 27,   900.00),
(35, 20, 16,  8500.00), (36, 20, 19,  7500.00), (37, 20, 10, 15000.00),   -- 15,000 = negotiated govt rate (list 16,000)
(38, 21, 22,  3000.00),
(39, 22, 29, 15000.00), (40, 22, 12,  9000.00),                           -- booked after CAT 320 price revision
(41, 23, 9,   4800.00),
(42, 24, 24,  4500.00), (43, 24, 31,  4500.00),
(44, 25, 2,  14000.00),
(45, 26, 14,  6500.00), (46, 26, 15,  6500.00), (47, 26, 26,   900.00);

-- ---------------------------------------------------------------------
-- Security deposits (23). Government bookings (3, 20, 26) are exempt.
-- ---------------------------------------------------------------------
INSERT INTO security_deposits (deposit_id, booking_id, required_amount, collected_amount, collected_date,
                               refunded_amount, retained_amount, settled_date, retention_reason, deposit_status) VALUES
(1,  1,  105000.00, 105000.00, '2025-11-05', 105000.00,     0.00, '2025-11-15', NULL, 'REFUNDED'),
(2,  2,  100000.00, 100000.00, '2026-01-10', 100000.00,     0.00, '2026-01-25', NULL, 'REFUNDED'),
(3,  4,   30000.00,  30000.00, '2026-03-02',   5250.00, 24750.00, '2026-03-12', 'Late return fee: 3 days x Rs 5,500 x 1.5', 'PARTIALLY_REFUNDED'),
(4,  5,   50000.00,  50000.00, '2026-04-12',  38000.00, 12000.00, '2026-04-23', 'Damage: hydraulic hose and outrigger pad', 'PARTIALLY_REFUNDED'),
(5,  6,  155000.00, 155000.00, '2026-05-05', 155000.00,     0.00, '2026-05-26', NULL, 'REFUNDED'),
(6,  7,   45000.00,  45000.00, '2026-06-03',  45000.00,     0.00, '2026-06-13', NULL, 'REFUNDED'),
(7,  8,   35000.00,  35000.00, '2026-06-25',  35000.00,     0.00, '2026-06-28', NULL, 'REFUNDED'),
(8,  9,   25000.00,  25000.00, '2026-07-03',  25000.00,     0.00, '2026-07-08', NULL, 'REFUNDED'),
(9,  10, 120000.00, 120000.00, '2026-07-15',  61500.00, 58500.00, '2026-08-18', 'Late return fee: Komatsu PC200 returned 3 days late', 'PARTIALLY_REFUNDED'),
(10, 11,  85000.00,  85000.00, '2026-08-20',  40000.00, 45000.00, '2026-09-05', 'Damage: tipper hoist cylinder and tail-gate', 'PARTIALLY_REFUNDED'),
(11, 12,  75000.00,      0.00, NULL,              0.00,     0.00, NULL,         NULL, 'CANCELLED'),
(12, 13,  75000.00,  75000.00, '2026-09-16',  75000.00,     0.00, '2026-09-26', NULL, 'REFUNDED'),
(13, 14,  20000.00,  20000.00, '2026-10-03',  20000.00,     0.00, '2026-10-05', NULL, 'REFUNDED'),
(14, 15,  70000.00,  70000.00, '2026-10-06',      0.00,     0.00, NULL,         NULL, 'HELD'),
(15, 16,  35000.00,  35000.00, '2026-10-18',      0.00,     0.00, NULL,         NULL, 'HELD'),
(16, 17, 145000.00, 145000.00, '2026-11-10',      0.00,     0.00, NULL,         NULL, 'HELD'),
(17, 18,  85000.00,  85000.00, '2026-11-03',      0.00,     0.00, NULL,         NULL, 'HELD'),
(18, 19,  50000.00,  50000.00, '2026-11-14',      0.00,     0.00, NULL,         NULL, 'HELD'),
(19, 21,  15000.00,  15000.00, '2026-11-19',      0.00,     0.00, NULL,         NULL, 'HELD'),
(20, 22, 125000.00,      0.00, NULL,              0.00,     0.00, NULL,         NULL, 'PENDING'),
(21, 23,  25000.00,      0.00, NULL,              0.00,     0.00, NULL,         NULL, 'PENDING'),
(22, 24,  40000.00,      0.00, NULL,              0.00,     0.00, NULL,         NULL, 'PENDING'),
(23, 25,  75000.00,  75000.00, '2026-11-05',  75000.00,     0.00, '2026-11-12', NULL, 'REFUNDED');

-- ---------------------------------------------------------------------
-- Payments (28). Only COMPLETED payments count as money received.
-- ---------------------------------------------------------------------
INSERT INTO payments (payment_id, booking_id, amount, payment_date, payment_method, payment_type, payment_status, reference_no) VALUES
(1,  1,  195000.00, '2025-11-14', 'BANK_TRANSFER', 'BALANCE', 'COMPLETED', 'NEFT-SBIN25111400417'),
(2,  2,  100000.00, '2026-01-10', 'UPI',           'ADVANCE', 'COMPLETED', 'UPI-601012847733'),
(3,  2,  177500.00, '2026-01-24', 'BANK_TRANSFER', 'BALANCE', 'COMPLETED', 'NEFT-HDFC26012400921'),
(4,  3,  336000.00, '2026-03-05', 'BANK_TRANSFER', 'BALANCE', 'COMPLETED', 'RTGS-PSIB26030500088'),
(5,  4,   38500.00, '2026-03-02', 'UPI',           'ADVANCE', 'COMPLETED', 'UPI-603021955160'),
(6,  5,   90000.00, '2026-04-12', 'CARD',          'ADVANCE', 'COMPLETED', 'CARD-AUTH-771204'),
(7,  6,  200000.00, '2026-05-05', 'BANK_TRANSFER', 'ADVANCE', 'COMPLETED', 'NEFT-PUNB26050500311'),
(8,  6,  400000.00, '2026-05-25', 'BANK_TRANSFER', 'BALANCE', 'COMPLETED', 'NEFT-PUNB26052500742'),
(9,  7,   95000.00, '2026-06-12', 'UPI',           'BALANCE', 'COMPLETED', 'UPI-606123390018'),
(10, 8,   22500.00, '2026-06-25', 'CASH',          'ADVANCE', 'COMPLETED', NULL),
(11, 9,   24000.00, '2026-07-03', 'UPI',           'ADVANCE', 'COMPLETED', 'UPI-607034410925'),
(12, 10, 300000.00, '2026-07-15', 'BANK_TRANSFER', 'ADVANCE', 'COMPLETED', 'RTGS-ICIC26071500154'),
(13, 10, 360000.00, '2026-08-13', 'BANK_TRANSFER', 'BALANCE', 'COMPLETED', 'RTGS-ICIC26081300209'),
(14, 11, 240000.00, '2026-08-20', 'BANK_TRANSFER', 'ADVANCE', 'COMPLETED', 'NEFT-SBIN26082000635'),
(15, 13, 140000.00, '2026-09-25', 'BANK_TRANSFER', 'BALANCE', 'COMPLETED', 'NEFT-PUNB26092500880'),
(16, 14,   7800.00, '2026-10-03', 'CASH',          'ADVANCE', 'COMPLETED', NULL),
(17, 15, 100000.00, '2026-10-06', 'UPI',           'ADVANCE', 'COMPLETED', 'UPI-610065528841'),
(18, 15,  95000.00, '2026-10-20', 'UPI',           'BALANCE', 'COMPLETED', 'UPI-610209917302'),
(19, 16,  50000.00, '2026-10-18', 'CHEQUE',        'ADVANCE', 'COMPLETED', 'CHQ-004417-AXIS'),
(20, 17, 200000.00, '2026-11-10', 'CARD',          'ADVANCE', 'FAILED',    'CARD-AUTH-DECLINED-1110'),
(21, 17, 200000.00, '2026-11-10', 'BANK_TRANSFER', 'ADVANCE', 'COMPLETED', 'RTGS-HDFC26111000377'),
(22, 18, 100000.00, '2026-11-03', 'UPI',           'ADVANCE', 'COMPLETED', 'UPI-611037730264'),
(23, 19,  45000.00, '2026-11-14', 'BANK_TRANSFER', 'ADVANCE', 'COMPLETED', 'NEFT-SBIN26111400512'),
(24, 20, 300000.00, '2026-11-19', 'BANK_TRANSFER', 'ADVANCE', 'PENDING',   'RTGS-PSIB26111900061'),
(25, 22,  50000.00, '2026-11-18', 'UPI',           'ADVANCE', 'COMPLETED', 'UPI-611184402197'),
(26, 24,  10000.00, '2026-11-16', 'CASH',          'ADVANCE', 'COMPLETED', NULL),
(27, 25,  30000.00, '2026-11-05', 'UPI',           'ADVANCE', 'REFUNDED',  'UPI-611051208843'),
(28, 21,   9000.00, '2026-11-19', 'UPI',           'ADVANCE', 'COMPLETED', 'UPI-611196674520');

-- ---------------------------------------------------------------------
-- Equipment returns (28) - includes late returns, damage and partial returns.
-- late_charge = late_days x agreed_daily_rate x 1.5 (policy at that time)
-- ---------------------------------------------------------------------
INSERT INTO equipment_returns (return_id, booking_item_id, return_date, received_by_staff_id, return_condition,
                               late_charge, damage_charge, damage_description, return_notes) VALUES
(1,  1,  '2025-11-14', 4, 'GOOD',          0.00,     0.00, NULL, NULL),
(2,  2,  '2025-11-14', 4, 'GOOD',          0.00,     0.00, NULL, 'Engine smoke noticed; sent for inspection later'),
(3,  3,  '2026-01-24', 5, 'GOOD',          0.00,     0.00, NULL, NULL),
(4,  4,  '2026-01-24', 5, 'GOOD',          0.00,     0.00, NULL, NULL),
(5,  5,  '2026-02-18', 4, 'GOOD',          0.00,     0.00, NULL, NULL),
(6,  6,  '2026-02-18', 4, 'GOOD',          0.00,     0.00, NULL, NULL),
(7,  7,  '2026-02-18', 4, 'GOOD',          0.00,     0.00, NULL, NULL),
(8,  8,  '2026-03-11', 5, 'GOOD',      24750.00,     0.00, NULL, 'Returned 3 days after due date'),
(9,  9,  '2026-04-21', 4, 'MINOR_DAMAGE',  0.00, 12000.00, 'Hydraulic hose cut and one outrigger pad cracked', NULL),
(10, 10, '2026-05-24', 5, 'GOOD',          0.00,     0.00, NULL, NULL),
(11, 11, '2026-05-24', 5, 'GOOD',          0.00,     0.00, NULL, NULL),
(12, 12, '2026-06-12', 4, 'GOOD',          0.00,     0.00, NULL, NULL),
(13, 13, '2026-06-12', 4, 'GOOD',          0.00,     0.00, NULL, NULL),
(14, 14, '2026-06-27', 5, 'GOOD',          0.00,     0.00, NULL, NULL),
(15, 15, '2026-06-27', 5, 'GOOD',          0.00,     0.00, NULL, NULL),
(16, 16, '2026-07-07', 4, 'GOOD',          0.00,     0.00, NULL, NULL),
(17, 17, '2026-08-13', 4, 'GOOD',          0.00,     0.00, NULL, NULL),
(18, 18, '2026-08-16', 4, 'GOOD',      58500.00,     0.00, NULL, 'Excavator returned 3 days late'),
(19, 19, '2026-09-03', 5, 'GOOD',          0.00,     0.00, NULL, NULL),
(20, 20, '2026-09-03', 5, 'MAJOR_DAMAGE',  0.00, 45000.00, 'Tipper hoist cylinder bent and tail-gate hinge broken', 'Sent to workshop'),
(21, 22, '2026-09-25', 4, 'GOOD',          0.00,     0.00, NULL, NULL),
(22, 23, '2026-10-04', 5, 'GOOD',          0.00,     0.00, NULL, NULL),
(23, 24, '2026-10-04', 5, 'GOOD',          0.00,     0.00, NULL, NULL),
(24, 25, '2026-10-20', 4, 'GOOD',          0.00,     0.00, NULL, NULL),
(25, 26, '2026-10-20', 4, 'GOOD',          0.00,     0.00, NULL, NULL),
(26, 27, '2026-10-27', 5, 'GOOD',          0.00,     0.00, NULL, NULL),
(27, 32, '2026-11-16', 4, 'GOOD',          0.00,     0.00, NULL, 'Forklift returned on time; excavator still at site'),
(28, 34, '2026-11-18', 5, 'GOOD',          0.00,     0.00, NULL, 'Compactor returned early - work finished');

-- ---------------------------------------------------------------------
-- Maintenance records (15)
-- ---------------------------------------------------------------------
INSERT INTO maintenance_records (maintenance_id, equipment_id, technician_staff_id, related_return_id, maintenance_type,
                                 maintenance_status, scheduled_start, scheduled_end, actual_start, actual_end,
                                 maintenance_cost, description) VALUES
(1,  1,  4,    NULL, 'PREVENTIVE', 'COMPLETED',   '2025-12-01', '2025-12-02', '2025-12-01', '2025-12-02', 18500.00, 'Periodic service: engine oil, filters, track tension'),
(2,  3,  5,    NULL, 'PREVENTIVE', 'COMPLETED',   '2026-03-15', '2026-03-16', '2026-03-15', '2026-03-16', 16000.00, 'Periodic service: hydraulic oil and filters'),
(3,  11, 4,    9,    'CORRECTIVE', 'COMPLETED',   '2026-04-22', '2026-04-23', '2026-04-22', '2026-04-23',  9500.00, 'Replaced damaged hydraulic hose and outrigger pad'),
(4,  30, NULL, NULL, 'CORRECTIVE', 'COMPLETED',   '2026-05-10', '2026-05-12', '2026-05-10', '2026-05-12', 42000.00, 'Engine seizure assessed at dealer workshop; declared uneconomical, unit retired'),
(5,  2,  5,    NULL, 'PREVENTIVE', 'CANCELLED',   '2026-07-01', '2026-07-02', NULL,         NULL,             0.00, 'Cancelled: service postponed until after monsoon'),
(6,  16, 4,    NULL, 'PREVENTIVE', 'COMPLETED',   '2026-07-20', '2026-07-21', '2026-07-20', '2026-07-21', 14000.00, 'Drum bearing greasing, vibration system check'),
(7,  6,  5,    NULL, 'PREVENTIVE', 'COMPLETED',   '2026-08-10', '2026-08-10', '2026-08-10', '2026-08-10',  6500.00, 'Periodic service: oil, filters, tyre pressure'),
(8,  19, 5,    20,   'CORRECTIVE', 'COMPLETED',   '2026-09-04', '2026-09-10', '2026-09-04', '2026-09-11', 38000.00, 'Replaced hoist cylinder and tail-gate hinge (one day overrun)'),
(9,  24, 5,    NULL, 'INSPECTION', 'COMPLETED',   '2026-10-10', '2026-10-10', '2026-10-10', '2026-10-10',  2500.00, 'Load bank test and AVR inspection'),
(10, 25, 4,    NULL, 'PREVENTIVE', 'COMPLETED',   '2026-10-28', '2026-10-29', '2026-10-28', '2026-10-29', 12000.00, 'Periodic service after rental return'),
(11, 13, 4,    NULL, 'CORRECTIVE', 'IN_PROGRESS', '2026-11-17', '2026-11-24', '2026-11-17', NULL,             0.00, 'Boom extension cylinder leaking - seal kit replacement'),
(12, 5,  5,    NULL, 'PREVENTIVE', 'IN_PROGRESS', '2026-11-19', '2026-11-21', '2026-11-19', NULL,             0.00, 'Annual service: swing bearing, hydraulic pump inspection'),
(13, 21, 5,    NULL, 'PREVENTIVE', 'SCHEDULED',   '2026-11-26', '2026-11-27', NULL,         NULL,             0.00, 'Mast chain lubrication and brake check'),
(14, 12, 4,    NULL, 'INSPECTION', 'SCHEDULED',   '2026-11-24', '2026-11-24', NULL,         NULL,             0.00, 'Annual load test and safety certification'),
(15, 18, 5,    NULL, 'PREVENTIVE', 'SCHEDULED',   '2026-12-01', '2026-12-02', NULL,         NULL,             0.00, 'Usage-based service after current rental');

-- ---------------------------------------------------------------------
-- Audit log baseline: one "migrated" entry per seeded booking.
-- (From now on the log is written automatically by triggers.)
-- ---------------------------------------------------------------------
INSERT INTO booking_status_log (booking_id, old_status, new_status, changed_at, changed_by)
SELECT booking_id, NULL, booking_status, TIMESTAMP(booking_date, '10:00:00'), 'seed_data_migration'
FROM bookings
ORDER BY booking_id;

-- Row counts after seeding
SELECT 'customers' AS table_name, COUNT(*) AS row_count FROM customers
UNION ALL SELECT 'staff', COUNT(*) FROM staff
UNION ALL SELECT 'depots', COUNT(*) FROM depots
UNION ALL SELECT 'equipment_categories', COUNT(*) FROM equipment_categories
UNION ALL SELECT 'equipment_models', COUNT(*) FROM equipment_models
UNION ALL SELECT 'equipment_units', COUNT(*) FROM equipment_units
UNION ALL SELECT 'bookings', COUNT(*) FROM bookings
UNION ALL SELECT 'booking_items', COUNT(*) FROM booking_items
UNION ALL SELECT 'security_deposits', COUNT(*) FROM security_deposits
UNION ALL SELECT 'payments', COUNT(*) FROM payments
UNION ALL SELECT 'equipment_returns', COUNT(*) FROM equipment_returns
UNION ALL SELECT 'maintenance_records', COUNT(*) FROM maintenance_records
UNION ALL SELECT 'booking_status_log', COUNT(*) FROM booking_status_log;

DELIMITER ;
-- ##### END 02_seed_data.sql

-- #####################################################################
-- ##### BEGIN 06_views.sql
-- #####################################################################
-- =====================================================================
--  File   : 06_views.sql
--  Purpose: Reusable virtual tables for reporting (8 views)
--  Run    : after 02_seed_data.sql (views use only tables, no routines)
-- ---------------------------------------------------------------------
--  Design notes
--  * A view cannot take parameters, so "which machines are free between
--    date X and date Y?" is answered by the procedure sp_check_availability
--    (07_procedures_functions.sql), not by a view. Views here answer
--    questions about "today" = the business date in system_settings.
--  * Financial views aggregate every child table in its OWN derived table
--    before joining. Joining payments and booking_items directly would
--    multiply rows (fan-out) and inflate totals - a classic SQL mistake.
-- =====================================================================

USE construction_rental_db;

-- ---------------------------------------------------------------------
-- V1. vw_equipment_inventory
--     Every physical unit with its model, category, yard and its state
--     TODAY, derived from bookings + maintenance (not stored anywhere).
--     State priority: RETIRED > IN_MAINTENANCE > ON_RENT > RESERVED > AVAILABLE
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_equipment_inventory AS
SELECT
    u.equipment_id,
    u.asset_tag,
    c.category_name,
    m.manufacturer,
    m.model_name,
    d.depot_name,
    u.condition_rating,
    u.lifecycle_status,
    m.daily_rate        AS current_daily_rate,
    m.deposit_per_unit,
    CASE
        WHEN u.lifecycle_status = 'RETIRED' THEN 'RETIRED'
        WHEN EXISTS (SELECT 1 FROM maintenance_records mr
                     WHERE mr.equipment_id = u.equipment_id
                       AND mr.maintenance_status = 'IN_PROGRESS') THEN 'IN_MAINTENANCE'
        WHEN EXISTS (SELECT 1 FROM booking_items bi
                     JOIN bookings b ON b.booking_id = bi.booking_id
                     LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
                     WHERE bi.equipment_id = u.equipment_id
                       AND b.booking_status = 'ACTIVE'
                       AND r.return_id IS NULL) THEN 'ON_RENT'
        WHEN EXISTS (SELECT 1 FROM booking_items bi
                     JOIN bookings b ON b.booking_id = bi.booking_id
                     WHERE bi.equipment_id = u.equipment_id
                       AND b.booking_status = 'RESERVED'
                       AND s.bd BETWEEN b.start_date AND b.expected_return_date) THEN 'RESERVED'
        ELSE 'AVAILABLE'
    END AS current_state,
    (SELECT MIN(b.start_date)
       FROM booking_items bi
       JOIN bookings b ON b.booking_id = bi.booking_id
      WHERE bi.equipment_id = u.equipment_id
        AND b.booking_status = 'RESERVED'
        AND b.start_date > s.bd)                       AS next_reservation_start,
    (SELECT MIN(mr.scheduled_start)
       FROM maintenance_records mr
      WHERE mr.equipment_id = u.equipment_id
        AND mr.maintenance_status = 'SCHEDULED'
        AND mr.scheduled_start >= s.bd)                AS next_planned_maintenance
FROM equipment_units u
JOIN equipment_models     m ON m.model_id    = u.model_id
JOIN equipment_categories c ON c.category_id = m.category_id
JOIN depots               d ON d.depot_id    = u.depot_id
CROSS JOIN (SELECT COALESCE(business_date, CURDATE()) AS bd
            FROM system_settings WHERE settings_id = 1) s;

-- ---------------------------------------------------------------------
-- V2. vw_active_rentals
--     Units currently out with customers (booking ACTIVE, unit not returned).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_active_rentals AS
SELECT
    b.booking_id,
    bi.booking_item_id,
    COALESCE(cu.organisation_name, cu.full_name)   AS customer_name,
    cu.phone                                        AS customer_phone,
    u.asset_tag,
    CONCAT(m.manufacturer, ' ', m.model_name)       AS machine,
    b.site_address,
    b.start_date,
    b.expected_return_date,
    DATEDIFF(s.bd, b.start_date) + 1                AS days_out_so_far,
    DATEDIFF(b.expected_return_date, s.bd)          AS days_until_due,     -- negative = overdue
    CASE WHEN b.expected_return_date < s.bd THEN 'OVERDUE' ELSE 'ON_TIME' END AS rental_status
FROM bookings b
JOIN customers       cu ON cu.customer_id   = b.customer_id
JOIN booking_items   bi ON bi.booking_id    = b.booking_id
JOIN equipment_units u  ON u.equipment_id   = bi.equipment_id
JOIN equipment_models m ON m.model_id       = u.model_id
LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
CROSS JOIN (SELECT COALESCE(business_date, CURDATE()) AS bd
            FROM system_settings WHERE settings_id = 1) s
WHERE b.booking_status = 'ACTIVE'
  AND r.return_id IS NULL;

-- ---------------------------------------------------------------------
-- V3. vw_overdue_rentals
--     Units past their expected return date and still not returned,
--     with the late fee accrued so far (late days x rate x multiplier).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_overdue_rentals AS
SELECT
    b.booking_id,
    bi.booking_item_id,
    COALESCE(cu.organisation_name, cu.full_name)   AS customer_name,
    cu.phone                                        AS customer_phone,
    u.asset_tag,
    CONCAT(m.manufacturer, ' ', m.model_name)       AS machine,
    b.expected_return_date,
    DATEDIFF(s.bd, b.expected_return_date)          AS days_overdue,
    bi.agreed_daily_rate,
    ROUND(DATEDIFF(s.bd, b.expected_return_date) * bi.agreed_daily_rate * s.late_fee_multiplier, 2)
                                                    AS accrued_late_charge
FROM bookings b
JOIN customers       cu ON cu.customer_id = b.customer_id
JOIN booking_items   bi ON bi.booking_id  = b.booking_id
JOIN equipment_units u  ON u.equipment_id = bi.equipment_id
JOIN equipment_models m ON m.model_id     = u.model_id
LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
CROSS JOIN (SELECT COALESCE(business_date, CURDATE()) AS bd, late_fee_multiplier
            FROM system_settings WHERE settings_id = 1) s
WHERE b.booking_status = 'ACTIVE'
  AND r.return_id IS NULL
  AND b.expected_return_date < s.bd;

-- ---------------------------------------------------------------------
-- V4. vw_customer_rental_history
--     One row per machine per booking (line-item level, so no double
--     counting): what each customer rented, for how long, at what price
--     and how it came back.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_customer_rental_history AS
SELECT
    cu.customer_id,
    COALESCE(cu.organisation_name, cu.full_name)   AS customer_name,
    cu.customer_type,
    b.booking_id,
    b.booking_status,
    b.start_date,
    b.expected_return_date,
    u.asset_tag,
    c.category_name,
    CONCAT(m.manufacturer, ' ', m.model_name)       AS machine,
    bi.agreed_daily_rate,
    DATEDIFF(b.expected_return_date, b.start_date) + 1 AS rental_days,
    CASE WHEN b.booking_status = 'CANCELLED' THEN 0.00
         ELSE bi.agreed_daily_rate * (DATEDIFF(b.expected_return_date, b.start_date) + 1)
    END                                             AS line_rental_charge,
    r.return_date,
    r.return_condition,
    COALESCE(r.late_charge, 0.00)                   AS late_charge,
    COALESCE(r.damage_charge, 0.00)                 AS damage_charge
FROM customers cu
JOIN bookings             b  ON b.customer_id   = cu.customer_id
JOIN booking_items        bi ON bi.booking_id   = b.booking_id
JOIN equipment_units      u  ON u.equipment_id  = bi.equipment_id
JOIN equipment_models     m  ON m.model_id      = u.model_id
JOIN equipment_categories c  ON c.category_id   = m.category_id
LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id;

-- ---------------------------------------------------------------------
-- V5. vw_booking_financial_summary
--     One row per booking. Each child table is aggregated separately
--     (derived tables it, rc, pay) and then joined 1:1 to the booking.
--       total_charges  = rental + late fees + damage charges
--       amount_received = completed payments + deposit retained
--       balance_due    = total_charges - amount_received
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_booking_financial_summary AS
SELECT
    b.booking_id,
    COALESCE(cu.organisation_name, cu.full_name)          AS customer_name,
    b.booking_status,
    b.start_date,
    b.expected_return_date,
    DATEDIFF(b.expected_return_date, b.start_date) + 1    AS rental_days,
    it.unit_count,
    CASE WHEN b.booking_status = 'CANCELLED' THEN 0.00
         ELSE it.sum_daily_rate * (DATEDIFF(b.expected_return_date, b.start_date) + 1)
    END                                                   AS rental_charge,
    COALESCE(rc.late_charges, 0.00)                       AS late_charges,
    COALESCE(rc.damage_charges, 0.00)                     AS damage_charges,
    CASE WHEN b.booking_status = 'CANCELLED' THEN 0.00
         ELSE it.sum_daily_rate * (DATEDIFF(b.expected_return_date, b.start_date) + 1)
    END + COALESCE(rc.late_charges, 0.00) + COALESCE(rc.damage_charges, 0.00)
                                                          AS total_charges,
    COALESCE(pay.paid_amount, 0.00)                       AS payments_received,
    COALESCE(sd.retained_amount, 0.00)                    AS deposit_retained,
    COALESCE(pay.paid_amount, 0.00) + COALESCE(sd.retained_amount, 0.00)
                                                          AS amount_received,
    CASE WHEN b.booking_status = 'CANCELLED' THEN 0.00
         ELSE it.sum_daily_rate * (DATEDIFF(b.expected_return_date, b.start_date) + 1)
    END + COALESCE(rc.late_charges, 0.00) + COALESCE(rc.damage_charges, 0.00)
        - COALESCE(pay.paid_amount, 0.00) - COALESCE(sd.retained_amount, 0.00)
                                                          AS balance_due,
    sd.required_amount                                    AS deposit_required,
    sd.collected_amount                                   AS deposit_collected,
    sd.refunded_amount                                    AS deposit_refunded,
    COALESCE(sd.deposit_status, 'NOT_REQUIRED')           AS deposit_status
FROM bookings b
JOIN customers cu ON cu.customer_id = b.customer_id
JOIN (SELECT booking_id, COUNT(*) AS unit_count, SUM(agreed_daily_rate) AS sum_daily_rate
      FROM booking_items GROUP BY booking_id) it
     ON it.booking_id = b.booking_id
LEFT JOIN (SELECT bi.booking_id,
                  SUM(r.late_charge)   AS late_charges,
                  SUM(r.damage_charge) AS damage_charges
           FROM equipment_returns r
           JOIN booking_items bi ON bi.booking_item_id = r.booking_item_id
           GROUP BY bi.booking_id) rc
     ON rc.booking_id = b.booking_id
LEFT JOIN (SELECT booking_id, SUM(amount) AS paid_amount
           FROM payments WHERE payment_status = 'COMPLETED'
           GROUP BY booking_id) pay
     ON pay.booking_id = b.booking_id
LEFT JOIN security_deposits sd ON sd.booking_id = b.booking_id;

-- ---------------------------------------------------------------------
-- V6. vw_maintenance_summary
--     Per active unit: maintenance history, cost, and usage-based service
--     status. usage_days_since_service = rental days the unit has been out
--     since its last COMPLETED preventive service (or since purchase).
--       OVERDUE   usage >= service interval
--       DUE_SOON  usage >= interval - 5
--       SERVICE_SCHEDULED  due/overdue but a preventive job is already planned
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_maintenance_summary AS
SELECT
    x.equipment_id,
    x.asset_tag,
    x.machine,
    x.total_jobs,
    x.completed_jobs,
    x.total_maintenance_cost,
    x.last_preventive_service,
    x.usage_days_since_service,
    x.service_interval_rental_days,
    x.currently_in_maintenance,
    x.next_scheduled_job,
    CASE
        WHEN x.usage_days_since_service >= x.service_interval_rental_days - 5
             AND x.next_preventive_planned IS NOT NULL                       THEN 'SERVICE_SCHEDULED'
        WHEN x.usage_days_since_service >= x.service_interval_rental_days     THEN 'OVERDUE'
        WHEN x.usage_days_since_service >= x.service_interval_rental_days - 5 THEN 'DUE_SOON'
        ELSE 'OK'
    END AS service_status
FROM (
    SELECT
        u.equipment_id,
        u.asset_tag,
        CONCAT(m.manufacturer, ' ', m.model_name)              AS machine,
        m.service_interval_rental_days,
        COALESCE(mh.total_jobs, 0)                             AS total_jobs,
        COALESCE(mh.completed_jobs, 0)                         AS completed_jobs,
        COALESCE(mh.total_cost, 0.00)                          AS total_maintenance_cost,
        mh.last_preventive_service,
        mh.next_scheduled_job,
        mh.next_preventive_planned,
        CASE WHEN mh.in_progress_jobs > 0 THEN 'YES' ELSE 'NO' END AS currently_in_maintenance,
        COALESCE((
            SELECT SUM(GREATEST(0,
                     DATEDIFF(LEAST(COALESCE(r.return_date, s.bd), s.bd),
                              GREATEST(b.start_date,
                                       DATE_ADD(COALESCE(mh.last_preventive_service, u.purchase_date), INTERVAL 1 DAY))) + 1))
            FROM booking_items bi
            JOIN bookings b ON b.booking_id = bi.booking_id
            LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
            WHERE bi.equipment_id = u.equipment_id
              AND b.booking_status IN ('ACTIVE','COMPLETED')
        ), 0)                                                  AS usage_days_since_service
    FROM equipment_units u
    JOIN equipment_models m ON m.model_id = u.model_id
    CROSS JOIN (SELECT COALESCE(business_date, CURDATE()) AS bd
                FROM system_settings WHERE settings_id = 1) s
    LEFT JOIN (
        SELECT equipment_id,
               COUNT(*)                                                       AS total_jobs,
               SUM(maintenance_status = 'COMPLETED')                          AS completed_jobs,
               SUM(maintenance_status = 'IN_PROGRESS')                        AS in_progress_jobs,
               SUM(CASE WHEN maintenance_status = 'COMPLETED' THEN maintenance_cost ELSE 0 END) AS total_cost,
               MAX(CASE WHEN maintenance_type = 'PREVENTIVE' AND maintenance_status = 'COMPLETED'
                        THEN actual_end END)                                  AS last_preventive_service,
               MIN(CASE WHEN maintenance_status = 'SCHEDULED' THEN scheduled_start END) AS next_scheduled_job,
               MIN(CASE WHEN maintenance_status = 'SCHEDULED' AND maintenance_type = 'PREVENTIVE'
                        THEN scheduled_start END)                             AS next_preventive_planned
        FROM maintenance_records
        GROUP BY equipment_id
    ) mh ON mh.equipment_id = u.equipment_id
    WHERE u.lifecycle_status = 'ACTIVE'
) x;

-- ---------------------------------------------------------------------
-- V7. vw_equipment_revenue
--     Revenue earned by each physical unit from ACTIVE and COMPLETED
--     bookings (reserved = not yet earned, cancelled = no revenue),
--     compared with what was spent maintaining it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_equipment_revenue AS
SELECT
    u.equipment_id,
    u.asset_tag,
    c.category_name,
    CONCAT(m.manufacturer, ' ', m.model_name)                 AS machine,
    u.lifecycle_status,
    COALESCE(rv.times_rented, 0)                              AS times_rented,
    COALESCE(rv.days_billed, 0)                               AS days_billed,
    COALESCE(rv.rental_revenue, 0.00)                         AS rental_revenue,
    COALESCE(rv.late_fees, 0.00)                              AS late_fees,
    COALESCE(rv.damage_recovered, 0.00)                       AS damage_recovered,
    COALESCE(rv.rental_revenue, 0) + COALESCE(rv.late_fees, 0) + COALESCE(rv.damage_recovered, 0)
                                                              AS total_revenue,
    COALESCE(mc.maintenance_cost, 0.00)                       AS maintenance_cost,
    COALESCE(rv.rental_revenue, 0) + COALESCE(rv.late_fees, 0) + COALESCE(rv.damage_recovered, 0)
        - COALESCE(mc.maintenance_cost, 0)                    AS net_contribution
FROM equipment_units u
JOIN equipment_models     m ON m.model_id    = u.model_id
JOIN equipment_categories c ON c.category_id = m.category_id
LEFT JOIN (
    SELECT bi.equipment_id,
           COUNT(*)                                                         AS times_rented,
           SUM(DATEDIFF(b.expected_return_date, b.start_date) + 1)          AS days_billed,
           SUM(bi.agreed_daily_rate * (DATEDIFF(b.expected_return_date, b.start_date) + 1)) AS rental_revenue,
           SUM(COALESCE(r.late_charge, 0))                                  AS late_fees,
           SUM(COALESCE(r.damage_charge, 0))                                AS damage_recovered
    FROM booking_items bi
    JOIN bookings b ON b.booking_id = bi.booking_id
    LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id   -- at most 1 per item: no fan-out
    WHERE b.booking_status IN ('ACTIVE','COMPLETED')
    GROUP BY bi.equipment_id
) rv ON rv.equipment_id = u.equipment_id
LEFT JOIN (
    SELECT equipment_id, SUM(maintenance_cost) AS maintenance_cost
    FROM maintenance_records
    WHERE maintenance_status = 'COMPLETED'
    GROUP BY equipment_id
) mc ON mc.equipment_id = u.equipment_id;

-- ---------------------------------------------------------------------
-- V8. vw_pending_deposit_refunds
--     Deposits still HELD although the rental is over. Shows how much
--     should be retained (to clear unpaid charges) and how much refunded.
--     Built on top of V5 (a view can query another view).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW vw_pending_deposit_refunds AS
SELECT
    f.booking_id,
    f.customer_name,
    f.booking_status,
    f.expected_return_date,
    f.deposit_collected,
    f.balance_due                                              AS unpaid_charges,
    LEAST(f.deposit_collected, GREATEST(f.balance_due, 0))     AS amount_to_retain,
    f.deposit_collected - LEAST(f.deposit_collected, GREATEST(f.balance_due, 0)) AS amount_to_refund
FROM vw_booking_financial_summary f
WHERE f.deposit_status = 'HELD'
  AND f.booking_status IN ('COMPLETED','CANCELLED');

-- List the views that now exist
SELECT table_name AS view_name
FROM information_schema.views
WHERE table_schema = 'construction_rental_db'
ORDER BY table_name;

DELIMITER ;
-- ##### END 06_views.sql

-- #####################################################################
-- ##### BEGIN 07_procedures_functions.sql
-- #####################################################################
-- =====================================================================
--  File   : 07_procedures_functions.sql
--  Purpose: Business logic as MySQL stored programs
--           7 functions + 14 procedures
--  Run    : after 06_views.sql and BEFORE 08_triggers.sql
--           (the triggers call fn_unit_conflict, fn_late_charge, ...)
-- ---------------------------------------------------------------------
--  CONVENTIONS USED EVERYWHERE
--  * Rental period is INCLUSIVE: days = DATEDIFF(end, start) + 1.
--  * Two periods [s1,e1] and [s2,e2] overlap  <=>  s1 <= e2 AND s2 <= e1.
--    Because dates are inclusive, a unit returned on 10-Dec can be rented
--    again from 11-Dec (the return day is used for check-in/inspection).
--  * "Today" = fn_business_date() (system_settings.business_date).
--  * Errors are raised with SIGNAL SQLSTATE '45000' and a clear message.
--  * Every procedure that writes data runs inside START TRANSACTION ...
--    COMMIT, with an EXIT HANDLER that ROLLBACKs and re-raises (RESIGNAL)
--    the error, so a failure never leaves half-written data (Atomicity).
--  * Procedures that call START TRANSACTION implicitly COMMIT any
--    transaction the caller already had open - call them in autocommit mode.
-- ---------------------------------------------------------------------
--  CONCURRENCY STRATEGY (preventing double booking)
--  MySQL has no "exclusion constraint" for overlapping date ranges, and a
--  plain "SELECT to check, then INSERT" is unsafe: two sessions can both
--  run the SELECT, both see the unit free, and both INSERT.
--  Solution used here:
--   1. Before checking a unit, lock its parent row:
--        SELECT ... FROM equipment_units WHERE equipment_id = ? FOR UPDATE;
--      A second session wanting the SAME unit now waits until the first
--      COMMITs or ROLLBACKs (requests for different units do not block).
--   2. The overlap check reads the LATEST committed data (locking read
--      FOR SHARE inside fn_unit_conflict, and READ COMMITTED isolation in
--      the booking procedure), so the waiting session sees the first
--      session's new booking once it gets the lock -> it is rejected.
--   3. Multi-unit bookings lock units in ascending equipment_id order so
--      two sessions can never wait on each other in a cycle (deadlock).
--   4. The BEFORE INSERT trigger on booking_items repeats steps 1-2, so
--      even a hand-written INSERT cannot create an overlap.
-- =====================================================================

USE construction_rental_db;

DROP FUNCTION  IF EXISTS fn_business_date;
DROP FUNCTION  IF EXISTS fn_rental_days;
DROP FUNCTION  IF EXISTS fn_unit_conflict;
DROP FUNCTION  IF EXISTS fn_booking_rental_charge;
DROP FUNCTION  IF EXISTS fn_late_charge;
DROP FUNCTION  IF EXISTS fn_booking_total_charges;
DROP FUNCTION  IF EXISTS fn_booking_amount_received;
DROP PROCEDURE IF EXISTS sp_set_business_date;
DROP PROCEDURE IF EXISTS sp_check_availability;
DROP PROCEDURE IF EXISTS sp_create_booking;
DROP PROCEDURE IF EXISTS sp_collect_deposit;
DROP PROCEDURE IF EXISTS sp_start_rental;
DROP PROCEDURE IF EXISTS sp_record_payment;
DROP PROCEDURE IF EXISTS sp_return_equipment;
DROP PROCEDURE IF EXISTS sp_settle_deposit;
DROP PROCEDURE IF EXISTS sp_cancel_booking;
DROP PROCEDURE IF EXISTS sp_schedule_maintenance;
DROP PROCEDURE IF EXISTS sp_start_maintenance;
DROP PROCEDURE IF EXISTS sp_complete_maintenance;
DROP PROCEDURE IF EXISTS sp_overdue_report;
DROP PROCEDURE IF EXISTS sp_customer_statement;

DELIMITER $$

-- =====================================================================
--                              FUNCTIONS
-- =====================================================================

-- F1. Business "today" (fixed demo date, or real date if setting is NULL)
CREATE FUNCTION fn_business_date()
RETURNS DATE
NOT DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_date DATE;
    SET v_date = (SELECT business_date FROM system_settings WHERE settings_id = 1);
    RETURN COALESCE(v_date, CURDATE());
END$$

-- F2. Inclusive rental days between two dates
CREATE FUNCTION fn_rental_days(p_start DATE, p_end DATE)
RETURNS INT
DETERMINISTIC
NO SQL
BEGIN
    RETURN DATEDIFF(p_end, p_start) + 1;
END$$

-- F3. Why can't this unit be used in [p_start, p_end]?
--     Returns NULL when the unit is free, otherwise a reason code:
--     UNIT_NOT_FOUND | UNIT_RETIRED | NOT_YET_PURCHASED |
--     BOOKING_CONFLICT | MAINTENANCE_CONFLICT
--     p_ignore_booking_id / p_ignore_maintenance_id let a record be
--     re-checked without colliding with itself (pass NULL normally).
--
--     How long does an existing booking item block the unit?
--       returned              -> start_date .. return_date
--       ACTIVE and overdue    -> start_date .. "forever" (until it comes back)
--       otherwise             -> start_date .. expected_return_date
--     How long does a maintenance job block the unit?
--       SCHEDULED             -> scheduled_start .. scheduled_end
--       IN_PROGRESS           -> actual_start .. scheduled_end
--                                ("forever" if it has overrun its schedule)
--       COMPLETED             -> actual_start .. actual_end
--       CANCELLED             -> nothing
--     The SELECTs use FOR SHARE (locking read) so they always see the
--     latest committed rows - required for the concurrency guarantee.
CREATE FUNCTION fn_unit_conflict(p_equipment_id INT, p_start DATE, p_end DATE,
                                 p_ignore_booking_id INT, p_ignore_maintenance_id INT)
RETURNS VARCHAR(30)
NOT DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_status   VARCHAR(10);
    DECLARE v_purchase DATE;
    DECLARE v_count    INT DEFAULT 0;
    DECLARE v_today    DATE DEFAULT fn_business_date();

    SELECT lifecycle_status, purchase_date INTO v_status, v_purchase
    FROM equipment_units WHERE equipment_id = p_equipment_id;

    IF v_status IS NULL THEN
        RETURN 'UNIT_NOT_FOUND';
    ELSEIF v_status = 'RETIRED' THEN
        RETURN 'UNIT_RETIRED';
    ELSEIF p_start < v_purchase THEN
        RETURN 'NOT_YET_PURCHASED';
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM booking_items bi
    JOIN bookings b ON b.booking_id = bi.booking_id
    LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
    WHERE bi.equipment_id = p_equipment_id
      AND b.booking_status IN ('RESERVED','ACTIVE','COMPLETED')
      AND b.booking_id <> COALESCE(p_ignore_booking_id, 0)
      AND b.start_date <= p_end
      AND (CASE
               WHEN r.return_id IS NOT NULL THEN r.return_date
               WHEN b.booking_status = 'ACTIVE' AND b.expected_return_date < v_today THEN DATE('9999-12-31')
               ELSE b.expected_return_date
           END) >= p_start
    FOR SHARE;

    IF v_count > 0 THEN
        RETURN 'BOOKING_CONFLICT';
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM maintenance_records mr
    WHERE mr.equipment_id = p_equipment_id
      AND mr.maintenance_status IN ('SCHEDULED','IN_PROGRESS','COMPLETED')
      AND mr.maintenance_id <> COALESCE(p_ignore_maintenance_id, 0)
      AND COALESCE(mr.actual_start, mr.scheduled_start) <= p_end
      AND (CASE mr.maintenance_status
               WHEN 'COMPLETED' THEN mr.actual_end
               WHEN 'IN_PROGRESS' THEN
                    IF(mr.scheduled_end < v_today, DATE('9999-12-31'), mr.scheduled_end)
               ELSE mr.scheduled_end
           END) >= p_start
    FOR SHARE;

    IF v_count > 0 THEN
        RETURN 'MAINTENANCE_CONFLICT';
    END IF;

    RETURN NULL;
END$$

-- F4. Base rental charge of a booking = SUM(agreed daily rates) x days
--     (cancelled bookings earn nothing). Early return does NOT reduce it.
CREATE FUNCTION fn_booking_rental_charge(p_booking_id INT)
RETURNS DECIMAL(12,2)
NOT DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_total DECIMAL(12,2) DEFAULT 0;
    SELECT CASE WHEN b.booking_status = 'CANCELLED' THEN 0
                ELSE COALESCE(SUM(bi.agreed_daily_rate), 0)
                     * fn_rental_days(b.start_date, b.expected_return_date) END
      INTO v_total
    FROM bookings b
    LEFT JOIN booking_items bi ON bi.booking_id = b.booking_id
    WHERE b.booking_id = p_booking_id
    GROUP BY b.booking_id, b.booking_status, b.start_date, b.expected_return_date;
    RETURN COALESCE(v_total, 0);
END$$

-- F5. Late fee for returning one booking item on p_return_date
--     = late days x agreed daily rate x late_fee_multiplier (default 1.5)
--     Single source of truth: used by sp_return_equipment AND validated by
--     the trigger on equipment_returns.
CREATE FUNCTION fn_late_charge(p_booking_item_id INT, p_return_date DATE)
RETURNS DECIMAL(12,2)
NOT DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_rate DECIMAL(10,2);
    DECLARE v_due  DATE;
    DECLARE v_mult DECIMAL(4,2);

    SELECT bi.agreed_daily_rate, b.expected_return_date INTO v_rate, v_due
    FROM booking_items bi JOIN bookings b ON b.booking_id = bi.booking_id
    WHERE bi.booking_item_id = p_booking_item_id;

    SET v_mult = (SELECT late_fee_multiplier FROM system_settings WHERE settings_id = 1);

    RETURN ROUND(GREATEST(0, DATEDIFF(p_return_date, v_due)) * v_rate * COALESCE(v_mult, 1.50), 2);
END$$

-- F6. Everything the customer owes for a booking (rental + late + damage)
CREATE FUNCTION fn_booking_total_charges(p_booking_id INT)
RETURNS DECIMAL(12,2)
NOT DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_extra DECIMAL(12,2);
    SELECT COALESCE(SUM(r.late_charge + r.damage_charge), 0) INTO v_extra
    FROM equipment_returns r
    JOIN booking_items bi ON bi.booking_item_id = r.booking_item_id
    WHERE bi.booking_id = p_booking_id;
    RETURN fn_booking_rental_charge(p_booking_id) + v_extra;
END$$

-- F7. Everything received against the charges
--     (completed payments + any part of the deposit that was retained)
CREATE FUNCTION fn_booking_amount_received(p_booking_id INT)
RETURNS DECIMAL(12,2)
NOT DETERMINISTIC
READS SQL DATA
BEGIN
    DECLARE v_paid     DECIMAL(12,2);
    DECLARE v_retained DECIMAL(12,2);
    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM payments WHERE booking_id = p_booking_id AND payment_status = 'COMPLETED';
    SET v_retained = (SELECT retained_amount FROM security_deposits WHERE booking_id = p_booking_id);
    RETURN v_paid + COALESCE(v_retained, 0);
END$$

-- =====================================================================
--                              PROCEDURES
-- =====================================================================

-- P1. Move the demo "today" (e.g. to show a booking becoming overdue)
CREATE PROCEDURE sp_set_business_date(IN p_date DATE)
BEGIN
    UPDATE system_settings SET business_date = p_date WHERE settings_id = 1;
    SELECT fn_business_date() AS business_date_now;
END$$

-- P2. Machines available for EVERY day of [p_start, p_end]
--     p_category_id = NULL -> all categories
CREATE PROCEDURE sp_check_availability(IN p_start DATE, IN p_end DATE, IN p_category_id INT)
BEGIN
    IF p_start IS NULL OR p_end IS NULL OR p_end < p_start THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid period: end date must be on or after start date';
    END IF;

    SELECT u.equipment_id,
           u.asset_tag,
           c.category_name,
           CONCAT(m.manufacturer, ' ', m.model_name)           AS machine,
           d.depot_name,
           u.condition_rating,
           m.daily_rate,
           fn_rental_days(p_start, p_end)                      AS rental_days,
           m.daily_rate * fn_rental_days(p_start, p_end)       AS estimated_rental,
           m.deposit_per_unit                                  AS deposit_per_unit
    FROM equipment_units u
    JOIN equipment_models     m ON m.model_id    = u.model_id
    JOIN equipment_categories c ON c.category_id = m.category_id
    JOIN depots               d ON d.depot_id    = u.depot_id
    WHERE u.lifecycle_status = 'ACTIVE'
      AND (p_category_id IS NULL OR c.category_id = p_category_id)
      AND fn_unit_conflict(u.equipment_id, p_start, p_end, NULL, NULL) IS NULL
    ORDER BY c.category_name, m.daily_rate, u.asset_tag;
END$$

-- P3. Create a booking for one or more machines - ALL OR NOTHING.
--     p_equipment_ids: comma-separated equipment ids, e.g. '7,21,26'
--     Demonstrates: parameters (IN/OUT), variables, WHILE loop, IF,
--     CURSOR with NOT FOUND handler, EXIT handler, transaction, row locks.
CREATE PROCEDURE sp_create_booking(
    IN  p_customer_id   INT,
    IN  p_staff_id      INT,
    IN  p_start         DATE,
    IN  p_end           DATE,
    IN  p_equipment_ids VARCHAR(255),
    IN  p_site_address  VARCHAR(200),
    OUT p_booking_id    INT)
BEGIN
    DECLARE v_today       DATE DEFAULT fn_business_date();
    DECLARE v_max_days    INT;
    DECLARE v_list        VARCHAR(255);
    DECLARE v_token       VARCHAR(20);
    DECLARE v_unit_count  INT DEFAULT 0;
    DECLARE v_cust_active BOOLEAN;
    DECLARE v_cust_type   VARCHAR(12);
    DECLARE v_staff_ok    INT DEFAULT 0;
    DECLARE v_eq_id       INT;
    DECLARE v_tag         VARCHAR(20);
    DECLARE v_reason      VARCHAR(30);
    DECLARE v_deposit     DECIMAL(12,2) DEFAULT 0;
    DECLARE v_rate        DECIMAL(10,2);
    DECLARE v_unit_deposit DECIMAL(10,2);
    DECLARE v_done        INT DEFAULT 0;
    DECLARE v_msg         VARCHAR(255);

    -- cursor walks the requested units in ascending id order (deadlock-safe locking)
    DECLARE cur_units CURSOR FOR
        SELECT equipment_id FROM tmp_requested_units ORDER BY equipment_id;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        DROP TEMPORARY TABLE IF EXISTS tmp_requested_units;
        SET p_booking_id = NULL;
        RESIGNAL;                       -- pass the original error to the caller
    END;

    SET p_booking_id = NULL;

    -- ---------- 1. validate simple inputs ----------
    SELECT max_rental_days INTO v_max_days FROM system_settings WHERE settings_id = 1;

    IF p_start IS NULL OR p_end IS NULL OR p_end < p_start THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid rental period: expected return date is before start date';
    END IF;
    IF p_start < v_today THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Rental cannot start in the past';
    END IF;
    IF fn_rental_days(p_start, p_end) > v_max_days THEN
        SET v_msg = CONCAT('Rental period exceeds the maximum of ', v_max_days, ' days');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;
    IF p_equipment_ids IS NULL OR TRIM(p_equipment_ids) = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'At least one equipment id is required';
    END IF;

    SELECT COUNT(*) INTO v_staff_ok FROM staff
    WHERE staff_id = p_staff_id AND is_active = TRUE AND staff_role IN ('RENTAL_AGENT','MANAGER');
    IF v_staff_ok = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Booking must be created by an active rental agent or manager';
    END IF;

    -- ---------- 2. parse '7,21,26' into a temporary table (WHILE loop) ----------
    DROP TEMPORARY TABLE IF EXISTS tmp_requested_units;
    CREATE TEMPORARY TABLE tmp_requested_units (equipment_id INT PRIMARY KEY);

    SET v_list = CONCAT(REPLACE(p_equipment_ids, ' ', ''), ',');
    WHILE LOCATE(',', v_list) > 0 DO
        SET v_token = SUBSTRING_INDEX(v_list, ',', 1);
        SET v_list  = SUBSTRING(v_list, LOCATE(',', v_list) + 1);
        IF v_token <> '' THEN
            IF v_token NOT REGEXP '^[0-9]+$' THEN
                SET v_msg = CONCAT('Invalid equipment id: ', v_token);
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
            END IF;
            IF EXISTS (SELECT 1 FROM tmp_requested_units WHERE equipment_id = CAST(v_token AS UNSIGNED)) THEN
                SET v_msg = CONCAT('Equipment id ', v_token, ' is listed more than once');
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
            END IF;
            INSERT INTO tmp_requested_units VALUES (CAST(v_token AS UNSIGNED));
            SET v_unit_count = v_unit_count + 1;
        END IF;
    END WHILE;

    IF v_unit_count = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'At least one equipment id is required';
    END IF;
    IF EXISTS (SELECT 1 FROM tmp_requested_units t
               WHERE NOT EXISTS (SELECT 1 FROM equipment_units u WHERE u.equipment_id = t.equipment_id)) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'One or more equipment ids do not exist';
    END IF;

    -- ---------- 3. the atomic part ----------
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;   -- each read sees latest committed data
    START TRANSACTION;

    -- customer must exist and be active (shared lock: nobody deactivates it meanwhile)
    SELECT is_active, customer_type INTO v_cust_active, v_cust_type
    FROM customers WHERE customer_id = p_customer_id FOR SHARE;
    IF v_done = 1 OR v_cust_active IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Customer does not exist';
    END IF;
    IF v_cust_active = FALSE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Customer account is inactive';
    END IF;

    -- booking header first (rolled back automatically if any unit fails)
    INSERT INTO bookings (customer_id, created_by_staff_id, booking_date, start_date,
                          expected_return_date, booking_status, site_address)
    VALUES (p_customer_id, p_staff_id, v_today, p_start, p_end, 'RESERVED', p_site_address);
    SET p_booking_id = LAST_INSERT_ID();

    -- for every requested unit (ascending id): lock it, check it, add it
    OPEN cur_units;
    unit_loop: LOOP
        FETCH cur_units INTO v_eq_id;
        IF v_done = 1 THEN
            LEAVE unit_loop;
        END IF;

        SELECT u.asset_tag, m.daily_rate, m.deposit_per_unit
          INTO v_tag, v_rate, v_unit_deposit
        FROM equipment_units u JOIN equipment_models m ON m.model_id = u.model_id
        WHERE u.equipment_id = v_eq_id
        FOR UPDATE;                                    -- serialises bookings of this unit

        SET v_reason = fn_unit_conflict(v_eq_id, p_start, p_end, NULL, NULL);
        IF v_reason IS NOT NULL THEN
            SET v_msg = CONCAT('Equipment ', v_tag, ' is not available for the requested period (', v_reason, ')');
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;   -- -> EXIT handler -> ROLLBACK of everything
        END IF;

        -- price snapshot: today's list price becomes the agreed price.
        -- (Row-by-row VALUES insert: MySQL error 1442 forbids the item trigger
        --  from locking equipment_units if this INSERT itself SELECTed from it.)
        INSERT INTO booking_items (booking_id, equipment_id, agreed_daily_rate)
        VALUES (p_booking_id, v_eq_id, v_rate);
        SET v_deposit = v_deposit + v_unit_deposit;
    END LOOP;
    CLOSE cur_units;

    -- security deposit (government customers are exempt - rule BR-D1)
    IF v_cust_type <> 'GOVERNMENT' THEN
        IF v_deposit > 0 THEN
            INSERT INTO security_deposits (booking_id, required_amount, deposit_status)
            VALUES (p_booking_id, v_deposit, 'PENDING');
        END IF;
    END IF;

    COMMIT;
    DROP TEMPORARY TABLE IF EXISTS tmp_requested_units;

    SELECT b.booking_id, b.booking_status, b.start_date, b.expected_return_date,
           fn_rental_days(b.start_date, b.expected_return_date) AS rental_days,
           v_unit_count                                        AS units_booked,
           fn_booking_rental_charge(b.booking_id)              AS rental_charge,
           COALESCE(sd.required_amount, 0)                     AS deposit_required
    FROM bookings b
    LEFT JOIN security_deposits sd ON sd.booking_id = b.booking_id
    WHERE b.booking_id = p_booking_id;
END$$

-- P4. Collect the full security deposit (PENDING -> HELD)
CREATE PROCEDURE sp_collect_deposit(IN p_booking_id INT)
BEGIN
    DECLARE v_status VARCHAR(20);
    DECLARE v_bstatus VARCHAR(20);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

    START TRANSACTION;
    SELECT b.booking_status, sd.deposit_status INTO v_bstatus, v_status
    FROM bookings b LEFT JOIN security_deposits sd ON sd.booking_id = b.booking_id
    WHERE b.booking_id = p_booking_id
    FOR UPDATE;

    IF v_bstatus IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Booking does not exist';
    ELSEIF v_bstatus <> 'RESERVED' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Deposit can only be collected for a RESERVED booking';
    ELSEIF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This booking does not require a security deposit';
    ELSEIF v_status <> 'PENDING' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Deposit has already been collected or closed';
    END IF;

    UPDATE security_deposits
       SET collected_amount = required_amount,
           collected_date   = fn_business_date(),
           deposit_status   = 'HELD'
     WHERE booking_id = p_booking_id;
    COMMIT;

    SELECT * FROM security_deposits WHERE booking_id = p_booking_id;
END$$

-- P5. Hand the machines over to the customer (RESERVED -> ACTIVE).
--     The bookings trigger refuses this if the deposit is not HELD.
CREATE PROCEDURE sp_start_rental(IN p_booking_id INT)
BEGIN
    DECLARE v_status VARCHAR(20);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

    START TRANSACTION;
    SELECT booking_status INTO v_status FROM bookings WHERE booking_id = p_booking_id FOR UPDATE;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Booking does not exist';
    END IF;
    UPDATE bookings SET booking_status = 'ACTIVE' WHERE booking_id = p_booking_id;
    COMMIT;

    SELECT booking_id, booking_status, start_date, expected_return_date
    FROM bookings WHERE booking_id = p_booking_id;
END$$

-- P6. Record a customer payment (always COMPLETED, dated today).
--     The booking row is locked so two cashiers cannot overpay together.
CREATE PROCEDURE sp_record_payment(
    IN  p_booking_id INT,
    IN  p_amount     DECIMAL(12,2),
    IN  p_method     VARCHAR(20),
    IN  p_type       VARCHAR(20),
    IN  p_reference  VARCHAR(40),
    OUT p_payment_id INT)
BEGIN
    DECLARE v_status VARCHAR(20);
    DECLARE v_balance DECIMAL(12,2);
    DECLARE v_msg VARCHAR(255);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET p_payment_id = NULL; RESIGNAL; END;

    SET p_payment_id = NULL;
    IF p_amount IS NULL OR p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment amount must be greater than zero';
    END IF;

    START TRANSACTION;
    SELECT booking_status INTO v_status FROM bookings WHERE booking_id = p_booking_id FOR UPDATE;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Booking does not exist';
    ELSEIF v_status = 'CANCELLED' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cannot take payment for a cancelled booking';
    END IF;

    SET v_balance = fn_booking_total_charges(p_booking_id) - fn_booking_amount_received(p_booking_id);
    IF p_amount > v_balance THEN
        SET v_msg = CONCAT('Payment of Rs ', p_amount, ' exceeds the balance due of Rs ', v_balance);
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    INSERT INTO payments (booking_id, amount, payment_date, payment_method, payment_type, payment_status, reference_no)
    VALUES (p_booking_id, p_amount, fn_business_date(), p_method, p_type, 'COMPLETED', p_reference);
    SET p_payment_id = LAST_INSERT_ID();
    COMMIT;

    SELECT p_payment_id AS payment_id, p_amount AS amount_paid,
           fn_booking_total_charges(p_booking_id) - fn_booking_amount_received(p_booking_id) AS balance_remaining;
END$$

-- P7. Return ONE machine of a booking (partial returns supported).
--     * late fee calculated by fn_late_charge (late days x rate x 1.5)
--     * damage charge entered by the inspecting staff member
--     * MAJOR_DAMAGE automatically schedules a 7-day corrective repair
--       starting the day after return, if the unit is free then
--     * when the last machine comes back, the trigger on equipment_returns
--       marks the booking COMPLETED
CREATE PROCEDURE sp_return_equipment(
    IN  p_booking_item_id INT,
    IN  p_return_date     DATE,          -- NULL = today
    IN  p_condition       VARCHAR(20),   -- GOOD | MINOR_DAMAGE | MAJOR_DAMAGE
    IN  p_damage_charge   DECIMAL(12,2),
    IN  p_damage_desc     VARCHAR(255),
    IN  p_staff_id        INT,
    OUT p_return_id       INT)
BEGIN
    DECLARE v_booking_id INT;
    DECLARE v_status     VARCHAR(20);
    DECLARE v_start      DATE;
    DECLARE v_due        DATE;
    DECLARE v_eq_id      INT;
    DECLARE v_date       DATE;
    DECLARE v_late       DECIMAL(12,2);
    DECLARE v_repair_note VARCHAR(200) DEFAULT 'No repair needed';
    DECLARE v_maint_id   INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET p_return_id = NULL; RESIGNAL; END;

    SET p_return_id = NULL;
    SET v_date = COALESCE(p_return_date, fn_business_date());
    SET p_damage_charge = COALESCE(p_damage_charge, 0);

    IF p_condition NOT IN ('GOOD','MINOR_DAMAGE','MAJOR_DAMAGE') OR p_condition IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Condition must be GOOD, MINOR_DAMAGE or MAJOR_DAMAGE';
    END IF;
    IF p_condition = 'GOOD' AND p_damage_charge <> 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A unit returned in GOOD condition cannot carry a damage charge';
    END IF;

    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;

    -- lock the booking so two clerks cannot process the same booking at once
    SELECT b.booking_id, b.booking_status, b.start_date, b.expected_return_date, bi.equipment_id
      INTO v_booking_id, v_status, v_start, v_due, v_eq_id
    FROM booking_items bi JOIN bookings b ON b.booking_id = bi.booking_id
    WHERE bi.booking_item_id = p_booking_item_id
    FOR UPDATE;

    IF v_booking_id IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Booking item does not exist';
    END IF;
    IF EXISTS (SELECT 1 FROM equipment_returns WHERE booking_item_id = p_booking_item_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This machine has already been returned (duplicate return refused)';
    END IF;
    IF v_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only machines of an ACTIVE booking can be returned';
    END IF;

    SET v_late = fn_late_charge(p_booking_item_id, v_date);

    INSERT INTO equipment_returns (booking_item_id, return_date, received_by_staff_id, return_condition,
                                   late_charge, damage_charge, damage_description)
    VALUES (p_booking_item_id, v_date, p_staff_id, p_condition, v_late, p_damage_charge, p_damage_desc);
    SET p_return_id = LAST_INSERT_ID();

    IF p_condition = 'MAJOR_DAMAGE' THEN
        IF fn_unit_conflict(v_eq_id, DATE_ADD(v_date, INTERVAL 1 DAY), DATE_ADD(v_date, INTERVAL 7 DAY), NULL, NULL) IS NULL THEN
            INSERT INTO maintenance_records (equipment_id, technician_staff_id, related_return_id, maintenance_type,
                                             maintenance_status, scheduled_start, scheduled_end, description)
            VALUES (v_eq_id, NULL, p_return_id, 'CORRECTIVE', 'SCHEDULED',
                    DATE_ADD(v_date, INTERVAL 1 DAY), DATE_ADD(v_date, INTERVAL 7 DAY),
                    CONCAT('Repair after damaged return: ', COALESCE(p_damage_desc, 'see return record')));
            SET v_maint_id = LAST_INSERT_ID();
            SET v_repair_note = CONCAT('Corrective maintenance #', v_maint_id, ' scheduled for the next 7 days');
        ELSE
            SET v_repair_note = 'Unit has an upcoming commitment - schedule the repair manually';
        END IF;
    END IF;

    COMMIT;

    SELECT p_return_id                                   AS return_id,
           v_date                                        AS return_date,
           GREATEST(0, DATEDIFF(v_date, v_due))          AS late_days,
           v_late                                        AS late_charge,
           p_damage_charge                               AS damage_charge,
           (SELECT booking_status FROM bookings WHERE booking_id = v_booking_id) AS booking_status_now,
           (SELECT COUNT(*) FROM booking_items bi
              LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
             WHERE bi.booking_id = v_booking_id AND r.return_id IS NULL) AS machines_still_out,
           v_repair_note                                 AS repair_note;
END$$

-- P8. Settle the deposit after the rental is COMPLETED:
--     retain what is needed to clear unpaid charges, refund the rest.
CREATE PROCEDURE sp_settle_deposit(IN p_booking_id INT)
BEGIN
    DECLARE v_bstatus   VARCHAR(20);
    DECLARE v_dstatus   VARCHAR(20);
    DECLARE v_collected DECIMAL(12,2);
    DECLARE v_balance   DECIMAL(12,2);
    DECLARE v_retain    DECIMAL(12,2);
    DECLARE v_refund    DECIMAL(12,2);
    DECLARE v_new_status VARCHAR(20);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

    START TRANSACTION;
    SELECT b.booking_status, sd.deposit_status, sd.collected_amount
      INTO v_bstatus, v_dstatus, v_collected
    FROM bookings b LEFT JOIN security_deposits sd ON sd.booking_id = b.booking_id
    WHERE b.booking_id = p_booking_id
    FOR UPDATE;

    IF v_bstatus IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Booking does not exist';
    ELSEIF v_bstatus <> 'COMPLETED' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Deposit can be settled only after all machines are returned (booking COMPLETED)';
    ELSEIF v_dstatus IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'This booking has no security deposit';
    ELSEIF v_dstatus <> 'HELD' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Deposit is not in HELD status (already settled or never collected)';
    END IF;

    SET v_balance = fn_booking_total_charges(p_booking_id) - fn_booking_amount_received(p_booking_id);
    SET v_retain  = LEAST(v_collected, GREATEST(v_balance, 0));
    SET v_refund  = v_collected - v_retain;
    SET v_new_status = CASE WHEN v_retain = 0 THEN 'REFUNDED'
                            WHEN v_refund = 0 THEN 'FORFEITED'
                            ELSE 'PARTIALLY_REFUNDED' END;

    UPDATE security_deposits
       SET retained_amount  = v_retain,
           refunded_amount  = v_refund,
           settled_date     = fn_business_date(),
           retention_reason = IF(v_retain > 0, CONCAT('Adjusted against unpaid charges of Rs ', v_balance), NULL),
           deposit_status   = v_new_status
     WHERE booking_id = p_booking_id;
    COMMIT;

    SELECT p_booking_id AS booking_id, v_collected AS deposit_collected, v_balance AS unpaid_before,
           v_retain AS retained, v_refund AS refunded, v_new_status AS deposit_status,
           v_balance - v_retain AS still_owed_by_customer;
END$$

-- P9. Cancel a RESERVED booking: frees the machines, closes the deposit,
--     marks advance payments as REFUNDED - one atomic transaction.
CREATE PROCEDURE sp_cancel_booking(IN p_booking_id INT, IN p_reason VARCHAR(200))
BEGIN
    DECLARE v_status VARCHAR(20);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

    IF p_reason IS NULL OR TRIM(p_reason) = '' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A cancellation reason is required';
    END IF;

    START TRANSACTION;
    SELECT booking_status INTO v_status FROM bookings WHERE booking_id = p_booking_id FOR UPDATE;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Booking does not exist';
    ELSEIF v_status <> 'RESERVED' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only RESERVED bookings can be cancelled (machines not yet handed over)';
    END IF;

    UPDATE bookings
       SET booking_status = 'CANCELLED', cancelled_date = fn_business_date(), cancellation_reason = p_reason
     WHERE booking_id = p_booking_id;

    UPDATE security_deposits
       SET deposit_status = 'CANCELLED'
     WHERE booking_id = p_booking_id AND deposit_status = 'PENDING';

    UPDATE security_deposits
       SET refunded_amount = collected_amount, settled_date = fn_business_date(), deposit_status = 'REFUNDED'
     WHERE booking_id = p_booking_id AND deposit_status = 'HELD';

    UPDATE payments
       SET payment_status = 'REFUNDED'
     WHERE booking_id = p_booking_id AND payment_status = 'COMPLETED';
    COMMIT;

    SELECT f.booking_id, f.booking_status, f.total_charges, f.amount_received, f.deposit_status
    FROM vw_booking_financial_summary f WHERE f.booking_id = p_booking_id;
END$$

-- P10. Plan maintenance; refuses if it overlaps any rental or other job
CREATE PROCEDURE sp_schedule_maintenance(
    IN  p_equipment_id  INT,
    IN  p_type          VARCHAR(20),
    IN  p_start         DATE,
    IN  p_end           DATE,
    IN  p_technician_id INT,
    IN  p_description   VARCHAR(255),
    OUT p_maintenance_id INT)
BEGIN
    DECLARE v_tag    VARCHAR(20);
    DECLARE v_reason VARCHAR(30);
    DECLARE v_msg    VARCHAR(255);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET p_maintenance_id = NULL; RESIGNAL; END;

    SET p_maintenance_id = NULL;
    IF p_start IS NULL OR p_end IS NULL OR p_end < p_start THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid maintenance period';
    END IF;
    IF p_start < fn_business_date() THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Maintenance cannot be scheduled in the past';
    END IF;

    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
    START TRANSACTION;
    SELECT asset_tag INTO v_tag FROM equipment_units WHERE equipment_id = p_equipment_id FOR UPDATE;
    IF v_tag IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Equipment does not exist';
    END IF;

    SET v_reason = fn_unit_conflict(p_equipment_id, p_start, p_end, NULL, NULL);
    IF v_reason IS NOT NULL THEN
        SET v_msg = CONCAT('Cannot schedule maintenance for ', v_tag, ': ', v_reason);
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;

    INSERT INTO maintenance_records (equipment_id, technician_staff_id, maintenance_type, maintenance_status,
                                     scheduled_start, scheduled_end, description)
    VALUES (p_equipment_id, p_technician_id, p_type, 'SCHEDULED', p_start, p_end, p_description);
    SET p_maintenance_id = LAST_INSERT_ID();
    COMMIT;

    SELECT * FROM maintenance_records WHERE maintenance_id = p_maintenance_id;
END$$

-- P11. Machine goes into the workshop today (SCHEDULED -> IN_PROGRESS)
CREATE PROCEDURE sp_start_maintenance(IN p_maintenance_id INT)
BEGIN
    DECLARE v_status VARCHAR(20);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

    START TRANSACTION;
    SELECT maintenance_status INTO v_status FROM maintenance_records
    WHERE maintenance_id = p_maintenance_id FOR UPDATE;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Maintenance record does not exist';
    END IF;
    UPDATE maintenance_records
       SET maintenance_status = 'IN_PROGRESS', actual_start = fn_business_date()
     WHERE maintenance_id = p_maintenance_id;
    COMMIT;
    SELECT * FROM maintenance_records WHERE maintenance_id = p_maintenance_id;
END$$

-- P12. Machine comes back from the workshop today (IN_PROGRESS -> COMPLETED)
CREATE PROCEDURE sp_complete_maintenance(IN p_maintenance_id INT, IN p_cost DECIMAL(10,2))
BEGIN
    DECLARE v_status VARCHAR(20);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; RESIGNAL; END;

    START TRANSACTION;
    SELECT maintenance_status INTO v_status FROM maintenance_records
    WHERE maintenance_id = p_maintenance_id FOR UPDATE;
    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Maintenance record does not exist';
    END IF;
    UPDATE maintenance_records
       SET maintenance_status = 'COMPLETED', actual_end = fn_business_date(),
           maintenance_cost = COALESCE(p_cost, 0)
     WHERE maintenance_id = p_maintenance_id;
    COMMIT;
    SELECT * FROM maintenance_records WHERE maintenance_id = p_maintenance_id;
END$$

-- P13. Overdue report built row-by-row with a CURSOR (syllabus: cursors).
--      For each overdue machine it computes the accrued late fee and a
--      follow-up priority, stores the rows in a temporary table and prints it.
CREATE PROCEDURE sp_overdue_report()
BEGIN
    DECLARE v_done      INT DEFAULT 0;
    DECLARE v_booking   INT;
    DECLARE v_customer  VARCHAR(150);
    DECLARE v_phone     VARCHAR(13);
    DECLARE v_tag       VARCHAR(20);
    DECLARE v_due       DATE;
    DECLARE v_rate      DECIMAL(10,2);
    DECLARE v_days      INT;
    DECLARE v_fee       DECIMAL(12,2);
    DECLARE v_priority  VARCHAR(10);
    DECLARE v_total_fee DECIMAL(12,2) DEFAULT 0;
    DECLARE v_mult      DECIMAL(4,2);
    DECLARE v_today     DATE DEFAULT fn_business_date();

    DECLARE cur_overdue CURSOR FOR
        SELECT b.booking_id, COALESCE(cu.organisation_name, cu.full_name), cu.phone,
               u.asset_tag, b.expected_return_date, bi.agreed_daily_rate
        FROM bookings b
        JOIN customers cu ON cu.customer_id = b.customer_id
        JOIN booking_items bi ON bi.booking_id = b.booking_id
        JOIN equipment_units u ON u.equipment_id = bi.equipment_id
        LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
        WHERE b.booking_status = 'ACTIVE' AND r.return_id IS NULL
          AND b.expected_return_date < v_today
        ORDER BY b.expected_return_date;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;

    SELECT late_fee_multiplier INTO v_mult FROM system_settings WHERE settings_id = 1;

    DROP TEMPORARY TABLE IF EXISTS tmp_overdue_report;
    CREATE TEMPORARY TABLE tmp_overdue_report (
        booking_id INT, customer_name VARCHAR(150), phone VARCHAR(13), asset_tag VARCHAR(20),
        due_date DATE, days_overdue INT, accrued_late_fee DECIMAL(12,2), priority VARCHAR(10));

    OPEN cur_overdue;
    read_loop: LOOP
        FETCH cur_overdue INTO v_booking, v_customer, v_phone, v_tag, v_due, v_rate;
        IF v_done = 1 THEN
            LEAVE read_loop;
        END IF;

        SET v_days = DATEDIFF(v_today, v_due);
        SET v_fee  = v_days * v_rate * v_mult;
        SET v_total_fee = v_total_fee + v_fee;

        IF v_days > 7 THEN
            SET v_priority = 'HIGH';
        ELSEIF v_days > 2 THEN
            SET v_priority = 'MEDIUM';
        ELSE
            SET v_priority = 'LOW';
        END IF;

        INSERT INTO tmp_overdue_report
        VALUES (v_booking, v_customer, v_phone, v_tag, v_due, v_days, v_fee, v_priority);
    END LOOP;
    CLOSE cur_overdue;

    SELECT * FROM tmp_overdue_report ORDER BY days_overdue DESC;
    SELECT COUNT(*) AS overdue_machines, v_total_fee AS total_accrued_late_fees, v_today AS as_of_date
    FROM tmp_overdue_report;
    DROP TEMPORARY TABLE IF EXISTS tmp_overdue_report;
END$$

-- P14. Customer statement: every booking with charges, receipts, balance
CREATE PROCEDURE sp_customer_statement(IN p_customer_id INT)
BEGIN
    IF NOT EXISTS (SELECT 1 FROM customers WHERE customer_id = p_customer_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Customer does not exist';
    END IF;

    SELECT f.booking_id, f.booking_status, f.start_date, f.expected_return_date, f.unit_count,
           f.rental_charge, f.late_charges, f.damage_charges, f.total_charges,
           f.amount_received, f.balance_due, f.deposit_status
    FROM vw_booking_financial_summary f
    JOIN bookings b ON b.booking_id = f.booking_id
    WHERE b.customer_id = p_customer_id
    ORDER BY f.start_date;

    SELECT COUNT(*) AS bookings, SUM(f.total_charges) AS lifetime_charges,
           SUM(f.amount_received) AS lifetime_received, SUM(f.balance_due) AS outstanding_balance
    FROM vw_booking_financial_summary f
    JOIN bookings b ON b.booking_id = f.booking_id
    WHERE b.customer_id = p_customer_id;
END$$

DELIMITER ;

-- List the routines that now exist
SELECT routine_type, routine_name
FROM information_schema.routines
WHERE routine_schema = 'construction_rental_db'
ORDER BY routine_type, routine_name;

DELIMITER ;
-- ##### END 07_procedures_functions.sql

-- #####################################################################
-- ##### BEGIN 08_triggers.sql
-- #####################################################################
-- =====================================================================
--  File   : 08_triggers.sql
--  Purpose: 12 triggers that protect business invariants even when data
--           is changed by hand-written SQL instead of the procedures.
--  Run    : LAST in the setup order (after seed data and routines).
-- ---------------------------------------------------------------------
--  Why triggers at all?  CHECK constraints can only look at ONE row of
--  ONE table. Rules such as "a machine cannot be in two bookings on the
--  same day" or "you cannot hand over machines before the deposit is
--  paid" involve several tables, so they are enforced here.
--  Triggers do not duplicate procedure logic: shared rules live in the
--  functions fn_unit_conflict / fn_late_charge / fn_booking_* and both the
--  procedures and the triggers call the same function.
--
--  Summary
--  #  Trigger                        Timing/Event          Rule enforced
--  1  trg_bookings_bi                BEFORE INSERT bookings   new booking is RESERVED, customer active,
--                                                              start not in past, length <= max days
--  2  trg_bookings_bu                BEFORE UPDATE bookings   valid status transitions, dates frozen,
--                                                              deposit HELD before handover, all units
--                                                              returned before COMPLETED
--  3  trg_bookings_ai                AFTER  INSERT bookings   audit log: first status
--  4  trg_bookings_au                AFTER  UPDATE bookings   audit log: status change
--  5  trg_booking_items_bi           BEFORE INSERT booking_items  NO DOUBLE BOOKING (locks unit row),
--                                                              booking must be RESERVED, price default
--  6  trg_equipment_returns_bi       BEFORE INSERT equipment_returns  booking ACTIVE, valid return date,
--                                                              late fee matches policy
--  7  trg_equipment_returns_ai       AFTER  INSERT equipment_returns  auto-complete booking when the
--                                                              last machine is back
--  8  trg_maintenance_bi             BEFORE INSERT maintenance_records  no overlap with rentals/jobs,
--                                                              technician role check
--  9  trg_maintenance_bu             BEFORE UPDATE maintenance_records  valid status transitions,
--                                                              re-check overlap when dates change
--  10 trg_payments_bi                BEFORE INSERT payments   no payments on cancelled bookings, no
--                                                              future-dated payments, no overpayment
--  11 trg_payments_bu                BEFORE UPDATE payments   amount/booking frozen, valid transitions,
--                                                              no overpayment on confirmation
--  12 trg_security_deposits_bu       BEFORE UPDATE security_deposits  settled deposits are final,
--                                                              cannot retain more than is owed
-- =====================================================================

USE construction_rental_db;

DROP TRIGGER IF EXISTS trg_bookings_bi;
DROP TRIGGER IF EXISTS trg_bookings_bu;
DROP TRIGGER IF EXISTS trg_bookings_ai;
DROP TRIGGER IF EXISTS trg_bookings_au;
DROP TRIGGER IF EXISTS trg_booking_items_bi;
DROP TRIGGER IF EXISTS trg_equipment_returns_bi;
DROP TRIGGER IF EXISTS trg_equipment_returns_ai;
DROP TRIGGER IF EXISTS trg_maintenance_bi;
DROP TRIGGER IF EXISTS trg_maintenance_bu;
DROP TRIGGER IF EXISTS trg_payments_bi;
DROP TRIGGER IF EXISTS trg_payments_bu;
DROP TRIGGER IF EXISTS trg_security_deposits_bu;

DELIMITER $$

-- ---------------------------------------------------------------------
-- 1. BEFORE INSERT ON bookings
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_bookings_bi
BEFORE INSERT ON bookings
FOR EACH ROW
BEGIN
    DECLARE v_active  BOOLEAN;
    DECLARE v_max     INT;

    IF NEW.booking_status <> 'RESERVED' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A new booking must start in RESERVED status';
    END IF;
    IF NEW.expected_return_date < NEW.start_date THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid rental period: expected return date is before start date';
    END IF;
    IF NEW.start_date < fn_business_date() THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Rental cannot start in the past';
    END IF;

    SET v_active = (SELECT is_active FROM customers WHERE customer_id = NEW.customer_id);
    IF v_active = FALSE THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Customer account is inactive';
    END IF;

    SET v_max = (SELECT max_rental_days FROM system_settings WHERE settings_id = 1);
    IF fn_rental_days(NEW.start_date, NEW.expected_return_date) > v_max THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Rental period exceeds the maximum allowed days';
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 2. BEFORE UPDATE ON bookings  (booking lifecycle state machine)
--      RESERVED -> ACTIVE     (handover; needs >=1 machine, deposit HELD,
--                              today within the rental period)
--      RESERVED -> CANCELLED  (needs a reason)
--      ACTIVE   -> COMPLETED  (needs every machine returned)
--    Customer and dates are frozen: change of plan = cancel + re-book.
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_bookings_bu
BEFORE UPDATE ON bookings
FOR EACH ROW
BEGIN
    DECLARE v_today    DATE DEFAULT fn_business_date();
    DECLARE v_items    INT;
    DECLARE v_open     INT;
    DECLARE v_deposit  VARCHAR(20);

    IF NEW.customer_id <> OLD.customer_id
       OR NEW.start_date <> OLD.start_date
       OR NEW.expected_return_date <> OLD.expected_return_date
       OR NEW.booking_date <> OLD.booking_date THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Booking customer and dates cannot be changed; cancel and create a new booking';
    END IF;

    IF NEW.booking_status <> OLD.booking_status THEN
        IF NOT ((OLD.booking_status = 'RESERVED' AND NEW.booking_status IN ('ACTIVE','CANCELLED'))
             OR (OLD.booking_status = 'ACTIVE'   AND NEW.booking_status = 'COMPLETED')) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid booking status transition';
        END IF;

        IF NEW.booking_status = 'ACTIVE' THEN
            SELECT COUNT(*) INTO v_items FROM booking_items WHERE booking_id = NEW.booking_id;
            IF v_items = 0 THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cannot start a rental with no machines';
            END IF;
            IF v_today < NEW.start_date OR v_today > NEW.expected_return_date THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Machines can be handed over only during the booked rental period';
            END IF;
            SET v_deposit = (SELECT deposit_status FROM security_deposits WHERE booking_id = NEW.booking_id);
            IF v_deposit IS NOT NULL AND v_deposit <> 'HELD' THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Security deposit must be collected before handover';
            END IF;
        END IF;

        IF NEW.booking_status = 'COMPLETED' THEN
            SELECT COUNT(*) INTO v_open
            FROM booking_items bi
            LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
            WHERE bi.booking_id = NEW.booking_id AND r.return_id IS NULL;
            IF v_open > 0 THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Booking cannot be COMPLETED while machines are still out';
            END IF;
        END IF;

        IF NEW.booking_status = 'CANCELLED' THEN
            IF NEW.cancellation_reason IS NULL OR TRIM(NEW.cancellation_reason) = '' THEN
                SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A cancellation reason is required';
            END IF;
            SET NEW.cancelled_date = COALESCE(NEW.cancelled_date, v_today);
        END IF;
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 3 & 4. Audit trail of booking status changes
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_bookings_ai
AFTER INSERT ON bookings
FOR EACH ROW
BEGIN
    INSERT INTO booking_status_log (booking_id, old_status, new_status, changed_by)
    VALUES (NEW.booking_id, NULL, NEW.booking_status, CURRENT_USER());
END$$

CREATE TRIGGER trg_bookings_au
AFTER UPDATE ON bookings
FOR EACH ROW
BEGIN
    IF NEW.booking_status <> OLD.booking_status THEN
        INSERT INTO booking_status_log (booking_id, old_status, new_status, changed_by)
        VALUES (NEW.booking_id, OLD.booking_status, NEW.booking_status, CURRENT_USER());
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 5. BEFORE INSERT ON booking_items  -  THE double-booking guard
--    (1) lock the unit row FOR UPDATE -> same-unit inserts are serialised
--    (2) fn_unit_conflict (locking reads) sees the latest committed rows
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_booking_items_bi
BEFORE INSERT ON booking_items
FOR EACH ROW
BEGIN
    DECLARE v_status VARCHAR(20);
    DECLARE v_start  DATE;
    DECLARE v_end    DATE;
    DECLARE v_tag    VARCHAR(20);
    DECLARE v_reason VARCHAR(30);
    DECLARE v_msg    VARCHAR(255);

    SELECT booking_status, start_date, expected_return_date INTO v_status, v_start, v_end
    FROM bookings WHERE booking_id = NEW.booking_id FOR SHARE;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Booking does not exist';
    END IF;
    IF v_status <> 'RESERVED' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Machines can be added only to a RESERVED booking';
    END IF;

    SELECT asset_tag INTO v_tag FROM equipment_units WHERE equipment_id = NEW.equipment_id FOR UPDATE;
    IF v_tag IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Equipment does not exist';
    END IF;

    SET v_reason = fn_unit_conflict(NEW.equipment_id, v_start, v_end, NULL, NULL);
    IF v_reason IS NOT NULL THEN
        SET v_msg = CONCAT('Equipment ', v_tag, ' is not available for the requested period (', v_reason, ')');
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 6. BEFORE INSERT ON equipment_returns
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_equipment_returns_bi
BEFORE INSERT ON equipment_returns
FOR EACH ROW
BEGIN
    DECLARE v_status   VARCHAR(20);
    DECLARE v_start    DATE;
    DECLARE v_staff_ok INT;

    SELECT b.booking_status, b.start_date INTO v_status, v_start
    FROM booking_items bi JOIN bookings b ON b.booking_id = bi.booking_id
    WHERE bi.booking_item_id = NEW.booking_item_id;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Booking item does not exist';
    END IF;
    IF v_status <> 'ACTIVE' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Only machines of an ACTIVE booking can be returned';
    END IF;
    IF NEW.return_date < v_start OR NEW.return_date > fn_business_date() THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Return date must be between the rental start date and today';
    END IF;
    IF NEW.late_charge <> fn_late_charge(NEW.booking_item_id, NEW.return_date) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Late charge does not match the late-fee policy (use fn_late_charge)';
    END IF;

    SELECT COUNT(*) INTO v_staff_ok FROM staff WHERE staff_id = NEW.received_by_staff_id AND is_active = TRUE;
    IF v_staff_ok = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Return must be received by an active staff member';
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 7. AFTER INSERT ON equipment_returns: last machine back -> COMPLETED
--    (updates a different table, so no recursion; the bookings BEFORE
--     UPDATE trigger double-checks that nothing is still out)
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_equipment_returns_ai
AFTER INSERT ON equipment_returns
FOR EACH ROW
BEGIN
    DECLARE v_booking INT;
    DECLARE v_open    INT;

    SELECT booking_id INTO v_booking FROM booking_items WHERE booking_item_id = NEW.booking_item_id;

    SELECT COUNT(*) INTO v_open
    FROM booking_items bi
    LEFT JOIN equipment_returns r ON r.booking_item_id = bi.booking_item_id
    WHERE bi.booking_id = v_booking AND r.return_id IS NULL;

    IF v_open = 0 THEN
        UPDATE bookings SET booking_status = 'COMPLETED' WHERE booking_id = v_booking;
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 8. BEFORE INSERT ON maintenance_records
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_maintenance_bi
BEFORE INSERT ON maintenance_records
FOR EACH ROW
BEGIN
    DECLARE v_tag    VARCHAR(20);
    DECLARE v_role   VARCHAR(20);
    DECLARE v_reason VARCHAR(30);
    DECLARE v_from   DATE;
    DECLARE v_to     DATE;
    DECLARE v_msg    VARCHAR(255);

    IF NEW.technician_staff_id IS NOT NULL THEN
        SET v_role = (SELECT staff_role FROM staff WHERE staff_id = NEW.technician_staff_id);
        IF v_role IS NULL OR v_role <> 'TECHNICIAN' THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Maintenance can only be assigned to a TECHNICIAN';
        END IF;
    END IF;

    IF NEW.maintenance_status <> 'CANCELLED' THEN
        SELECT asset_tag INTO v_tag FROM equipment_units WHERE equipment_id = NEW.equipment_id FOR UPDATE;

        SET v_from = COALESCE(NEW.actual_start, NEW.scheduled_start);
        SET v_to   = CASE NEW.maintenance_status WHEN 'COMPLETED' THEN NEW.actual_end ELSE NEW.scheduled_end END;
        SET v_reason = fn_unit_conflict(NEW.equipment_id, v_from, v_to, NULL, NULL);
        IF v_reason IS NOT NULL THEN
            SET v_msg = CONCAT('Maintenance for ', COALESCE(v_tag, 'unknown unit'), ' conflicts: ', v_reason);
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
        END IF;
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 9. BEFORE UPDATE ON maintenance_records
--      SCHEDULED -> IN_PROGRESS | CANCELLED,  IN_PROGRESS -> COMPLETED
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_maintenance_bu
BEFORE UPDATE ON maintenance_records
FOR EACH ROW
BEGIN
    DECLARE v_tag    VARCHAR(20);
    DECLARE v_reason VARCHAR(30);
    DECLARE v_msg    VARCHAR(255);

    IF NEW.equipment_id <> OLD.equipment_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A maintenance record cannot be moved to another machine';
    END IF;

    IF NEW.maintenance_status <> OLD.maintenance_status THEN
        IF NOT ((OLD.maintenance_status = 'SCHEDULED'   AND NEW.maintenance_status IN ('IN_PROGRESS','CANCELLED'))
             OR (OLD.maintenance_status = 'IN_PROGRESS' AND NEW.maintenance_status = 'COMPLETED')) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid maintenance status transition';
        END IF;
    END IF;

    -- re-validate the blocked window if it changed (status or any date)
    IF NEW.maintenance_status IN ('SCHEDULED','IN_PROGRESS')
       AND (NEW.maintenance_status <> OLD.maintenance_status
            OR NEW.scheduled_start <> OLD.scheduled_start
            OR NEW.scheduled_end   <> OLD.scheduled_end
            OR NOT (NEW.actual_start <=> OLD.actual_start)) THEN
        SELECT asset_tag INTO v_tag FROM equipment_units WHERE equipment_id = NEW.equipment_id FOR UPDATE;
        SET v_reason = fn_unit_conflict(NEW.equipment_id,
                                        COALESCE(NEW.actual_start, NEW.scheduled_start),
                                        GREATEST(NEW.scheduled_end, COALESCE(NEW.actual_start, NEW.scheduled_end)),
                                        NULL, OLD.maintenance_id);
        IF v_reason IS NOT NULL THEN
            SET v_msg = CONCAT('Maintenance for ', v_tag, ' conflicts: ', v_reason);
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg;
        END IF;
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 10. BEFORE INSERT ON payments
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_payments_bi
BEFORE INSERT ON payments
FOR EACH ROW
BEGIN
    DECLARE v_status   VARCHAR(20);
    DECLARE v_booked   DATE;

    SELECT booking_status, booking_date INTO v_status, v_booked
    FROM bookings WHERE booking_id = NEW.booking_id;

    IF v_status IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Booking does not exist';
    END IF;
    IF v_status = 'CANCELLED' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cannot take payment for a cancelled booking';
    END IF;
    IF NEW.payment_date < v_booked OR NEW.payment_date > fn_business_date() THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment date must be between the booking date and today';
    END IF;
    IF NEW.payment_status = 'REFUNDED' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A payment cannot be inserted as REFUNDED';
    END IF;
    IF NEW.payment_status = 'COMPLETED'
       AND fn_booking_amount_received(NEW.booking_id) + NEW.amount > fn_booking_total_charges(NEW.booking_id) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Overpayment: amount exceeds the balance due on this booking';
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 11. BEFORE UPDATE ON payments
--      PENDING -> COMPLETED | FAILED,  COMPLETED -> REFUNDED
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_payments_bu
BEFORE UPDATE ON payments
FOR EACH ROW
BEGIN
    IF NEW.amount <> OLD.amount OR NEW.booking_id <> OLD.booking_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Payment amount and booking cannot be changed; record a new payment instead';
    END IF;

    IF NEW.payment_status <> OLD.payment_status THEN
        IF NOT ((OLD.payment_status = 'PENDING'   AND NEW.payment_status IN ('COMPLETED','FAILED'))
             OR (OLD.payment_status = 'COMPLETED' AND NEW.payment_status = 'REFUNDED')) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Invalid payment status transition';
        END IF;
        IF NEW.payment_status = 'COMPLETED'
           AND fn_booking_amount_received(NEW.booking_id) + NEW.amount > fn_booking_total_charges(NEW.booking_id) THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Overpayment: confirming this payment would exceed the balance due';
        END IF;
    END IF;
END$$

-- ---------------------------------------------------------------------
-- 12. BEFORE UPDATE ON security_deposits
-- ---------------------------------------------------------------------
CREATE TRIGGER trg_security_deposits_bu
BEFORE UPDATE ON security_deposits
FOR EACH ROW
BEGIN
    DECLARE v_paid    DECIMAL(12,2);
    DECLARE v_charges DECIMAL(12,2);

    IF OLD.deposit_status IN ('REFUNDED','PARTIALLY_REFUNDED','FORFEITED','CANCELLED') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A settled or cancelled deposit record is final and cannot be changed';
    END IF;
    IF NEW.booking_id <> OLD.booking_id THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'A deposit cannot be moved to another booking';
    END IF;
    IF OLD.deposit_status <> 'PENDING' AND NEW.required_amount <> OLD.required_amount THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Required deposit cannot change after collection';
    END IF;

    IF NEW.retained_amount > 0 THEN
        SELECT COALESCE(SUM(amount), 0) INTO v_paid
        FROM payments WHERE booking_id = NEW.booking_id AND payment_status = 'COMPLETED';
        SET v_charges = fn_booking_total_charges(NEW.booking_id);
        IF NEW.retained_amount > v_charges - v_paid THEN
            SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cannot retain more deposit than the customer owes';
        END IF;
    END IF;
END$$

DELIMITER ;

-- List the triggers that now exist
SELECT trigger_name, action_timing, event_manipulation, event_object_table
FROM information_schema.triggers
WHERE trigger_schema = 'construction_rental_db'
ORDER BY event_object_table, action_timing, event_manipulation;

DELIMITER ;
-- ##### END 08_triggers.sql

SELECT 'construction_rental_db installed successfully' AS setup_status,
       (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'construction_rental_db' AND table_type = 'BASE TABLE') AS tables_created,
       (SELECT COUNT(*) FROM information_schema.views WHERE table_schema = 'construction_rental_db') AS views_created,
       (SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema = 'construction_rental_db') AS routines_created,
       (SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema = 'construction_rental_db') AS triggers_created;
