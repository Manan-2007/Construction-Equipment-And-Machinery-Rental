-- =====================================================================
--  File   : 12_dcl_security.sql      (OPTIONAL - not run by the master setup)
--  Purpose: DCL - GRANT / REVOKE with roles, so that sensitive business
--           changes can ONLY happen through the stored procedures.
--  Run as : root (or another account allowed to CREATE USER / ROLE).
--  Effect : creates 4 roles and 3 demo user accounts on YOUR MySQL server
--           (server-wide objects, outside construction_rental_db).
--           Section 5 removes them again.
--  NOTE   : the demo passwords below are placeholders for a local practice
--           server only. Change them, or drop the users after the demo.
--  Syllabus: Lectures 22-24 (DCL: GRANT, REVOKE)
-- =====================================================================

USE construction_rental_db;

-- ---------------------------------------------------------------------
-- 1. Roles = named bundles of privileges
-- ---------------------------------------------------------------------
DROP ROLE IF EXISTS 'cer_report_viewer', 'cer_rental_agent', 'cer_accountant', 'cer_technician';
CREATE ROLE 'cer_report_viewer', 'cer_rental_agent', 'cer_accountant', 'cer_technician';

-- Read-only reporting: views only (no direct access to base tables)
GRANT SELECT ON construction_rental_db.vw_equipment_inventory       TO 'cer_report_viewer';
GRANT SELECT ON construction_rental_db.vw_active_rentals            TO 'cer_report_viewer';
GRANT SELECT ON construction_rental_db.vw_overdue_rentals           TO 'cer_report_viewer';
GRANT SELECT ON construction_rental_db.vw_customer_rental_history   TO 'cer_report_viewer';
GRANT SELECT ON construction_rental_db.vw_booking_financial_summary TO 'cer_report_viewer';
GRANT SELECT ON construction_rental_db.vw_maintenance_summary       TO 'cer_report_viewer';
GRANT SELECT ON construction_rental_db.vw_equipment_revenue         TO 'cer_report_viewer';
GRANT SELECT ON construction_rental_db.vw_pending_deposit_refunds   TO 'cer_report_viewer';

-- Rental agent: reports + customer register + booking procedures.
-- Procedures run with their DEFINER's rights (SQL SECURITY DEFINER is the
-- default), so EXECUTE is enough - the agent never gets INSERT on bookings.
GRANT 'cer_report_viewer' TO 'cer_rental_agent';
GRANT SELECT, INSERT, UPDATE ON construction_rental_db.customers TO 'cer_rental_agent';
GRANT EXECUTE ON PROCEDURE construction_rental_db.sp_check_availability TO 'cer_rental_agent';
GRANT EXECUTE ON PROCEDURE construction_rental_db.sp_create_booking     TO 'cer_rental_agent';
GRANT EXECUTE ON PROCEDURE construction_rental_db.sp_cancel_booking     TO 'cer_rental_agent';
GRANT EXECUTE ON PROCEDURE construction_rental_db.sp_start_rental       TO 'cer_rental_agent';
GRANT EXECUTE ON PROCEDURE construction_rental_db.sp_return_equipment   TO 'cer_rental_agent';

-- Accountant: reports + money procedures
GRANT 'cer_report_viewer' TO 'cer_accountant';
GRANT SELECT ON construction_rental_db.payments          TO 'cer_accountant';
GRANT SELECT ON construction_rental_db.security_deposits TO 'cer_accountant';
GRANT EXECUTE ON PROCEDURE construction_rental_db.sp_record_payment     TO 'cer_accountant';
GRANT EXECUTE ON PROCEDURE construction_rental_db.sp_collect_deposit    TO 'cer_accountant';
GRANT EXECUTE ON PROCEDURE construction_rental_db.sp_settle_deposit     TO 'cer_accountant';
GRANT EXECUTE ON PROCEDURE construction_rental_db.sp_customer_statement TO 'cer_accountant';

-- Technician: maintenance only
GRANT SELECT ON construction_rental_db.vw_maintenance_summary  TO 'cer_technician';
GRANT SELECT ON construction_rental_db.maintenance_records     TO 'cer_technician';
GRANT EXECUTE ON PROCEDURE construction_rental_db.sp_schedule_maintenance TO 'cer_technician';
GRANT EXECUTE ON PROCEDURE construction_rental_db.sp_start_maintenance    TO 'cer_technician';
GRANT EXECUTE ON PROCEDURE construction_rental_db.sp_complete_maintenance TO 'cer_technician';

-- ---------------------------------------------------------------------
-- 2. Demo user accounts (local connections only)
-- ---------------------------------------------------------------------
DROP USER IF EXISTS 'neha_agent'@'localhost', 'amit_accounts'@'localhost', 'vikram_tech'@'localhost';
CREATE USER 'neha_agent'@'localhost'    IDENTIFIED BY 'Agent#Demo2026';
CREATE USER 'amit_accounts'@'localhost' IDENTIFIED BY 'Accounts#Demo2026';
CREATE USER 'vikram_tech'@'localhost'   IDENTIFIED BY 'Tech#Demo2026';

GRANT 'cer_rental_agent' TO 'neha_agent'@'localhost';
GRANT 'cer_accountant'   TO 'amit_accounts'@'localhost';
GRANT 'cer_technician'   TO 'vikram_tech'@'localhost';

-- roles are inactive until activated; make them active at every login
SET DEFAULT ROLE ALL TO 'neha_agent'@'localhost', 'amit_accounts'@'localhost', 'vikram_tech'@'localhost';

SHOW GRANTS FOR 'neha_agent'@'localhost' USING 'cer_rental_agent';

-- ---------------------------------------------------------------------
-- 3. Try it: open a NEW Workbench connection as neha_agent and run
--      USE construction_rental_db;
--      SELECT * FROM vw_equipment_inventory;                 -- allowed (view)
--      CALL sp_check_availability('2026-12-20','2026-12-22', NULL);   -- allowed
--      INSERT INTO bookings (customer_id, created_by_staff_id, booking_date,
--             start_date, expected_return_date, site_address)
--      VALUES (4, 2, '2026-11-20', '2026-12-20', '2026-12-22', 'x');
--                    -- ERROR 1142: INSERT command denied to user 'neha_agent'
--      SELECT * FROM payments;                                -- ERROR 1142: SELECT command denied
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- 4. REVOKE: the agent may no longer cancel bookings (manager approval needed)
-- ---------------------------------------------------------------------
REVOKE EXECUTE ON PROCEDURE construction_rental_db.sp_cancel_booking FROM 'cer_rental_agent';
-- neha_agent now gets: ERROR 1370 execute command denied ... for routine 'construction_rental_db.sp_cancel_booking'
SHOW GRANTS FOR 'cer_rental_agent';

-- ---------------------------------------------------------------------
-- 5. CLEAN-UP (run when the demo is over)
-- ---------------------------------------------------------------------
-- DROP USER IF EXISTS 'neha_agent'@'localhost', 'amit_accounts'@'localhost', 'vikram_tech'@'localhost';
-- DROP ROLE IF EXISTS 'cer_report_viewer', 'cer_rental_agent', 'cer_accountant', 'cer_technician';
