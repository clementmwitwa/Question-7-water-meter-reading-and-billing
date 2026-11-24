-- ICT371 Advanced Database | Question 6: Monthly Payroll Processing
-- Student: Clement Mwitwa | Student No: 202406171 | PostgreSQL
-- gross = basic_salary + allowance ; net = gross - deduction

DROP SCHEMA IF EXISTS q6_payroll CASCADE;
CREATE SCHEMA q6_payroll;
SET search_path = q6_payroll, public;

/* ===================== (a) Database and seed data ===================== */
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active       BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE          NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL,
    net_pay     NUMERIC(12,2) NOT NULL,
    CONSTRAINT ck_pay_month_start CHECK (EXTRACT(DAY FROM pay_month) = 1),   -- first date of a month
    CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP     NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Alice Mulenga', 8000, 1500, 1200, TRUE),
    ('Brian Tembo',   6500, 1000,  900, TRUE),
    ('Chanda Zulu',   5000,  800,  700, TRUE),
    ('Daniel Mwale',  7000, 1200, 1000, TRUE),    -- will be deactivated after month 1
    ('Eve Lungu',     4500,  500,  400, FALSE);   -- inactive from the start

/* ===================== (b) Function ===================== */
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql AS $$
DECLARE
    v_net NUMERIC(12,2);
BEGIN
    SELECT basic_salary + allowance - deduction INTO v_net
    FROM employees WHERE employee_id = p_employee_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;
    RETURN v_net;
END;
$$;

/* ===================== (c) Procedure ===================== */
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month must be the first date of a month, got %', p_month;
    END IF;

    FOR r IN SELECT employee_id, basic_salary, allowance
             FROM employees WHERE active ORDER BY employee_id
    LOOP
        -- fn_net_pay raises for an invalid (negative) result, which fails the WHOLE call.
        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, fn_net_pay(r.employee_id))
        ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing rows stay unchanged
    END LOOP;
END;
$$;

/* ===================== (d) Trigger ===================== */
CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (NEW.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NULL;
END;
$$;

CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

/* ---- (a) continued: payroll data for two months ---- */
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date);   -- month 1

UPDATE employees SET active = FALSE WHERE employee_id = 4;           -- Daniel leaves (no audit: salary unchanged)
UPDATE employees SET basic_salary = 6500 WHERE employee_id = 2;      -- same value, no actual change -> no audit row
UPDATE employees SET basic_salary = 6900 WHERE employee_id = 2;      -- real change -> 1 audit row

CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date);    -- month 2

SELECT * FROM payroll ORDER BY pay_month, employee_id;     -- 4 rows in month 1, 3 rows in month 2
SELECT * FROM salary_audit;                                -- exactly one row (6500 -> 6900)

-- Function tests
SELECT employee_id, fn_net_pay(employee_id) AS net FROM employees ORDER BY 1;
DO $$ BEGIN PERFORM fn_net_pay(99);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;

-- Re-processing a month leaves existing rows unchanged (even after a salary change)
UPDATE employees SET basic_salary = 9999 WHERE employee_id = 1;
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date);
SELECT employee_id, gross_pay, net_pay FROM payroll
WHERE employee_id = 1 AND pay_month = (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date;  -- still 9500 / 8300
UPDATE employees SET basic_salary = 8000 WHERE employee_id = 1;    -- restore

-- Invalid month and all-or-nothing failure
DO $$ BEGIN CALL pr_process_payroll(DATE '2026-03-15');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;

INSERT INTO employees (full_name, basic_salary, allowance, deduction) VALUES ('Bad Calc', 100, 0, 5000);  -- net < 0
DO $$ BEGIN CALL pr_process_payroll(date_trunc('month', CURRENT_DATE)::date);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM; END $$;
SELECT count(*) AS rows_for_current_month FROM payroll WHERE pay_month = date_trunc('month', CURRENT_DATE)::date;  -- 0: whole call failed
DELETE FROM employees WHERE full_name = 'Bad Calc';

/* ===================== (e) View ===================== */
-- INNER JOIN from payroll to employees: historical rows stay even when the employee is inactive.
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT p.pay_month, e.employee_id, e.full_name, e.active, p.gross_pay, p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, employee_id;   -- Daniel (inactive) still in month 1

/* ===================== (f) Index ===================== */
-- Justification: UNIQUE (employee_id, pay_month) has employee_id as its LEADING column, so it
-- cannot efficiently serve "all employees for one month". An index on pay_month alone does,
-- and it is NOT a duplicate of the unique index (different leading column).
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;

SET enable_seqscan = off;   -- tiny demo table: force the planner to show the index
EXPLAIN
SELECT * FROM payroll WHERE pay_month = (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date;
RESET enable_seqscan;

/* ===================== (g) Scheduled job ===================== */
CREATE EXTENSION IF NOT EXISTS pg_cron;
-- 02:00 on day 1 of every month; passes the first date of the PREVIOUS month.
SELECT cron.schedule('q6_process_payroll_monthly', '0 2 1 * *',
    $$CALL q6_payroll.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);

-- Inspect the job definition:
SELECT jobid, jobname, schedule, command, active FROM cron.job WHERE jobname = 'q6_process_payroll_monthly';
-- Inspect its run history (newest first):
SELECT d.runid, d.status, d.start_time
FROM cron.job_run_details d
JOIN cron.job j ON j.jobid = d.jobid
WHERE j.jobname = 'q6_process_payroll_monthly'
ORDER BY d.start_time DESC;
-- (pg_cron's real job_run_details table also has return_message and end_time columns.)
