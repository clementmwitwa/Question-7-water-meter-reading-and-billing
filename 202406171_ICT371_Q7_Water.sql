-- ICT371 Advanced Database | Question 7: Water Meter Readings and Billing
-- Student: Clement Mwitwa | Student No: 202406171 | PostgreSQL
-- Tariff: first 10 units K5 each, units above 10 K8 each, zero units = K0.

DROP SCHEMA IF EXISTS q7_water CASCADE;
CREATE SCHEMA q7_water;
SET search_path = q7_water, public;

/* ===================== (a) Database and seed data ===================== */
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER       NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE          NOT NULL,
    previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
    CONSTRAINT ck_reading_month_start CHECK (EXTRACT(DAY FROM reading_month) = 1),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER       NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE          NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL
);

INSERT INTO customers (full_name) VALUES ('Alice Mulenga'), ('Brian Tembo'), ('Chanda Zulu');

/* ===================== (b) Function ===================== */
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: % (must be zero or more)', p_units;
    END IF;
    -- Band 1: up to 10 units at K5. Band 2: units above 10 at K8.
    RETURN ROUND(LEAST(p_units, 10) * 5 + GREATEST(p_units - 10, 0) * 8, 2);
END;
$$;

/* ===================== (d) Trigger (created before data is loaded) ===================== */
CREATE OR REPLACE FUNCTION trg_fn_check_reading()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) cannot be below previous_reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;      -- raising aborts the statement, so the bad reading is never stored
END;
$$;

CREATE TRIGGER trg_readings_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_reading();

/* ---- (a) continued: six readings covering zero, exactly 10 and above 10 units ---- */
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date, 100,   100),   -- 0 units
    (1, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date,  100,   110),   -- exactly 10
    (2, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date,  50,    75),   -- 25 units
    (2, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date,   75,    82),   -- 7 units
    (3, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date,   0,    10),   -- exactly 10
    (3, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date,   10,    40);   -- 30 units

-- Trigger test: rejected reading is not stored
DO $$ BEGIN INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
            VALUES (1, date_trunc('month', CURRENT_DATE)::date, 110, 105);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN UPDATE readings SET current_reading = 1 WHERE reading_id = 2;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
SELECT count(*) AS readings_stored FROM readings;      -- still 6

-- Function tests
SELECT fn_water_charge(0) AS u0, fn_water_charge(10) AS u10, fn_water_charge(25) AS u25, fn_water_charge(12.5) AS u12_5;
-- expected 0.00, 50.00, 170.00, 70.00
DO $$ BEGIN PERFORM fn_water_charge(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_water_charge(-1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;

/* ===================== (c) Procedure ===================== */
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_prev   NUMERIC(10,2);
    v_curr   NUMERIC(10,2);
    v_charge NUMERIC(12,2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'due_on must not be NULL';
    END IF;

    SELECT previous_reading, current_reading INTO v_prev, v_curr
    FROM readings WHERE reading_id = p_reading_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;

    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_charge := fn_water_charge(v_curr - v_prev);      -- derive consumption, then call the function

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$;

-- Generate bills: older months are past due, last month is still within its due date.
CALL pr_generate_bill(1, CURRENT_DATE - 30);
CALL pr_generate_bill(3, CURRENT_DATE - 30);
CALL pr_generate_bill(5, CURRENT_DATE - 30);
CALL pr_generate_bill(2, CURRENT_DATE + 10);
CALL pr_generate_bill(4, CURRENT_DATE - 5);
CALL pr_generate_bill(6, CURRENT_DATE - 2);

-- Some payments: reading 5 fully paid, reading 3 partly paid
UPDATE bills SET amount_paid = charge WHERE reading_id = 5;
UPDATE bills SET amount_paid = 100    WHERE reading_id = 3;

SELECT * FROM bills ORDER BY bill_id;     -- charges: 0, 170, 50, 50, 35, 210

DO $$ BEGIN CALL pr_generate_bill(99, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(1, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;

/* ===================== (e) View ===================== */
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name AS customer_name, b.due_on, b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills ORDER BY due_on, customer_name;
-- zero-charge and fully paid bills are excluded

/* ===================== (f) Index ===================== */
-- Justification: overdue searches filter by a due_on date and only care about bills that are
-- not fully paid. A PARTIAL index on due_on restricted to (amount_paid < charge) stays small
-- (paid bills drop out of it) and its predicate matches the unpaid-bill query exactly.
CREATE INDEX idx_bills_unpaid_due_on ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;

SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM bills WHERE due_on < CURRENT_DATE AND amount_paid < charge;
RESET enable_seqscan;

/* ===================== (g) Scheduled job ===================== */
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0) FROM bills
    ON CONFLICT (snapshot_date) DO UPDATE SET total_due = EXCLUDED.total_due;   -- replace, not add
END;
$$;

CREATE EXTENSION IF NOT EXISTS pg_cron;
-- Every day at 00:30 (pg_cron time zone).
SELECT cron.schedule('q7_refresh_receivables_daily', '30 0 * * *',
                     $$CALL q7_water.pr_refresh_receivables()$$);

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();     -- rerun: same single row
SELECT * FROM receivable_snapshot; -- expected: 70 + 50 + 35 + 210 = 365.00
SELECT jobid, jobname, schedule, command FROM cron.job WHERE jobname = 'q7_refresh_receivables_daily';
