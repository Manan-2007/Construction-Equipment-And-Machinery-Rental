# References

## Prescribed and recommended books (from the Course Handout, 24CSE0209)
1. A. Silberschatz, H. F. Korth, S. Sudarshan. *Database System Concepts*, 7th ed., McGraw-Hill. (ER model ch. 6, normalisation ch. 7, indexing ch. 14, transactions/concurrency ch. 17–18)
2. C. J. Date. *An Introduction to Database Systems*, 8th ed. (relational algebra, normalisation)
3. R. Elmasri, S. B. Navathe. *Fundamentals of Database Systems*, 7th ed., Pearson. (ER-to-relational mapping, Crow's Foot notation)
4. Parteek Bhatia. *DBMS: A Simplified Approach*, 1st ed. (SQL, joins, views)
5. Ashwin Pajankar. *Learn SQL with MySQL*, 1st ed. (DDL/DML, subqueries)
6. Sergey Skudaev. *Learn SQL By Examples: Examples of SQL Queries and Stored Procedures for MySQL and Oracle Databases*, 1st ed.

## Course material
7. Chitkara University. *Course Handout: Database Management System (24CSE0209)*, Session July–Dec 2026.
8. DBMS Reference Drive (faculty-shared): *MySQL Stored Programs till Cursor*, *Database Normalization*, *MySQL Views*, *views handson.sql*, *DCL GRANT/REVOKE Roles*.

## Official MySQL documentation (MySQL 8.0 Reference Manual, dev.mysql.com/doc/refman/8.0/en/)
9. CREATE TABLE and CHECK constraints: `create-table-check-constraints.html` (enforced from 8.0.16).
10. FOREIGN KEY constraints and referential actions: `create-table-foreign-keys.html`.
11. Locking reads (`SELECT … FOR UPDATE / FOR SHARE`): `innodb-locking-reads.html`.
12. Transaction isolation levels and consistent reads: `innodb-transaction-isolation-levels.html`, `innodb-consistent-read.html`.
13. Deadlocks in InnoDB: `innodb-deadlocks.html`.
14. Stored programs, DECLARE … HANDLER, SIGNAL/RESIGNAL, cursors: `stored-programs-views.html`, `declare-handler.html`, `signal.html`, `cursors.html`.
15. Restrictions on stored programs (trigger cannot modify/lock the invoking table, error 1442): `stored-program-restrictions.html`.
16. INTERSECT and EXCEPT (8.0.31+): `intersect.html`, `except.html`.
17. EXPLAIN output format and EXPLAIN ANALYZE: `explain-output.html`, `explain.html`.
18. Roles, GRANT, REVOKE: `roles.html`, `grant.html`, `revoke.html`.
19. MySQL Workbench Manual, Reverse Engineering and Data Export: `dev.mysql.com/doc/workbench/en/`.

## Web references listed in the Course Handout
20. GeeksforGeeks DBMS tutorials: https://www.geeksforgeeks.org/dbms/dbms/
21. Tutorialspoint DBMS / SQL: https://www.tutorialspoint.com/dbms/index.htm
22. NPTEL DBMS course: https://onlinecourses.nptel.ac.in/noc22_cs91/preview
23. W3Schools MySQL: https://www.w3schools.com/MySQL/default.asp

## Data note
All customer, staff and company records in the seed data are fictional and created for this project. Equipment manufacturer and model names (Caterpillar, Komatsu, Tata Hitachi, JCB, Mahindra, BEML, ACE, Escorts, Ajax Fiori, Volvo, CASE, Tata Motors, Godrej, Kirloskar, Cummins, Wacker Neuson) are real products used only as realistic catalogue entries. Specifications and prices are approximate and illustrative.
