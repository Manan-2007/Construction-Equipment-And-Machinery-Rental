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
