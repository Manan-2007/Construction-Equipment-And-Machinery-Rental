-- =====================================================================
--  File   : tests/00_test_helpers.sql
--  Purpose: Tiny test framework so that EXPECTED errors do not stop a
--           test file. Run this file ONCE (after 00_master_setup.sql),
--           then run integrity_tests.sql, business_rule_tests.sql and
--           financial_tests.sql - in any Workbench tab, with "run all".
--
--  How it works: each test statement is passed as TEXT, executed with
--  PREPARE/EXECUTE (dynamic SQL) inside a procedure that has a CONTINUE
--  HANDLER FOR SQLEXCEPTION. The handler records the error message instead
--  of aborting, and the result (PASS/FAIL) goes into a TEMPORARY table
--  that belongs to your session only.
--
--  Procedures created (all prefixed test_ so they are easy to recognise):
--    test_init(suite)                       start a fresh result list
--    test_expect_error(name, sql, fragment) PASS if sql FAILS and the error
--                                           text contains `fragment`
--    test_expect_ok(name, sql)              PASS if sql runs without error
--    test_assert_equals(name, scalar_sql, expected)
--                                           PASS if the query's single value
--                                           equals `expected` (compared as text)
--    test_summary()                         show every result + totals
-- =====================================================================

USE construction_rental_db;

DROP PROCEDURE IF EXISTS test_init;
DROP PROCEDURE IF EXISTS test_expect_error;
DROP PROCEDURE IF EXISTS test_expect_ok;
DROP PROCEDURE IF EXISTS test_assert_equals;
DROP PROCEDURE IF EXISTS test_summary;

DELIMITER $$

CREATE PROCEDURE test_init(IN p_suite VARCHAR(60))
BEGIN
    DROP TEMPORARY TABLE IF EXISTS tmp_test_results;
    CREATE TEMPORARY TABLE tmp_test_results (
        test_no     INT AUTO_INCREMENT PRIMARY KEY,
        suite       VARCHAR(60),
        test_name   VARCHAR(150),
        expectation VARCHAR(255),
        actual      VARCHAR(500),
        result      VARCHAR(4)
    );
    SET @test_suite = p_suite;
END$$

CREATE PROCEDURE test_expect_error(IN p_name VARCHAR(150), IN p_sql TEXT, IN p_fragment VARCHAR(200))
BEGIN
    DECLARE v_failed INT DEFAULT 0;
    DECLARE v_errno  INT DEFAULT 0;
    DECLARE v_msg    VARCHAR(500) DEFAULT 'statement succeeded';
    -- SQLWARNING is included because strict-mode data errors such as
    -- ERROR 1265 (data truncated / bad ENUM value) carry SQLSTATE '01000'.
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION, SQLWARNING
    BEGIN
        GET CURRENT DIAGNOSTICS CONDITION 1 v_errno = MYSQL_ERRNO, v_msg = MESSAGE_TEXT;
        SET v_failed = 1;
    END;

    SET @test_sql = p_sql;
    PREPARE test_stmt FROM @test_sql;
    IF v_failed = 0 THEN
        EXECUTE test_stmt;
        DEALLOCATE PREPARE test_stmt;
    END IF;

    INSERT INTO tmp_test_results (suite, test_name, expectation, actual, result)
    VALUES (@test_suite, p_name, CONCAT('error containing: ', p_fragment),
            IF(v_failed = 1, CONCAT('ERROR ', v_errno, ': ', v_msg), v_msg),
            IF(v_failed = 1 AND CONCAT(v_errno, ' ', v_msg) LIKE CONCAT('%', p_fragment, '%'), 'PASS', 'FAIL'));
END$$

CREATE PROCEDURE test_expect_ok(IN p_name VARCHAR(150), IN p_sql TEXT)
BEGIN
    DECLARE v_failed INT DEFAULT 0;
    DECLARE v_errno  INT DEFAULT 0;
    DECLARE v_msg    VARCHAR(500) DEFAULT 'OK';
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    BEGIN
        GET CURRENT DIAGNOSTICS CONDITION 1 v_errno = MYSQL_ERRNO, v_msg = MESSAGE_TEXT;
        SET v_failed = 1;
    END;

    SET @test_sql = p_sql;
    PREPARE test_stmt FROM @test_sql;
    IF v_failed = 0 THEN
        EXECUTE test_stmt;
        DEALLOCATE PREPARE test_stmt;
    END IF;

    INSERT INTO tmp_test_results (suite, test_name, expectation, actual, result)
    VALUES (@test_suite, p_name, 'runs without error',
            IF(v_failed = 1, CONCAT('ERROR ', v_errno, ': ', v_msg), v_msg),
            IF(v_failed = 0, 'PASS', 'FAIL'));
END$$

CREATE PROCEDURE test_assert_equals(IN p_name VARCHAR(150), IN p_scalar_sql TEXT, IN p_expected VARCHAR(200))
BEGIN
    DECLARE v_failed INT DEFAULT 0;
    DECLARE v_msg    VARCHAR(500);
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
    BEGIN
        GET CURRENT DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;
        SET v_failed = 1;
    END;

    SET @test_value = NULL;
    SET @test_sql = CONCAT('SELECT (', p_scalar_sql, ') INTO @test_value');
    PREPARE test_stmt FROM @test_sql;
    IF v_failed = 0 THEN
        EXECUTE test_stmt;
        DEALLOCATE PREPARE test_stmt;
    END IF;

    INSERT INTO tmp_test_results (suite, test_name, expectation, actual, result)
    VALUES (@test_suite, p_name, CONCAT('value = ', p_expected),
            IF(v_failed = 1, CONCAT('ERROR: ', v_msg), CONCAT('value = ', COALESCE(CAST(@test_value AS CHAR), 'NULL'))),
            IF(v_failed = 0 AND CAST(@test_value AS CHAR) = p_expected, 'PASS', 'FAIL'));
END$$

CREATE PROCEDURE test_summary()
BEGIN
    SELECT test_no, test_name, result, expectation, actual
    FROM tmp_test_results ORDER BY test_no;

    SELECT suite,
           SUM(result = 'PASS') AS passed,
           SUM(result = 'FAIL') AS failed,
           COUNT(*)             AS executed
    FROM tmp_test_results
    GROUP BY suite;
END$$

DELIMITER ;

SELECT 'Test helpers installed' AS status;
