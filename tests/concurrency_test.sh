#!/bin/sh
# =====================================================================
#  tests/concurrency_test.sh  (optional, command-line version)
#  Runs REAL parallel MySQL sessions to prove that two people cannot
#  book the same machine for overlapping dates.
#
#  Usage (from the project root, after a fresh 00_master_setup.sql):
#     MYSQL="mysql -u root -pYOURPASSWORD" sh tests/concurrency_test.sh
#  or, with a saved login path (mysql_config_editor):
#     MYSQL="mysql --login-path=local" sh tests/concurrency_test.sh
#
#  Each test leaves at most one TEST booking; they are removed at the end.
#  The Workbench (two-tab) version of the same tests is in concurrency_tests.md.
# =====================================================================
MYSQL=${MYSQL:-"mysql -u root -p"}
DB=construction_rental_db
TMP=${TMPDIR:-/tmp}/cer_conc.$$
mkdir -p "$TMP"

run() { $MYSQL -t $DB; }

echo "=== TEST C1: Session A holds unit 7 in an open transaction; Session B calls sp_create_booking for overlapping dates"
( run > "$TMP/a1.txt" 2>&1 <<'SQL'
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
START TRANSACTION;
INSERT INTO bookings (customer_id, created_by_staff_id, booking_date, start_date, expected_return_date, booking_status, site_address)
VALUES (4, 2, '2026-11-20', '2026-11-26', '2026-11-28', 'RESERVED', 'TEST: Session A');
INSERT INTO booking_items (booking_id, equipment_id, agreed_daily_rate) VALUES (LAST_INSERT_ID(), 7, 5500);
SELECT NOW(6) AS a_locked_unit_7, SLEEP(4) AS sleeping;
COMMIT;
SELECT NOW(6) AS a_committed;
SQL
) &
sleep 1
run > "$TMP/b1.txt" 2>&1 <<'SQL'
SELECT NOW(6) AS b_started;
CALL sp_create_booking(10, 3, '2026-11-27', '2026-11-30', '7', 'TEST: Session B', @bid);
SQL
run >> "$TMP/b1.txt" 2>&1 <<'SQL'
SELECT NOW(6) AS b_finished;
SQL
wait
echo "--- Session A"; cat "$TMP/a1.txt"
echo "--- Session B (expected: waits until A commits, then BOOKING_CONFLICT)"; cat "$TMP/b1.txt"

echo
echo "=== TEST C2: B = REPEATABLE READ with an OLD snapshot, manual INSERT after A commits"
( run > "$TMP/a2.txt" 2>&1 <<'SQL'
START TRANSACTION;
INSERT INTO bookings (customer_id, created_by_staff_id, booking_date, start_date, expected_return_date, booking_status, site_address)
VALUES (4, 2, '2026-11-20', '2026-12-26', '2026-12-28', 'RESERVED', 'TEST: Session A2');
INSERT INTO booking_items (booking_id, equipment_id, agreed_daily_rate) VALUES (LAST_INSERT_ID(), 8, 5500);
SELECT SLEEP(3) AS a_sleeping;
COMMIT;
SQL
) &
sleep 0.5
run > "$TMP/c2.txt" 2>&1 <<'SQL'
SELECT NOW(6) AS c_start;
CALL sp_create_booking(10, 3, '2026-12-27', '2026-12-30', '20', 'TEST: Session C (other unit)', @x);
SELECT NOW(6) AS c_end;
SQL
run > "$TMP/b2.txt" 2>&1 <<'SQL'
SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
START TRANSACTION;
SELECT COUNT(*) AS b_snapshot_items_unit8 FROM booking_items WHERE equipment_id = 8;
SELECT SLEEP(4) AS b_waits_for_A;
SELECT COUNT(*) AS b_plain_read_still_sees FROM booking_items WHERE equipment_id = 8;
INSERT INTO bookings (customer_id, created_by_staff_id, booking_date, start_date, expected_return_date, booking_status, site_address)
VALUES (10, 3, '2026-11-20', '2026-12-27', '2026-12-30', 'RESERVED', 'TEST: Session B2');
INSERT INTO booking_items (booking_id, equipment_id, agreed_daily_rate) VALUES (LAST_INSERT_ID(), 8, 5500);
SQL
wait
echo "--- Session C (different unit; expected: finishes immediately, not blocked)"; cat "$TMP/c2.txt"
echo "--- Session B (expected: plain read shows the old count, but the INSERT is rejected)"; cat "$TMP/b2.txt"

echo
echo "=== Result: bookings created by the tests"
run <<'SQL'
SELECT b.booking_id, b.site_address, bi.equipment_id, b.start_date, b.expected_return_date
FROM bookings b JOIN booking_items bi ON bi.booking_id = b.booking_id
WHERE b.site_address LIKE 'TEST:%' ORDER BY b.booking_id;
SET SESSION sql_safe_updates = 0;
DELETE sd FROM security_deposits sd JOIN bookings b ON b.booking_id = sd.booking_id WHERE b.site_address LIKE 'TEST:%';
DELETE l  FROM booking_status_log l JOIN bookings b ON b.booking_id = l.booking_id WHERE b.site_address LIKE 'TEST:%';
DELETE bi FROM booking_items bi JOIN bookings b ON b.booking_id = bi.booking_id WHERE b.site_address LIKE 'TEST:%';
DELETE FROM bookings WHERE site_address LIKE 'TEST:%';
SELECT 'test bookings removed' AS cleanup;
SQL
rm -rf "$TMP"
