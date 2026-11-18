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
