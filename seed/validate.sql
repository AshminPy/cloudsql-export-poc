-- Run against the restored database (Phase 6). Every check here maps directly to a
-- README "pg_dump compatibility findings" row -- this is the empirical evidence, not
-- an assumption from reading docs.

\echo '--- tables present ---'
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public' ORDER BY table_name;

\echo '--- row counts ---'
SELECT 'customers' AS table_name, COUNT(*) FROM customers
UNION ALL SELECT 'orders', COUNT(*) FROM orders
UNION ALL SELECT 'order_items', COUNT(*) FROM order_items
UNION ALL SELECT 'audit_log', COUNT(*) FROM audit_log;

\echo '--- sample record check (customer #1) ---'
SELECT customer_id, full_name, email FROM customers WHERE customer_id = 1;

\echo '--- indexes present ---'
SELECT indexname, tablename FROM pg_indexes
WHERE schemaname = 'public' ORDER BY tablename, indexname;

\echo '--- view present + queryable ---'
SELECT to_regclass('public.customer_order_totals') AS view_exists;
SELECT * FROM customer_order_totals ORDER BY customer_id LIMIT 3;

\echo '--- function present? (recalculate_order_total) ---'
SELECT proname FROM pg_proc WHERE proname = 'recalculate_order_total';

\echo '--- trigger function present? (log_order_change) ---'
SELECT proname FROM pg_proc WHERE proname = 'log_order_change';

\echo '--- trigger present on orders table? ---'
SELECT tgname, tgrelid::regclass AS table_name
FROM pg_trigger
WHERE tgrelid = 'orders'::regclass AND NOT tgisinternal;

\echo '--- does the audit_log already have rows from the original DO block? ---'
SELECT COUNT(*) FROM audit_log;

-- Stored procedure check: this is the strengthened part of the test. Presence of the
-- definition as text is not enough -- prokind = 'p' confirms Postgres itself
-- classifies it as a genuine PROCEDURE (not a function, which is prokind = 'f'), and
-- actually CALLing it and re-reading the row proves it survived as *working code*,
-- not just as inert text in the dump.
\echo '--- stored procedure present, and classified as a real PROCEDURE (prokind=p)? ---'
SELECT proname, prokind FROM pg_proc WHERE proname = 'mark_order_shipped';

\echo '--- order #3 status BEFORE calling the procedure ---'
SELECT order_id, status FROM orders WHERE order_id = 3;

\echo '--- CALL mark_order_shipped(3) ---'
CALL mark_order_shipped(3);

\echo '--- order #3 status AFTER calling the procedure (expect: shipped) ---'
SELECT order_id, status FROM orders WHERE order_id = 3;
