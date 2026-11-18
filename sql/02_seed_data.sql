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
