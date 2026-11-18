#!/bin/sh
# Rebuilds sql/00_master_setup.sql by concatenating the setup scripts in
# dependency order. Run from the project root:  sh tools/build_master_setup.sh
# (Developer convenience only - students simply open sql/00_master_setup.sql.)
set -e
OUT=sql/00_master_setup.sql
{
cat <<'HDR'
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

HDR
for f in 01_create_database.sql 02_seed_data.sql 06_views.sql 07_procedures_functions.sql 08_triggers.sql; do
  echo ""
  echo "-- #####################################################################"
  echo "-- ##### BEGIN $f"
  echo "-- #####################################################################"
  cat "sql/$f"
  echo ""
  echo "DELIMITER ;"
  echo "-- ##### END $f"
done
echo ""
echo "SELECT 'construction_rental_db installed successfully' AS setup_status,"
echo "       (SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'construction_rental_db' AND table_type = 'BASE TABLE') AS tables_created,"
echo "       (SELECT COUNT(*) FROM information_schema.views WHERE table_schema = 'construction_rental_db') AS views_created,"
echo "       (SELECT COUNT(*) FROM information_schema.routines WHERE routine_schema = 'construction_rental_db') AS routines_created,"
echo "       (SELECT COUNT(*) FROM information_schema.triggers WHERE trigger_schema = 'construction_rental_db') AS triggers_created;"
} > "$OUT"
echo "wrote $OUT ($(wc -l < "$OUT") lines)"
