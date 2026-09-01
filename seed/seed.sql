-- Seed dataset for the Cloud SQL offloaded-export POC.
-- Deliberately includes one of each object type pg_dump normally captures, so the
-- export/restore cycle can prove empirically what native Cloud SQL SQL export keeps
-- and what it drops: tables, rows, an index, a view, two functions, a trigger, and a
-- genuine stored procedure (CREATE PROCEDURE, not a function).

CREATE TABLE customers (
    customer_id   SERIAL PRIMARY KEY,
    full_name     TEXT NOT NULL,
    email         TEXT NOT NULL UNIQUE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE orders (
    order_id      SERIAL PRIMARY KEY,
    customer_id   INTEGER NOT NULL REFERENCES customers(customer_id),
    order_total   NUMERIC(10,2) NOT NULL,
    status        TEXT NOT NULL DEFAULT 'pending',
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE order_items (
    order_item_id SERIAL PRIMARY KEY,
    order_id      INTEGER NOT NULL REFERENCES orders(order_id),
    product_name  TEXT NOT NULL,
    quantity      INTEGER NOT NULL CHECK (quantity > 0),
    unit_price    NUMERIC(10,2) NOT NULL
);

-- explicit index beyond the implicit PK indexes, to check it survives export/restore
CREATE INDEX idx_orders_customer_id ON orders(customer_id);
CREATE INDEX idx_order_items_order_id ON order_items(order_id);

-- view: joins across tables, should be included per Google's own documentation
CREATE VIEW customer_order_totals AS
SELECT
    c.customer_id,
    c.full_name,
    COUNT(DISTINCT o.order_id)      AS order_count,
    COALESCE(SUM(o.order_total), 0) AS lifetime_total
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.customer_id
GROUP BY c.customer_id, c.full_name;

-- function: documented as ambiguous in Cloud SQL's own SQL-export page (not explicitly
-- listed as included or excluded) -- this is exactly what Phase 6 empirically checks
CREATE FUNCTION recalculate_order_total(p_order_id INTEGER)
RETURNS NUMERIC AS $$
DECLARE
    v_total NUMERIC;
BEGIN
    SELECT COALESCE(SUM(quantity * unit_price), 0) INTO v_total
    FROM order_items
    WHERE order_id = p_order_id;

    UPDATE orders SET order_total = v_total, updated_at = now() WHERE order_id = p_order_id;
    RETURN v_total;
END;
$$ LANGUAGE plpgsql;

-- trigger: Google's docs explicitly state SQL export "does not contain triggers or
-- stored procedures" -- this table+trigger pair is the direct empirical test of that
CREATE TABLE audit_log (
    audit_id    SERIAL PRIMARY KEY,
    table_name  TEXT NOT NULL,
    row_id      INTEGER NOT NULL,
    action      TEXT NOT NULL,
    changed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE FUNCTION log_order_change() RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO audit_log(table_name, row_id, action)
    VALUES ('orders', NEW.order_id, TG_OP);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_orders_audit
AFTER INSERT OR UPDATE ON orders
FOR EACH ROW EXECUTE FUNCTION log_order_change();

-- stored procedure: distinct PostgreSQL object type from a function (CREATE PROCEDURE,
-- invoked via CALL, added in PostgreSQL 11) -- the exact object type Google's
-- documentation names when it says SQL export "does not contain triggers or stored
-- procedures". validate.sql explicitly CALLs this after restore and checks it actually
-- changed data, not just that its definition survived as text.
CREATE PROCEDURE mark_order_shipped(p_order_id INTEGER)
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE orders SET status = 'shipped', updated_at = now() WHERE order_id = p_order_id;
END;
$$;

-- data: enough rows to make row-count validation meaningful, small enough to keep the
-- POC's export/download/restore cycle fast and cheap
INSERT INTO customers (full_name, email) VALUES
    ('Amara Okafor',      'amara.okafor@example.com'),
    ('Liam Chen',         'liam.chen@example.com'),
    ('Priya Natarajan',   'priya.natarajan@example.com'),
    ('Sofia Mendes',      'sofia.mendes@example.com'),
    ('Daniel Kowalski',   'daniel.kowalski@example.com'),
    ('Fatima Al-Sayed',   'fatima.alsayed@example.com'),
    ('Noah Johansson',    'noah.johansson@example.com'),
    ('Grace Adeyemi',     'grace.adeyemi@example.com'),
    ('Hiro Tanaka',       'hiro.tanaka@example.com'),
    ('Elena Petrova',     'elena.petrova@example.com');

INSERT INTO orders (customer_id, order_total, status) VALUES
    (1, 0, 'pending'),
    (1, 0, 'shipped'),
    (2, 0, 'pending'),
    (3, 0, 'delivered'),
    (4, 0, 'pending'),
    (5, 0, 'shipped'),
    (6, 0, 'delivered'),
    (7, 0, 'pending'),
    (8, 0, 'shipped'),
    (9, 0, 'delivered'),
    (10,0, 'pending'),
    (2, 0, 'delivered');

INSERT INTO order_items (order_id, product_name, quantity, unit_price) VALUES
    (1,  'USB-C Cable',        2,  9.99),
    (1,  'Wireless Mouse',     1, 24.50),
    (2,  'Mechanical Keyboard',1, 89.00),
    (3,  'Laptop Stand',       1, 34.00),
    (4,  'Monitor Arm',        2, 45.00),
    (5,  'Webcam',             1, 59.99),
    (6,  'USB Hub',            3, 15.00),
    (7,  'Desk Mat',           1, 22.00),
    (8,  'Noise-Cancelling Headphones', 1, 129.99),
    (9,  'Bluetooth Speaker',  1, 39.99),
    (10, 'Cable Organizer',    5,  4.50),
    (11, 'Ergonomic Chair Cushion', 1, 49.00),
    (12, 'HDMI Cable',         2,  8.00),
    (12, 'Power Strip',        1, 19.99);

-- backfill order_total via the function above, so restored data exercises real
-- application logic rather than just static INSERT values
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN SELECT DISTINCT order_id FROM order_items LOOP
        PERFORM recalculate_order_total(r.order_id);
    END LOOP;
END;
$$;
