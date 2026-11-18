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
