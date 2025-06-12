--
-- PostgreSQL database dump
--

-- Dumped from database version 17.3
-- Dumped by pg_dump version 17.3

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: activate_employee_on_contract(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.activate_employee_on_contract() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE employee
    SET employment_status = 'active'
    WHERE employee_id = NEW.employee_id
      AND employment_status = 'pending';
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.activate_employee_on_contract() OWNER TO postgres;

--
-- Name: auto_refund_when_canceled(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.auto_refund_when_canceled() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF OLD.order_status <> 'canceled' AND NEW.order_status = 'canceled' 
       AND OLD.payment_status = 'paid' THEN
        NEW.payment_status := 'refunded';
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.auto_refund_when_canceled() OWNER TO postgres;

--
-- Name: block_invalid_refund(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.block_invalid_refund() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.payment_status = 'refunded' AND NEW.order_status <> 'canceled' THEN
        RAISE EXCEPTION 'Cannot set payment_status to refunded unless order_status is canceled.';
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.block_invalid_refund() OWNER TO postgres;

--
-- Name: cancel_order_and_refund(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.cancel_order_and_refund(p_order_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    od_rec RECORD;
BEGIN
    -- 1. N?u don da thanh to n, chuy?n payment_status th…nh 'refunded'
    UPDATE customer_order
    SET payment_status = 'refunded'
    WHERE order_id = p_order_id AND payment_status = 'paid';

    -- 2. C?p nh?t order_status th…nh 'canceled'
    UPDATE customer_order
    SET order_status = 'canceled'
    WHERE order_id = p_order_id;

    -- 3. Duy?t qua t?ng order_detail d? ho…n kho
    FOR od_rec IN
        SELECT batch_id, quantity
        FROM order_detail
        WHERE order_id = p_order_id
    LOOP
        UPDATE batch
        SET remaining_quantity = remaining_quantity + od_rec.quantity
        WHERE batch_id = od_rec.batch_id;
    END LOOP;
END;
$$;


ALTER FUNCTION public.cancel_order_and_refund(p_order_id integer) OWNER TO postgres;

--
-- Name: check_batch_warehouse_category(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.check_batch_warehouse_category() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    prod_cat_id INT;
    allowed_warehouse_cat_id INT;
    actual_warehouse_cat_id INT;
BEGIN
    -- Get the product category id from product
    SELECT product_category_id INTO prod_cat_id
    FROM product
    WHERE product_id = NEW.product_id;

    -- Get the allowed warehouse category id for this product category
    SELECT warehouse_category_id INTO allowed_warehouse_cat_id
    FROM product_category
    WHERE product_category_id = prod_cat_id;

    -- Get the warehouse category id from warehouse
    SELECT warehouse_category_id INTO actual_warehouse_cat_id
    FROM warehouse
    WHERE warehouse_id = NEW.warehouse_id;

    -- Check if allowed and actual warehouse category are the same
    IF allowed_warehouse_cat_id IS NULL OR actual_warehouse_cat_id IS NULL OR allowed_warehouse_cat_id <> actual_warehouse_cat_id THEN
        RAISE EXCEPTION 'Cannot insert batch: Product category only allowed in warehouse category %, but this warehouse has category %',
            allowed_warehouse_cat_id, actual_warehouse_cat_id;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.check_batch_warehouse_category() OWNER TO postgres;

--
-- Name: check_employee_role(integer, character varying); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.check_employee_role(p_employee_id integer, p_role character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_role VARCHAR(64);
BEGIN
    SELECT role INTO v_role FROM employee WHERE employee_id = p_employee_id;
    IF v_role IS NULL THEN
        RAISE EXCEPTION 'Employee % does not exist.', p_employee_id;
    END IF;
    IF v_role <> p_role THEN
        RAISE EXCEPTION 'Employee % does not have required role: % (actual: %)', p_employee_id, p_role, v_role;
    END IF;
END;
$$;


ALTER FUNCTION public.check_employee_role(p_employee_id integer, p_role character varying) OWNER TO postgres;

--
-- Name: check_employee_status(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.check_employee_status(p_employee_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_status VARCHAR(32);
BEGIN
    SELECT employment_status INTO v_status FROM employee WHERE employee_id = p_employee_id;
    IF v_status NOT IN ('active', 'probation') THEN
        RAISE EXCEPTION 'Employee % is not allowed to perform this action (status: %)', p_employee_id, v_status;
    END IF;
END;
$$;


ALTER FUNCTION public.check_employee_status(p_employee_id integer) OWNER TO postgres;

--
-- Name: check_expiry_date_not_null(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.check_expiry_date_not_null() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    prod_cat_id INT;
BEGIN
    SELECT product_category_id INTO prod_cat_id
    FROM product
    WHERE product_id = NEW.product_id;

    IF prod_cat_id IN (1,2,3,5) AND NEW.expiry_date IS NULL THEN
        RAISE EXCEPTION 'expiry_date cannot be NULL for this product category (id %)', prod_cat_id;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.check_expiry_date_not_null() OWNER TO postgres;

--
-- Name: check_rank_valid(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.check_rank_valid() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.rank IS DISTINCT FROM OLD.rank THEN
        IF NEW.rank = 'silver' AND NEW.member_points >= 1000 THEN
            RAISE EXCEPTION 'Rank ''silver'' requires member_points < 1000!';
        ELSIF NEW.rank = 'gold' AND (NEW.member_points < 1000 OR NEW.member_points >= 10000) THEN
            RAISE EXCEPTION 'Rank ''gold'' requires 1000 <= member_points < 10000!';
        ELSIF NEW.rank = 'diamond' AND NEW.member_points < 10000 THEN
            RAISE EXCEPTION 'Rank ''diamond'' requires member_points >= 10000!';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.check_rank_valid() OWNER TO postgres;

--
-- Name: create_order_details(integer, integer, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.create_order_details(p_order_id integer, p_product_id integer, p_quantity integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_total_remaining INT;
    v_needed INT := p_quantity;
    v_batch_id INT;
    v_take INT;
    v_product_price NUMERIC(15,2);
    v_total_price NUMERIC(15,2);
    v_total_order_price NUMERIC(15,2);
    v_order_status VARCHAR(32);
    batch_rec RECORD;
BEGIN
    -- 0. Ki?m tra tr?ng th i don h…ng
    SELECT order_status INTO v_order_status FROM customer_order WHERE order_id = p_order_id;
    IF v_order_status IS DISTINCT FROM 'pending' THEN
        RAISE EXCEPTION 'Can only add product to order with status pending!';
    END IF;

    -- 1. Ki?m tra t?n kho
    SELECT COALESCE(SUM(remaining_quantity), 0) INTO v_total_remaining
    FROM batch
    WHERE product_id = p_product_id AND remaining_quantity > 0;

    IF v_total_remaining < p_quantity THEN
        RAISE EXCEPTION 'Not enough product in stock! Remain: %, Needed: %', v_total_remaining, p_quantity;
    END IF;

    -- 2. L?y gi  b n
    SELECT price INTO v_product_price FROM product WHERE product_id = p_product_id;

    -- 3. Chia batch & chŠn order_detail
    FOR batch_rec IN
        SELECT * FROM batch
        WHERE product_id = p_product_id AND remaining_quantity > 0
        ORDER BY expiry_date NULLS FIRST, import_date
    LOOP
        EXIT WHEN v_needed = 0;

        v_batch_id := batch_rec.batch_id;
        IF batch_rec.remaining_quantity >= v_needed THEN
            v_take := v_needed;
        ELSE
            v_take := batch_rec.remaining_quantity;
        END IF;

        v_total_price := v_product_price * v_take;

        INSERT INTO order_detail(order_id, product_id, batch_id, quantity, product_price, total_price)
        VALUES (p_order_id, p_product_id, v_batch_id, v_take, v_product_price, v_total_price);

        UPDATE batch
        SET remaining_quantity = remaining_quantity - v_take
        WHERE batch_id = v_batch_id;

        v_needed := v_needed - v_take;
    END LOOP;

    -- 4. T¡nh l?i t?ng ti?n order
    SELECT SUM(total_price) INTO v_total_order_price
    FROM order_detail
    WHERE order_id = p_order_id;

    UPDATE customer_order
    SET total_amount = v_total_order_price
    WHERE order_id = p_order_id;

END;
$$;


ALTER FUNCTION public.create_order_details(p_order_id integer, p_product_id integer, p_quantity integer) OWNER TO postgres;

--
-- Name: enforce_contract_on_status_change(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.enforce_contract_on_status_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_end_date date;
BEGIN
    SELECT contract_end_date INTO v_end_date
    FROM employment_contract
    WHERE employee_id = NEW.employee_id
    ORDER BY contract_end_date DESC
    LIMIT 1;

    IF v_end_date IS NULL THEN
        IF NEW.employment_status <> 'pending' THEN
            RAISE EXCEPTION 'No contract: only pending status allowed.';
        END IF;
        RETURN NEW;
    END IF;

    IF v_end_date < CURRENT_DATE THEN
        IF NEW.employment_status NOT IN ('pending', 'resigned') THEN
            RAISE EXCEPTION 'Contract expired: only pending or resigned status allowed.';
        END IF;
        RETURN NEW;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.enforce_contract_on_status_change() OWNER TO postgres;

--
-- Name: enforce_pending_on_insert(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.enforce_pending_on_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.employment_status := 'pending';
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.enforce_pending_on_insert() OWNER TO postgres;

--
-- Name: log_employee_status_change(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.log_employee_status_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.employment_status IS DISTINCT FROM OLD.employment_status THEN
        INSERT INTO work_status_log(employee_id, status, log_time, note)
        VALUES (NEW.employee_id, NEW.employment_status, CURRENT_DATE, 'Status changed automatically');
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.log_employee_status_change() OWNER TO postgres;

--
-- Name: log_employee_status_on_insert(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.log_employee_status_on_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO work_status_log(employee_id, status, log_time, note)
    VALUES (NEW.employee_id, NEW.employment_status, CURRENT_DATE, 'Employee created');
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.log_employee_status_on_insert() OWNER TO postgres;

--
-- Name: order_status_rank(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.order_status_rank(s text) RETURNS integer
    LANGUAGE plpgsql IMMUTABLE
    AS $$
BEGIN
    CASE s
        WHEN 'pending'   THEN RETURN 0;
        WHEN 'approved'  THEN RETURN 1;
        WHEN 'shipping'  THEN RETURN 2;
        WHEN 'delivered' THEN RETURN 3;
        WHEN 'canceled'  THEN RETURN 4;
        ELSE RETURN -1; -- unknown
    END CASE;
END;
$$;


ALTER FUNCTION public.order_status_rank(s text) OWNER TO postgres;

--
-- Name: reactivate_employee_on_contract_update(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.reactivate_employee_on_contract_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.contract_end_date IS NOT NULL 
       AND NEW.contract_end_date >= CURRENT_DATE THEN
        UPDATE employee
        SET employment_status = 'active'
        WHERE employee_id = NEW.employee_id
          AND employment_status <> 'resigned';
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.reactivate_employee_on_contract_update() OWNER TO postgres;

--
-- Name: restore_batch_quantity_on_cancel(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.restore_batch_quantity_on_cancel() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    rec RECORD;
BEGIN
    IF OLD.order_status <> 'canceled' AND NEW.order_status = 'canceled' THEN
        FOR rec IN
            SELECT batch_id, quantity
            FROM order_detail
            WHERE order_id = NEW.order_id
        LOOP
            UPDATE batch
            SET remaining_quantity = remaining_quantity + rec.quantity
            WHERE batch_id = rec.batch_id;
        END LOOP;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.restore_batch_quantity_on_cancel() OWNER TO postgres;

--
-- Name: set_delivered_at_when_completed(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_delivered_at_when_completed() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.order_status = 'delivered'
       AND NEW.payment_status = 'paid'
       AND (OLD.order_status <> 'delivered' OR OLD.payment_status <> 'paid' OR OLD.delivered_at IS NULL)
    THEN
        NEW.delivered_at := CURRENT_TIMESTAMP;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.set_delivered_at_when_completed() OWNER TO postgres;

--
-- Name: set_employee_pending_when_contract_expired(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_employee_pending_when_contract_expired() RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT e.employee_id
        FROM employee e
        LEFT JOIN LATERAL (
            SELECT contract_end_date
            FROM employment_contract c
            WHERE c.employee_id = e.employee_id
            ORDER BY contract_end_date DESC
            LIMIT 1
        ) latest_contract ON TRUE
        WHERE 
            (latest_contract.contract_end_date IS NULL OR latest_contract.contract_end_date < CURRENT_DATE)
            AND e.employment_status NOT IN ('pending', 'resigned')
    LOOP
        UPDATE employee
        SET employment_status = 'pending'
        WHERE employee_id = rec.employee_id;
    END LOOP;
END;
$$;


ALTER FUNCTION public.set_employee_pending_when_contract_expired() OWNER TO postgres;

--
-- Name: set_remaining_quantity_on_batch_insert(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.set_remaining_quantity_on_batch_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.remaining_quantity := NEW.quantity;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.set_remaining_quantity_on_batch_insert() OWNER TO postgres;

--
-- Name: trg_block_update_when_closed(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.trg_block_update_when_closed() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Ch?n c?p nh?t n?u don da b? hu?
    IF OLD.order_status = 'canceled' THEN
        RAISE EXCEPTION 'Order canceled, cannot update this order!';
    END IF;

    -- Ch?n c?p nh?t n?u don da giao, da thanh to n, v… da qu  7 ng…y k? t? giao
    IF OLD.order_status = 'delivered'
        AND OLD.payment_status = 'paid'
        AND OLD.delivered_at IS NOT NULL
        AND (NOW() - OLD.delivered_at) >= INTERVAL '7 days'
    THEN
        RAISE EXCEPTION 'Cannot update: delivered and paid order is closed after 7 days!';
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.trg_block_update_when_closed() OWNER TO postgres;

--
-- Name: trg_check_order_status_order(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.trg_check_order_status_order() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    old_rank integer;
    new_rank integer;
BEGIN
    IF OLD.order_status = 'pending' THEN
        RETURN NEW;
    END IF;

    IF NEW.order_status = OLD.order_status THEN
        RETURN NEW;
    END IF;

    old_rank := order_status_rank(OLD.order_status);
    new_rank := order_status_rank(NEW.order_status);

    IF new_rank < old_rank THEN
        RAISE EXCEPTION 'Cannot change order_status to a previous state!';
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.trg_check_order_status_order() OWNER TO postgres;

--
-- Name: trg_validate_payment_status(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.trg_validate_payment_status() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF OLD.payment_status = 'unpaid' AND NEW.payment_status NOT IN ('unpaid', 'paid') THEN
        RAISE EXCEPTION 'Invalid status transition: unpaid can only be changed to paid.';
    ELSIF OLD.payment_status = 'paid' AND NEW.payment_status NOT IN ('paid', 'refunded') THEN
        RAISE EXCEPTION 'Invalid status transition: paid can only be changed to refunded.';
    ELSIF OLD.payment_status = 'refunded' AND NEW.payment_status <> 'refunded' THEN
        RAISE EXCEPTION 'Invalid status transition: refunded cannot be changed to any other status.';
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.trg_validate_payment_status() OWNER TO postgres;

--
-- Name: update_customer_last_active(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_customer_last_active() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    UPDATE customer
    SET last_active_at = NOW()
    WHERE customer_id = NEW.customer_id;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_customer_last_active() OWNER TO postgres;

--
-- Name: update_employee_status(integer, integer, character varying); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_employee_status(p_executor_id integer, p_target_id integer, p_new_status character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM check_employee_role(p_executor_id, 'manager');
    IF p_new_status NOT IN (
        'active', 'on_leave', 'on_maternity_leave', 'contract_suspended',
        'probation', 'suspended', 'resigned', 'pending'
    ) THEN
        RAISE EXCEPTION 'Invalid status: %', p_new_status;
    END IF;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Target employee % does not exist.', p_target_id;
    END IF;
    UPDATE employee
    SET employment_status = p_new_status
    WHERE employee_id = p_target_id;
END;
$$;


ALTER FUNCTION public.update_employee_status(p_executor_id integer, p_target_id integer, p_new_status character varying) OWNER TO postgres;

--
-- Name: update_member_points_after_payment(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_member_points_after_payment() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_points numeric(10,2);
BEGIN
    IF OLD.payment_status = 'unpaid' AND NEW.payment_status = 'paid' THEN
        v_points := FLOOR(NEW.total_amount / 1000.0);
        UPDATE customer
        SET member_points = member_points + v_points
        WHERE customer_id = NEW.customer_id;

    ELSIF OLD.payment_status = 'paid' AND NEW.payment_status = 'refunded' THEN
        v_points := FLOOR(NEW.total_amount / 1000.0);
        UPDATE customer
        SET member_points = member_points - v_points
        WHERE customer_id = NEW.customer_id;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_member_points_after_payment() OWNER TO postgres;

--
-- Name: update_rank_when_points_change(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.update_rank_when_points_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.member_points IS DISTINCT FROM OLD.member_points THEN
        IF NEW.member_points < 1000 THEN
            NEW.rank := 'silver';
        ELSIF NEW.member_points < 10000 THEN
            NEW.rank := 'gold';
        ELSE
            NEW.rank := 'diamond';
        END IF;
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_rank_when_points_change() OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: batch; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.batch (
    batch_id integer NOT NULL,
    product_id integer NOT NULL,
    import_date date NOT NULL,
    expiry_date date,
    purchase_price numeric(15,2) NOT NULL,
    quantity integer NOT NULL,
    note text,
    warehouse_id integer NOT NULL,
    remaining_quantity integer DEFAULT 0 NOT NULL,
    CONSTRAINT chk_batch_remaining_quantity_non_negative CHECK ((remaining_quantity >= 0))
);


ALTER TABLE public.batch OWNER TO postgres;

--
-- Name: batch_batch_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.batch_batch_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.batch_batch_id_seq OWNER TO postgres;

--
-- Name: batch_batch_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.batch_batch_id_seq OWNED BY public.batch.batch_id;


--
-- Name: customer; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.customer (
    customer_id integer NOT NULL,
    full_name character varying(128) NOT NULL,
    gender character(1),
    date_of_birth date,
    phone character varying(32) NOT NULL,
    email character varying(128),
    member_points integer DEFAULT 0,
    rank character varying(16),
    registration_date date DEFAULT CURRENT_DATE,
    password character varying(128),
    last_active_at date DEFAULT CURRENT_TIMESTAMP,
    status character varying(16) DEFAULT 'active'::character varying NOT NULL,
    CONSTRAINT customer_gender_check CHECK ((gender = ANY (ARRAY['M'::bpchar, 'F'::bpchar]))),
    CONSTRAINT customer_rank_check CHECK (((rank)::text = ANY ((ARRAY['silver'::character varying, 'gold'::character varying, 'diamond'::character varying])::text[]))),
    CONSTRAINT customer_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'blocked'::character varying])::text[])))
);


ALTER TABLE public.customer OWNER TO postgres;

--
-- Name: customer_customer_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.customer_customer_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.customer_customer_id_seq OWNER TO postgres;

--
-- Name: customer_customer_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.customer_customer_id_seq OWNED BY public.customer.customer_id;


--
-- Name: customer_order; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.customer_order (
    order_id integer NOT NULL,
    customer_id integer,
    employee_id integer,
    delivered_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    total_amount numeric(15,2) DEFAULT 0,
    payment_method character varying(32),
    order_status character varying(32) DEFAULT 'pending'::character varying,
    note text,
    payment_status character varying(32) DEFAULT 'unpaid'::character varying,
    CONSTRAINT customer_order_order_status_check CHECK (((order_status)::text = ANY ((ARRAY['pending'::character varying, 'approved'::character varying, 'shipping'::character varying, 'delivered'::character varying, 'canceled'::character varying])::text[]))),
    CONSTRAINT customer_order_payment_status_check CHECK (((payment_status)::text = ANY ((ARRAY['unpaid'::character varying, 'paid'::character varying, 'partial'::character varying, 'refunded'::character varying, 'failed'::character varying])::text[])))
);


ALTER TABLE public.customer_order OWNER TO postgres;

--
-- Name: customer_order_order_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.customer_order_order_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.customer_order_order_id_seq OWNER TO postgres;

--
-- Name: customer_order_order_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.customer_order_order_id_seq OWNED BY public.customer_order.order_id;


--
-- Name: employee; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.employee (
    employee_id integer NOT NULL,
    full_name character varying(128) NOT NULL,
    role character varying(64) NOT NULL,
    age integer,
    national_id character varying(32) NOT NULL,
    gender character(1),
    address character varying(256),
    phone character varying(32) NOT NULL,
    email character varying(128),
    salary numeric(15,2) NOT NULL,
    password character varying(128) NOT NULL,
    employment_status character varying(32) NOT NULL,
    CONSTRAINT employee_employment_status_check CHECK (((employment_status)::text = ANY (ARRAY[('active'::character varying)::text, ('on_leave'::character varying)::text, ('on_maternity_leave'::character varying)::text, ('contract_suspended'::character varying)::text, ('probation'::character varying)::text, ('suspended'::character varying)::text, ('resigned'::character varying)::text, ('pending'::character varying)::text]))),
    CONSTRAINT employee_gender_check CHECK ((gender = ANY (ARRAY['M'::bpchar, 'F'::bpchar]))),
    CONSTRAINT employee_role_check CHECK (((role)::text = ANY ((ARRAY['sales_staff'::character varying, 'warehouse_staff'::character varying, 'manager'::character varying])::text[])))
);


ALTER TABLE public.employee OWNER TO postgres;

--
-- Name: employee_employee_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.employee_employee_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.employee_employee_id_seq OWNER TO postgres;

--
-- Name: employee_employee_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.employee_employee_id_seq OWNED BY public.employee.employee_id;


--
-- Name: employment_contract; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.employment_contract (
    contract_id integer NOT NULL,
    employee_id integer NOT NULL,
    contract_date date,
    termination_reason text,
    termination_date date,
    content text,
    contract_end_date date,
    effective_date date,
    status character varying(16) DEFAULT 'active'::character varying NOT NULL,
    CONSTRAINT employment_contract_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'terminated'::character varying])::text[])))
);


ALTER TABLE public.employment_contract OWNER TO postgres;

--
-- Name: employment_contract_contract_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.employment_contract_contract_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.employment_contract_contract_id_seq OWNER TO postgres;

--
-- Name: employment_contract_contract_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.employment_contract_contract_id_seq OWNED BY public.employment_contract.contract_id;


--
-- Name: operating_expense_log; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.operating_expense_log (
    log_id integer NOT NULL,
    expense_type character varying(16) NOT NULL,
    amount_paid numeric(15,2) NOT NULL,
    pay_date date NOT NULL,
    note text,
    CONSTRAINT operating_expense_log_expense_type_check CHECK (((expense_type)::text = ANY ((ARRAY['tax'::character varying, 'electricity'::character varying, 'water'::character varying, 'rent'::character varying, 'other'::character varying])::text[])))
);


ALTER TABLE public.operating_expense_log OWNER TO postgres;

--
-- Name: operating_expense_log_log_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.operating_expense_log_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.operating_expense_log_log_id_seq OWNER TO postgres;

--
-- Name: operating_expense_log_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.operating_expense_log_log_id_seq OWNED BY public.operating_expense_log.log_id;


--
-- Name: order_detail; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.order_detail (
    order_detail_id integer NOT NULL,
    order_id integer,
    product_id integer,
    batch_id integer,
    quantity integer NOT NULL,
    product_price numeric(15,2) NOT NULL,
    total_price numeric(15,2) NOT NULL
);


ALTER TABLE public.order_detail OWNER TO postgres;

--
-- Name: order_detail_order_detail_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.order_detail_order_detail_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.order_detail_order_detail_id_seq OWNER TO postgres;

--
-- Name: order_detail_order_detail_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.order_detail_order_detail_id_seq OWNED BY public.order_detail.order_detail_id;


--
-- Name: product; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.product (
    product_id integer NOT NULL,
    product_name character varying(128) NOT NULL,
    product_type character varying(64) NOT NULL,
    price numeric(15,2) NOT NULL,
    unit character varying(16),
    description text,
    product_category_id integer
);


ALTER TABLE public.product OWNER TO postgres;

--
-- Name: product_category; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.product_category (
    product_category_id integer NOT NULL,
    name character varying(64) NOT NULL,
    warehouse_category_id integer NOT NULL
);


ALTER TABLE public.product_category OWNER TO postgres;

--
-- Name: product_category_product_category_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.product_category_product_category_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.product_category_product_category_id_seq OWNER TO postgres;

--
-- Name: product_category_product_category_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.product_category_product_category_id_seq OWNED BY public.product_category.product_category_id;


--
-- Name: product_product_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.product_product_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.product_product_id_seq OWNER TO postgres;

--
-- Name: product_product_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.product_product_id_seq OWNED BY public.product.product_id;


--
-- Name: salary_bonus_log; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.salary_bonus_log (
    log_id integer NOT NULL,
    employee_id integer NOT NULL,
    pay_period character varying(16),
    pay_type character varying(16) NOT NULL,
    amount_paid numeric(15,2) NOT NULL,
    pay_date date NOT NULL,
    note text,
    CONSTRAINT salary_bonus_log_pay_type_check CHECK (((pay_type)::text = ANY ((ARRAY['salary'::character varying, 'bonus'::character varying, 'penalty'::character varying])::text[])))
);


ALTER TABLE public.salary_bonus_log OWNER TO postgres;

--
-- Name: salary_bonus_log_log_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.salary_bonus_log_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.salary_bonus_log_log_id_seq OWNER TO postgres;

--
-- Name: salary_bonus_log_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.salary_bonus_log_log_id_seq OWNED BY public.salary_bonus_log.log_id;


--
-- Name: warehouse; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.warehouse (
    warehouse_id integer NOT NULL,
    warehouse_name character varying(128),
    warehouse_category_id integer
);


ALTER TABLE public.warehouse OWNER TO postgres;

--
-- Name: warehouse_category; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.warehouse_category (
    warehouse_category_id integer NOT NULL,
    name character varying(64) NOT NULL
);


ALTER TABLE public.warehouse_category OWNER TO postgres;

--
-- Name: warehouse_category_warehouse_category_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.warehouse_category_warehouse_category_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.warehouse_category_warehouse_category_id_seq OWNER TO postgres;

--
-- Name: warehouse_category_warehouse_category_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.warehouse_category_warehouse_category_id_seq OWNED BY public.warehouse_category.warehouse_category_id;


--
-- Name: warehouse_warehouse_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.warehouse_warehouse_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.warehouse_warehouse_id_seq OWNER TO postgres;

--
-- Name: warehouse_warehouse_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.warehouse_warehouse_id_seq OWNED BY public.warehouse.warehouse_id;


--
-- Name: work_status_log; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.work_status_log (
    log_id integer NOT NULL,
    employee_id integer NOT NULL,
    status character varying(32) NOT NULL,
    log_time date DEFAULT CURRENT_DATE NOT NULL,
    note text,
    CONSTRAINT log_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'on_leave'::character varying, 'on_maternity_leave'::character varying, 'contract_suspended'::character varying, 'probation'::character varying, 'suspended'::character varying, 'resigned'::character varying, 'pending'::character varying])::text[])))
);


ALTER TABLE public.work_status_log OWNER TO postgres;

--
-- Name: work_status_log_log_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.work_status_log_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.work_status_log_log_id_seq OWNER TO postgres;

--
-- Name: work_status_log_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.work_status_log_log_id_seq OWNED BY public.work_status_log.log_id;


--
-- Name: batch batch_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.batch ALTER COLUMN batch_id SET DEFAULT nextval('public.batch_batch_id_seq'::regclass);


--
-- Name: customer customer_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer ALTER COLUMN customer_id SET DEFAULT nextval('public.customer_customer_id_seq'::regclass);


--
-- Name: customer_order order_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer_order ALTER COLUMN order_id SET DEFAULT nextval('public.customer_order_order_id_seq'::regclass);


--
-- Name: employee employee_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.employee ALTER COLUMN employee_id SET DEFAULT nextval('public.employee_employee_id_seq'::regclass);


--
-- Name: employment_contract contract_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.employment_contract ALTER COLUMN contract_id SET DEFAULT nextval('public.employment_contract_contract_id_seq'::regclass);


--
-- Name: operating_expense_log log_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.operating_expense_log ALTER COLUMN log_id SET DEFAULT nextval('public.operating_expense_log_log_id_seq'::regclass);


--
-- Name: order_detail order_detail_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_detail ALTER COLUMN order_detail_id SET DEFAULT nextval('public.order_detail_order_detail_id_seq'::regclass);


--
-- Name: product product_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product ALTER COLUMN product_id SET DEFAULT nextval('public.product_product_id_seq'::regclass);


--
-- Name: product_category product_category_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_category ALTER COLUMN product_category_id SET DEFAULT nextval('public.product_category_product_category_id_seq'::regclass);


--
-- Name: salary_bonus_log log_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salary_bonus_log ALTER COLUMN log_id SET DEFAULT nextval('public.salary_bonus_log_log_id_seq'::regclass);


--
-- Name: warehouse warehouse_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouse ALTER COLUMN warehouse_id SET DEFAULT nextval('public.warehouse_warehouse_id_seq'::regclass);


--
-- Name: warehouse_category warehouse_category_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouse_category ALTER COLUMN warehouse_category_id SET DEFAULT nextval('public.warehouse_category_warehouse_category_id_seq'::regclass);


--
-- Name: work_status_log log_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.work_status_log ALTER COLUMN log_id SET DEFAULT nextval('public.work_status_log_log_id_seq'::regclass);


--
-- Data for Name: batch; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.batch (batch_id, product_id, import_date, expiry_date, purchase_price, quantity, note, warehouse_id, remaining_quantity) FROM stdin;
38	4	2024-06-01	2024-11-30	190000.00	5	\N	1	5
49	4	2024-07-01	2026-04-30	192000.00	7	\N	1	7
39	5	2024-06-01	2024-07-10	14000.00	50	\N	2	50
50	5	2024-07-05	2026-05-10	14200.00	30	\N	2	30
36	2	2024-06-01	2024-12-01	68000.00	15	\N	1	15
37	3	2024-06-01	2024-11-15	148000.00	10	\N	1	10
40	6	2024-06-01	2024-07-10	22000.00	40	\N	2	40
41	7	2024-06-01	2024-06-30	29000.00	25	\N	2	25
42	8	2024-06-01	2024-07-31	48000.00	30	\N	2	30
43	9	2024-06-01	2025-06-01	6500.00	100	\N	3	100
44	10	2024-06-01	2026-06-01	44000.00	60	\N	3	60
45	16	2024-06-01	\N	1700000.00	5	\N	4	5
47	2	2024-06-15	2026-02-20	69000.00	10	\N	1	10
48	3	2024-06-20	2026-03-15	149000.00	8	\N	1	8
51	6	2024-07-10	2026-06-15	22500.00	20	\N	2	20
52	7	2024-07-12	2026-07-20	29500.00	18	\N	2	18
53	8	2024-07-15	2026-08-31	48200.00	22	\N	2	22
54	9	2024-07-20	2026-09-01	6600.00	80	\N	3	80
55	10	2024-08-01	2026-10-01	44500.00	35	\N	3	35
35	1	2024-06-01	2024-12-01	75000.00	20	\N	1	0
46	1	2024-06-10	2026-01-10	76000.00	25	\N	1	5
\.


--
-- Data for Name: customer; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.customer (customer_id, full_name, gender, date_of_birth, phone, email, member_points, rank, registration_date, password, last_active_at, status) FROM stdin;
1	Nguyen Van A	M	1990-01-01	0901000001	a.nguyen@email.com	21	silver	2024-06-01	password1	2025-06-01	active
2	Tran Thi B	F	1992-02-02	0901000002	b.tran@email.com	21	silver	2024-06-02	password2	2025-06-01	active
3	Le Van C	M	1988-03-03	0901000003	c.le@email.com	21	silver	2024-06-03	password3	2025-06-01	active
4	Pham Thi D	F	1995-04-04	0901000004	d.pham@email.com	21	silver	2024-06-04	password4	2025-06-01	active
6	Bui Thi F	F	1991-06-06	0901000006	f.bui@email.com	21	silver	2024-06-06	password6	2025-06-01	active
7	Doan Van G	M	1989-07-07	0901000007	g.doan@email.com	21	silver	2024-06-07	password7	2025-06-01	active
9	Pham Van I	M	1994-09-09	0901000009	i.pham@email.com	21	silver	2024-06-09	password9	2025-06-01	active
5	Vo Minh E	M	1993-05-05	0901000005	e.vo@email.com	21	silver	2024-06-05	password5	2025-06-02	active
10	Tran Thi J	F	1997-10-10	0901000010	j.tran@email.com	21	silver	2024-06-10	password10	2025-06-01	active
8	Dang Thi H	F	1996-08-08	0901000008	h.dang@email.com	21	silver	2024-06-08	password8	2025-06-02	active
\.


--
-- Data for Name: customer_order; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.customer_order (order_id, customer_id, employee_id, delivered_at, total_amount, payment_method, order_status, note, payment_status) FROM stdin;
1	1	2	2025-06-01 21:29:40.507785	6400000.00	cash	canceled	\N	refunded
2	2	2	2025-06-01 21:55:09.986117	6400000.00	cash	canceled	\N	unpaid
5	5	3	2025-06-02 06:42:58.246201	0.00	cash	canceled	\N	unpaid
3	5	2	2025-06-02 05:42:45.941878	0.00	card	canceled	\N	refunded
6	5	3	2025-06-02 06:58:55.407764	3200000.00	cash	canceled	\N	refunded
7	8	3	2025-06-02 07:24:47.054879	3200000.00	card	canceled	\N	refunded
\.


--
-- Data for Name: employee; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.employee (employee_id, full_name, role, age, national_id, gender, address, phone, email, salary, password, employment_status) FROM stdin;
1	Alice Johnson	sales_staff	25	ID001	F	123 Main St	0123456789	alice@example.com	800.00	alicepass	pending
4	David Kim	sales_staff	40	ID004	M	321 South St	0123456792	david@example.com	1500.00	davidpass	pending
8	Henry Ford	sales_staff	38	ID008	M	258 Garden Dr	0123456796	henry@example.com	1100.00	henrypass	pending
9	Ivy Nguyen	sales_staff	27	ID009	F	369 Lake St	0123456797	ivy@example.com	1450.00	ivypass	active
2	Bob Smith	sales_staff	30	ID002	M	456 First Ave	0123456790	bob@example.com	900.00	bobpass	active
7	Grace Lee	sales_staff	29	ID007	F	147 Park Blvd	0123456795	grace@example.com	880.00	gracepass	resigned
10	Jack White	sales_staff	31	ID010	M	753 Hill Rd	0123456798	jack@example.com	970.00	jackpass	pending
3	Carol Lee	manager	35	ID003	F	789 North Rd	0123456791	carol@example.com	1200.00	carolpass	active
5	Eva Green	manager	28	ID005	F	654 West St	0123456793	eva@example.com	950.00	evapass	active
6	Frank Brown	sales_staff	32	ID006	M	987 East Ave	0123456794	frank@example.com	820.00	frankpass	active
\.


--
-- Data for Name: employment_contract; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.employment_contract (contract_id, employee_id, contract_date, termination_reason, termination_date, content, contract_end_date, effective_date, status) FROM stdin;
1	2	2024-06-01	\N	\N	Labor contract for Bob Smith	2026-06-01	2024-06-10	active
2	3	2024-06-01	\N	\N	Labor contract for Carol Lee	2026-06-01	2024-06-10	active
3	5	2024-06-01	\N	\N	Labor contract for Eva Green	2026-06-01	2024-06-10	active
4	6	2024-06-01	\N	\N	Labor contract for Frank Brown	2026-06-01	2024-06-10	active
5	9	2024-06-01	\N	\N	Labor contract for Ivy Nguyen	2026-06-01	2024-06-10	active
6	10	2024-06-01	\N	\N	Labor contract for Jack White	2026-06-01	2024-06-10	active
8	7	2022-06-01	Contract ended normally	2023-06-10	Expired labor contract for Grace Lee	2023-06-10	2022-06-10	active
\.


--
-- Data for Name: operating_expense_log; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.operating_expense_log (log_id, expense_type, amount_paid, pay_date, note) FROM stdin;
\.


--
-- Data for Name: order_detail; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.order_detail (order_detail_id, order_id, product_id, batch_id, quantity, product_price, total_price) FROM stdin;
1	1	1	35	20	80000.00	1600000.00
2	1	1	46	20	80000.00	1600000.00
3	1	4	38	5	200000.00	1000000.00
4	1	4	49	5	200000.00	1000000.00
5	1	5	39	50	15000.00	750000.00
6	1	5	50	30	15000.00	450000.00
7	2	1	35	20	80000.00	1600000.00
8	2	1	46	20	80000.00	1600000.00
9	2	4	38	5	200000.00	1000000.00
10	2	4	49	5	200000.00	1000000.00
11	2	5	39	50	15000.00	750000.00
12	2	5	50	30	15000.00	450000.00
13	6	1	35	20	80000.00	1600000.00
14	6	1	46	20	80000.00	1600000.00
15	7	4	38	5	200000.00	1000000.00
16	7	4	49	5	200000.00	1000000.00
17	7	5	39	50	15000.00	750000.00
18	7	5	50	30	15000.00	450000.00
\.


--
-- Data for Name: product; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.product (product_id, product_name, product_type, price, unit, description, product_category_id) FROM stdin;
11	Toothpaste	Cosmetic	30000.00	tube	\N	3
12	Rice	Dry Food	18000.00	kg	\N	3
13	Electric Kettle	Appliance	350000.00	piece	\N	4
14	Frying Pan	Appliance	180000.00	piece	\N	4
15	Rice Cooker	Appliance	600000.00	piece	\N	4
17	Laundry Detergent	Chemical	120000.00	bottle	\N	5
18	Dishwashing Liquid	Chemical	40000.00	bottle	\N	5
19	Bleach	Chemical	25000.00	bottle	\N	5
20	Glass Cleaner	Chemical	30000.00	bottle	\N	5
1	Pork Loin	Meat	80000.00	kg	\N	1
2	Chicken Breast	Meat	70000.00	kg	\N	1
3	Salmon Fillet	Fish	150000.00	kg	\N	1
4	Beef Steak	Meat	200000.00	kg	\N	1
5	Cabbage	Vegetable	15000.00	piece	\N	2
6	Tomato	Vegetable	25000.00	kg	\N	2
7	Banana	Fruit	30000.00	kg	\N	2
8	Apple	Fruit	50000.00	kg	\N	2
9	Instant Noodles	Dry Food	7000.00	pack	\N	3
10	Shampoo	Cosmetic	45000.00	bottle	\N	3
16	Microwave Oven	Appliance	1800000.00	piece	\N	4
21	Eggs	Fresh Food	35000.00	dozen		1
22	Orange	Fruit	40000.00	kg		2
23	Potato	Vegetable	20000.00	kg		2
24	Broccoli	Vegetable	35000.00	piece		2
25	Grapes	Fruit	65000.00	kg		2
26	Green Tea	Dry Food	25000.00	box		3
27	Coffee	Dry Food	75000.00	box		3
28	Mouthwash	Cosmetic	55000.00	bottle		3
29	Hair Gel	Cosmetic	50000.00	tube		3
30	Electric Fan	Appliance	450000.00	piece		4
31	Rice Cooker Mini	Appliance	400000.00	piece		4
32	Air Fryer	Appliance	1800000.00	piece		4
33	Iron	Appliance	320000.00	piece		4
34	Fabric Softener	Chemical	90000.00	bottle		5
35	Hand Soap	Chemical	30000.00	bottle		5
36	Surface Cleaner	Chemical	35000.00	bottle		5
37	Hand Sanitizer	Chemical	45000.00	bottle		5
38	Frozen Shrimp	Fresh Food	90000.00	kg		1
39	Fish Ball	Fresh Food	70000.00	kg		1
40	Bread	Dry Food	20000.00	bag		3
\.


--
-- Data for Name: product_category; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.product_category (product_category_id, name, warehouse_category_id) FROM stdin;
1	Fresh Food	1
2	Vegetables & Fruits	2
3	Dry Food & Cosmetics	3
4	Household Appliances	4
5	Chemicals	5
\.


--
-- Data for Name: salary_bonus_log; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.salary_bonus_log (log_id, employee_id, pay_period, pay_type, amount_paid, pay_date, note) FROM stdin;
\.


--
-- Data for Name: warehouse; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.warehouse (warehouse_id, warehouse_name, warehouse_category_id) FROM stdin;
1	Cold Store 1	1
2	Cool Store 1	2
3	Dry Store 1	3
4	General Store 1	4
5	Chemical Store 1	5
6	Transit Store 1	6
7	Finished Goods 1	7
8	Cold Store 2	1
9	Cool Store 2	2
10	General Store 2	4
\.


--
-- Data for Name: warehouse_category; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.warehouse_category (warehouse_category_id, name) FROM stdin;
1	Cold Storage
2	Cool Storage
3	Dry Storage
4	General Goods
5	Chemical Storage
6	Transit Storage
7	Finished Goods
\.


--
-- Data for Name: work_status_log; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.work_status_log (log_id, employee_id, status, log_time, note) FROM stdin;
1	10	pending	2025-06-02	Status changed automatically
2	6	pending	2025-06-02	Status changed automatically
3	6	active	2025-06-02	Status changed automatically
\.


--
-- Name: batch_batch_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.batch_batch_id_seq', 55, true);


--
-- Name: customer_customer_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.customer_customer_id_seq', 513, true);


--
-- Name: customer_order_order_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.customer_order_order_id_seq', 7, true);


--
-- Name: employee_employee_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.employee_employee_id_seq', 10, true);


--
-- Name: employment_contract_contract_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.employment_contract_contract_id_seq', 8, true);


--
-- Name: operating_expense_log_log_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.operating_expense_log_log_id_seq', 1, false);


--
-- Name: order_detail_order_detail_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.order_detail_order_detail_id_seq', 18, true);


--
-- Name: product_category_product_category_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.product_category_product_category_id_seq', 7, true);


--
-- Name: product_product_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.product_product_id_seq', 40, true);


--
-- Name: salary_bonus_log_log_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.salary_bonus_log_log_id_seq', 1, false);


--
-- Name: warehouse_category_warehouse_category_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.warehouse_category_warehouse_category_id_seq', 7, true);


--
-- Name: warehouse_warehouse_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.warehouse_warehouse_id_seq', 10, true);


--
-- Name: work_status_log_log_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.work_status_log_log_id_seq', 3, true);


--
-- Name: batch batch_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.batch
    ADD CONSTRAINT batch_pkey PRIMARY KEY (batch_id);


--
-- Name: customer customer_email_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_email_unique UNIQUE (email);


--
-- Name: customer_order customer_order_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer_order
    ADD CONSTRAINT customer_order_pkey PRIMARY KEY (order_id);


--
-- Name: customer customer_phone_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_phone_unique UNIQUE (phone);


--
-- Name: customer customer_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_pkey PRIMARY KEY (customer_id);


--
-- Name: employee employee_email_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.employee
    ADD CONSTRAINT employee_email_unique UNIQUE (email);


--
-- Name: employee employee_phone_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.employee
    ADD CONSTRAINT employee_phone_unique UNIQUE (phone);


--
-- Name: employee employee_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.employee
    ADD CONSTRAINT employee_pkey PRIMARY KEY (employee_id);


--
-- Name: employment_contract employment_contract_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.employment_contract
    ADD CONSTRAINT employment_contract_pkey PRIMARY KEY (contract_id);


--
-- Name: operating_expense_log operating_expense_log_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.operating_expense_log
    ADD CONSTRAINT operating_expense_log_pkey PRIMARY KEY (log_id);


--
-- Name: order_detail order_detail_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_detail
    ADD CONSTRAINT order_detail_pkey PRIMARY KEY (order_detail_id);


--
-- Name: product_category product_category_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_category
    ADD CONSTRAINT product_category_pkey PRIMARY KEY (product_category_id);


--
-- Name: product product_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product
    ADD CONSTRAINT product_pkey PRIMARY KEY (product_id);


--
-- Name: salary_bonus_log salary_bonus_log_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salary_bonus_log
    ADD CONSTRAINT salary_bonus_log_pkey PRIMARY KEY (log_id);


--
-- Name: warehouse_category warehouse_category_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouse_category
    ADD CONSTRAINT warehouse_category_pkey PRIMARY KEY (warehouse_category_id);


--
-- Name: warehouse warehouse_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouse
    ADD CONSTRAINT warehouse_pkey PRIMARY KEY (warehouse_id);


--
-- Name: work_status_log work_status_log_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.work_status_log
    ADD CONSTRAINT work_status_log_pkey PRIMARY KEY (log_id);


--
-- Name: employment_contract trg_activate_employee_on_contract; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_activate_employee_on_contract AFTER INSERT ON public.employment_contract FOR EACH ROW EXECUTE FUNCTION public.activate_employee_on_contract();


--
-- Name: customer_order trg_auto_refund_when_canceled; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_auto_refund_when_canceled BEFORE UPDATE ON public.customer_order FOR EACH ROW EXECUTE FUNCTION public.auto_refund_when_canceled();


--
-- Name: customer_order trg_block_invalid_refund; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_block_invalid_refund BEFORE UPDATE ON public.customer_order FOR EACH ROW EXECUTE FUNCTION public.block_invalid_refund();


--
-- Name: customer_order trg_block_update_when_closed; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_block_update_when_closed BEFORE UPDATE ON public.customer_order FOR EACH ROW EXECUTE FUNCTION public.trg_block_update_when_closed();


--
-- Name: batch trg_check_batch_warehouse_category; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_check_batch_warehouse_category BEFORE INSERT ON public.batch FOR EACH ROW EXECUTE FUNCTION public.check_batch_warehouse_category();


--
-- Name: batch trg_check_expiry_date_not_null; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_check_expiry_date_not_null BEFORE INSERT OR UPDATE ON public.batch FOR EACH ROW EXECUTE FUNCTION public.check_expiry_date_not_null();


--
-- Name: customer_order trg_check_order_status_order; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_check_order_status_order BEFORE UPDATE ON public.customer_order FOR EACH ROW EXECUTE FUNCTION public.trg_check_order_status_order();


--
-- Name: customer trg_check_rank_valid; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_check_rank_valid BEFORE UPDATE OF rank ON public.customer FOR EACH ROW EXECUTE FUNCTION public.check_rank_valid();


--
-- Name: employee trg_enforce_contract_on_status_change; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_enforce_contract_on_status_change BEFORE UPDATE OF employment_status ON public.employee FOR EACH ROW EXECUTE FUNCTION public.enforce_contract_on_status_change();


--
-- Name: employee trg_enforce_pending_on_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_enforce_pending_on_insert BEFORE INSERT ON public.employee FOR EACH ROW EXECUTE FUNCTION public.enforce_pending_on_insert();


--
-- Name: employee trg_log_employee_status_change; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_log_employee_status_change AFTER UPDATE OF employment_status ON public.employee FOR EACH ROW EXECUTE FUNCTION public.log_employee_status_change();


--
-- Name: employee trg_log_employee_status_on_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_log_employee_status_on_insert AFTER INSERT ON public.employee FOR EACH ROW EXECUTE FUNCTION public.log_employee_status_on_insert();


--
-- Name: customer_order trg_payment_status_flow; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_payment_status_flow BEFORE UPDATE ON public.customer_order FOR EACH ROW EXECUTE FUNCTION public.trg_validate_payment_status();


--
-- Name: employment_contract trg_reactivate_employee_on_contract_update; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_reactivate_employee_on_contract_update AFTER UPDATE ON public.employment_contract FOR EACH ROW EXECUTE FUNCTION public.reactivate_employee_on_contract_update();


--
-- Name: customer_order trg_restore_batch_quantity_on_cancel; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_restore_batch_quantity_on_cancel AFTER UPDATE OF order_status ON public.customer_order FOR EACH ROW EXECUTE FUNCTION public.restore_batch_quantity_on_cancel();


--
-- Name: customer_order trg_set_delivered_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_set_delivered_at BEFORE UPDATE ON public.customer_order FOR EACH ROW EXECUTE FUNCTION public.set_delivered_at_when_completed();


--
-- Name: batch trg_set_remaining_quantity_on_batch_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_set_remaining_quantity_on_batch_insert BEFORE INSERT ON public.batch FOR EACH ROW EXECUTE FUNCTION public.set_remaining_quantity_on_batch_insert();


--
-- Name: customer_order trg_update_customer_last_active; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_customer_last_active AFTER INSERT ON public.customer_order FOR EACH ROW EXECUTE FUNCTION public.update_customer_last_active();


--
-- Name: customer_order trg_update_member_points; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_member_points AFTER UPDATE ON public.customer_order FOR EACH ROW EXECUTE FUNCTION public.update_member_points_after_payment();


--
-- Name: customer trg_update_rank_when_points_change; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_update_rank_when_points_change BEFORE UPDATE OF member_points ON public.customer FOR EACH ROW EXECUTE FUNCTION public.update_rank_when_points_change();


--
-- Name: batch batch_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.batch
    ADD CONSTRAINT batch_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.product(product_id);


--
-- Name: batch batch_warehouse_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.batch
    ADD CONSTRAINT batch_warehouse_id_fkey FOREIGN KEY (warehouse_id) REFERENCES public.warehouse(warehouse_id);


--
-- Name: customer_order customer_order_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer_order
    ADD CONSTRAINT customer_order_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customer(customer_id);


--
-- Name: customer_order customer_order_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer_order
    ADD CONSTRAINT customer_order_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employee(employee_id);


--
-- Name: employment_contract employment_contract_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.employment_contract
    ADD CONSTRAINT employment_contract_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employee(employee_id);


--
-- Name: order_detail order_detail_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_detail
    ADD CONSTRAINT order_detail_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.batch(batch_id);


--
-- Name: order_detail order_detail_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_detail
    ADD CONSTRAINT order_detail_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.customer_order(order_id);


--
-- Name: order_detail order_detail_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.order_detail
    ADD CONSTRAINT order_detail_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.product(product_id);


--
-- Name: product_category product_category_warehouse_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product_category
    ADD CONSTRAINT product_category_warehouse_category_id_fkey FOREIGN KEY (warehouse_category_id) REFERENCES public.warehouse_category(warehouse_category_id);


--
-- Name: product product_product_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.product
    ADD CONSTRAINT product_product_category_id_fkey FOREIGN KEY (product_category_id) REFERENCES public.product_category(product_category_id);


--
-- Name: salary_bonus_log salary_bonus_log_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.salary_bonus_log
    ADD CONSTRAINT salary_bonus_log_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employee(employee_id);


--
-- Name: warehouse warehouse_warehouse_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouse
    ADD CONSTRAINT warehouse_warehouse_category_id_fkey FOREIGN KEY (warehouse_category_id) REFERENCES public.warehouse_category(warehouse_category_id) ON DELETE SET NULL;


--
-- Name: work_status_log work_status_log_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.work_status_log
    ADD CONSTRAINT work_status_log_employee_id_fkey FOREIGN KEY (employee_id) REFERENCES public.employee(employee_id);


--
-- PostgreSQL database dump complete
--

