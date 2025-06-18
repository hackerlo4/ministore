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
    shipping_address character varying(256),
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
    CONSTRAINT chk_effective_date_after_contract_date CHECK (((effective_date IS NULL) OR (contract_date IS NULL) OR (effective_date >= contract_date))),
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
1557	30	2024-12-26	\N	7504340.93	55	\N	4	55
1558	14	2024-05-08	\N	5806064.28	396	\N	4	396
1559	14	2024-04-15	\N	5850326.63	284	\N	4	284
1560	30	2024-08-19	\N	4809958.77	29	\N	4	29
38	4	2024-06-01	2024-11-30	190000.00	5	\N	1	5
49	4	2024-07-01	2026-04-30	192000.00	7	\N	1	7
39	5	2024-06-01	2024-07-10	14000.00	50	\N	2	50
50	5	2024-07-05	2026-05-10	14200.00	30	\N	2	30
57	3	2024-01-15	2025-07-11	4628245.37	544	\N	1	544
58	3	2024-03-17	2026-12-20	2407039.58	399	\N	1	399
59	2	2024-10-19	2025-07-08	3313952.18	564	\N	1	564
60	4	2024-09-30	2026-02-18	7764824.10	624	\N	1	624
61	1	2024-02-24	2025-09-24	4607640.78	154	\N	1	154
62	21	2024-12-16	2026-01-05	8863534.02	229	\N	1	229
63	2	2024-11-25	2026-11-17	5507838.77	590	\N	1	590
64	21	2024-12-14	2026-03-04	2732704.94	951	\N	1	951
65	2	2024-12-11	2026-05-14	2606392.75	280	\N	1	280
66	2	2024-06-04	2026-01-19	8858631.71	260	\N	1	260
67	4	2024-05-09	2025-06-22	2965348.60	162	\N	1	162
68	2	2024-05-18	2025-08-21	616608.21	987	\N	1	987
69	2	2024-08-17	2025-10-22	1413716.38	826	\N	1	826
70	39	2024-04-29	2025-11-25	449553.94	814	\N	1	814
71	1	2024-05-20	2026-12-12	9465202.80	391	\N	1	391
72	1	2024-06-15	2026-05-31	5984683.00	46	\N	1	46
73	2	2024-12-11	2026-03-06	9675102.91	787	\N	1	787
74	1	2024-09-06	2026-11-04	5351692.11	163	\N	1	163
75	39	2024-03-15	2025-11-05	1267460.61	836	\N	1	836
76	3	2024-10-03	2026-06-15	1642612.98	116	\N	1	116
77	39	2024-07-18	2025-06-19	3031140.81	96	\N	1	96
78	39	2024-01-10	2025-11-20	4538488.91	923	\N	1	923
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
79	3	2024-11-14	2026-04-02	8368960.79	180	\N	1	180
80	2	2024-07-21	2026-09-26	5312395.91	233	\N	1	233
81	38	2024-08-18	2026-07-12	1123848.53	535	\N	1	535
82	21	2024-02-02	2026-07-21	2319962.85	113	\N	1	113
83	1	2024-01-21	2026-08-01	1701877.74	868	\N	1	868
84	39	2024-06-05	2025-11-12	3171737.11	638	\N	1	638
85	39	2024-07-02	2026-02-04	8720710.14	148	\N	1	148
86	39	2024-12-29	2026-01-27	8381289.08	319	\N	1	319
87	2	2024-05-24	2026-06-19	1380471.67	244	\N	1	244
88	2	2024-08-01	2026-04-06	880447.63	592	\N	1	592
89	21	2024-08-26	2026-05-16	5950523.65	588	\N	1	588
90	21	2024-01-24	2025-06-21	9693776.49	315	\N	1	315
91	2	2024-05-02	2026-02-06	4683484.13	778	\N	1	778
92	2	2024-12-26	2026-02-06	2438998.95	86	\N	1	86
93	39	2024-02-03	2025-12-09	4242772.14	809	\N	1	809
94	4	2024-06-10	2026-06-30	9287057.96	248	\N	1	248
95	3	2024-12-01	2025-07-27	9951715.92	717	\N	1	717
96	2	2024-02-07	2025-07-28	3548865.01	247	\N	1	247
97	21	2024-04-16	2026-05-17	6592091.81	357	\N	1	357
98	1	2024-05-11	2025-11-04	1408967.47	854	\N	1	854
1561	30	2024-11-12	\N	2599510.58	951	\N	4	951
1562	16	2024-06-18	\N	9900646.84	257	\N	4	257
1563	30	2024-05-22	\N	6704725.27	962	\N	4	962
1564	33	2024-08-19	\N	5903905.97	458	\N	4	458
35	1	2024-06-01	2024-12-01	75000.00	20	\N	1	0
46	1	2024-06-10	2026-01-10	76000.00	25	\N	1	5
99	38	2024-10-27	2025-10-03	5908742.83	628	\N	1	628
100	38	2024-12-05	2025-06-26	4001180.77	344	\N	1	344
101	1	2024-04-02	2025-07-12	6824676.04	519	\N	1	519
102	39	2024-02-23	2026-10-09	5091045.64	64	\N	1	64
103	1	2024-10-25	2026-07-06	3725022.27	970	\N	1	970
104	21	2024-04-07	2025-08-11	4747074.85	993	\N	1	993
105	3	2024-03-15	2026-06-26	346153.41	377	\N	1	377
106	1	2024-10-08	2025-12-06	2008614.11	610	\N	1	610
107	4	2024-09-01	2026-10-25	1113534.72	353	\N	1	353
108	1	2024-10-07	2026-01-19	2223069.87	714	\N	1	714
109	21	2024-11-11	2026-11-07	1969706.79	416	\N	1	416
110	38	2024-12-31	2026-03-03	7808602.31	427	\N	1	427
111	21	2024-07-29	2025-07-29	7716076.59	822	\N	1	822
112	2	2024-04-29	2026-03-27	5935346.50	245	\N	1	245
113	2	2024-03-30	2026-12-23	7747055.36	199	\N	1	199
114	3	2024-12-16	2025-11-11	8466696.55	986	\N	1	986
115	38	2024-12-07	2026-10-19	1709192.52	439	\N	1	439
116	1	2024-08-17	2025-10-04	3477370.26	93	\N	1	93
117	38	2024-12-17	2025-11-03	3482911.86	844	\N	1	844
118	38	2024-12-15	2026-08-23	5163941.34	834	\N	1	834
119	3	2024-05-30	2026-09-12	3605983.74	353	\N	1	353
120	3	2024-12-03	2026-08-05	3155927.50	182	\N	1	182
121	2	2024-01-26	2025-10-23	3280578.57	254	\N	1	254
122	4	2024-11-10	2026-10-17	4449041.15	943	\N	1	943
123	38	2024-09-05	2026-03-01	4379267.82	295	\N	1	295
124	38	2024-11-21	2026-02-24	8640671.22	207	\N	1	207
125	4	2024-04-28	2025-06-12	9238959.03	652	\N	1	652
126	1	2024-01-10	2026-02-17	851293.89	29	\N	1	29
127	2	2024-10-15	2026-06-22	5747182.66	666	\N	1	666
128	21	2024-04-29	2025-07-28	6099947.97	355	\N	1	355
129	21	2024-10-05	2025-08-16	7944499.06	406	\N	1	406
130	39	2024-08-07	2026-10-09	4372762.17	175	\N	1	175
131	21	2024-02-01	2026-03-02	7395923.15	527	\N	1	527
132	39	2024-01-17	2026-08-20	4560886.48	165	\N	1	165
133	2	2024-03-13	2025-08-13	5499028.32	770	\N	1	770
134	21	2024-01-12	2026-12-31	4086378.13	29	\N	1	29
135	3	2024-08-19	2026-02-05	8312125.32	337	\N	1	337
136	2	2024-06-15	2025-07-02	7798285.37	822	\N	1	822
137	38	2024-08-12	2026-05-14	2244124.24	882	\N	1	882
138	4	2024-12-25	2026-03-09	9959454.03	616	\N	1	616
139	39	2024-10-08	2026-08-01	9328119.01	401	\N	1	401
140	21	2024-12-05	2026-07-05	9619212.05	28	\N	1	28
141	38	2024-07-11	2026-08-02	9666396.14	304	\N	1	304
142	3	2024-10-14	2026-12-05	6537654.05	577	\N	1	577
143	3	2024-11-02	2026-08-03	7237445.71	34	\N	1	34
144	38	2024-06-29	2026-11-19	1687781.47	721	\N	1	721
145	39	2024-11-04	2025-07-15	2341133.34	339	\N	1	339
146	3	2024-05-03	2026-01-05	8128869.61	639	\N	1	639
147	1	2024-05-01	2025-06-22	9577893.50	814	\N	1	814
148	3	2024-05-16	2026-02-17	2120527.27	795	\N	1	795
149	39	2024-03-02	2025-08-08	7317094.02	906	\N	1	906
150	38	2024-05-28	2025-06-15	924530.29	192	\N	1	192
151	2	2024-07-13	2025-11-08	2788017.07	389	\N	1	389
152	21	2024-10-02	2026-02-16	1890101.47	585	\N	1	585
153	39	2024-03-03	2026-02-24	909626.71	881	\N	1	881
154	4	2024-01-24	2025-11-19	1228725.48	599	\N	1	599
155	1	2024-10-07	2025-11-26	6264797.66	802	\N	1	802
156	39	2024-10-04	2025-06-11	832980.65	698	\N	1	698
157	1	2024-03-20	2026-10-11	757409.00	308	\N	1	308
158	2	2024-01-19	2026-09-05	5753052.81	460	\N	1	460
159	3	2024-03-14	2026-06-15	4977766.76	317	\N	1	317
160	4	2024-09-03	2025-10-06	2120898.02	549	\N	1	549
161	21	2024-05-20	2026-10-02	4017785.73	309	\N	1	309
162	4	2024-06-21	2025-06-30	4879012.57	97	\N	1	97
163	21	2024-11-11	2026-09-09	92201.97	518	\N	1	518
164	1	2024-04-24	2026-01-11	6311361.21	683	\N	1	683
165	1	2024-09-17	2025-07-30	266735.53	961	\N	1	961
166	2	2024-08-27	2025-06-25	6438325.20	38	\N	1	38
167	38	2024-11-26	2026-04-03	5358883.43	683	\N	1	683
168	2	2024-06-05	2026-12-10	7502417.84	760	\N	1	760
169	21	2024-04-13	2026-08-17	8299855.16	63	\N	1	63
170	1	2024-06-30	2026-10-09	9619374.46	369	\N	1	369
171	39	2024-04-16	2026-06-26	4480971.35	859	\N	1	859
172	39	2024-06-04	2025-09-02	3942937.87	542	\N	1	542
173	2	2024-09-25	2026-09-03	3698426.85	284	\N	1	284
174	1	2024-04-18	2025-07-08	591938.77	136	\N	1	136
175	2	2024-09-15	2026-01-14	9843407.48	940	\N	1	940
176	38	2024-09-19	2026-07-13	2465429.18	888	\N	1	888
177	1	2024-01-06	2026-05-30	3920470.15	19	\N	1	19
178	39	2024-12-13	2026-09-24	1635045.89	747	\N	1	747
179	4	2024-07-07	2026-05-04	3548586.78	711	\N	1	711
180	39	2024-11-21	2026-05-11	9323879.31	311	\N	1	311
181	2	2024-11-05	2026-07-10	1489952.90	43	\N	1	43
182	4	2024-10-04	2026-09-04	6320925.37	689	\N	1	689
183	1	2024-02-17	2025-08-20	9867073.59	372	\N	1	372
184	1	2024-08-28	2025-09-22	7836856.76	521	\N	1	521
185	3	2024-10-28	2026-09-22	2592046.50	309	\N	1	309
186	38	2024-07-27	2025-06-15	1016540.17	344	\N	1	344
187	39	2024-06-30	2026-10-26	4930777.82	718	\N	1	718
188	2	2024-12-21	2026-12-20	573458.58	494	\N	1	494
189	2	2024-08-25	2026-04-21	4627803.94	228	\N	1	228
190	3	2024-05-21	2026-05-07	2303060.26	958	\N	1	958
191	38	2024-06-07	2025-12-27	7772465.35	416	\N	1	416
192	4	2024-02-22	2026-10-05	9597308.11	48	\N	1	48
193	2	2024-06-14	2026-12-05	2160683.25	560	\N	1	560
194	2	2024-06-19	2026-02-02	6393252.82	351	\N	1	351
195	39	2024-03-05	2026-09-22	4842056.42	806	\N	1	806
196	39	2024-08-11	2025-08-21	6000284.21	849	\N	1	849
197	4	2024-10-08	2026-04-27	7872425.99	494	\N	1	494
198	1	2024-06-20	2026-03-07	3653509.65	545	\N	1	545
199	4	2024-09-03	2026-09-15	7100227.31	440	\N	1	440
200	39	2024-02-14	2026-07-07	7401721.54	168	\N	1	168
201	1	2024-11-23	2025-12-19	8081987.82	238	\N	1	238
202	38	2024-03-10	2025-06-22	6037250.39	971	\N	1	971
203	3	2024-05-01	2025-07-05	451129.98	985	\N	1	985
204	2	2024-05-22	2026-10-16	1834364.12	552	\N	1	552
205	21	2024-02-08	2026-10-13	9172869.98	179	\N	1	179
206	4	2024-04-05	2025-11-11	4350665.82	19	\N	1	19
207	4	2024-03-24	2026-08-14	1971105.40	180	\N	1	180
208	1	2024-11-10	2025-11-21	2105811.29	26	\N	1	26
209	2	2024-10-30	2026-10-12	9380712.13	278	\N	1	278
210	38	2024-01-25	2025-07-28	6778030.55	2	\N	1	2
211	4	2024-02-25	2026-03-19	1988328.17	291	\N	1	291
212	21	2024-02-04	2026-11-13	109677.82	546	\N	1	546
213	39	2024-01-29	2026-07-07	3828291.86	926	\N	1	926
214	1	2024-06-26	2026-12-20	7032762.11	998	\N	1	998
215	4	2024-08-26	2025-06-14	1946405.63	525	\N	1	525
216	39	2024-03-25	2026-09-15	6850477.35	658	\N	1	658
217	39	2024-10-09	2026-07-13	9788804.85	360	\N	1	360
218	39	2024-12-01	2025-07-30	9393788.55	527	\N	1	527
219	3	2024-10-15	2026-11-09	7264483.40	881	\N	1	881
220	4	2024-05-25	2026-03-18	9328716.38	643	\N	1	643
221	21	2024-11-28	2026-05-13	4908752.54	877	\N	1	877
222	39	2024-04-18	2025-12-13	5873090.30	922	\N	1	922
223	21	2024-09-09	2026-11-14	6897365.95	201	\N	1	201
224	38	2024-09-21	2025-07-28	1358132.14	546	\N	1	546
225	38	2024-09-23	2026-04-11	2006738.98	782	\N	1	782
226	38	2024-08-04	2026-09-18	9402716.67	344	\N	1	344
227	38	2024-01-09	2026-03-04	8532393.20	593	\N	1	593
228	38	2024-08-06	2026-06-03	1540006.65	775	\N	1	775
229	21	2024-09-20	2026-10-17	3067580.08	303	\N	1	303
230	38	2024-03-29	2026-04-14	1632167.13	816	\N	1	816
231	4	2024-06-02	2026-12-14	6646300.07	642	\N	1	642
232	39	2024-06-08	2025-07-31	7516679.09	144	\N	1	144
233	4	2024-02-25	2025-12-15	8454985.74	962	\N	1	962
234	39	2024-07-14	2026-05-31	3198997.59	742	\N	1	742
235	3	2024-10-18	2026-12-08	3867484.68	839	\N	1	839
236	38	2024-09-05	2026-04-11	8913718.43	674	\N	1	674
237	21	2024-03-02	2025-07-09	9583353.52	743	\N	1	743
238	2	2024-01-23	2026-05-18	5425830.46	994	\N	1	994
239	3	2024-12-07	2026-12-10	4250997.05	415	\N	1	415
240	2	2024-02-16	2025-12-09	9729370.30	648	\N	1	648
241	2	2024-09-23	2026-05-06	3126791.53	356	\N	1	356
242	39	2024-01-07	2025-11-11	9489929.28	29	\N	1	29
243	39	2024-03-14	2025-12-08	8338197.52	698	\N	1	698
244	2	2024-02-23	2025-11-15	7968966.47	290	\N	1	290
245	38	2024-07-12	2026-02-27	6410537.25	247	\N	1	247
246	21	2024-07-28	2026-12-09	8083430.43	208	\N	1	208
247	38	2024-12-30	2026-04-10	8101291.88	356	\N	1	356
248	2	2024-11-05	2026-09-14	6299050.90	230	\N	1	230
249	39	2024-03-26	2026-05-01	3417296.50	699	\N	1	699
250	39	2024-02-22	2026-05-14	5786071.42	923	\N	1	923
251	3	2024-05-24	2025-12-08	2593093.85	384	\N	1	384
252	21	2024-05-29	2025-12-02	6378075.26	602	\N	1	602
253	3	2024-09-05	2025-12-07	8149381.40	850	\N	1	850
254	3	2024-03-25	2025-10-20	1858026.21	716	\N	1	716
255	1	2024-08-15	2026-03-25	2861519.95	740	\N	1	740
256	38	2024-09-28	2026-05-23	9325856.76	7	\N	1	7
257	2	2024-02-10	2025-10-18	5842028.33	890	\N	1	890
258	3	2024-10-12	2025-07-13	2048893.58	769	\N	1	769
259	3	2024-12-01	2026-12-02	1365856.92	15	\N	1	15
260	1	2024-01-21	2026-02-28	5767983.59	402	\N	1	402
261	21	2024-06-10	2026-09-28	2271977.85	126	\N	1	126
262	2	2024-02-26	2026-12-13	2680446.76	721	\N	1	721
263	2	2024-03-15	2026-12-22	7403937.97	22	\N	1	22
264	39	2024-12-31	2026-02-24	3609488.49	91	\N	1	91
265	21	2024-02-29	2026-02-23	251843.00	884	\N	1	884
266	39	2024-06-23	2026-02-18	7078505.09	888	\N	1	888
267	1	2024-04-23	2025-06-30	1839631.90	194	\N	1	194
268	1	2024-03-23	2025-08-22	1091126.77	340	\N	1	340
269	21	2024-05-19	2026-04-01	1845409.00	930	\N	1	930
270	39	2024-08-13	2025-08-20	6334824.78	584	\N	1	584
271	39	2024-10-14	2026-05-27	6684030.14	602	\N	1	602
272	4	2024-09-15	2026-02-11	1777607.58	77	\N	1	77
273	39	2024-07-29	2026-10-01	5144748.70	522	\N	1	522
274	21	2024-10-10	2026-08-02	4435417.72	980	\N	1	980
275	3	2024-03-11	2026-02-12	1124628.48	758	\N	1	758
276	1	2024-06-27	2025-11-15	3794817.34	385	\N	1	385
277	38	2024-07-28	2026-10-27	4453542.02	266	\N	1	266
278	3	2024-09-08	2026-12-31	8980199.29	4	\N	1	4
279	21	2024-09-14	2026-08-17	3601813.50	287	\N	1	287
280	3	2024-05-24	2026-07-11	5021348.54	691	\N	1	691
281	39	2024-04-07	2025-11-27	6134620.63	243	\N	1	243
282	4	2024-10-18	2025-12-10	2505844.15	39	\N	1	39
283	38	2024-09-24	2025-11-19	3090545.65	170	\N	1	170
284	2	2024-05-07	2025-08-02	9634879.71	204	\N	1	204
285	39	2024-12-15	2025-06-29	3673241.11	237	\N	1	237
286	2	2024-04-09	2026-04-01	3146847.31	113	\N	1	113
287	39	2024-06-21	2026-05-15	8739695.78	974	\N	1	974
288	3	2024-03-28	2026-04-03	3521233.85	110	\N	1	110
289	38	2024-07-24	2025-09-03	3600050.39	761	\N	1	761
290	2	2024-03-14	2026-06-06	5584912.85	85	\N	1	85
291	2	2024-05-14	2026-01-31	8702420.78	352	\N	1	352
292	4	2024-02-26	2026-09-28	3803598.90	762	\N	1	762
293	39	2024-05-05	2026-10-09	8097884.99	987	\N	1	987
294	21	2024-05-14	2026-06-11	7570430.61	101	\N	1	101
295	4	2024-03-05	2025-11-08	6379768.00	165	\N	1	165
296	21	2024-07-22	2025-08-25	8945997.72	351	\N	1	351
297	4	2024-11-13	2026-02-23	6191591.66	749	\N	1	749
298	39	2024-07-05	2026-01-12	7065527.92	131	\N	1	131
299	21	2024-03-19	2025-11-23	2337369.32	705	\N	1	705
300	39	2024-03-30	2026-03-09	9433291.25	954	\N	1	954
301	39	2024-03-26	2026-05-22	5357939.87	69	\N	1	69
302	4	2024-03-13	2026-04-11	4834577.12	948	\N	1	948
303	4	2024-04-06	2026-11-26	7787927.96	420	\N	1	420
304	38	2024-02-13	2026-02-18	8943871.29	166	\N	1	166
305	38	2024-09-07	2025-09-10	7303631.15	737	\N	1	737
306	4	2024-08-23	2025-11-18	9899100.19	653	\N	1	653
307	21	2024-02-24	2025-12-24	5571044.14	245	\N	1	245
308	38	2024-01-20	2026-12-13	4595209.55	418	\N	1	418
309	3	2024-05-31	2025-08-20	4908179.67	933	\N	1	933
310	2	2024-11-09	2025-11-12	9511745.78	862	\N	1	862
311	3	2024-03-15	2025-08-17	7670288.36	612	\N	1	612
312	4	2024-09-27	2026-11-21	7998746.51	402	\N	1	402
313	38	2024-01-20	2026-02-15	1670707.23	880	\N	1	880
314	1	2024-06-28	2026-01-25	4055609.30	921	\N	1	921
315	4	2024-12-01	2025-06-11	1032921.03	44	\N	1	44
316	3	2024-03-17	2026-03-21	9629595.60	769	\N	1	769
317	3	2024-09-07	2025-06-11	7227951.88	710	\N	1	710
318	1	2024-03-27	2025-06-07	9344377.87	798	\N	1	798
319	1	2024-08-01	2026-04-30	7968803.77	641	\N	1	641
320	1	2024-07-22	2025-09-05	2300589.49	286	\N	1	286
321	21	2024-04-18	2026-10-16	3686896.22	331	\N	1	331
322	21	2024-07-20	2025-06-30	4911892.55	431	\N	1	431
323	39	2024-02-27	2025-07-10	9879957.65	111	\N	1	111
324	21	2024-03-03	2025-06-12	138244.57	382	\N	1	382
325	38	2024-03-22	2026-09-23	8639155.52	933	\N	1	933
326	39	2024-10-20	2026-11-14	2464874.29	68	\N	1	68
327	38	2024-10-26	2025-11-28	2082711.21	729	\N	1	729
328	38	2024-01-26	2026-01-14	986331.66	228	\N	1	228
329	2	2024-03-18	2025-12-18	6381714.58	572	\N	1	572
330	21	2024-05-09	2025-12-19	4299534.37	482	\N	1	482
331	21	2024-04-18	2026-08-06	9038075.03	708	\N	1	708
332	4	2024-12-28	2025-11-13	5053080.34	655	\N	1	655
333	38	2024-07-20	2025-07-24	3767453.67	422	\N	1	422
334	1	2024-03-10	2026-02-13	9094326.27	391	\N	1	391
335	38	2024-07-02	2026-08-01	6808197.39	191	\N	1	191
336	2	2024-07-10	2026-10-19	9931238.52	640	\N	1	640
337	4	2024-04-14	2025-10-22	3529376.36	247	\N	1	247
338	21	2024-05-12	2025-12-07	155077.89	825	\N	1	825
339	39	2024-10-11	2026-10-23	8433160.13	567	\N	1	567
340	3	2024-08-13	2026-08-06	4626977.51	579	\N	1	579
341	2	2024-12-02	2025-07-07	5402902.76	463	\N	1	463
342	21	2024-02-25	2026-07-27	902411.01	885	\N	1	885
343	1	2024-05-15	2026-12-02	2473445.36	939	\N	1	939
344	2	2024-04-07	2025-10-11	3000413.91	123	\N	1	123
345	39	2024-12-14	2026-09-10	4313959.98	376	\N	1	376
346	4	2024-01-06	2026-05-03	4981442.40	373	\N	1	373
347	1	2024-12-17	2025-10-05	5885905.27	106	\N	1	106
348	1	2024-03-07	2026-05-25	1265718.79	600	\N	1	600
349	38	2024-04-13	2026-05-07	8351693.35	386	\N	1	386
350	3	2024-08-17	2026-12-22	469339.65	390	\N	1	390
351	4	2024-03-27	2026-01-10	6992454.03	258	\N	1	258
352	38	2024-06-29	2026-04-14	2665035.29	43	\N	1	43
353	39	2024-06-06	2025-07-25	2336238.44	647	\N	1	647
354	21	2024-12-04	2025-08-27	2220716.34	668	\N	1	668
355	38	2024-09-02	2026-09-08	8321124.02	453	\N	1	453
356	3	2024-02-02	2026-01-20	314894.66	144	\N	1	144
357	4	2024-04-14	2026-10-02	7128556.42	869	\N	1	869
358	3	2024-09-11	2026-05-04	9693114.14	175	\N	1	175
359	4	2024-02-12	2026-12-14	4995634.71	306	\N	1	306
360	21	2024-08-12	2026-08-01	8656865.02	708	\N	1	708
361	3	2024-05-01	2026-09-11	9473208.96	426	\N	1	426
362	4	2024-08-08	2025-09-06	8768726.90	434	\N	1	434
363	38	2024-02-08	2026-01-02	2883210.65	173	\N	1	173
364	38	2024-06-06	2026-08-09	6045839.14	841	\N	1	841
365	39	2024-09-18	2025-09-29	1186470.74	361	\N	1	361
366	39	2024-06-23	2026-03-16	8203781.22	368	\N	1	368
367	2	2024-04-04	2026-10-05	5496791.92	684	\N	1	684
368	4	2024-11-20	2026-12-21	8906762.84	692	\N	1	692
369	2	2024-12-02	2026-01-03	1575617.76	494	\N	1	494
370	1	2024-03-04	2026-01-01	3014620.87	875	\N	1	875
371	4	2024-07-30	2026-09-17	9029261.82	7	\N	1	7
372	21	2024-04-08	2026-12-16	8487652.49	685	\N	1	685
373	3	2024-06-28	2026-09-27	9807388.31	239	\N	1	239
374	1	2024-04-16	2025-12-03	6551041.48	932	\N	1	932
375	38	2024-01-25	2026-08-14	4199775.86	66	\N	1	66
376	3	2024-07-19	2026-01-31	9257754.37	562	\N	1	562
377	3	2024-11-18	2025-12-17	1977432.25	306	\N	1	306
378	39	2024-08-16	2025-08-02	5269996.78	275	\N	1	275
379	2	2024-03-03	2026-04-14	382889.00	289	\N	1	289
380	39	2024-04-18	2026-03-27	996287.16	498	\N	1	498
381	3	2024-06-09	2026-08-15	209291.03	401	\N	1	401
382	2	2024-11-25	2025-10-01	3538236.36	166	\N	1	166
383	39	2024-09-10	2026-02-01	1384969.89	988	\N	1	988
384	21	2024-10-01	2026-05-23	8288217.66	290	\N	1	290
385	1	2024-01-28	2025-06-09	7786949.39	693	\N	1	693
386	1	2024-03-05	2025-12-13	2364466.23	969	\N	1	969
387	4	2024-02-06	2026-08-11	5198330.44	602	\N	1	602
388	4	2024-04-05	2025-07-18	3891893.87	176	\N	1	176
389	4	2024-01-19	2026-04-21	9354498.21	449	\N	1	449
390	21	2024-12-05	2026-03-11	8364945.31	883	\N	1	883
391	1	2024-05-19	2025-08-09	3180386.90	822	\N	1	822
392	4	2024-12-11	2026-11-16	1138319.07	766	\N	1	766
393	39	2024-11-08	2026-04-08	2650007.86	227	\N	1	227
394	38	2024-06-29	2026-08-27	9619004.59	281	\N	1	281
395	3	2024-09-18	2026-03-27	8215122.92	730	\N	1	730
396	2	2024-09-03	2026-05-21	2675247.17	657	\N	1	657
397	3	2024-07-02	2025-10-15	2426815.07	494	\N	1	494
398	38	2024-07-02	2026-02-16	2664527.32	678	\N	1	678
399	21	2024-10-04	2026-03-17	758402.82	235	\N	1	235
400	38	2024-12-26	2025-10-27	6956231.39	460	\N	1	460
401	21	2024-05-15	2025-08-03	3413222.14	665	\N	1	665
402	38	2024-11-10	2026-01-20	1586312.96	272	\N	1	272
403	1	2024-03-09	2025-11-07	9363071.53	266	\N	1	266
404	39	2024-05-02	2026-02-09	8624654.26	612	\N	1	612
405	1	2024-11-23	2026-07-01	7839524.49	274	\N	1	274
406	39	2024-10-03	2026-12-23	4752826.27	313	\N	1	313
407	2	2024-10-29	2026-05-16	2514338.67	245	\N	1	245
408	21	2024-04-25	2025-10-31	9104144.35	352	\N	1	352
409	1	2024-07-18	2025-12-11	140580.69	575	\N	1	575
410	38	2024-08-17	2025-10-23	7807237.62	518	\N	1	518
411	4	2024-03-15	2025-12-18	7594988.34	42	\N	1	42
412	39	2024-12-26	2026-11-05	8440757.80	985	\N	1	985
413	2	2024-01-20	2026-07-20	5969896.81	821	\N	1	821
414	38	2024-04-12	2025-12-29	7285679.00	267	\N	1	267
415	2	2024-03-29	2026-07-03	2447846.62	613	\N	1	613
416	39	2024-12-30	2026-09-04	4656471.30	315	\N	1	315
417	38	2024-08-16	2026-03-04	4274886.43	854	\N	1	854
418	21	2024-12-31	2025-07-07	5543589.97	297	\N	1	297
419	39	2024-09-18	2026-11-10	5837444.32	860	\N	1	860
420	2	2024-03-09	2026-03-24	9876380.70	852	\N	1	852
421	4	2024-09-23	2026-05-10	7988779.98	607	\N	1	607
422	4	2024-02-28	2026-06-09	4641437.99	869	\N	1	869
423	39	2024-06-13	2026-01-01	2118432.05	926	\N	1	926
424	39	2024-02-20	2026-05-01	45730.50	270	\N	1	270
425	1	2024-03-13	2026-01-05	8674588.63	927	\N	1	927
426	2	2024-03-27	2026-07-01	6054434.02	83	\N	1	83
427	2	2024-04-16	2026-09-10	7206463.20	166	\N	1	166
428	21	2024-07-09	2026-09-02	568113.53	416	\N	1	416
429	39	2024-08-03	2026-01-09	1167942.78	385	\N	1	385
430	2	2024-01-09	2026-02-05	2150609.34	425	\N	1	425
431	38	2024-11-07	2025-12-26	5029547.92	743	\N	1	743
432	4	2024-08-14	2026-11-02	3096025.47	228	\N	1	228
433	3	2024-07-19	2025-11-08	9709619.01	263	\N	1	263
434	38	2024-02-28	2025-08-21	9774891.74	125	\N	1	125
435	21	2024-02-04	2025-12-04	9483763.24	214	\N	1	214
436	4	2024-12-11	2026-11-16	9602692.22	270	\N	1	270
437	3	2024-08-07	2026-09-29	8739514.11	313	\N	1	313
438	1	2024-03-30	2026-10-05	7844469.75	328	\N	1	328
439	4	2024-12-14	2026-01-20	1123577.03	636	\N	1	636
440	4	2024-06-23	2025-08-18	9902155.81	119	\N	1	119
441	4	2024-10-12	2026-07-01	3940619.90	417	\N	1	417
442	2	2024-02-22	2026-12-08	1552640.03	112	\N	1	112
443	4	2024-11-28	2025-11-27	1084748.19	185	\N	1	185
444	2	2024-08-17	2026-09-13	9048531.84	162	\N	1	162
445	3	2024-09-01	2026-02-03	5441755.15	2	\N	1	2
446	4	2024-04-19	2026-11-19	5780494.57	920	\N	1	920
447	21	2024-04-25	2026-08-25	4651925.79	777	\N	1	777
448	38	2024-04-04	2026-12-17	761755.41	894	\N	1	894
449	3	2024-05-29	2025-10-17	1711556.29	93	\N	1	93
450	4	2024-06-07	2025-12-12	5044014.40	666	\N	1	666
451	3	2024-03-29	2025-11-25	4568683.86	181	\N	1	181
452	4	2024-08-20	2026-02-09	979548.88	724	\N	1	724
453	2	2024-10-19	2025-12-30	943515.82	8	\N	1	8
454	1	2024-06-22	2026-01-29	9165887.25	849	\N	1	849
455	21	2024-03-25	2026-03-31	9130193.53	675	\N	1	675
456	2	2024-12-06	2026-07-17	1045483.31	232	\N	1	232
457	21	2024-09-18	2025-10-27	7769720.02	536	\N	1	536
458	3	2024-01-29	2025-06-26	7175687.09	745	\N	1	745
459	3	2024-08-01	2026-01-11	3559382.68	779	\N	1	779
460	38	2024-10-15	2026-12-08	4552152.12	241	\N	1	241
461	21	2024-11-13	2025-08-24	5388084.23	651	\N	1	651
462	39	2024-12-03	2026-02-25	2309725.34	618	\N	1	618
463	21	2024-10-09	2026-07-07	3938899.96	392	\N	1	392
464	39	2024-02-10	2025-06-29	9276257.69	42	\N	1	42
465	1	2024-01-11	2026-09-24	3031940.58	994	\N	1	994
466	2	2024-03-30	2025-12-02	8548305.80	623	\N	1	623
467	21	2024-05-04	2026-04-25	3131737.08	746	\N	1	746
468	2	2024-10-21	2026-04-16	6425497.85	529	\N	1	529
469	2	2024-08-28	2025-08-20	6830024.28	887	\N	1	887
470	4	2024-02-08	2026-04-03	4176475.28	717	\N	1	717
471	39	2024-11-10	2026-08-23	4990042.17	838	\N	1	838
472	38	2024-04-13	2025-06-12	2034728.06	862	\N	1	862
473	2	2024-10-12	2025-11-30	3587331.15	465	\N	1	465
474	1	2024-05-06	2026-06-25	5745172.63	272	\N	1	272
475	39	2024-03-30	2025-06-24	948878.68	158	\N	1	158
476	2	2024-05-26	2026-03-15	969137.47	705	\N	1	705
477	1	2024-11-04	2025-09-18	6192435.23	224	\N	1	224
478	21	2024-05-12	2025-12-15	9349285.26	150	\N	1	150
479	3	2024-11-08	2026-04-14	8331361.19	588	\N	1	588
480	38	2024-12-15	2026-02-11	9487668.69	820	\N	1	820
481	1	2024-04-28	2026-05-21	3326974.46	421	\N	1	421
482	4	2024-07-07	2025-10-18	7968810.61	724	\N	1	724
483	3	2024-04-11	2026-09-09	8499571.03	997	\N	1	997
484	4	2024-01-26	2025-07-31	1066306.61	358	\N	1	358
485	3	2024-08-23	2026-05-12	4677452.24	601	\N	1	601
486	1	2024-01-25	2026-08-31	4925391.60	500	\N	1	500
487	2	2024-03-20	2026-04-01	8713083.94	832	\N	1	832
488	4	2024-09-11	2026-08-22	728442.80	518	\N	1	518
489	3	2024-01-08	2026-06-26	8143312.27	228	\N	1	228
490	4	2024-06-23	2026-07-23	9290170.49	53	\N	1	53
491	1	2024-02-10	2026-01-16	3383107.58	695	\N	1	695
492	3	2024-11-22	2026-09-11	4264947.75	587	\N	1	587
493	39	2024-05-26	2026-12-12	6693154.12	140	\N	1	140
494	1	2024-06-13	2025-10-20	6550239.66	686	\N	1	686
495	38	2024-06-23	2026-04-19	9864112.53	216	\N	1	216
496	38	2024-10-10	2026-11-25	9261440.34	960	\N	1	960
497	2	2024-05-04	2025-07-17	8665185.29	289	\N	1	289
498	3	2024-09-04	2025-10-09	5818010.33	706	\N	1	706
499	1	2024-12-13	2026-03-19	710950.64	919	\N	1	919
500	3	2024-09-13	2026-10-14	6575695.59	1000	\N	1	1000
501	38	2024-01-11	2026-10-21	4515794.77	344	\N	1	344
502	4	2024-10-23	2025-06-06	3109208.44	710	\N	1	710
503	4	2024-08-29	2026-02-23	8211612.21	828	\N	1	828
504	38	2024-05-02	2026-10-12	175502.58	989	\N	1	989
505	1	2024-09-21	2026-01-10	4497365.05	19	\N	1	19
506	4	2024-01-23	2026-12-31	7314025.95	931	\N	1	931
507	38	2024-09-26	2026-08-27	1658115.22	331	\N	1	331
508	21	2024-02-14	2026-09-04	8850590.12	620	\N	1	620
509	2	2024-10-20	2026-11-23	2531656.90	620	\N	1	620
510	3	2024-03-16	2026-01-30	7505758.66	613	\N	1	613
511	21	2024-02-03	2025-10-01	9740527.00	883	\N	1	883
512	21	2024-06-16	2026-06-12	592617.54	137	\N	1	137
513	4	2024-03-12	2026-03-21	3632116.35	857	\N	1	857
514	4	2024-10-29	2026-04-04	8210916.73	159	\N	1	159
515	2	2024-03-12	2026-11-27	9999502.68	281	\N	1	281
516	4	2024-12-07	2026-03-27	638888.12	68	\N	1	68
517	3	2024-06-12	2026-01-26	825479.36	620	\N	1	620
518	3	2024-07-30	2026-08-19	6836634.63	298	\N	1	298
519	1	2024-12-04	2026-05-30	9228701.87	169	\N	1	169
520	39	2024-02-21	2025-12-25	3789553.70	515	\N	1	515
521	3	2024-01-04	2025-10-20	9378493.00	945	\N	1	945
522	1	2024-06-22	2025-07-12	8583683.37	598	\N	1	598
523	21	2024-08-10	2026-03-06	4200984.49	305	\N	1	305
524	3	2024-01-15	2026-08-13	6567293.97	250	\N	1	250
525	4	2024-09-15	2026-03-10	473463.49	813	\N	1	813
526	2	2024-03-13	2026-06-09	135274.32	290	\N	1	290
527	38	2024-01-31	2025-06-28	36616.06	82	\N	1	82
528	21	2024-12-05	2026-04-08	3608751.38	198	\N	1	198
529	21	2024-03-20	2025-11-13	9651958.65	881	\N	1	881
530	2	2024-11-24	2025-07-05	3731816.96	556	\N	1	556
531	39	2024-05-11	2025-07-19	7808420.32	807	\N	1	807
532	1	2024-06-22	2025-11-07	904123.43	436	\N	1	436
533	3	2024-05-09	2025-06-27	7292586.49	498	\N	1	498
534	39	2024-01-29	2025-10-11	4755467.51	724	\N	1	724
535	4	2024-09-19	2026-04-27	746504.33	377	\N	1	377
536	4	2024-02-17	2025-08-25	9805265.06	382	\N	1	382
537	21	2024-01-13	2026-05-23	5617083.04	245	\N	1	245
538	3	2024-08-13	2025-12-07	1024514.32	960	\N	1	960
539	2	2024-10-03	2025-08-14	2855230.54	112	\N	1	112
540	1	2024-03-31	2026-10-06	2696319.56	190	\N	1	190
541	38	2024-08-03	2025-07-11	6911831.37	137	\N	1	137
542	21	2024-04-06	2025-09-06	5371790.90	332	\N	1	332
543	38	2024-07-09	2025-11-19	908480.63	355	\N	1	355
544	2	2024-04-13	2026-02-26	5272343.14	857	\N	1	857
545	38	2024-06-29	2026-02-05	6132083.21	839	\N	1	839
546	1	2024-12-26	2026-11-06	8542238.05	804	\N	1	804
547	1	2024-11-10	2025-06-25	3625181.80	238	\N	1	238
548	21	2024-08-20	2025-11-04	2506683.63	581	\N	1	581
549	1	2024-09-28	2026-07-31	6685405.44	454	\N	1	454
550	38	2024-04-01	2026-01-03	9428630.58	471	\N	1	471
551	3	2024-12-19	2026-01-31	8450431.89	135	\N	1	135
552	4	2024-12-30	2026-05-19	7987382.07	498	\N	1	498
553	2	2024-08-23	2026-06-26	1656921.89	695	\N	1	695
554	21	2024-05-28	2025-11-16	7765231.10	884	\N	1	884
555	1	2024-04-06	2026-08-25	6586740.05	479	\N	1	479
556	1	2024-01-15	2026-01-12	3135726.40	413	\N	1	413
557	25	2024-11-26	2025-08-23	9488212.67	709	\N	2	709
558	5	2024-07-01	2025-06-23	7761284.42	275	\N	2	275
559	23	2024-09-03	2026-10-07	4928893.26	41	\N	2	41
560	5	2024-01-25	2026-10-17	8721657.21	24	\N	2	24
561	25	2024-02-25	2026-08-11	8847090.84	255	\N	2	255
562	6	2024-12-03	2025-07-07	4840546.11	623	\N	2	623
563	8	2024-03-29	2025-10-10	9351280.36	657	\N	2	657
564	6	2024-04-27	2026-06-27	6663024.67	141	\N	2	141
565	25	2024-03-21	2025-11-30	3804472.64	863	\N	2	863
566	8	2024-03-08	2026-11-27	3643136.96	865	\N	2	865
567	6	2024-08-30	2026-02-24	8830231.46	608	\N	2	608
568	8	2024-07-26	2026-06-17	5101484.25	500	\N	2	500
569	7	2024-07-09	2026-08-19	8357228.94	172	\N	2	172
570	22	2024-10-09	2026-03-17	1168385.87	762	\N	2	762
571	22	2024-10-28	2026-02-09	5852747.23	49	\N	2	49
572	24	2024-05-09	2025-08-02	2863057.73	777	\N	2	777
573	7	2024-11-15	2025-11-10	7444968.29	861	\N	2	861
574	22	2024-04-25	2026-06-13	9912748.88	240	\N	2	240
575	22	2024-10-29	2026-12-22	4594989.08	376	\N	2	376
576	6	2024-03-21	2026-01-05	7023295.10	782	\N	2	782
577	7	2024-01-29	2026-03-18	2280480.37	177	\N	2	177
578	22	2024-07-24	2025-07-02	1875829.04	681	\N	2	681
579	7	2024-09-12	2025-08-15	1732745.64	819	\N	2	819
580	7	2024-10-21	2026-12-07	8987812.40	724	\N	2	724
581	7	2024-11-20	2026-06-20	5962837.71	234	\N	2	234
582	6	2024-07-23	2026-11-20	1781275.50	352	\N	2	352
583	22	2024-06-20	2026-07-01	5480568.36	147	\N	2	147
584	6	2024-07-15	2026-03-17	4526340.06	419	\N	2	419
585	23	2024-11-29	2026-03-21	7163413.34	382	\N	2	382
586	23	2024-09-04	2026-11-19	7701471.85	238	\N	2	238
587	5	2024-10-15	2026-09-29	7382014.02	272	\N	2	272
588	24	2024-08-11	2026-04-05	4006482.89	914	\N	2	914
589	5	2024-07-25	2026-08-20	619165.93	696	\N	2	696
590	24	2024-10-02	2026-09-08	8584642.67	889	\N	2	889
591	6	2024-12-29	2026-11-08	5273863.73	941	\N	2	941
592	23	2024-09-08	2025-08-15	6888730.07	8	\N	2	8
593	22	2024-04-23	2026-12-27	5060381.63	136	\N	2	136
594	23	2024-07-16	2026-05-31	7713467.25	281	\N	2	281
595	25	2024-02-16	2026-01-28	3301246.48	756	\N	2	756
596	7	2024-09-16	2026-11-05	2552644.26	846	\N	2	846
597	5	2024-04-26	2026-09-08	5533676.26	669	\N	2	669
598	24	2024-07-01	2026-12-12	2632793.29	427	\N	2	427
599	24	2024-08-22	2026-07-26	6006738.80	487	\N	2	487
600	25	2024-01-29	2026-01-05	5633836.68	588	\N	2	588
601	5	2024-11-12	2025-08-01	1205918.04	146	\N	2	146
602	6	2024-11-12	2026-01-12	2086832.10	942	\N	2	942
603	7	2024-03-02	2026-04-10	4244535.69	424	\N	2	424
604	22	2024-05-19	2025-09-07	6461581.71	142	\N	2	142
605	8	2024-03-19	2026-05-05	2507686.88	111	\N	2	111
606	5	2024-08-19	2026-01-20	8138335.36	58	\N	2	58
607	22	2024-06-12	2025-06-22	2692441.61	91	\N	2	91
608	22	2024-05-12	2026-11-16	6790393.19	204	\N	2	204
609	7	2024-10-14	2025-07-28	7742727.08	383	\N	2	383
610	7	2024-07-22	2025-09-22	2907512.60	702	\N	2	702
611	22	2024-05-01	2025-07-16	7764357.37	911	\N	2	911
612	7	2024-08-08	2025-08-06	2804017.32	596	\N	2	596
613	25	2024-08-21	2026-11-18	9966196.55	422	\N	2	422
614	6	2024-01-29	2025-11-22	9933907.57	504	\N	2	504
615	25	2024-04-21	2026-11-19	3580658.69	435	\N	2	435
616	6	2024-10-24	2026-08-02	5013185.33	866	\N	2	866
617	5	2024-06-01	2025-08-05	6504480.42	81	\N	2	81
618	6	2024-03-03	2026-10-09	5880656.37	120	\N	2	120
619	24	2024-05-16	2026-08-17	7034690.59	996	\N	2	996
620	25	2024-06-02	2026-03-31	5113890.46	980	\N	2	980
621	23	2024-07-13	2026-11-24	7818800.15	67	\N	2	67
622	8	2024-07-26	2025-10-03	4369316.99	944	\N	2	944
623	5	2024-01-30	2026-01-12	159977.99	992	\N	2	992
624	8	2024-02-19	2025-07-05	8186549.20	971	\N	2	971
625	24	2024-12-29	2026-04-04	7802773.74	749	\N	2	749
626	5	2024-03-16	2026-06-11	4800529.19	670	\N	2	670
627	5	2024-06-03	2026-05-13	5153395.30	200	\N	2	200
628	22	2024-08-22	2026-09-21	9584460.13	580	\N	2	580
629	7	2024-07-07	2026-02-27	3275098.15	889	\N	2	889
630	7	2024-07-01	2026-10-10	418068.40	924	\N	2	924
631	24	2024-09-20	2026-05-27	9666959.18	907	\N	2	907
632	25	2024-01-28	2026-08-27	597033.41	751	\N	2	751
633	5	2024-09-26	2026-02-10	2458127.85	749	\N	2	749
634	25	2024-05-08	2026-05-04	2845081.42	220	\N	2	220
635	23	2024-03-12	2026-06-10	2931765.28	63	\N	2	63
636	22	2024-11-09	2026-09-01	1368364.30	521	\N	2	521
637	23	2024-11-15	2026-08-07	1515498.78	267	\N	2	267
638	23	2024-01-06	2026-09-18	1118557.31	344	\N	2	344
639	8	2024-11-16	2026-09-09	3955374.55	706	\N	2	706
640	7	2024-08-15	2025-11-06	4836720.11	400	\N	2	400
641	7	2024-02-14	2026-03-26	3362158.23	39	\N	2	39
642	25	2024-08-04	2025-08-09	2758803.47	264	\N	2	264
643	8	2024-07-26	2025-09-19	3432303.93	127	\N	2	127
644	7	2024-01-31	2025-06-18	8561868.59	284	\N	2	284
645	7	2024-09-29	2026-03-18	3273137.77	117	\N	2	117
646	25	2024-08-02	2026-02-27	9966232.48	6	\N	2	6
647	25	2024-02-14	2026-11-24	8467822.53	753	\N	2	753
648	5	2024-12-04	2026-04-21	792698.96	409	\N	2	409
649	8	2024-02-09	2026-01-24	3070894.16	412	\N	2	412
650	23	2024-09-10	2026-11-16	5078644.91	665	\N	2	665
651	23	2024-06-16	2026-06-15	1291663.54	818	\N	2	818
652	25	2024-09-24	2026-04-17	4511081.25	411	\N	2	411
653	8	2024-03-21	2025-10-21	2547468.19	414	\N	2	414
654	6	2024-02-13	2026-08-04	4382655.22	212	\N	2	212
655	8	2024-08-09	2026-01-08	8734340.44	466	\N	2	466
656	25	2024-01-11	2026-10-29	3879213.75	421	\N	2	421
657	24	2024-11-25	2026-09-05	9532882.38	470	\N	2	470
658	7	2024-12-27	2026-06-07	782941.21	788	\N	2	788
659	22	2024-07-30	2026-03-10	4208311.46	104	\N	2	104
660	8	2024-06-02	2026-09-18	1522974.15	279	\N	2	279
661	5	2024-03-31	2025-09-02	3528830.25	493	\N	2	493
662	5	2024-08-12	2026-12-23	5596382.63	198	\N	2	198
663	7	2024-01-28	2026-02-06	967311.78	665	\N	2	665
664	8	2024-03-03	2026-12-04	3508457.94	80	\N	2	80
665	6	2024-12-13	2026-10-14	4729255.71	129	\N	2	129
666	6	2024-06-11	2025-12-27	3103961.31	809	\N	2	809
667	7	2024-03-12	2025-10-01	5630091.81	961	\N	2	961
668	6	2024-06-12	2026-11-26	2839996.95	650	\N	2	650
669	22	2024-05-17	2026-08-15	4461806.35	39	\N	2	39
670	6	2024-08-28	2025-11-05	280498.12	825	\N	2	825
671	25	2024-06-14	2026-03-29	8875045.91	991	\N	2	991
672	5	2024-02-18	2026-04-19	5708595.85	808	\N	2	808
673	25	2024-01-01	2026-01-18	4994965.42	862	\N	2	862
674	5	2024-10-25	2025-08-09	1701739.01	68	\N	2	68
675	24	2024-12-17	2025-11-18	4718901.45	442	\N	2	442
676	22	2024-04-23	2026-10-03	8083313.68	836	\N	2	836
677	7	2024-04-25	2026-12-30	3537587.69	478	\N	2	478
678	24	2024-04-27	2025-06-18	7894781.91	501	\N	2	501
679	25	2024-08-25	2026-01-23	7586490.46	782	\N	2	782
680	5	2024-01-29	2026-10-20	5114763.94	325	\N	2	325
681	24	2024-04-17	2026-09-15	2876799.85	423	\N	2	423
682	5	2024-10-19	2025-07-02	3109170.19	774	\N	2	774
683	7	2024-01-05	2025-06-20	9642928.69	740	\N	2	740
684	5	2024-11-15	2026-12-12	8746743.82	436	\N	2	436
685	22	2024-02-28	2026-11-07	7015722.73	782	\N	2	782
686	5	2024-07-19	2026-03-26	8785983.42	731	\N	2	731
687	25	2024-10-04	2026-01-14	4783084.65	390	\N	2	390
688	6	2024-09-19	2026-08-28	5547020.35	157	\N	2	157
689	7	2024-01-14	2025-07-15	7554791.16	885	\N	2	885
690	22	2024-05-13	2026-09-30	6632605.50	782	\N	2	782
691	24	2024-12-05	2025-12-10	2945459.67	16	\N	2	16
692	7	2024-11-17	2026-07-06	4555458.18	315	\N	2	315
693	5	2024-09-17	2025-07-09	4752873.60	319	\N	2	319
694	22	2024-06-09	2026-04-18	9624746.64	640	\N	2	640
695	6	2024-05-29	2026-02-19	6857009.88	813	\N	2	813
696	23	2024-11-13	2026-08-29	7954123.32	169	\N	2	169
697	25	2024-03-23	2026-05-19	9295101.36	918	\N	2	918
698	24	2024-10-16	2025-07-08	9749679.96	993	\N	2	993
699	23	2024-12-16	2026-08-20	8672301.49	541	\N	2	541
700	23	2024-08-14	2026-04-16	5546034.64	660	\N	2	660
701	25	2024-06-03	2026-02-10	6958327.29	831	\N	2	831
702	25	2024-07-21	2026-10-20	4736644.84	350	\N	2	350
703	24	2024-03-10	2026-04-08	2416322.28	459	\N	2	459
704	25	2024-02-11	2025-07-27	3383847.88	944	\N	2	944
705	23	2024-04-19	2025-07-16	1372078.17	563	\N	2	563
706	8	2024-07-01	2025-07-16	4800678.47	979	\N	2	979
707	7	2024-01-11	2026-07-13	2357932.25	671	\N	2	671
708	22	2024-01-06	2026-02-08	8036832.63	399	\N	2	399
709	22	2024-03-23	2026-02-23	9363710.55	338	\N	2	338
710	22	2024-08-17	2026-05-06	5216297.84	308	\N	2	308
711	6	2024-11-21	2025-06-19	7949547.89	608	\N	2	608
712	22	2024-03-19	2025-11-28	7604433.71	43	\N	2	43
713	23	2024-07-28	2025-10-04	8961754.49	79	\N	2	79
714	23	2024-03-11	2025-11-14	5571306.24	69	\N	2	69
715	22	2024-09-04	2026-11-15	338851.05	132	\N	2	132
716	25	2024-10-06	2026-01-02	2683541.07	291	\N	2	291
717	7	2024-04-21	2026-05-27	9021346.61	585	\N	2	585
718	24	2024-08-11	2026-09-09	4405950.16	621	\N	2	621
719	25	2024-04-12	2025-08-05	248614.56	119	\N	2	119
720	23	2024-07-08	2026-03-14	6872397.74	15	\N	2	15
721	22	2024-04-11	2025-12-12	3651156.86	777	\N	2	777
722	6	2024-02-11	2026-05-23	2841408.46	837	\N	2	837
723	6	2024-01-18	2026-08-13	9394625.03	411	\N	2	411
724	7	2024-11-07	2026-06-19	2327886.02	944	\N	2	944
725	23	2024-09-28	2026-01-28	5976760.54	954	\N	2	954
726	5	2024-09-01	2026-08-02	4496061.50	640	\N	2	640
727	7	2024-05-31	2026-03-09	9053275.82	337	\N	2	337
728	24	2024-01-25	2026-04-19	8100367.89	441	\N	2	441
729	6	2024-01-30	2026-02-26	5891214.66	21	\N	2	21
730	7	2024-07-13	2025-10-18	7206679.66	689	\N	2	689
731	22	2024-01-06	2026-03-22	8793579.02	379	\N	2	379
732	6	2024-07-10	2025-11-04	1461436.47	101	\N	2	101
733	5	2024-10-20	2026-11-05	3862203.10	11	\N	2	11
734	5	2024-01-11	2026-03-09	8973671.44	563	\N	2	563
735	24	2024-06-10	2026-08-04	2371372.47	994	\N	2	994
736	7	2024-12-13	2026-10-05	2452512.54	770	\N	2	770
737	23	2024-05-26	2025-12-06	7685045.31	279	\N	2	279
738	22	2024-06-26	2026-04-16	5322682.90	669	\N	2	669
739	24	2024-12-24	2025-06-22	7862045.55	920	\N	2	920
740	24	2024-04-30	2025-07-22	7860208.03	967	\N	2	967
741	5	2024-12-01	2025-08-25	6278759.85	373	\N	2	373
742	5	2024-03-01	2025-12-05	5241496.55	45	\N	2	45
743	23	2024-12-17	2026-03-17	7233835.20	845	\N	2	845
744	8	2024-09-11	2026-12-01	1818376.63	446	\N	2	446
745	7	2024-11-07	2026-09-01	9361336.80	144	\N	2	144
746	5	2024-06-21	2026-07-28	9911360.75	632	\N	2	632
747	6	2024-07-10	2025-07-27	2786717.94	71	\N	2	71
748	23	2024-05-24	2026-08-15	1757907.14	975	\N	2	975
749	23	2024-06-23	2026-04-30	1319253.57	90	\N	2	90
750	8	2024-07-02	2026-04-27	309859.22	229	\N	2	229
751	7	2024-08-10	2026-08-28	7330169.50	220	\N	2	220
752	23	2024-06-09	2026-05-18	7770623.51	889	\N	2	889
753	8	2024-02-06	2026-05-28	3731152.04	326	\N	2	326
754	25	2024-02-13	2025-07-18	6998927.28	380	\N	2	380
755	24	2024-09-28	2025-10-09	5026694.64	657	\N	2	657
756	25	2024-08-19	2025-10-24	4717596.12	430	\N	2	430
757	24	2024-11-30	2025-08-20	2069540.25	477	\N	2	477
758	22	2024-10-20	2026-05-04	1903403.83	800	\N	2	800
759	8	2024-08-03	2025-12-06	3688157.93	722	\N	2	722
760	7	2024-01-17	2025-10-07	3417327.06	951	\N	2	951
761	7	2024-02-26	2025-07-12	4045777.30	525	\N	2	525
762	25	2024-06-22	2026-04-08	6715764.17	403	\N	2	403
763	22	2024-03-01	2026-10-30	1175744.19	900	\N	2	900
764	22	2024-02-15	2026-09-03	6273889.94	281	\N	2	281
765	5	2024-05-07	2025-08-12	5353104.23	61	\N	2	61
766	7	2024-02-22	2026-07-11	5253255.09	145	\N	2	145
767	23	2024-09-16	2025-06-28	9636899.60	327	\N	2	327
768	24	2024-09-18	2026-12-19	3469780.83	712	\N	2	712
769	23	2024-07-30	2025-08-04	9945544.55	772	\N	2	772
770	23	2024-04-30	2026-01-07	3334011.87	341	\N	2	341
771	23	2024-08-09	2026-08-09	9476259.45	746	\N	2	746
772	5	2024-03-20	2026-05-14	5198038.51	674	\N	2	674
773	23	2024-09-29	2025-09-10	7926574.89	997	\N	2	997
774	25	2024-05-22	2026-02-19	8545194.81	261	\N	2	261
775	7	2024-10-31	2026-09-22	2618824.83	667	\N	2	667
776	7	2024-07-13	2025-09-21	2272114.10	3	\N	2	3
777	25	2024-12-13	2026-09-29	1136080.79	897	\N	2	897
778	8	2024-05-10	2026-05-04	9700161.81	177	\N	2	177
779	22	2024-02-25	2026-04-12	9167365.73	328	\N	2	328
780	23	2024-10-05	2026-05-01	1117868.40	936	\N	2	936
781	24	2024-11-12	2026-10-21	9285589.74	642	\N	2	642
782	24	2024-04-03	2025-07-18	9050278.81	500	\N	2	500
783	25	2024-02-16	2026-10-16	2131263.42	148	\N	2	148
784	7	2024-04-01	2026-01-18	2241511.85	822	\N	2	822
785	8	2024-09-07	2026-11-16	3328614.63	707	\N	2	707
786	6	2024-05-19	2025-07-07	4262062.20	957	\N	2	957
787	8	2024-01-29	2026-05-27	7885016.35	624	\N	2	624
788	24	2024-12-25	2026-12-21	3812670.97	125	\N	2	125
789	6	2024-03-21	2025-12-21	11936.95	909	\N	2	909
790	8	2024-04-03	2026-05-18	7646841.33	394	\N	2	394
791	25	2024-12-05	2026-11-12	5279272.09	465	\N	2	465
792	6	2024-04-05	2026-09-04	6226200.11	705	\N	2	705
793	8	2024-01-02	2026-06-12	6303415.10	966	\N	2	966
794	8	2024-03-08	2026-09-26	698680.06	7	\N	2	7
795	24	2024-07-01	2025-07-06	9726461.73	582	\N	2	582
796	23	2024-06-21	2025-12-26	3775736.09	663	\N	2	663
797	25	2024-05-16	2026-12-05	4698080.66	886	\N	2	886
798	7	2024-02-13	2025-08-13	9256701.65	472	\N	2	472
799	6	2024-10-23	2026-10-24	7751947.69	600	\N	2	600
800	6	2024-09-11	2026-04-25	4866488.68	596	\N	2	596
801	8	2024-05-29	2026-03-23	274272.02	365	\N	2	365
802	5	2024-01-20	2026-01-11	9116039.92	955	\N	2	955
803	8	2024-07-19	2026-07-17	1022249.65	169	\N	2	169
804	8	2024-10-14	2026-03-04	4175886.23	359	\N	2	359
805	24	2024-05-10	2025-12-23	9139818.19	905	\N	2	905
806	22	2024-12-24	2026-04-09	1534888.91	924	\N	2	924
807	23	2024-09-07	2026-02-20	8356196.20	952	\N	2	952
808	23	2024-06-18	2025-11-25	9586283.06	466	\N	2	466
809	23	2024-12-13	2025-08-17	2607077.20	227	\N	2	227
810	23	2024-12-30	2026-05-22	2824263.23	97	\N	2	97
811	22	2024-08-14	2026-06-10	5210387.41	711	\N	2	711
812	25	2024-12-31	2025-12-12	1622217.35	453	\N	2	453
813	22	2024-02-12	2025-11-11	1677466.63	509	\N	2	509
814	8	2024-12-22	2025-10-08	3660981.46	457	\N	2	457
815	8	2024-08-26	2026-07-08	8477359.61	58	\N	2	58
816	7	2024-10-07	2026-07-05	7451392.85	429	\N	2	429
817	24	2024-11-08	2025-10-24	6479291.99	22	\N	2	22
818	5	2024-09-18	2025-10-17	6143269.84	367	\N	2	367
819	23	2024-01-30	2026-11-13	9227319.12	418	\N	2	418
820	8	2024-06-13	2025-11-04	1750008.85	371	\N	2	371
821	23	2024-08-08	2025-11-25	2801544.03	742	\N	2	742
822	24	2024-10-14	2026-11-07	9214836.90	583	\N	2	583
823	6	2024-03-23	2025-06-25	2049059.15	533	\N	2	533
824	8	2024-03-25	2026-04-08	4785702.54	359	\N	2	359
825	24	2024-12-29	2026-01-02	8260072.15	646	\N	2	646
826	25	2024-10-04	2025-11-12	1297277.79	513	\N	2	513
827	6	2024-12-20	2025-11-29	2596567.83	158	\N	2	158
828	25	2024-09-03	2026-03-30	405853.07	395	\N	2	395
829	22	2024-02-13	2026-04-17	4044860.02	372	\N	2	372
830	5	2024-11-13	2025-09-07	9293718.40	143	\N	2	143
831	22	2024-11-21	2025-09-16	9299935.99	83	\N	2	83
832	6	2024-09-08	2026-09-16	1368040.24	261	\N	2	261
833	22	2024-09-01	2025-12-08	254805.55	541	\N	2	541
834	6	2024-04-15	2026-12-22	4312005.77	158	\N	2	158
835	22	2024-08-30	2026-03-04	8106902.71	746	\N	2	746
836	23	2024-07-05	2026-11-22	8139419.73	260	\N	2	260
837	5	2024-09-11	2026-10-28	4446382.81	667	\N	2	667
838	22	2024-02-26	2025-12-02	7284761.30	585	\N	2	585
839	7	2024-03-25	2026-11-04	5543628.44	897	\N	2	897
840	22	2024-08-06	2025-08-04	9071175.36	759	\N	2	759
841	24	2024-08-29	2025-09-28	7683599.16	340	\N	2	340
842	8	2024-08-19	2025-10-17	9891310.41	217	\N	2	217
843	23	2024-12-31	2026-07-04	4146479.75	804	\N	2	804
844	22	2024-05-01	2025-06-24	6152733.80	575	\N	2	575
845	23	2024-09-15	2026-07-27	924927.38	882	\N	2	882
846	5	2024-10-29	2025-11-19	4019297.42	644	\N	2	644
847	8	2024-03-05	2026-07-17	7250071.60	837	\N	2	837
848	23	2024-02-06	2025-07-24	8044022.80	354	\N	2	354
849	25	2024-11-12	2026-02-24	2312834.00	447	\N	2	447
850	23	2024-08-19	2026-02-06	4830628.66	533	\N	2	533
851	24	2024-01-12	2025-11-30	2262159.21	681	\N	2	681
852	6	2024-07-04	2025-07-09	4012263.99	622	\N	2	622
853	22	2024-05-16	2025-07-05	5520213.13	949	\N	2	949
854	6	2024-06-12	2025-12-03	3377003.37	915	\N	2	915
855	6	2024-09-19	2025-07-19	3007354.87	366	\N	2	366
856	24	2024-10-15	2026-03-12	241216.76	806	\N	2	806
857	6	2024-10-30	2026-01-16	1224426.53	237	\N	2	237
858	24	2024-08-30	2025-07-25	4255203.07	595	\N	2	595
859	23	2024-10-16	2026-12-30	8102571.42	445	\N	2	445
860	6	2024-01-30	2025-10-02	4654664.47	970	\N	2	970
861	23	2024-02-16	2026-12-11	6602509.85	164	\N	2	164
862	8	2024-05-05	2026-08-09	3079706.98	648	\N	2	648
863	8	2024-07-19	2025-07-04	5062647.58	809	\N	2	809
864	23	2024-09-03	2026-01-15	6699360.20	405	\N	2	405
865	25	2024-05-23	2026-07-20	735975.91	818	\N	2	818
866	7	2024-09-25	2025-09-13	2351521.85	594	\N	2	594
867	24	2024-12-19	2026-11-03	1546583.65	235	\N	2	235
868	6	2024-01-05	2026-09-22	4527019.98	454	\N	2	454
869	6	2024-06-12	2025-06-21	8971133.80	291	\N	2	291
870	24	2024-07-14	2025-07-03	8596413.98	466	\N	2	466
871	24	2024-02-16	2025-11-16	1515101.67	501	\N	2	501
872	24	2024-12-17	2025-07-09	311576.22	680	\N	2	680
873	23	2024-11-28	2026-08-27	2315553.90	112	\N	2	112
874	24	2024-08-06	2025-09-08	4089926.39	899	\N	2	899
875	22	2024-02-22	2025-08-01	635927.38	782	\N	2	782
876	6	2024-03-16	2026-07-02	5404333.96	182	\N	2	182
877	22	2024-08-27	2026-07-08	2564688.16	55	\N	2	55
878	8	2024-06-30	2026-10-26	9938449.79	428	\N	2	428
879	22	2024-12-26	2026-03-11	6495850.32	559	\N	2	559
880	6	2024-07-02	2026-12-13	3849941.08	896	\N	2	896
881	23	2024-01-12	2026-06-01	5929338.72	835	\N	2	835
882	5	2024-08-20	2025-12-11	2013105.47	928	\N	2	928
883	7	2024-03-01	2025-12-03	6076694.08	197	\N	2	197
884	23	2024-03-07	2026-05-21	8949377.59	536	\N	2	536
885	5	2024-04-03	2026-02-21	248551.27	932	\N	2	932
886	22	2024-08-22	2026-05-14	5539948.81	501	\N	2	501
887	23	2024-12-05	2026-07-31	7766966.79	796	\N	2	796
888	25	2024-05-09	2025-10-21	358818.56	858	\N	2	858
889	6	2024-10-01	2026-05-14	6407652.10	278	\N	2	278
890	22	2024-08-12	2026-01-20	8280979.95	509	\N	2	509
891	22	2024-03-24	2026-08-14	2391036.65	612	\N	2	612
892	7	2024-10-13	2025-11-04	4888726.68	63	\N	2	63
893	25	2024-08-19	2025-10-07	5179971.78	308	\N	2	308
894	5	2024-09-24	2025-11-22	3452301.30	815	\N	2	815
895	8	2024-02-04	2025-06-23	5995551.00	681	\N	2	681
896	7	2024-07-13	2026-08-15	9733601.96	497	\N	2	497
897	25	2024-10-03	2026-08-18	7810265.58	885	\N	2	885
898	22	2024-01-08	2026-07-23	2840093.36	923	\N	2	923
899	24	2024-06-27	2026-06-03	1700131.19	394	\N	2	394
900	8	2024-04-29	2026-12-19	3822358.86	57	\N	2	57
901	5	2024-03-10	2026-02-11	1200900.71	884	\N	2	884
902	8	2024-09-02	2026-07-01	1434378.24	948	\N	2	948
903	8	2024-10-19	2026-04-20	8183229.33	873	\N	2	873
904	25	2024-12-04	2026-05-04	9211792.91	946	\N	2	946
905	8	2024-03-30	2025-06-10	9957504.11	900	\N	2	900
906	23	2024-07-21	2025-07-10	8474257.29	670	\N	2	670
907	25	2024-01-18	2026-02-14	8750897.90	396	\N	2	396
908	6	2024-10-02	2026-03-19	4965157.18	304	\N	2	304
909	23	2024-12-02	2026-04-13	7954674.94	9	\N	2	9
910	7	2024-03-03	2025-08-18	620015.68	687	\N	2	687
911	5	2024-01-10	2026-09-15	5776659.39	904	\N	2	904
912	23	2024-03-14	2026-07-13	9106746.02	67	\N	2	67
913	7	2024-04-05	2026-07-26	7671094.28	354	\N	2	354
914	24	2024-08-03	2025-08-30	7262434.97	640	\N	2	640
915	24	2024-08-05	2026-02-17	3243339.21	746	\N	2	746
916	23	2024-01-27	2025-06-12	8811279.10	992	\N	2	992
917	7	2024-01-15	2026-11-17	1254440.14	541	\N	2	541
918	6	2024-05-25	2026-08-26	40490.26	484	\N	2	484
919	25	2024-06-22	2026-12-14	1310660.45	36	\N	2	36
920	7	2024-04-15	2025-11-19	1109224.12	826	\N	2	826
921	23	2024-07-11	2026-02-23	190203.87	52	\N	2	52
922	24	2024-05-20	2026-04-08	8921837.22	194	\N	2	194
923	22	2024-02-15	2026-11-19	1832931.32	507	\N	2	507
924	8	2024-11-30	2026-01-02	3963727.78	11	\N	2	11
925	5	2024-02-29	2026-02-07	7132145.85	828	\N	2	828
926	24	2024-09-02	2025-06-07	8348645.84	166	\N	2	166
927	6	2024-01-20	2026-06-03	6259877.55	99	\N	2	99
928	22	2024-05-14	2025-08-26	7751565.64	168	\N	2	168
929	25	2024-07-21	2026-09-09	3049601.75	424	\N	2	424
930	23	2024-11-21	2026-12-18	2705286.37	398	\N	2	398
931	23	2024-11-02	2026-11-11	5605500.54	433	\N	2	433
932	8	2024-03-12	2026-05-27	6616112.89	60	\N	2	60
933	23	2024-08-04	2025-10-07	7096402.68	741	\N	2	741
934	7	2024-07-29	2026-09-12	534763.87	932	\N	2	932
935	7	2024-12-20	2026-07-31	4760137.14	414	\N	2	414
936	7	2024-11-19	2026-01-15	9621120.60	800	\N	2	800
937	5	2024-11-14	2026-04-22	8602534.23	10	\N	2	10
938	6	2024-04-08	2026-01-05	5257137.45	295	\N	2	295
939	8	2024-05-16	2026-04-08	530427.10	835	\N	2	835
940	25	2024-12-29	2025-07-08	9577615.38	492	\N	2	492
941	25	2024-02-21	2025-11-11	978447.81	143	\N	2	143
942	24	2024-05-26	2026-11-28	9614102.37	515	\N	2	515
943	6	2024-05-25	2025-10-05	7515733.64	87	\N	2	87
944	7	2024-09-13	2026-02-08	5501272.04	981	\N	2	981
945	23	2024-11-01	2025-12-05	8257158.84	224	\N	2	224
946	22	2024-10-13	2026-11-19	2158057.68	65	\N	2	65
947	8	2024-12-15	2025-09-03	3256405.48	919	\N	2	919
948	6	2024-02-07	2025-09-28	3588917.84	9	\N	2	9
949	22	2024-07-28	2025-10-18	7716250.01	528	\N	2	528
950	24	2024-05-26	2026-12-28	716111.73	631	\N	2	631
951	22	2024-04-27	2025-06-12	2271018.14	246	\N	2	246
952	25	2024-12-09	2026-12-21	9612362.54	659	\N	2	659
953	22	2024-08-24	2026-04-24	1634770.47	196	\N	2	196
954	7	2024-04-04	2025-08-01	1800585.27	938	\N	2	938
955	5	2024-11-29	2025-11-13	1573748.07	252	\N	2	252
956	7	2024-02-24	2026-10-26	4034408.87	634	\N	2	634
957	23	2024-03-25	2026-05-26	853884.37	670	\N	2	670
958	25	2024-06-11	2025-07-14	8008447.45	744	\N	2	744
959	25	2024-10-22	2026-08-13	3241832.25	554	\N	2	554
960	6	2024-05-19	2025-10-24	9776562.13	545	\N	2	545
961	23	2024-07-16	2026-09-25	8807884.86	561	\N	2	561
962	5	2024-12-30	2025-08-02	343151.69	350	\N	2	350
963	5	2024-09-12	2025-07-13	3074584.31	868	\N	2	868
964	23	2024-07-01	2025-12-14	7904624.69	405	\N	2	405
965	22	2024-01-22	2025-10-20	4229123.93	457	\N	2	457
966	24	2024-10-31	2025-12-28	5552382.30	742	\N	2	742
967	23	2024-02-02	2025-07-16	1643952.84	571	\N	2	571
968	24	2024-07-19	2026-04-01	4074905.64	832	\N	2	832
969	24	2024-07-20	2026-09-16	4375345.30	485	\N	2	485
970	7	2024-09-03	2026-11-13	3345291.22	192	\N	2	192
971	22	2024-10-19	2026-07-11	7945635.80	79	\N	2	79
972	25	2024-10-11	2026-12-10	8810978.55	507	\N	2	507
973	23	2024-12-28	2025-06-16	6794124.45	440	\N	2	440
974	23	2024-04-20	2025-09-08	1233469.72	267	\N	2	267
975	7	2024-10-10	2026-03-11	9755711.56	418	\N	2	418
976	6	2024-05-12	2026-07-09	9278978.58	527	\N	2	527
977	6	2024-05-28	2025-06-29	7072204.29	528	\N	2	528
978	24	2024-01-06	2026-06-24	4611092.59	707	\N	2	707
979	22	2024-10-28	2025-10-09	3186659.81	384	\N	2	384
980	5	2024-12-18	2026-06-01	7286252.77	50	\N	2	50
981	23	2024-11-25	2026-04-08	1122623.85	343	\N	2	343
982	7	2024-08-22	2026-09-17	718038.67	624	\N	2	624
983	7	2024-07-24	2025-11-14	6444089.38	929	\N	2	929
984	5	2024-06-28	2025-08-25	5662436.98	810	\N	2	810
985	7	2024-08-20	2026-05-12	4283693.23	888	\N	2	888
986	8	2024-11-03	2026-08-20	4013960.62	151	\N	2	151
987	23	2024-10-04	2026-06-10	5959764.28	981	\N	2	981
988	5	2024-11-18	2025-07-02	9567679.34	665	\N	2	665
989	8	2024-06-24	2026-01-02	6325667.39	183	\N	2	183
990	23	2024-01-25	2026-02-18	6168292.76	397	\N	2	397
991	7	2024-05-30	2025-08-03	1301438.18	585	\N	2	585
992	7	2024-07-02	2026-02-09	3815149.95	441	\N	2	441
993	23	2024-03-27	2025-10-27	7371658.62	553	\N	2	553
994	8	2024-10-23	2026-05-07	4793600.18	942	\N	2	942
995	24	2024-05-11	2026-07-12	8760843.95	550	\N	2	550
996	5	2024-08-20	2026-07-09	9108992.37	27	\N	2	27
997	5	2024-01-25	2025-06-18	6925779.16	677	\N	2	677
998	25	2024-10-12	2026-03-12	5958546.85	48	\N	2	48
999	23	2024-05-26	2026-01-15	7545677.50	222	\N	2	222
1000	6	2024-04-05	2026-04-28	4248618.56	951	\N	2	951
1001	6	2024-04-21	2026-12-20	6560998.16	996	\N	2	996
1002	23	2024-05-03	2026-03-08	1837291.42	773	\N	2	773
1003	24	2024-02-08	2026-06-02	2267201.14	496	\N	2	496
1004	24	2024-05-12	2026-01-23	3447030.21	989	\N	2	989
1005	5	2024-02-25	2026-11-24	7312244.98	777	\N	2	777
1006	24	2024-05-15	2026-02-20	8415785.70	364	\N	2	364
1007	7	2024-02-26	2025-11-23	8746113.15	333	\N	2	333
1008	25	2024-08-04	2025-07-22	1634081.35	790	\N	2	790
1009	8	2024-06-16	2026-02-19	1417843.69	722	\N	2	722
1010	22	2024-04-08	2026-04-20	2757119.41	294	\N	2	294
1011	6	2024-02-12	2025-11-19	5982945.07	439	\N	2	439
1012	5	2024-06-25	2026-07-17	6060437.13	328	\N	2	328
1013	25	2024-04-02	2026-09-22	8822927.85	17	\N	2	17
1014	8	2024-08-01	2026-01-19	7065258.99	299	\N	2	299
1015	7	2024-07-25	2026-11-27	9985223.92	425	\N	2	425
1016	6	2024-06-24	2026-10-19	35418.86	37	\N	2	37
1017	24	2024-05-23	2026-09-21	9392278.33	190	\N	2	190
1018	25	2024-04-24	2026-04-27	82910.29	828	\N	2	828
1019	25	2024-07-21	2025-06-26	7539482.33	162	\N	2	162
1020	6	2024-07-28	2026-10-13	2257800.41	826	\N	2	826
1021	25	2024-02-13	2026-08-26	8813667.54	893	\N	2	893
1022	23	2024-02-19	2026-12-04	4321160.59	460	\N	2	460
1023	22	2024-12-23	2026-04-20	9892410.29	774	\N	2	774
1024	25	2024-10-14	2025-06-11	3478784.37	713	\N	2	713
1025	5	2024-04-13	2026-04-24	192999.20	927	\N	2	927
1026	22	2024-09-11	2026-10-07	1528349.25	188	\N	2	188
1027	22	2024-07-16	2026-06-07	8735376.60	827	\N	2	827
1028	24	2024-11-12	2025-09-15	9218826.07	143	\N	2	143
1029	5	2024-12-16	2026-11-21	7649348.66	397	\N	2	397
1030	8	2024-04-24	2026-02-18	791162.56	578	\N	2	578
1031	5	2024-07-22	2026-04-07	1125299.99	983	\N	2	983
1032	7	2024-08-08	2026-04-21	9050847.30	646	\N	2	646
1033	6	2024-02-04	2026-02-27	1644168.38	784	\N	2	784
1034	8	2024-10-14	2026-07-01	9542981.30	983	\N	2	983
1035	5	2024-07-15	2025-07-17	2599522.24	594	\N	2	594
1036	5	2024-09-03	2026-05-20	1817610.34	437	\N	2	437
1037	24	2024-06-30	2026-08-17	933850.41	349	\N	2	349
1038	22	2024-09-25	2026-01-24	6769195.84	943	\N	2	943
1039	25	2024-01-11	2026-08-20	9594278.40	282	\N	2	282
1040	7	2024-01-22	2026-04-21	9500128.86	886	\N	2	886
1041	22	2024-10-10	2026-02-18	3994521.81	209	\N	2	209
1042	24	2024-02-04	2026-09-09	9183476.32	492	\N	2	492
1043	24	2024-09-29	2026-05-02	9723823.60	992	\N	2	992
1044	22	2024-12-28	2026-07-31	2436381.82	969	\N	2	969
1045	7	2024-07-17	2025-07-08	3870452.68	18	\N	2	18
1046	8	2024-03-12	2026-04-24	1653594.77	686	\N	2	686
1047	5	2024-03-06	2026-04-05	563492.81	583	\N	2	583
1048	6	2024-12-27	2025-08-20	2150000.20	174	\N	2	174
1049	6	2024-01-03	2026-05-04	6310565.77	202	\N	2	202
1050	8	2024-02-24	2026-04-29	8810437.08	180	\N	2	180
1051	22	2024-10-16	2026-03-19	1676995.67	139	\N	2	139
1052	24	2024-11-06	2026-01-03	2120847.15	982	\N	2	982
1053	23	2024-09-23	2026-04-07	9411502.41	546	\N	2	546
1054	24	2024-04-09	2025-12-01	7124289.44	728	\N	2	728
1055	7	2024-07-06	2026-01-14	2561689.43	269	\N	2	269
1056	22	2024-04-05	2026-07-24	1706329.42	967	\N	2	967
1057	29	2024-06-10	2025-09-04	559373.81	221	\N	3	221
1058	9	2024-11-16	2026-07-17	7776074.26	532	\N	3	532
1059	10	2024-02-26	2026-11-04	3326665.06	608	\N	3	608
1060	27	2024-09-11	2025-07-03	3618125.63	355	\N	3	355
1061	26	2024-06-04	2026-04-24	4669488.27	800	\N	3	800
1062	11	2024-05-23	2026-01-09	3419006.19	354	\N	3	354
1063	28	2024-07-01	2026-10-03	3053715.89	454	\N	3	454
1064	40	2024-04-17	2025-06-16	6839528.03	964	\N	3	964
1065	28	2024-04-24	2026-12-06	61181.62	186	\N	3	186
1066	9	2024-11-26	2026-04-05	1940880.28	142	\N	3	142
1067	12	2024-04-23	2026-11-14	5334506.93	398	\N	3	398
1068	26	2024-07-16	2026-07-18	7078006.31	536	\N	3	536
1069	28	2024-08-05	2025-07-03	6939780.95	127	\N	3	127
1070	11	2024-08-23	2025-12-11	4797238.24	92	\N	3	92
1071	26	2024-12-27	2026-02-14	3842714.59	604	\N	3	604
1072	29	2024-09-08	2025-12-02	1010239.41	492	\N	3	492
1073	11	2024-09-30	2026-10-30	1395648.66	280	\N	3	280
1074	12	2024-10-23	2026-05-04	2176713.77	482	\N	3	482
1075	12	2024-05-29	2025-07-02	5181522.70	435	\N	3	435
1076	10	2024-08-21	2026-10-14	9946249.24	499	\N	3	499
1077	28	2024-09-15	2026-09-03	5554821.15	482	\N	3	482
1078	26	2024-02-24	2025-11-13	1645916.01	9	\N	3	9
1079	27	2024-06-30	2026-04-22	1044696.89	840	\N	3	840
1080	10	2024-08-21	2025-06-29	9252251.81	162	\N	3	162
1081	26	2024-12-18	2026-11-08	8932330.84	268	\N	3	268
1082	28	2024-08-17	2026-03-18	3234767.60	46	\N	3	46
1083	27	2024-11-12	2025-12-20	8147168.80	223	\N	3	223
1084	10	2024-11-13	2025-08-10	495900.65	224	\N	3	224
1085	11	2024-07-19	2025-09-25	9536084.05	160	\N	3	160
1086	10	2024-01-16	2026-12-02	4795147.24	297	\N	3	297
1087	27	2024-11-19	2026-09-05	435474.30	748	\N	3	748
1088	26	2024-05-03	2026-08-27	5415081.36	579	\N	3	579
1089	9	2024-05-20	2026-11-09	1354341.58	879	\N	3	879
1090	28	2024-01-27	2026-07-06	4975648.67	777	\N	3	777
1091	12	2024-05-08	2026-08-30	5691762.34	720	\N	3	720
1092	26	2024-06-13	2025-06-10	2676140.37	774	\N	3	774
1093	28	2024-04-11	2026-01-25	5514287.84	159	\N	3	159
1094	29	2024-12-09	2025-07-19	5204619.14	700	\N	3	700
1095	11	2024-07-04	2025-12-18	9031310.07	881	\N	3	881
1096	11	2024-02-06	2026-09-25	6436623.09	417	\N	3	417
1097	12	2024-05-04	2026-09-11	5091789.99	480	\N	3	480
1098	27	2024-11-15	2025-09-18	9129241.23	300	\N	3	300
1099	10	2024-12-06	2025-08-23	922405.75	678	\N	3	678
1100	29	2024-03-05	2026-10-14	7136216.07	966	\N	3	966
1101	28	2024-03-05	2026-11-21	6532745.82	101	\N	3	101
1102	28	2024-07-08	2026-01-08	2065585.58	473	\N	3	473
1103	12	2024-02-06	2026-05-10	8904590.78	386	\N	3	386
1104	28	2024-04-13	2026-11-19	8176873.57	615	\N	3	615
1105	11	2024-05-10	2026-04-13	4029313.22	336	\N	3	336
1106	27	2024-08-07	2025-08-22	1271359.66	6	\N	3	6
1107	40	2024-12-23	2025-11-09	7464657.86	145	\N	3	145
1108	27	2024-02-10	2026-07-02	8095647.49	536	\N	3	536
1109	26	2024-11-08	2026-07-11	1307485.45	381	\N	3	381
1110	11	2024-03-13	2025-10-24	2573054.71	959	\N	3	959
1111	28	2024-03-05	2026-10-08	405737.37	401	\N	3	401
1112	28	2024-12-05	2026-06-10	970067.69	526	\N	3	526
1113	10	2024-07-29	2025-12-15	5907910.91	536	\N	3	536
1114	28	2024-03-15	2025-09-24	5421297.66	386	\N	3	386
1115	11	2024-12-01	2025-07-27	3339831.24	463	\N	3	463
1116	9	2024-08-26	2026-03-31	7285508.65	884	\N	3	884
1117	29	2024-12-11	2026-08-13	6990519.27	484	\N	3	484
1118	12	2024-03-04	2026-05-15	907392.86	224	\N	3	224
1119	27	2024-04-28	2025-12-31	3065677.54	127	\N	3	127
1120	27	2024-07-10	2026-09-04	2299505.00	206	\N	3	206
1121	29	2024-11-15	2026-01-24	7274885.88	225	\N	3	225
1122	12	2024-07-14	2026-03-01	9248603.49	994	\N	3	994
1123	26	2024-12-21	2026-09-25	4693202.83	681	\N	3	681
1124	12	2024-03-22	2025-09-17	39216.50	569	\N	3	569
1125	12	2024-05-20	2026-08-11	3153025.72	976	\N	3	976
1126	12	2024-11-26	2026-06-11	2837745.27	19	\N	3	19
1127	40	2024-09-19	2026-10-04	9922087.37	254	\N	3	254
1128	10	2024-09-11	2026-01-05	9590125.11	856	\N	3	856
1129	11	2024-09-01	2026-07-22	7282512.63	165	\N	3	165
1130	27	2024-06-28	2026-01-31	7378482.79	608	\N	3	608
1131	12	2024-12-19	2026-11-14	3214168.93	605	\N	3	605
1132	10	2024-04-19	2025-07-29	4184020.19	862	\N	3	862
1133	29	2024-02-27	2026-11-24	6417442.07	748	\N	3	748
1134	12	2024-03-26	2026-03-01	9372835.41	153	\N	3	153
1135	9	2024-05-02	2025-11-22	4371607.00	873	\N	3	873
1136	11	2024-07-14	2026-11-17	9803605.59	906	\N	3	906
1137	28	2024-02-11	2026-10-26	4541914.16	755	\N	3	755
1138	29	2024-10-21	2025-09-26	1566145.43	41	\N	3	41
1139	11	2024-11-28	2025-09-30	6541332.68	875	\N	3	875
1140	29	2024-01-12	2026-10-22	9503524.39	565	\N	3	565
1141	40	2024-04-30	2026-05-31	7675862.33	761	\N	3	761
1142	9	2024-02-17	2026-03-23	8727843.79	329	\N	3	329
1143	10	2024-08-17	2026-08-14	1218125.89	1	\N	3	1
1144	29	2024-06-25	2026-03-21	8935908.52	9	\N	3	9
1145	40	2024-11-29	2026-06-11	652253.52	640	\N	3	640
1146	9	2024-08-29	2026-06-02	4319806.60	363	\N	3	363
1147	9	2024-07-30	2026-04-01	7262700.62	528	\N	3	528
1148	40	2024-08-08	2025-07-25	5756291.05	963	\N	3	963
1149	12	2024-05-15	2025-06-23	7225222.09	993	\N	3	993
1150	29	2024-01-14	2025-08-09	1879618.66	618	\N	3	618
1151	29	2024-03-31	2025-09-04	6957947.56	120	\N	3	120
1152	29	2024-01-15	2026-03-25	9422650.55	485	\N	3	485
1153	11	2024-07-26	2026-07-23	2460415.26	638	\N	3	638
1154	11	2024-11-24	2026-10-24	7790616.25	485	\N	3	485
1155	9	2024-04-24	2026-06-04	1875515.92	832	\N	3	832
1156	9	2024-08-17	2026-03-30	9054966.57	651	\N	3	651
1157	28	2024-01-03	2025-12-15	8084749.40	846	\N	3	846
1158	29	2024-01-28	2026-05-11	7117581.60	21	\N	3	21
1159	28	2024-09-29	2026-10-26	4251691.62	667	\N	3	667
1160	27	2024-05-13	2025-07-02	5594883.15	601	\N	3	601
1161	26	2024-02-06	2025-09-13	4499110.51	836	\N	3	836
1162	28	2024-10-13	2026-06-02	3305935.91	886	\N	3	886
1163	40	2024-10-18	2026-04-19	9119328.52	730	\N	3	730
1164	9	2024-05-12	2025-10-12	6592371.64	317	\N	3	317
1165	26	2024-12-19	2025-09-16	8159721.89	564	\N	3	564
1166	10	2024-09-09	2025-11-09	3767911.47	254	\N	3	254
1167	12	2024-11-04	2026-01-01	6995923.77	599	\N	3	599
1168	12	2024-05-20	2025-11-04	1276440.95	852	\N	3	852
1169	26	2024-04-06	2025-07-16	7743174.71	194	\N	3	194
1170	40	2024-04-11	2025-10-20	9578426.57	332	\N	3	332
1171	40	2024-12-07	2026-05-09	8682100.27	221	\N	3	221
1172	9	2024-12-05	2026-10-27	3270523.22	710	\N	3	710
1173	9	2024-01-16	2026-06-17	2889235.40	150	\N	3	150
1174	28	2024-10-12	2025-12-26	9665994.68	625	\N	3	625
1175	40	2024-11-03	2025-07-13	1864404.53	443	\N	3	443
1176	27	2024-05-04	2026-06-02	9940114.49	409	\N	3	409
1177	29	2024-04-06	2026-07-05	6262852.38	241	\N	3	241
1178	28	2024-10-19	2025-12-18	3911182.97	544	\N	3	544
1179	29	2024-09-05	2025-09-12	932920.32	59	\N	3	59
1180	29	2024-06-04	2025-07-19	4614865.07	15	\N	3	15
1181	27	2024-09-17	2025-06-29	8688360.37	454	\N	3	454
1182	11	2024-05-10	2025-11-08	2072088.93	794	\N	3	794
1183	28	2024-09-26	2026-04-21	3604277.67	35	\N	3	35
1184	11	2024-03-29	2026-09-09	554949.96	331	\N	3	331
1185	9	2024-08-03	2025-06-19	7716202.65	570	\N	3	570
1186	26	2024-10-05	2026-02-16	6815724.70	225	\N	3	225
1187	28	2024-12-28	2025-08-28	421962.84	268	\N	3	268
1188	28	2024-03-08	2026-01-25	59919.10	948	\N	3	948
1189	10	2024-10-03	2026-04-10	3894305.34	35	\N	3	35
1190	10	2024-05-22	2026-08-06	3704200.51	370	\N	3	370
1191	28	2024-04-30	2026-04-09	6319872.64	372	\N	3	372
1192	40	2024-09-27	2025-09-15	6350174.36	641	\N	3	641
1193	12	2024-09-12	2026-01-31	7440530.23	43	\N	3	43
1194	26	2024-08-27	2026-07-11	5690574.21	854	\N	3	854
1195	9	2024-01-28	2026-04-26	2953580.29	87	\N	3	87
1196	9	2024-08-28	2026-11-20	4569875.16	326	\N	3	326
1197	10	2024-07-26	2026-12-16	3587234.44	635	\N	3	635
1198	28	2024-01-01	2026-02-25	23332.25	614	\N	3	614
1199	9	2024-10-24	2025-06-26	1934476.61	221	\N	3	221
1200	29	2024-10-10	2025-07-16	9053249.04	736	\N	3	736
1201	10	2024-12-09	2025-09-05	4012578.26	494	\N	3	494
1202	10	2024-12-29	2026-06-02	6012535.44	561	\N	3	561
1203	40	2024-05-24	2025-11-15	1731985.58	752	\N	3	752
1204	12	2024-11-24	2026-07-18	8415726.31	228	\N	3	228
1205	28	2024-09-28	2026-02-08	4504975.30	219	\N	3	219
1206	29	2024-02-24	2026-02-22	5787623.67	143	\N	3	143
1207	28	2024-12-17	2026-01-17	9477005.20	645	\N	3	645
1208	12	2024-12-26	2026-11-30	4076151.82	763	\N	3	763
1209	12	2024-10-26	2025-10-22	5850059.03	154	\N	3	154
1210	29	2024-04-10	2025-10-07	5120334.93	624	\N	3	624
1211	10	2024-04-11	2025-12-19	9786680.45	670	\N	3	670
1212	11	2024-03-30	2026-01-02	4892894.18	741	\N	3	741
1213	26	2024-06-20	2026-04-21	1797258.13	200	\N	3	200
1214	11	2024-01-22	2025-08-22	7430660.04	836	\N	3	836
1215	9	2024-12-04	2026-04-30	9892607.21	204	\N	3	204
1216	26	2024-01-22	2026-05-16	6052447.08	847	\N	3	847
1217	10	2024-05-19	2025-06-21	8413285.64	380	\N	3	380
1218	26	2024-12-07	2026-09-10	6929492.76	151	\N	3	151
1219	12	2024-10-01	2025-08-13	7816468.48	324	\N	3	324
1220	9	2024-06-21	2026-06-01	6076079.90	17	\N	3	17
1221	40	2024-04-10	2026-12-24	4661533.53	851	\N	3	851
1222	9	2024-03-10	2026-03-30	43317.80	212	\N	3	212
1223	26	2024-08-06	2025-11-11	7885085.21	846	\N	3	846
1224	11	2024-06-17	2025-06-08	2150169.38	855	\N	3	855
1225	29	2024-08-16	2025-07-20	1357189.25	76	\N	3	76
1226	29	2024-06-09	2026-06-21	3338892.25	300	\N	3	300
1227	29	2024-12-30	2026-03-11	4480003.42	225	\N	3	225
1228	26	2024-02-11	2026-05-19	7858021.97	364	\N	3	364
1229	11	2024-05-01	2026-07-04	4861505.19	429	\N	3	429
1230	11	2024-12-09	2026-04-22	6688199.90	976	\N	3	976
1231	29	2024-06-11	2025-07-28	4046044.71	501	\N	3	501
1232	28	2024-04-04	2026-03-25	8577912.51	446	\N	3	446
1233	11	2024-11-05	2026-12-27	3447268.13	2	\N	3	2
1234	27	2024-09-16	2026-11-26	1581925.93	497	\N	3	497
1235	9	2024-03-30	2026-05-18	5267144.66	1000	\N	3	1000
1236	10	2024-07-08	2026-06-08	9074689.84	599	\N	3	599
1237	28	2024-10-18	2026-07-25	4897907.21	143	\N	3	143
1238	26	2024-08-28	2026-08-25	2906434.02	560	\N	3	560
1239	26	2024-06-30	2025-11-12	7759657.65	708	\N	3	708
1240	9	2024-07-21	2026-09-16	7182329.35	50	\N	3	50
1241	12	2024-12-23	2026-06-07	8883823.25	972	\N	3	972
1242	10	2024-11-16	2025-11-09	3837942.84	928	\N	3	928
1243	12	2024-04-13	2026-06-08	3641297.80	340	\N	3	340
1244	10	2024-06-02	2025-07-17	180261.52	299	\N	3	299
1245	10	2024-01-22	2026-03-10	8157669.17	569	\N	3	569
1246	11	2024-09-19	2026-09-14	791295.71	331	\N	3	331
1247	9	2024-10-02	2026-08-19	5647729.44	813	\N	3	813
1248	12	2024-08-27	2026-03-22	9186641.80	102	\N	3	102
1249	11	2024-09-13	2025-08-07	8470421.80	364	\N	3	364
1250	40	2024-05-25	2025-06-18	7497865.60	678	\N	3	678
1251	12	2024-07-30	2025-07-04	2116984.23	922	\N	3	922
1252	29	2024-10-20	2026-11-15	5252239.27	293	\N	3	293
1253	10	2024-08-18	2026-02-02	6701717.05	6	\N	3	6
1254	40	2024-01-18	2025-10-31	7522516.36	864	\N	3	864
1255	10	2024-10-23	2025-09-06	3436275.26	580	\N	3	580
1256	26	2024-03-10	2026-10-27	3942737.94	619	\N	3	619
1257	40	2024-04-08	2026-10-24	3273697.98	25	\N	3	25
1258	11	2024-02-21	2026-10-23	8488425.42	913	\N	3	913
1259	26	2024-03-07	2025-09-12	9436660.12	340	\N	3	340
1260	26	2024-12-30	2026-05-04	6193803.62	498	\N	3	498
1261	11	2024-06-23	2026-02-13	6728804.88	330	\N	3	330
1262	27	2024-06-22	2026-02-26	4803369.15	278	\N	3	278
1263	40	2024-01-26	2025-08-09	6157979.79	200	\N	3	200
1264	26	2024-04-12	2025-06-26	5446986.51	301	\N	3	301
1265	26	2024-08-28	2025-11-18	4336631.83	825	\N	3	825
1266	26	2024-12-14	2026-04-22	7328137.90	724	\N	3	724
1267	26	2024-08-16	2025-09-14	1622929.82	943	\N	3	943
1268	12	2024-06-16	2026-12-15	4459297.74	182	\N	3	182
1269	27	2024-05-13	2025-10-29	3977024.74	791	\N	3	791
1270	11	2024-08-19	2026-05-26	5701732.25	883	\N	3	883
1271	26	2024-05-21	2026-11-17	8905491.06	691	\N	3	691
1272	11	2024-02-04	2026-05-01	1802228.46	125	\N	3	125
1273	10	2024-12-09	2026-03-24	2857567.34	116	\N	3	116
1274	28	2024-10-22	2026-06-02	5819526.79	758	\N	3	758
1275	26	2024-03-11	2025-09-17	5191834.91	813	\N	3	813
1276	11	2024-04-02	2026-02-05	2271342.20	236	\N	3	236
1277	27	2024-09-16	2025-06-12	8338993.29	38	\N	3	38
1278	26	2024-04-18	2026-05-08	1478113.04	52	\N	3	52
1279	27	2024-07-24	2025-12-23	420097.34	156	\N	3	156
1280	9	2024-03-22	2025-08-13	2698693.39	263	\N	3	263
1281	11	2024-07-24	2025-12-16	1349247.80	3	\N	3	3
1282	26	2024-12-12	2026-05-09	5584210.62	920	\N	3	920
1283	9	2024-06-19	2026-07-18	6894291.74	668	\N	3	668
1284	28	2024-12-01	2025-06-16	582665.00	322	\N	3	322
1285	27	2024-01-02	2026-07-31	7526137.01	761	\N	3	761
1286	29	2024-01-28	2026-11-04	6560393.63	385	\N	3	385
1287	9	2024-09-12	2026-12-05	81094.48	878	\N	3	878
1288	9	2024-11-11	2026-12-13	2870021.05	249	\N	3	249
1289	10	2024-02-13	2026-04-24	5730779.79	828	\N	3	828
1290	26	2024-08-26	2026-03-22	2159597.23	908	\N	3	908
1291	29	2024-06-17	2026-02-13	676352.60	381	\N	3	381
1292	9	2024-04-17	2026-07-05	5529926.05	323	\N	3	323
1293	28	2024-06-15	2026-12-23	9918413.12	701	\N	3	701
1294	10	2024-10-13	2025-09-01	1738839.29	594	\N	3	594
1295	40	2024-05-24	2026-01-02	1696719.33	794	\N	3	794
1296	29	2024-10-27	2026-04-09	8906179.82	561	\N	3	561
1297	12	2024-01-07	2026-06-19	8355497.94	184	\N	3	184
1298	27	2024-07-04	2025-11-18	9780564.53	630	\N	3	630
1299	28	2024-04-05	2026-06-02	2132517.39	700	\N	3	700
1300	26	2024-11-20	2025-06-27	2040293.42	957	\N	3	957
1301	26	2024-02-20	2026-11-25	2375457.50	713	\N	3	713
1302	10	2024-09-02	2026-05-24	6381617.75	142	\N	3	142
1303	9	2024-01-24	2026-03-02	576647.10	659	\N	3	659
1304	12	2024-08-16	2026-01-06	9766049.08	769	\N	3	769
1305	40	2024-02-05	2025-07-07	4672116.36	866	\N	3	866
1306	9	2024-02-01	2026-07-30	8087435.64	226	\N	3	226
1307	10	2024-01-15	2025-09-29	1649146.78	836	\N	3	836
1308	10	2024-12-21	2026-09-01	3732948.49	553	\N	3	553
1309	28	2024-07-23	2026-07-26	3222851.24	939	\N	3	939
1310	10	2024-10-06	2026-11-26	3804428.14	255	\N	3	255
1311	26	2024-08-09	2026-03-25	7046529.65	335	\N	3	335
1312	28	2024-03-12	2026-09-16	6264596.09	173	\N	3	173
1313	11	2024-05-20	2025-08-29	4302603.52	653	\N	3	653
1314	10	2024-05-13	2025-08-10	1647948.59	963	\N	3	963
1315	12	2024-11-08	2026-08-13	495809.62	296	\N	3	296
1316	11	2024-12-13	2026-10-30	574880.41	970	\N	3	970
1317	27	2024-03-11	2025-10-28	3311555.27	353	\N	3	353
1318	12	2024-08-31	2026-05-22	7934139.57	166	\N	3	166
1319	27	2024-08-24	2025-09-22	8401986.57	749	\N	3	749
1320	10	2024-10-02	2026-02-13	8347629.46	682	\N	3	682
1321	10	2024-11-09	2026-04-11	9608069.55	197	\N	3	197
1322	29	2024-04-24	2026-09-16	8345918.33	93	\N	3	93
1323	10	2024-11-25	2025-07-09	6059115.91	637	\N	3	637
1324	11	2024-03-18	2026-07-04	2584522.91	840	\N	3	840
1325	12	2024-03-29	2025-10-10	8434085.09	317	\N	3	317
1326	26	2024-05-04	2025-10-25	8299232.77	990	\N	3	990
1327	29	2024-11-05	2026-02-03	8902874.02	900	\N	3	900
1328	40	2024-09-13	2026-12-22	2886104.28	158	\N	3	158
1329	9	2024-10-05	2026-05-04	4634984.73	77	\N	3	77
1330	10	2024-02-25	2026-07-21	4948978.34	907	\N	3	907
1331	40	2024-01-22	2026-10-09	5310408.43	655	\N	3	655
1332	10	2024-10-14	2025-08-01	254479.60	497	\N	3	497
1333	12	2024-02-19	2026-07-08	9816906.43	846	\N	3	846
1334	11	2024-02-26	2026-07-24	6246279.86	435	\N	3	435
1335	27	2024-05-14	2025-08-24	867759.60	95	\N	3	95
1336	12	2024-02-20	2026-09-14	4877518.66	584	\N	3	584
1337	40	2024-07-30	2025-11-30	1454343.10	965	\N	3	965
1338	26	2024-01-07	2026-04-04	4602348.00	112	\N	3	112
1339	12	2024-07-28	2026-03-17	5011989.53	64	\N	3	64
1340	29	2024-03-15	2025-09-12	2021392.66	138	\N	3	138
1341	9	2024-03-13	2026-07-10	5050236.02	350	\N	3	350
1342	27	2024-09-21	2025-07-13	5364298.21	166	\N	3	166
1343	11	2024-07-19	2025-11-20	8343236.98	28	\N	3	28
1344	11	2024-01-09	2026-03-08	363972.01	617	\N	3	617
1345	26	2024-05-23	2026-12-12	294666.17	501	\N	3	501
1346	27	2024-08-14	2026-08-04	4241809.46	444	\N	3	444
1347	9	2024-03-28	2026-07-24	938759.69	431	\N	3	431
1348	26	2024-03-02	2026-11-02	1350351.78	196	\N	3	196
1349	26	2024-09-02	2026-02-14	7005801.78	124	\N	3	124
1350	27	2024-05-12	2026-07-10	6183671.45	335	\N	3	335
1351	40	2024-07-03	2025-10-15	5951734.52	588	\N	3	588
1352	10	2024-01-19	2025-07-25	1732777.15	856	\N	3	856
1353	11	2024-10-01	2026-05-19	7660693.10	14	\N	3	14
1354	28	2024-07-11	2026-05-19	6521621.71	105	\N	3	105
1355	26	2024-10-25	2026-08-24	9952125.03	573	\N	3	573
1356	9	2024-11-07	2025-10-06	7631362.62	615	\N	3	615
1357	9	2024-12-02	2025-08-14	4943255.22	341	\N	3	341
1358	29	2024-07-06	2026-03-26	931155.53	223	\N	3	223
1359	11	2024-06-07	2026-06-29	7927416.42	75	\N	3	75
1360	11	2024-01-07	2026-02-24	3679061.60	108	\N	3	108
1361	29	2024-03-19	2026-08-07	9188329.93	363	\N	3	363
1362	40	2024-02-11	2026-12-08	7947533.65	115	\N	3	115
1363	29	2024-06-21	2026-11-08	9639652.36	460	\N	3	460
1364	28	2024-04-27	2026-02-01	2656643.68	473	\N	3	473
1365	10	2024-10-05	2025-08-30	5056817.87	963	\N	3	963
1366	12	2024-06-26	2025-10-22	4358475.18	941	\N	3	941
1367	29	2024-04-13	2026-10-07	1763010.32	583	\N	3	583
1368	12	2024-04-19	2025-06-07	8494430.14	878	\N	3	878
1369	10	2024-07-28	2026-03-05	1913135.53	938	\N	3	938
1370	11	2024-09-18	2026-01-11	7633503.39	791	\N	3	791
1371	27	2024-06-06	2026-08-02	6757036.25	488	\N	3	488
1372	11	2024-03-26	2025-09-08	2575357.93	900	\N	3	900
1373	29	2024-11-25	2026-07-30	7975831.48	75	\N	3	75
1374	26	2024-02-17	2026-09-19	5697411.22	254	\N	3	254
1375	40	2024-04-13	2026-07-27	3813667.30	582	\N	3	582
1376	29	2024-07-28	2026-04-10	7338473.77	187	\N	3	187
1377	11	2024-10-30	2025-07-01	5691541.76	745	\N	3	745
1378	10	2024-04-24	2026-02-16	374096.81	728	\N	3	728
1379	12	2024-10-11	2025-09-15	8409729.97	35	\N	3	35
1380	10	2024-04-23	2025-12-12	7280054.68	179	\N	3	179
1381	40	2024-05-23	2025-06-17	6873335.24	362	\N	3	362
1382	10	2024-01-26	2026-06-30	5115064.04	90	\N	3	90
1383	9	2024-10-16	2026-11-20	4628019.01	666	\N	3	666
1384	26	2024-08-16	2026-10-16	923190.85	804	\N	3	804
1385	28	2024-07-24	2025-08-29	9598522.54	83	\N	3	83
1386	27	2024-03-28	2026-06-25	9830691.99	967	\N	3	967
1387	12	2024-09-01	2026-11-28	8230876.20	317	\N	3	317
1388	10	2024-11-14	2026-07-04	5781337.20	879	\N	3	879
1389	26	2024-01-11	2025-11-01	5787799.61	364	\N	3	364
1390	29	2024-01-16	2025-09-04	3999396.92	747	\N	3	747
1391	12	2024-12-06	2026-03-16	3147358.97	18	\N	3	18
1392	27	2024-09-21	2026-01-19	8431595.58	921	\N	3	921
1393	26	2024-04-11	2026-01-21	4541025.65	553	\N	3	553
1394	26	2024-03-12	2026-07-17	2708294.33	199	\N	3	199
1395	29	2024-10-15	2025-06-14	3278531.56	319	\N	3	319
1396	10	2024-05-20	2026-04-29	469640.86	286	\N	3	286
1397	11	2024-02-11	2026-07-24	8840115.07	567	\N	3	567
1398	12	2024-05-10	2025-07-27	7026793.56	562	\N	3	562
1399	11	2024-05-16	2025-12-30	4865851.95	429	\N	3	429
1400	11	2024-09-23	2026-12-10	5736592.77	349	\N	3	349
1401	26	2024-02-21	2026-12-19	3602013.22	6	\N	3	6
1402	28	2024-09-01	2026-05-07	3533691.13	792	\N	3	792
1403	11	2024-01-30	2026-05-04	9856067.65	75	\N	3	75
1404	40	2024-05-19	2025-10-05	1647837.09	124	\N	3	124
1405	9	2024-12-26	2026-06-12	6844319.10	318	\N	3	318
1406	28	2024-08-23	2025-06-24	6920265.84	321	\N	3	321
1407	12	2024-08-31	2026-02-05	4929469.25	127	\N	3	127
1408	11	2024-05-07	2026-06-29	3063894.76	128	\N	3	128
1409	40	2024-09-03	2026-06-09	4364065.55	266	\N	3	266
1410	10	2024-03-11	2026-03-26	4587132.90	718	\N	3	718
1411	12	2024-11-17	2025-10-20	9708651.67	122	\N	3	122
1412	10	2024-03-03	2025-06-15	494580.44	40	\N	3	40
1413	28	2024-05-13	2025-11-05	9798609.83	465	\N	3	465
1414	26	2024-10-15	2026-11-17	765319.86	49	\N	3	49
1415	26	2024-07-20	2025-07-30	224774.35	620	\N	3	620
1416	9	2024-07-09	2026-09-29	4673877.72	557	\N	3	557
1417	40	2024-07-16	2025-06-10	3002395.24	176	\N	3	176
1418	11	2024-12-26	2025-08-14	7969461.58	9	\N	3	9
1419	12	2024-08-25	2026-03-09	7272097.02	281	\N	3	281
1420	11	2024-04-28	2025-10-29	4765628.57	733	\N	3	733
1421	9	2024-10-05	2026-06-13	5160240.54	498	\N	3	498
1422	26	2024-08-12	2026-02-22	4514802.21	626	\N	3	626
1423	10	2024-11-01	2026-04-09	5915446.97	406	\N	3	406
1424	28	2024-10-16	2026-11-20	7269657.89	543	\N	3	543
1425	40	2024-02-26	2025-12-17	1706097.09	349	\N	3	349
1426	10	2024-11-25	2026-02-03	5664246.69	745	\N	3	745
1427	26	2024-09-05	2026-03-14	7082866.65	193	\N	3	193
1428	28	2024-06-10	2026-07-04	1187671.61	918	\N	3	918
1429	11	2024-03-07	2025-07-28	8047711.88	93	\N	3	93
1430	28	2024-03-05	2026-09-22	8477391.59	534	\N	3	534
1431	29	2024-03-05	2026-01-09	2000060.40	97	\N	3	97
1432	27	2024-12-16	2026-09-12	557452.74	117	\N	3	117
1433	27	2024-12-07	2026-10-09	7235185.17	806	\N	3	806
1434	11	2024-07-23	2026-08-19	6044697.06	87	\N	3	87
1435	40	2024-06-01	2026-02-22	651097.81	360	\N	3	360
1436	40	2024-05-14	2026-05-27	9910229.32	598	\N	3	598
1437	40	2024-08-23	2026-03-24	4895376.21	994	\N	3	994
1438	10	2024-05-03	2026-06-20	1073169.69	211	\N	3	211
1439	26	2024-07-27	2025-12-29	9270331.46	753	\N	3	753
1440	11	2024-11-07	2025-08-01	3522076.25	793	\N	3	793
1441	9	2024-07-18	2025-09-28	6653636.53	371	\N	3	371
1442	12	2024-03-19	2026-11-19	9309765.15	656	\N	3	656
1443	27	2024-01-28	2025-07-04	2320336.95	944	\N	3	944
1444	26	2024-08-19	2025-07-12	5273424.19	756	\N	3	756
1445	29	2024-06-12	2026-05-12	6698177.26	852	\N	3	852
1446	11	2024-07-26	2026-05-20	3108440.65	673	\N	3	673
1447	40	2024-11-15	2026-02-24	1677277.76	816	\N	3	816
1448	27	2024-10-30	2026-04-27	3216218.64	144	\N	3	144
1449	27	2024-04-26	2026-06-19	9640457.00	807	\N	3	807
1450	12	2024-12-19	2025-08-07	4736063.22	494	\N	3	494
1451	12	2024-04-18	2025-10-16	4898318.26	590	\N	3	590
1452	26	2024-03-04	2025-11-25	6901131.60	465	\N	3	465
1453	28	2024-12-16	2026-12-29	1624014.33	746	\N	3	746
1454	27	2024-03-12	2026-11-02	199467.17	617	\N	3	617
1455	10	2024-10-24	2025-11-28	2207632.15	488	\N	3	488
1456	40	2024-01-26	2026-10-23	7141741.88	770	\N	3	770
1457	12	2024-09-20	2026-01-24	8550425.51	977	\N	3	977
1458	29	2024-04-22	2025-11-09	1501293.33	958	\N	3	958
1459	9	2024-11-18	2026-07-21	1593346.75	437	\N	3	437
1460	26	2024-01-04	2025-09-12	8244285.11	46	\N	3	46
1461	9	2024-03-17	2026-04-29	9399065.60	17	\N	3	17
1462	12	2024-08-09	2026-09-13	5952635.21	789	\N	3	789
1463	9	2024-12-07	2026-12-28	3740623.29	100	\N	3	100
1464	11	2024-07-23	2026-04-03	7589057.96	452	\N	3	452
1465	12	2024-04-25	2026-02-21	6408429.05	696	\N	3	696
1466	27	2024-08-10	2026-12-03	4581248.84	89	\N	3	89
1467	11	2024-06-30	2025-11-09	1629173.06	228	\N	3	228
1468	9	2024-06-29	2026-07-23	2819499.28	867	\N	3	867
1469	12	2024-08-20	2025-08-01	3420724.27	577	\N	3	577
1470	10	2024-04-11	2026-11-06	7073661.75	307	\N	3	307
1471	27	2024-02-20	2026-12-23	7451836.19	128	\N	3	128
1472	29	2024-10-07	2025-08-07	5483502.01	636	\N	3	636
1473	27	2024-12-02	2026-12-05	8134392.13	755	\N	3	755
1474	29	2024-05-14	2025-06-27	3060107.01	186	\N	3	186
1475	10	2024-09-16	2025-11-23	7113550.39	122	\N	3	122
1476	29	2024-09-15	2025-08-20	5667758.38	699	\N	3	699
1477	28	2024-09-21	2026-09-21	182383.15	98	\N	3	98
1478	28	2024-03-16	2025-11-15	3630347.52	532	\N	3	532
1479	11	2024-12-21	2026-05-15	9948208.55	785	\N	3	785
1480	26	2024-09-13	2026-08-29	7275387.85	209	\N	3	209
1481	9	2024-07-24	2025-11-03	6081230.93	501	\N	3	501
1482	28	2024-09-10	2025-08-17	8559978.74	307	\N	3	307
1483	40	2024-02-03	2026-11-03	2124197.65	544	\N	3	544
1484	9	2024-06-01	2026-10-05	9958641.78	752	\N	3	752
1485	11	2024-09-09	2025-06-19	2902499.97	55	\N	3	55
1486	27	2024-05-04	2025-10-06	9424283.44	55	\N	3	55
1487	28	2024-11-29	2026-02-02	2986829.51	961	\N	3	961
1488	10	2024-12-09	2026-11-10	8207727.35	927	\N	3	927
1489	27	2024-10-28	2026-11-06	1150065.83	416	\N	3	416
1490	28	2024-05-17	2026-12-08	1833727.80	793	\N	3	793
1491	10	2024-04-15	2026-09-11	8077180.84	827	\N	3	827
1492	9	2024-06-10	2026-07-06	3212037.05	346	\N	3	346
1493	40	2024-04-24	2026-11-17	1889488.09	819	\N	3	819
1494	12	2024-09-09	2026-09-20	6451563.44	710	\N	3	710
1495	12	2024-01-08	2026-07-14	4111518.13	56	\N	3	56
1496	9	2024-04-14	2026-08-08	5086447.53	424	\N	3	424
1497	10	2024-05-15	2026-05-24	8135046.76	517	\N	3	517
1498	27	2024-03-28	2026-06-24	7943090.46	844	\N	3	844
1499	10	2024-06-12	2025-11-06	4706388.79	963	\N	3	963
1500	28	2024-04-30	2026-06-24	9887129.85	871	\N	3	871
1501	9	2024-01-18	2026-09-05	9041189.78	328	\N	3	328
1502	40	2024-10-06	2026-06-09	3016859.29	869	\N	3	869
1503	29	2024-02-18	2026-12-04	6821721.75	542	\N	3	542
1504	11	2024-10-04	2026-01-24	970746.37	400	\N	3	400
1505	12	2024-06-17	2026-02-04	1225207.64	111	\N	3	111
1506	29	2024-11-08	2025-12-17	7572408.95	737	\N	3	737
1507	9	2024-05-14	2026-05-08	6684749.73	444	\N	3	444
1508	29	2024-10-06	2026-07-11	5343408.53	909	\N	3	909
1509	29	2024-12-22	2026-09-02	73554.13	970	\N	3	970
1510	40	2024-03-04	2025-08-19	7774949.01	855	\N	3	855
1511	28	2024-12-12	2026-11-08	7504831.25	527	\N	3	527
1512	27	2024-06-09	2026-06-13	2874849.20	10	\N	3	10
1513	9	2024-08-27	2026-01-11	8220078.58	810	\N	3	810
1514	12	2024-01-30	2026-07-06	5495200.07	842	\N	3	842
1515	27	2024-03-25	2025-12-11	5654353.01	774	\N	3	774
1516	10	2024-02-24	2025-07-25	9446521.85	46	\N	3	46
1517	26	2024-09-10	2026-03-01	2443850.65	621	\N	3	621
1518	29	2024-03-25	2026-04-11	2951107.69	581	\N	3	581
1519	40	2024-05-21	2026-10-15	9987749.70	136	\N	3	136
1520	27	2024-11-23	2026-03-08	9427298.30	654	\N	3	654
1521	12	2024-05-18	2025-07-08	7312887.08	494	\N	3	494
1522	40	2024-04-11	2025-09-15	4314346.36	538	\N	3	538
1523	10	2024-10-14	2025-09-03	946122.54	319	\N	3	319
1524	9	2024-07-17	2026-03-14	4389411.64	186	\N	3	186
1525	10	2024-11-07	2026-02-01	9595871.84	741	\N	3	741
1526	28	2024-11-12	2026-05-02	150536.64	697	\N	3	697
1527	11	2024-12-03	2026-12-22	8431846.29	918	\N	3	918
1528	10	2024-05-15	2025-11-03	9374963.65	461	\N	3	461
1529	10	2024-04-28	2026-09-01	1835388.01	623	\N	3	623
1530	28	2024-07-09	2025-12-22	6092127.56	714	\N	3	714
1531	27	2024-01-04	2026-06-21	7288634.09	623	\N	3	623
1532	27	2024-04-13	2025-12-30	9653988.29	68	\N	3	68
1533	11	2024-10-03	2025-08-29	9536018.71	495	\N	3	495
1534	26	2024-02-25	2026-10-10	8562927.89	103	\N	3	103
1535	26	2024-10-04	2026-12-22	5145500.41	795	\N	3	795
1536	12	2024-12-22	2026-04-21	3061401.79	169	\N	3	169
1537	27	2024-04-08	2026-04-05	5543709.50	578	\N	3	578
1538	12	2024-05-01	2026-11-24	9818123.33	186	\N	3	186
1539	12	2024-04-26	2026-08-11	5799805.31	421	\N	3	421
1540	9	2024-11-15	2026-12-03	3674592.04	417	\N	3	417
1541	28	2024-05-03	2026-08-26	6003103.73	50	\N	3	50
1542	10	2024-07-23	2025-10-15	7413825.14	892	\N	3	892
1543	40	2024-07-24	2026-08-14	2722878.43	124	\N	3	124
1544	28	2024-07-01	2026-04-19	2646732.77	273	\N	3	273
1545	28	2024-10-06	2025-11-09	7155536.90	390	\N	3	390
1546	40	2024-10-30	2025-07-12	9237822.09	301	\N	3	301
1547	9	2024-06-24	2026-09-04	7779000.69	946	\N	3	946
1548	10	2024-05-10	2026-05-17	3875922.84	47	\N	3	47
1549	29	2024-05-02	2025-07-27	8388510.27	408	\N	3	408
1550	28	2024-04-25	2026-03-21	9830438.65	733	\N	3	733
1551	9	2024-04-18	2026-09-23	881220.08	669	\N	3	669
1552	28	2024-03-10	2026-10-01	7167651.05	962	\N	3	962
1553	12	2024-11-17	2025-08-09	4664271.05	743	\N	3	743
1554	28	2024-07-14	2026-09-25	2917350.69	367	\N	3	367
1555	40	2024-10-15	2026-04-29	5059145.84	415	\N	3	415
1556	12	2024-02-22	2025-08-17	8893187.60	989	\N	3	989
1565	15	2024-09-12	\N	2492873.54	934	\N	4	934
1566	13	2024-04-20	\N	6522548.85	896	\N	4	896
1567	32	2024-03-01	\N	5509641.17	604	\N	4	604
1568	31	2024-11-16	\N	1780809.92	367	\N	4	367
1569	33	2024-06-06	\N	7080255.22	203	\N	4	203
1570	30	2024-08-03	\N	2077010.53	205	\N	4	205
1571	31	2024-11-18	\N	6585943.39	983	\N	4	983
1572	30	2024-02-02	\N	1117208.63	762	\N	4	762
1573	30	2024-06-21	\N	6601929.14	536	\N	4	536
1574	32	2024-03-05	\N	9698487.50	836	\N	4	836
1575	15	2024-09-09	\N	5019410.53	332	\N	4	332
1576	32	2024-08-31	\N	9772764.75	336	\N	4	336
1577	32	2024-01-08	\N	4571774.89	495	\N	4	495
1578	30	2024-03-29	\N	8169571.96	263	\N	4	263
1579	31	2024-03-15	\N	4941603.79	732	\N	4	732
1580	31	2024-05-27	\N	9996051.22	936	\N	4	936
1581	33	2024-06-26	\N	544780.41	629	\N	4	629
1582	33	2024-03-15	\N	9801722.31	657	\N	4	657
1583	16	2024-05-24	\N	7559241.67	532	\N	4	532
1584	30	2024-06-27	\N	4670708.40	704	\N	4	704
1585	30	2024-04-02	\N	1939059.19	390	\N	4	390
1586	13	2024-08-04	\N	1018979.82	970	\N	4	970
1587	13	2024-06-08	\N	616010.66	674	\N	4	674
1588	13	2024-11-27	\N	9968862.15	619	\N	4	619
1589	30	2024-12-31	\N	4710711.69	964	\N	4	964
1590	14	2024-02-07	\N	4771595.60	653	\N	4	653
1591	15	2024-12-12	\N	1344940.17	108	\N	4	108
1592	14	2024-12-26	\N	9307726.14	790	\N	4	790
1593	13	2024-08-23	\N	646091.28	754	\N	4	754
1594	32	2024-07-19	\N	8673737.00	297	\N	4	297
1595	33	2024-08-22	\N	3402873.70	282	\N	4	282
1596	31	2024-05-20	\N	8037369.31	95	\N	4	95
1597	16	2024-09-25	\N	6076318.85	122	\N	4	122
1598	30	2024-05-07	\N	6714553.09	998	\N	4	998
1599	15	2024-08-26	\N	3898511.32	765	\N	4	765
1600	33	2024-07-12	\N	842652.90	650	\N	4	650
1601	14	2024-09-09	\N	1158353.92	352	\N	4	352
1602	31	2024-07-03	\N	276286.88	857	\N	4	857
1603	30	2024-02-02	\N	8091963.88	134	\N	4	134
1604	30	2024-04-10	\N	2111963.27	538	\N	4	538
1605	14	2024-08-14	\N	3179630.89	116	\N	4	116
1606	16	2024-07-04	\N	6532477.14	4	\N	4	4
1607	15	2024-02-26	\N	7946704.66	147	\N	4	147
1608	15	2024-09-04	\N	7979475.16	591	\N	4	591
1609	15	2024-10-06	\N	9443025.42	284	\N	4	284
1610	15	2024-10-22	\N	5085828.47	810	\N	4	810
1611	14	2024-03-10	\N	2715353.07	328	\N	4	328
1612	32	2024-08-14	\N	7764969.03	366	\N	4	366
1613	33	2024-05-09	\N	4174528.29	898	\N	4	898
1614	32	2024-02-22	\N	7991699.79	810	\N	4	810
1615	32	2024-11-21	\N	1848399.86	262	\N	4	262
1616	15	2024-04-20	\N	139266.31	537	\N	4	537
1617	31	2024-11-05	\N	8722421.36	193	\N	4	193
1618	16	2024-01-28	\N	5785743.27	366	\N	4	366
1619	13	2024-05-06	\N	6366054.18	523	\N	4	523
1620	30	2024-10-19	\N	7785876.58	664	\N	4	664
1621	32	2024-11-16	\N	9184419.10	672	\N	4	672
1622	33	2024-05-11	\N	4285537.29	684	\N	4	684
1623	30	2024-01-22	\N	822551.03	721	\N	4	721
1624	15	2024-08-24	\N	6011273.90	394	\N	4	394
1625	33	2024-02-06	\N	6993042.58	272	\N	4	272
1626	14	2024-11-29	\N	1293525.24	372	\N	4	372
1627	13	2024-09-08	\N	1691116.35	788	\N	4	788
1628	33	2024-04-11	\N	6185309.28	133	\N	4	133
1629	31	2024-07-14	\N	2077435.00	794	\N	4	794
1630	14	2024-09-25	\N	2773528.05	779	\N	4	779
1631	30	2024-01-09	\N	510477.87	963	\N	4	963
1632	32	2024-04-15	\N	3543108.00	824	\N	4	824
1633	33	2024-02-01	\N	5065120.26	812	\N	4	812
1634	31	2024-05-15	\N	3167109.57	536	\N	4	536
1635	31	2024-08-06	\N	8578224.92	741	\N	4	741
1636	32	2024-05-12	\N	2774895.87	195	\N	4	195
1637	30	2024-01-21	\N	4811324.06	501	\N	4	501
1638	30	2024-02-08	\N	5167152.73	790	\N	4	790
1639	31	2024-09-18	\N	4685692.39	933	\N	4	933
1640	16	2024-02-24	\N	8837227.08	306	\N	4	306
1641	13	2024-03-07	\N	3747475.68	771	\N	4	771
1642	33	2024-08-13	\N	5228009.82	50	\N	4	50
1643	31	2024-04-07	\N	3917721.91	396	\N	4	396
1644	15	2024-12-27	\N	5887246.95	677	\N	4	677
1645	14	2024-12-03	\N	1290872.84	691	\N	4	691
1646	32	2024-02-13	\N	9611787.50	578	\N	4	578
1647	33	2024-06-29	\N	9744739.78	143	\N	4	143
1648	13	2024-12-18	\N	9708801.29	517	\N	4	517
1649	30	2024-09-23	\N	8519917.36	936	\N	4	936
1650	15	2024-05-26	\N	5612608.79	280	\N	4	280
1651	30	2024-03-12	\N	7953721.50	290	\N	4	290
1652	30	2024-07-01	\N	8231237.44	239	\N	4	239
1653	31	2024-10-29	\N	1740282.78	596	\N	4	596
1654	33	2024-02-19	\N	4476714.81	184	\N	4	184
1655	30	2024-11-05	\N	8099581.59	679	\N	4	679
1656	33	2024-01-28	\N	2668258.09	408	\N	4	408
1657	32	2024-07-20	\N	8177720.19	743	\N	4	743
1658	16	2024-04-04	\N	3695077.91	471	\N	4	471
1659	13	2024-01-17	\N	3973763.38	621	\N	4	621
1660	31	2024-09-24	\N	4325956.73	603	\N	4	603
1661	13	2024-07-16	\N	4470410.21	750	\N	4	750
1662	33	2024-03-10	\N	1054662.23	88	\N	4	88
1663	33	2024-05-31	\N	2526683.78	776	\N	4	776
1664	13	2024-11-09	\N	1342764.76	846	\N	4	846
1665	30	2024-02-18	\N	776394.54	220	\N	4	220
1666	13	2024-09-03	\N	4392649.59	916	\N	4	916
1667	31	2024-05-22	\N	8188850.45	797	\N	4	797
1668	33	2024-07-08	\N	5254701.49	35	\N	4	35
1669	30	2024-08-12	\N	5746104.34	467	\N	4	467
1670	31	2024-12-20	\N	4167586.23	331	\N	4	331
1671	14	2024-06-17	\N	1892192.18	233	\N	4	233
1672	14	2024-04-08	\N	7301136.80	629	\N	4	629
1673	16	2024-01-15	\N	356303.95	557	\N	4	557
1674	16	2024-10-11	\N	1068093.14	307	\N	4	307
1675	16	2024-11-25	\N	6625538.85	574	\N	4	574
1676	33	2024-04-17	\N	4830191.66	979	\N	4	979
1677	30	2024-04-16	\N	4119410.87	201	\N	4	201
1678	32	2024-08-26	\N	6150752.17	943	\N	4	943
1679	31	2024-11-19	\N	4781596.69	986	\N	4	986
1680	14	2024-11-25	\N	8046686.88	342	\N	4	342
1681	16	2024-09-09	\N	8654415.83	845	\N	4	845
1682	33	2024-08-04	\N	5350880.12	682	\N	4	682
1683	30	2024-11-18	\N	2665007.63	663	\N	4	663
1684	33	2024-10-18	\N	1137341.18	884	\N	4	884
1685	33	2024-11-26	\N	7995269.15	320	\N	4	320
1686	33	2024-07-26	\N	2569626.85	982	\N	4	982
1687	15	2024-07-17	\N	336404.62	44	\N	4	44
1688	16	2024-12-20	\N	4251974.04	766	\N	4	766
1689	14	2024-10-21	\N	9454329.90	41	\N	4	41
1690	32	2024-04-17	\N	3648662.92	585	\N	4	585
1691	33	2024-07-08	\N	2910728.33	417	\N	4	417
1692	13	2024-06-26	\N	8316790.52	880	\N	4	880
1693	15	2024-03-06	\N	397044.04	255	\N	4	255
1694	30	2024-02-10	\N	1530469.78	533	\N	4	533
1695	31	2024-12-05	\N	3980257.56	678	\N	4	678
1696	13	2024-01-27	\N	2734189.77	811	\N	4	811
1697	31	2024-06-26	\N	7936344.54	629	\N	4	629
1698	15	2024-02-11	\N	7938153.90	678	\N	4	678
1699	15	2024-05-14	\N	7587072.03	784	\N	4	784
1700	14	2024-01-18	\N	8872588.04	908	\N	4	908
1701	32	2024-12-28	\N	5826271.04	107	\N	4	107
1702	33	2024-12-06	\N	9880731.86	955	\N	4	955
1703	33	2024-03-29	\N	2820443.95	383	\N	4	383
1704	14	2024-11-25	\N	6298513.21	322	\N	4	322
1705	31	2024-10-17	\N	2072159.19	982	\N	4	982
1706	31	2024-07-29	\N	509581.86	885	\N	4	885
1707	16	2024-09-02	\N	3096101.88	711	\N	4	711
1708	31	2024-03-19	\N	3983694.44	107	\N	4	107
1709	14	2024-07-02	\N	3228290.51	784	\N	4	784
1710	15	2024-01-17	\N	1402300.61	348	\N	4	348
1711	30	2024-06-09	\N	7293486.16	542	\N	4	542
1712	16	2024-04-09	\N	510864.46	775	\N	4	775
1713	15	2024-08-16	\N	882438.65	368	\N	4	368
1714	14	2024-11-25	\N	7214366.24	720	\N	4	720
1715	30	2024-03-24	\N	1099609.44	210	\N	4	210
1716	16	2024-11-23	\N	4669309.17	489	\N	4	489
1717	16	2024-06-26	\N	2395704.38	847	\N	4	847
1718	33	2024-05-11	\N	7298881.00	882	\N	4	882
1719	33	2024-10-10	\N	9272491.59	190	\N	4	190
1720	31	2024-01-14	\N	9894876.47	752	\N	4	752
1721	15	2024-12-30	\N	3537368.20	472	\N	4	472
1722	30	2024-02-16	\N	4705674.43	316	\N	4	316
1723	16	2024-12-01	\N	9471452.36	119	\N	4	119
1724	14	2024-09-25	\N	979036.03	627	\N	4	627
1725	14	2024-10-13	\N	3143252.63	212	\N	4	212
1726	15	2024-05-22	\N	914097.40	577	\N	4	577
1727	15	2024-12-01	\N	8613796.50	827	\N	4	827
1728	30	2024-10-22	\N	7738954.01	850	\N	4	850
1729	15	2024-05-13	\N	77067.84	11	\N	4	11
1730	13	2024-08-15	\N	827527.89	227	\N	4	227
1731	16	2024-01-13	\N	3171605.96	115	\N	4	115
1732	15	2024-03-25	\N	749100.52	608	\N	4	608
1733	30	2024-06-01	\N	359882.03	972	\N	4	972
1734	15	2024-01-29	\N	2171650.23	123	\N	4	123
1735	13	2024-02-03	\N	1798461.07	381	\N	4	381
1736	16	2024-10-21	\N	6369291.21	486	\N	4	486
1737	15	2024-06-20	\N	6927216.69	181	\N	4	181
1738	16	2024-09-19	\N	8589527.76	299	\N	4	299
1739	32	2024-12-01	\N	6603481.38	445	\N	4	445
1740	31	2024-09-30	\N	4569756.06	751	\N	4	751
1741	33	2024-07-24	\N	3017084.58	87	\N	4	87
1742	32	2024-03-23	\N	5029567.78	32	\N	4	32
1743	16	2024-09-03	\N	6100042.57	752	\N	4	752
1744	33	2024-01-31	\N	6228754.90	382	\N	4	382
1745	31	2024-04-12	\N	5647155.14	638	\N	4	638
1746	13	2024-07-01	\N	6377363.20	194	\N	4	194
1747	33	2024-07-16	\N	1000826.14	44	\N	4	44
1748	30	2024-03-11	\N	1453773.51	115	\N	4	115
1749	16	2024-03-28	\N	4608174.19	175	\N	4	175
1750	30	2024-03-02	\N	2102319.69	978	\N	4	978
1751	31	2024-09-22	\N	4318424.34	84	\N	4	84
1752	33	2024-06-19	\N	614260.25	690	\N	4	690
1753	30	2024-02-18	\N	7432622.05	247	\N	4	247
1754	32	2024-05-03	\N	3846776.61	979	\N	4	979
1755	33	2024-11-11	\N	5421054.75	216	\N	4	216
1756	32	2024-01-02	\N	6712709.28	340	\N	4	340
1757	13	2024-11-10	\N	1573173.67	943	\N	4	943
1758	32	2024-04-05	\N	7364266.34	899	\N	4	899
1759	14	2024-04-19	\N	6419139.28	151	\N	4	151
1760	15	2024-12-11	\N	55923.54	127	\N	4	127
1761	16	2024-07-04	\N	645824.90	550	\N	4	550
1762	31	2024-03-21	\N	2825023.27	383	\N	4	383
1763	30	2024-02-14	\N	8801225.25	652	\N	4	652
1764	33	2024-05-21	\N	8415341.34	488	\N	4	488
1765	31	2024-04-28	\N	6476727.50	304	\N	4	304
1766	33	2024-02-24	\N	3088090.08	38	\N	4	38
1767	30	2024-05-12	\N	1921142.81	402	\N	4	402
1768	33	2024-06-23	\N	1670038.24	758	\N	4	758
1769	32	2024-04-26	\N	6134960.47	538	\N	4	538
1770	15	2024-05-05	\N	6485384.32	176	\N	4	176
1771	32	2024-01-28	\N	9524858.60	373	\N	4	373
1772	16	2024-05-04	\N	9166365.05	664	\N	4	664
1773	30	2024-11-09	\N	7606727.35	463	\N	4	463
1774	14	2024-01-09	\N	1792058.50	569	\N	4	569
1775	30	2024-06-21	\N	3644934.50	619	\N	4	619
1776	30	2024-08-03	\N	4910222.77	44	\N	4	44
1777	15	2024-02-15	\N	6119861.69	885	\N	4	885
1778	32	2024-03-05	\N	3104759.95	205	\N	4	205
1779	30	2024-05-28	\N	1461645.77	117	\N	4	117
1780	32	2024-12-29	\N	6885076.17	554	\N	4	554
1781	15	2024-12-15	\N	8418883.31	162	\N	4	162
1782	30	2024-09-13	\N	6998630.52	862	\N	4	862
1783	16	2024-03-08	\N	208522.67	230	\N	4	230
1784	33	2024-07-22	\N	6265600.73	175	\N	4	175
1785	16	2024-06-02	\N	8046915.21	377	\N	4	377
1786	13	2024-01-15	\N	880159.04	271	\N	4	271
1787	14	2024-11-26	\N	4442294.18	660	\N	4	660
1788	33	2024-09-23	\N	6786111.95	113	\N	4	113
1789	33	2024-04-14	\N	5373690.21	305	\N	4	305
1790	30	2024-06-29	\N	5692438.70	632	\N	4	632
1791	16	2024-11-19	\N	6975298.22	929	\N	4	929
1792	14	2024-11-26	\N	4189289.25	870	\N	4	870
1793	32	2024-07-21	\N	5416391.26	678	\N	4	678
1794	30	2024-03-16	\N	7187195.10	297	\N	4	297
1795	31	2024-07-13	\N	5255001.23	817	\N	4	817
1796	16	2024-10-27	\N	2824632.46	78	\N	4	78
1797	33	2024-12-24	\N	7594492.49	142	\N	4	142
1798	16	2024-09-07	\N	5123460.48	712	\N	4	712
1799	16	2024-04-19	\N	8305289.45	597	\N	4	597
1800	30	2024-01-27	\N	2675331.30	394	\N	4	394
1801	13	2024-10-30	\N	2864483.71	166	\N	4	166
1802	33	2024-05-26	\N	5011548.34	447	\N	4	447
1803	16	2024-09-10	\N	4100078.29	8	\N	4	8
1804	14	2024-09-26	\N	362868.95	895	\N	4	895
1805	33	2024-05-04	\N	2519761.43	471	\N	4	471
1806	15	2024-02-08	\N	683313.73	617	\N	4	617
1807	13	2024-06-12	\N	3345007.72	916	\N	4	916
1808	32	2024-11-27	\N	5883116.29	718	\N	4	718
1809	31	2024-12-26	\N	2007363.64	988	\N	4	988
1810	33	2024-06-12	\N	6601251.58	74	\N	4	74
1811	14	2024-06-09	\N	2957215.35	825	\N	4	825
1812	16	2024-10-21	\N	2548443.19	797	\N	4	797
1813	32	2024-09-12	\N	4764213.88	140	\N	4	140
1814	30	2024-07-15	\N	4565229.91	289	\N	4	289
1815	13	2024-02-28	\N	6251359.67	110	\N	4	110
1816	32	2024-11-07	\N	1710077.90	585	\N	4	585
1817	13	2024-08-10	\N	2574853.75	899	\N	4	899
1818	30	2024-11-25	\N	5818393.86	605	\N	4	605
1819	32	2024-04-10	\N	5219875.13	902	\N	4	902
1820	15	2024-09-10	\N	6867606.64	280	\N	4	280
1821	30	2024-06-23	\N	1901148.70	902	\N	4	902
1822	13	2024-09-16	\N	2461640.06	945	\N	4	945
1823	14	2024-10-28	\N	9085473.37	252	\N	4	252
1824	15	2024-03-06	\N	5113128.42	32	\N	4	32
1825	32	2024-07-05	\N	9533695.87	432	\N	4	432
1826	30	2024-03-28	\N	1026580.95	28	\N	4	28
1827	33	2024-08-19	\N	7694235.00	272	\N	4	272
1828	30	2024-11-27	\N	2507577.09	199	\N	4	199
1829	32	2024-01-31	\N	6885008.84	71	\N	4	71
1830	30	2024-06-25	\N	9640721.46	496	\N	4	496
1831	15	2024-08-10	\N	2582325.56	594	\N	4	594
1832	13	2024-06-04	\N	626049.83	30	\N	4	30
1833	13	2024-01-14	\N	8785367.50	857	\N	4	857
1834	32	2024-01-14	\N	1705418.50	184	\N	4	184
1835	13	2024-08-26	\N	4144322.29	859	\N	4	859
1836	31	2024-01-06	\N	5461696.55	289	\N	4	289
1837	33	2024-06-07	\N	5074018.95	990	\N	4	990
1838	16	2024-04-19	\N	9400421.37	699	\N	4	699
1839	30	2024-04-17	\N	4311671.38	608	\N	4	608
1840	13	2024-01-26	\N	1379496.89	931	\N	4	931
1841	15	2024-04-20	\N	1493045.36	571	\N	4	571
1842	13	2024-02-15	\N	5007658.77	192	\N	4	192
1843	15	2024-10-13	\N	9266553.14	301	\N	4	301
1844	16	2024-11-16	\N	3136765.83	642	\N	4	642
1845	31	2024-09-18	\N	248580.10	790	\N	4	790
1846	32	2024-12-13	\N	89086.45	941	\N	4	941
1847	16	2024-02-19	\N	3386679.70	347	\N	4	347
1848	30	2024-08-25	\N	3429719.91	590	\N	4	590
1849	32	2024-01-17	\N	4323341.58	822	\N	4	822
1850	13	2024-09-12	\N	8794917.29	627	\N	4	627
1851	16	2024-12-04	\N	6100624.77	300	\N	4	300
1852	13	2024-07-17	\N	7425475.56	568	\N	4	568
1853	31	2024-07-03	\N	8979237.48	7	\N	4	7
1854	13	2024-04-13	\N	8955646.67	596	\N	4	596
1855	16	2024-05-30	\N	6356024.99	504	\N	4	504
1856	32	2024-11-29	\N	7461936.74	259	\N	4	259
1857	13	2024-10-18	\N	3210578.88	747	\N	4	747
1858	16	2024-02-11	\N	4923498.49	477	\N	4	477
1859	33	2024-11-07	\N	4020595.52	938	\N	4	938
1860	33	2024-07-19	\N	3931680.97	405	\N	4	405
1861	33	2024-01-31	\N	4815849.40	774	\N	4	774
1862	33	2024-04-11	\N	3001175.01	924	\N	4	924
1863	15	2024-01-21	\N	8384638.14	925	\N	4	925
1864	16	2024-10-09	\N	9836209.42	672	\N	4	672
1865	33	2024-05-26	\N	1229524.56	389	\N	4	389
1866	14	2024-02-28	\N	6992170.66	990	\N	4	990
1867	30	2024-03-15	\N	2657551.80	138	\N	4	138
1868	14	2024-02-29	\N	4043506.23	610	\N	4	610
1869	32	2024-09-14	\N	7497568.81	954	\N	4	954
1870	14	2024-02-22	\N	7706314.79	373	\N	4	373
1871	15	2024-11-20	\N	4655158.46	292	\N	4	292
1872	31	2024-11-17	\N	7131025.16	682	\N	4	682
1873	14	2024-02-17	\N	662412.82	361	\N	4	361
1874	32	2024-08-11	\N	3867839.42	971	\N	4	971
1875	13	2024-10-07	\N	2450507.02	46	\N	4	46
1876	30	2024-03-31	\N	7648266.60	281	\N	4	281
1877	31	2024-08-21	\N	9704233.79	213	\N	4	213
1878	32	2024-03-12	\N	968498.52	4	\N	4	4
1879	30	2024-05-09	\N	6694301.59	132	\N	4	132
1880	33	2024-08-18	\N	2591383.73	104	\N	4	104
1881	30	2024-04-11	\N	4861770.08	363	\N	4	363
1882	13	2024-04-09	\N	8275301.76	246	\N	4	246
1883	13	2024-02-05	\N	9798972.88	552	\N	4	552
1884	32	2024-02-15	\N	4418619.38	815	\N	4	815
1885	13	2024-12-07	\N	6730476.70	15	\N	4	15
1886	13	2024-01-04	\N	7739226.23	811	\N	4	811
1887	30	2024-01-22	\N	9624341.37	788	\N	4	788
1888	15	2024-10-03	\N	9669310.80	461	\N	4	461
1889	31	2024-11-27	\N	622487.91	965	\N	4	965
1890	16	2024-05-24	\N	6915012.33	195	\N	4	195
1891	33	2024-07-06	\N	162191.68	109	\N	4	109
1892	33	2024-04-19	\N	4196611.08	428	\N	4	428
1893	30	2024-01-08	\N	8288424.35	400	\N	4	400
1894	33	2024-12-09	\N	3232457.37	296	\N	4	296
1895	15	2024-05-19	\N	5997987.02	27	\N	4	27
1896	31	2024-01-23	\N	1972836.25	713	\N	4	713
1897	33	2024-08-29	\N	4022907.61	942	\N	4	942
1898	13	2024-01-30	\N	4223424.79	909	\N	4	909
1899	32	2024-10-12	\N	9831109.01	389	\N	4	389
1900	15	2024-02-02	\N	5353086.18	697	\N	4	697
1901	14	2024-07-15	\N	8363541.93	94	\N	4	94
1902	31	2024-10-12	\N	9639325.29	475	\N	4	475
1903	14	2024-05-01	\N	1818051.21	280	\N	4	280
1904	14	2024-10-22	\N	3290922.81	106	\N	4	106
1905	30	2024-09-30	\N	4860270.23	445	\N	4	445
1906	31	2024-07-10	\N	3340176.78	210	\N	4	210
1907	32	2024-11-12	\N	9678519.27	822	\N	4	822
1908	13	2024-08-31	\N	8189846.90	56	\N	4	56
1909	14	2024-02-05	\N	2159730.55	324	\N	4	324
1910	13	2024-06-14	\N	9355960.82	829	\N	4	829
1911	16	2024-05-20	\N	5299674.58	236	\N	4	236
1912	13	2024-06-12	\N	5289814.03	173	\N	4	173
1913	14	2024-03-16	\N	7771156.54	605	\N	4	605
1914	30	2024-04-14	\N	1681480.36	341	\N	4	341
1915	15	2024-02-14	\N	7381396.32	829	\N	4	829
1916	32	2024-11-09	\N	1807080.67	857	\N	4	857
1917	31	2024-11-17	\N	9831782.28	823	\N	4	823
1918	31	2024-03-22	\N	5727292.01	303	\N	4	303
1919	15	2024-11-29	\N	6330175.77	902	\N	4	902
1920	15	2024-03-04	\N	4620121.84	72	\N	4	72
1921	14	2024-08-10	\N	9700856.86	576	\N	4	576
1922	33	2024-03-25	\N	5578854.01	56	\N	4	56
1923	15	2024-03-03	\N	4405028.68	176	\N	4	176
1924	14	2024-05-13	\N	3717966.44	958	\N	4	958
1925	14	2024-06-12	\N	6204297.84	946	\N	4	946
1926	30	2024-12-06	\N	269805.80	177	\N	4	177
1927	30	2024-05-01	\N	3743261.18	652	\N	4	652
1928	13	2024-03-16	\N	3490217.46	844	\N	4	844
1929	30	2024-12-10	\N	8701965.13	617	\N	4	617
1930	13	2024-08-03	\N	4201624.53	730	\N	4	730
1931	16	2024-06-04	\N	542283.63	920	\N	4	920
1932	15	2024-02-07	\N	3598846.79	452	\N	4	452
1933	15	2024-04-20	\N	663040.04	17	\N	4	17
1934	13	2024-02-09	\N	7333495.16	785	\N	4	785
1935	31	2024-10-30	\N	730934.30	244	\N	4	244
1936	33	2024-04-06	\N	7600249.36	775	\N	4	775
1937	30	2024-04-23	\N	921024.07	527	\N	4	527
1938	16	2024-02-23	\N	7757296.89	880	\N	4	880
1939	13	2024-10-18	\N	545563.37	179	\N	4	179
1940	33	2024-12-15	\N	6529470.32	383	\N	4	383
1941	13	2024-03-31	\N	4007505.50	425	\N	4	425
1942	13	2024-12-21	\N	5447728.45	573	\N	4	573
1943	32	2024-08-01	\N	5381363.34	741	\N	4	741
1944	32	2024-08-31	\N	7202726.10	61	\N	4	61
1945	13	2024-01-30	\N	5815694.89	584	\N	4	584
1946	32	2024-07-28	\N	2458667.62	381	\N	4	381
1947	30	2024-03-26	\N	1321950.31	535	\N	4	535
1948	32	2024-08-03	\N	9558689.29	879	\N	4	879
1949	32	2024-07-05	\N	4224169.94	57	\N	4	57
1950	33	2024-06-01	\N	7944657.18	603	\N	4	603
1951	16	2024-11-12	\N	5947333.04	321	\N	4	321
1952	31	2024-11-18	\N	6197691.74	430	\N	4	430
1953	15	2024-07-09	\N	5867403.35	851	\N	4	851
1954	16	2024-07-30	\N	3763593.25	398	\N	4	398
1955	32	2024-04-22	\N	6271150.01	309	\N	4	309
1956	16	2024-05-19	\N	8732287.49	782	\N	4	782
1957	13	2024-05-15	\N	6345667.70	710	\N	4	710
1958	13	2024-01-26	\N	9461533.52	463	\N	4	463
1959	30	2024-08-24	\N	6200133.82	262	\N	4	262
1960	15	2024-09-20	\N	4582536.10	225	\N	4	225
1961	16	2024-04-02	\N	1888521.23	320	\N	4	320
1962	14	2024-03-21	\N	2957224.38	554	\N	4	554
1963	31	2024-08-22	\N	4663558.79	879	\N	4	879
1964	31	2024-11-09	\N	9145765.73	231	\N	4	231
1965	13	2024-08-29	\N	3667582.03	28	\N	4	28
1966	14	2024-08-26	\N	7901164.78	595	\N	4	595
1967	16	2024-04-04	\N	6405439.57	694	\N	4	694
1968	15	2024-05-27	\N	5793129.89	266	\N	4	266
1969	13	2024-05-21	\N	4060243.89	689	\N	4	689
1970	32	2024-05-02	\N	8156899.22	187	\N	4	187
1971	30	2024-03-16	\N	4100676.05	404	\N	4	404
1972	30	2024-08-21	\N	2322855.76	49	\N	4	49
1973	31	2024-08-07	\N	2586449.00	267	\N	4	267
1974	13	2024-02-18	\N	6233469.77	914	\N	4	914
1975	32	2024-11-24	\N	6835081.96	309	\N	4	309
1976	32	2024-11-12	\N	3792053.34	88	\N	4	88
1977	32	2024-10-08	\N	3748516.14	482	\N	4	482
1978	13	2024-02-14	\N	6178690.30	147	\N	4	147
1979	13	2024-08-04	\N	8270180.41	376	\N	4	376
1980	33	2024-03-04	\N	9934363.09	962	\N	4	962
1981	30	2024-11-13	\N	7207957.66	809	\N	4	809
1982	13	2024-07-21	\N	5833872.52	354	\N	4	354
1983	13	2024-01-01	\N	5099024.13	61	\N	4	61
1984	15	2024-07-19	\N	8519893.79	880	\N	4	880
1985	32	2024-10-28	\N	9266674.19	784	\N	4	784
1986	13	2024-12-07	\N	705459.10	417	\N	4	417
1987	15	2024-07-31	\N	1169169.08	96	\N	4	96
1988	32	2024-02-13	\N	9564687.73	351	\N	4	351
1989	15	2024-04-28	\N	9630063.92	732	\N	4	732
1990	16	2024-09-08	\N	9041308.90	334	\N	4	334
1991	15	2024-12-21	\N	262015.79	889	\N	4	889
1992	14	2024-07-03	\N	9220090.94	195	\N	4	195
1993	15	2024-02-03	\N	5816653.98	122	\N	4	122
1994	33	2024-12-14	\N	717496.23	817	\N	4	817
1995	30	2024-12-03	\N	7563414.98	388	\N	4	388
1996	33	2024-03-07	\N	6485094.06	40	\N	4	40
1997	14	2024-01-26	\N	8762194.90	308	\N	4	308
1998	15	2024-06-10	\N	2179036.55	814	\N	4	814
1999	30	2024-04-26	\N	4871793.14	505	\N	4	505
2000	31	2024-09-22	\N	7676758.88	551	\N	4	551
2001	13	2024-08-25	\N	3436005.17	95	\N	4	95
2002	13	2024-11-08	\N	4240986.43	887	\N	4	887
2003	32	2024-12-30	\N	176942.03	700	\N	4	700
2004	16	2024-11-08	\N	9518484.50	253	\N	4	253
2005	30	2024-06-12	\N	2210396.18	32	\N	4	32
2006	33	2024-07-16	\N	982206.72	465	\N	4	465
2007	30	2024-12-16	\N	8651723.64	909	\N	4	909
2008	16	2024-10-07	\N	9068050.45	770	\N	4	770
2009	15	2024-03-08	\N	4082455.45	800	\N	4	800
2010	31	2024-11-18	\N	7241250.26	955	\N	4	955
2011	31	2024-03-17	\N	4644306.86	803	\N	4	803
2012	15	2024-11-24	\N	150074.51	794	\N	4	794
2013	16	2024-08-24	\N	9191056.20	680	\N	4	680
2014	33	2024-11-08	\N	8533073.18	807	\N	4	807
2015	32	2024-11-13	\N	65520.31	562	\N	4	562
2016	30	2024-09-27	\N	350651.29	222	\N	4	222
2017	16	2024-07-27	\N	5539845.78	864	\N	4	864
2018	16	2024-11-19	\N	2686907.75	140	\N	4	140
2019	30	2024-09-07	\N	3579473.63	342	\N	4	342
2020	31	2024-09-07	\N	8459220.33	729	\N	4	729
2021	31	2024-07-03	\N	6067263.37	410	\N	4	410
2022	30	2024-03-17	\N	3589926.79	336	\N	4	336
2023	32	2024-07-05	\N	5045901.99	955	\N	4	955
2024	16	2024-12-23	\N	7275528.49	159	\N	4	159
2025	13	2024-12-31	\N	9796337.34	893	\N	4	893
2026	33	2024-10-26	\N	3068045.20	700	\N	4	700
2027	14	2024-04-27	\N	8772015.03	454	\N	4	454
2028	33	2024-12-18	\N	2165649.94	506	\N	4	506
2029	31	2024-08-05	\N	3033376.50	565	\N	4	565
2030	33	2024-05-01	\N	6712715.80	884	\N	4	884
2031	15	2024-12-12	\N	1038519.58	677	\N	4	677
2032	32	2024-12-07	\N	3695460.88	127	\N	4	127
2033	15	2024-09-26	\N	9573466.69	689	\N	4	689
2034	32	2024-05-12	\N	5146165.13	946	\N	4	946
2035	13	2024-04-15	\N	1980576.92	649	\N	4	649
2036	13	2024-04-05	\N	2116389.45	472	\N	4	472
2037	16	2024-02-09	\N	5216899.94	722	\N	4	722
2038	33	2024-10-10	\N	3756739.93	144	\N	4	144
2039	31	2024-08-29	\N	1275893.06	542	\N	4	542
2040	14	2024-07-15	\N	2220087.10	569	\N	4	569
2041	15	2024-10-26	\N	9728196.26	431	\N	4	431
2042	16	2024-10-14	\N	9476007.70	996	\N	4	996
2043	32	2024-08-21	\N	8894799.20	133	\N	4	133
2044	13	2024-02-07	\N	6549492.01	952	\N	4	952
2045	33	2024-11-25	\N	451351.68	35	\N	4	35
2046	14	2024-08-12	\N	1750050.37	166	\N	4	166
2047	31	2024-12-27	\N	263839.41	977	\N	4	977
2048	31	2024-11-28	\N	7227515.05	541	\N	4	541
2049	32	2024-10-08	\N	4532628.58	935	\N	4	935
2050	14	2024-05-23	\N	4347396.82	330	\N	4	330
2051	31	2024-02-15	\N	2372992.12	721	\N	4	721
2052	16	2024-12-03	\N	752308.40	572	\N	4	572
2053	16	2024-09-12	\N	2480987.79	607	\N	4	607
2054	14	2024-05-24	\N	8095953.47	728	\N	4	728
2055	13	2024-05-26	\N	1349157.77	86	\N	4	86
2056	13	2024-12-01	\N	9111851.37	52	\N	4	52
2058	37	2024-09-14	2026-08-20	5134076.35	951	\N	5	951
2059	36	2024-09-19	2026-05-31	7280758.18	485	\N	5	485
2060	18	2024-12-16	2026-02-10	3177185.62	666	\N	5	666
2061	37	2024-08-09	2026-09-14	1503792.93	243	\N	5	243
2062	37	2024-09-03	2025-10-12	3439225.42	894	\N	5	894
2063	20	2024-05-20	2026-05-13	1102885.15	537	\N	5	537
2064	20	2024-11-01	2025-11-26	7794172.73	762	\N	5	762
2065	36	2024-08-01	2025-12-13	771756.43	414	\N	5	414
2066	34	2024-10-26	2025-10-27	7706929.91	873	\N	5	873
2067	37	2024-09-10	2025-07-20	155265.50	814	\N	5	814
2068	19	2024-12-26	2026-09-30	1542437.48	480	\N	5	480
2069	17	2024-07-01	2026-06-23	1666501.54	537	\N	5	537
2070	34	2024-06-16	2026-02-02	5000508.65	440	\N	5	440
2071	20	2024-09-18	2026-03-20	6113376.11	663	\N	5	663
2072	17	2024-10-23	2025-08-23	9450480.73	499	\N	5	499
2073	19	2024-10-12	2026-08-28	8966008.24	548	\N	5	548
2074	20	2024-09-12	2026-09-04	6870659.31	649	\N	5	649
2075	18	2024-04-29	2026-08-16	4270966.15	582	\N	5	582
2076	20	2024-05-18	2026-07-29	7879352.16	278	\N	5	278
2077	19	2024-07-01	2026-05-03	6290126.88	492	\N	5	492
2078	19	2024-06-25	2026-09-08	6048047.53	85	\N	5	85
2079	36	2024-11-14	2026-09-27	9316316.94	306	\N	5	306
2080	37	2024-06-13	2026-12-30	5432089.74	9	\N	5	9
2081	18	2024-12-23	2026-07-04	2841856.51	498	\N	5	498
2082	19	2024-11-04	2026-12-01	6157493.90	463	\N	5	463
2083	36	2024-01-22	2025-10-18	9292323.89	650	\N	5	650
2084	19	2024-08-29	2026-01-20	6230576.50	951	\N	5	951
2085	18	2024-12-01	2026-10-21	3140153.54	497	\N	5	497
2086	17	2024-05-15	2025-12-09	5066687.60	209	\N	5	209
2087	36	2024-04-29	2025-06-26	2690230.09	981	\N	5	981
2088	19	2024-06-24	2025-08-27	6108960.38	725	\N	5	725
2089	35	2024-11-03	2026-08-04	3206697.95	78	\N	5	78
2090	36	2024-10-06	2025-07-08	8810804.78	360	\N	5	360
2091	20	2024-03-30	2026-04-18	1469181.39	50	\N	5	50
2092	34	2024-07-28	2026-01-08	1940242.67	732	\N	5	732
2093	34	2024-07-23	2025-06-25	5372010.63	25	\N	5	25
2094	19	2024-01-17	2026-10-25	1145715.91	64	\N	5	64
2095	35	2024-04-24	2025-09-03	6196692.38	756	\N	5	756
2096	20	2024-08-09	2025-12-08	5818764.70	383	\N	5	383
2097	18	2024-09-30	2025-10-21	9588211.66	560	\N	5	560
2098	19	2024-07-10	2026-03-18	5685728.87	367	\N	5	367
2099	34	2024-10-27	2026-12-09	6960880.85	52	\N	5	52
2100	19	2024-12-01	2026-01-23	2446429.33	260	\N	5	260
2101	35	2024-05-14	2026-08-16	5181454.22	40	\N	5	40
2102	34	2024-12-27	2026-11-20	5166512.55	890	\N	5	890
2103	19	2024-11-21	2026-05-11	4415711.02	276	\N	5	276
2104	17	2024-12-01	2026-09-17	7847540.71	251	\N	5	251
2105	35	2024-05-13	2026-04-11	5384437.03	506	\N	5	506
2106	37	2024-05-16	2025-11-26	7827964.20	79	\N	5	79
2107	37	2024-02-09	2026-03-09	7669418.96	871	\N	5	871
2108	20	2024-08-09	2025-12-31	6072017.56	688	\N	5	688
2109	34	2024-11-22	2025-08-06	1644101.16	614	\N	5	614
2110	19	2024-04-13	2025-10-10	1592589.22	24	\N	5	24
2111	18	2024-12-21	2026-12-09	9306875.83	259	\N	5	259
2112	20	2024-12-13	2025-12-08	7659451.88	818	\N	5	818
2113	18	2024-07-02	2026-03-28	4088664.80	145	\N	5	145
2114	34	2024-05-20	2026-05-10	1428920.41	929	\N	5	929
2115	17	2024-04-04	2025-11-11	3617321.27	83	\N	5	83
2116	35	2024-10-29	2026-12-26	7345354.68	68	\N	5	68
2117	18	2024-11-24	2025-07-03	8086835.63	970	\N	5	970
2118	19	2024-05-10	2026-02-12	7202386.58	344	\N	5	344
2119	35	2024-06-21	2025-12-13	5599429.62	255	\N	5	255
2120	19	2024-11-01	2025-12-15	8104248.04	54	\N	5	54
2121	18	2024-08-22	2025-08-21	1371450.90	50	\N	5	50
2122	19	2024-11-29	2026-04-02	285403.94	658	\N	5	658
2123	20	2024-08-27	2026-12-03	7901626.68	928	\N	5	928
2124	18	2024-09-12	2025-08-28	6299255.48	21	\N	5	21
2125	37	2024-03-19	2025-10-01	9874876.41	487	\N	5	487
2126	20	2024-11-11	2026-07-23	8156973.30	426	\N	5	426
2127	34	2024-03-07	2025-09-25	1278986.15	706	\N	5	706
2128	37	2024-12-20	2026-09-29	6531299.11	298	\N	5	298
2129	18	2024-02-22	2026-06-15	1513733.73	674	\N	5	674
2130	18	2024-03-18	2026-08-24	4152644.86	927	\N	5	927
2131	17	2024-11-21	2026-02-25	6217705.16	142	\N	5	142
2132	19	2024-03-21	2025-08-14	8951469.10	538	\N	5	538
2133	18	2024-10-08	2026-10-22	4284844.88	426	\N	5	426
2134	20	2024-04-16	2025-07-22	6821130.48	799	\N	5	799
2135	34	2024-09-04	2026-06-22	9278539.16	954	\N	5	954
2136	35	2024-05-08	2025-10-25	4150884.64	461	\N	5	461
2137	34	2024-12-21	2025-10-01	1391122.49	337	\N	5	337
2138	19	2024-12-19	2026-02-22	2656095.43	861	\N	5	861
2139	36	2024-03-03	2026-08-13	9108398.46	419	\N	5	419
2140	35	2024-09-09	2026-10-09	741187.53	803	\N	5	803
2141	36	2024-09-08	2025-09-07	2524904.62	350	\N	5	350
2142	35	2024-08-14	2026-09-23	9711904.47	161	\N	5	161
2143	17	2024-03-26	2026-02-10	4818773.92	891	\N	5	891
2144	35	2024-05-01	2026-12-29	6214425.28	143	\N	5	143
2145	17	2024-12-06	2025-08-02	9283480.42	377	\N	5	377
2146	34	2024-10-19	2026-11-22	1141646.15	231	\N	5	231
2147	35	2024-06-17	2026-06-24	9300110.31	264	\N	5	264
2148	34	2024-03-05	2026-04-26	851645.34	872	\N	5	872
2149	35	2024-03-04	2026-09-28	9446950.85	128	\N	5	128
2150	20	2024-07-11	2026-11-04	3330079.57	513	\N	5	513
2151	18	2024-04-23	2026-05-02	6458300.00	631	\N	5	631
2152	37	2024-12-12	2026-04-01	7128712.34	839	\N	5	839
2153	35	2024-09-11	2025-07-22	6118885.25	897	\N	5	897
2154	34	2024-11-06	2026-05-26	1870268.43	674	\N	5	674
2155	34	2024-06-24	2025-12-13	3593298.28	15	\N	5	15
2156	17	2024-11-28	2025-10-07	5176157.14	821	\N	5	821
2157	34	2024-12-26	2026-11-07	5160330.07	196	\N	5	196
2158	36	2024-06-07	2026-01-25	8836329.35	889	\N	5	889
2159	37	2024-01-08	2026-01-29	1772823.39	952	\N	5	952
2160	17	2024-10-10	2025-10-29	7221609.82	855	\N	5	855
2161	20	2024-10-07	2025-10-15	1720196.24	622	\N	5	622
2162	20	2024-09-11	2025-06-24	4144515.19	569	\N	5	569
2163	36	2024-06-28	2026-11-21	5686318.00	854	\N	5	854
2164	18	2024-02-15	2026-06-02	3633662.70	761	\N	5	761
2165	19	2024-03-21	2026-02-16	2605337.57	693	\N	5	693
2166	17	2024-12-23	2026-08-27	1138389.78	244	\N	5	244
2167	37	2024-05-16	2025-09-23	4018287.40	122	\N	5	122
2168	18	2024-04-30	2025-11-16	1235000.54	682	\N	5	682
2169	35	2024-08-19	2026-03-07	2667592.05	597	\N	5	597
2170	35	2024-03-13	2026-03-31	5705546.44	822	\N	5	822
2171	19	2024-09-19	2026-04-23	7771089.66	835	\N	5	835
2172	37	2024-03-28	2026-05-30	9343290.61	289	\N	5	289
2173	18	2024-09-30	2026-07-28	7519493.10	90	\N	5	90
2174	18	2024-02-07	2025-12-03	2470324.26	881	\N	5	881
2175	18	2024-11-23	2025-10-09	3472730.84	489	\N	5	489
2176	17	2024-05-19	2026-06-08	1561299.48	308	\N	5	308
2177	18	2024-08-06	2026-11-12	1158202.20	521	\N	5	521
2178	17	2024-05-05	2025-07-16	6333636.38	643	\N	5	643
2179	36	2024-06-08	2026-07-25	223310.67	515	\N	5	515
2180	19	2024-02-10	2026-10-01	6946564.34	321	\N	5	321
2181	35	2024-08-06	2025-11-03	2875492.45	78	\N	5	78
2182	35	2024-08-09	2026-01-07	7946869.45	923	\N	5	923
2183	20	2024-02-18	2025-07-23	5518643.33	400	\N	5	400
2184	18	2024-07-21	2026-07-14	1455174.53	412	\N	5	412
2185	36	2024-03-30	2026-09-03	1420464.44	172	\N	5	172
2186	36	2024-09-30	2025-12-31	8730391.04	957	\N	5	957
2187	36	2024-06-14	2026-12-22	347564.13	489	\N	5	489
2188	19	2024-12-04	2026-10-16	1006259.66	856	\N	5	856
2189	19	2024-05-10	2026-10-29	9723151.37	745	\N	5	745
2190	34	2024-08-15	2025-09-13	2808499.09	174	\N	5	174
2191	36	2024-02-23	2026-12-11	3731441.54	443	\N	5	443
2192	17	2024-02-04	2026-08-18	9846688.88	521	\N	5	521
2193	37	2024-12-09	2026-10-03	7432838.78	883	\N	5	883
2194	18	2024-01-21	2026-12-12	7474979.40	11	\N	5	11
2195	19	2024-02-28	2026-12-23	226008.34	297	\N	5	297
2196	35	2024-04-22	2026-10-13	7273317.32	507	\N	5	507
2197	19	2024-11-25	2026-11-03	5317073.46	803	\N	5	803
2198	34	2024-07-18	2026-11-07	9660038.24	467	\N	5	467
2199	20	2024-02-22	2025-06-06	936393.26	770	\N	5	770
2200	19	2024-02-19	2025-12-24	1506543.95	618	\N	5	618
2201	17	2024-06-12	2026-01-17	1362115.23	670	\N	5	670
2202	20	2024-06-16	2026-10-21	1630714.98	790	\N	5	790
2203	37	2024-01-11	2025-10-23	1169454.81	627	\N	5	627
2204	36	2024-11-14	2026-04-07	7205480.05	791	\N	5	791
2205	19	2024-06-10	2025-07-25	2935437.84	947	\N	5	947
2206	36	2024-01-23	2025-08-03	5311997.80	610	\N	5	610
2207	20	2024-10-01	2026-03-21	6918298.88	807	\N	5	807
2208	19	2024-09-19	2025-06-08	7466881.06	930	\N	5	930
2209	34	2024-12-27	2025-12-09	9067472.45	351	\N	5	351
2210	17	2024-05-31	2026-12-30	1425987.96	338	\N	5	338
2211	37	2024-09-21	2025-08-11	948671.73	346	\N	5	346
2212	35	2024-01-02	2026-11-28	3962903.84	505	\N	5	505
2213	37	2024-05-10	2025-06-15	7480059.85	484	\N	5	484
2214	20	2024-06-22	2025-10-18	704683.43	523	\N	5	523
2215	18	2024-04-28	2026-09-11	8568196.92	919	\N	5	919
2216	20	2024-07-05	2025-12-10	9814840.37	299	\N	5	299
2217	17	2024-04-13	2026-05-04	9474089.00	142	\N	5	142
2218	36	2024-12-27	2026-07-31	3187968.40	626	\N	5	626
2219	35	2024-11-05	2026-08-16	890877.06	64	\N	5	64
2220	35	2024-06-22	2025-09-13	4701596.44	701	\N	5	701
2221	34	2024-12-28	2026-04-19	4000665.82	357	\N	5	357
2222	17	2024-04-10	2026-06-10	4075119.18	314	\N	5	314
2223	17	2024-02-24	2026-06-01	6505148.27	757	\N	5	757
2224	36	2024-09-23	2026-12-16	4326185.53	42	\N	5	42
2225	37	2024-07-11	2026-10-09	8116093.95	90	\N	5	90
2226	20	2024-02-05	2025-06-06	1848377.36	61	\N	5	61
2227	17	2024-02-05	2025-08-03	8359556.21	832	\N	5	832
2228	18	2024-04-18	2026-06-02	1317350.65	697	\N	5	697
2229	19	2024-12-25	2026-06-21	292079.73	21	\N	5	21
2230	18	2024-11-26	2026-03-17	531654.13	181	\N	5	181
2231	19	2024-11-05	2025-12-30	2848675.84	90	\N	5	90
2232	35	2024-11-07	2026-11-16	298298.60	975	\N	5	975
2233	18	2024-09-18	2025-12-19	4220171.68	152	\N	5	152
2234	37	2024-12-20	2026-05-14	3326513.70	765	\N	5	765
2235	36	2024-09-15	2025-11-03	3892591.65	189	\N	5	189
2236	37	2024-10-23	2026-06-17	6806876.54	214	\N	5	214
2237	20	2024-09-25	2026-01-09	3159784.26	58	\N	5	58
2238	20	2024-07-25	2026-11-29	4309808.55	674	\N	5	674
2239	37	2024-03-01	2026-02-18	8704009.17	98	\N	5	98
2240	17	2024-04-02	2025-12-05	9573135.95	311	\N	5	311
2241	19	2024-12-09	2026-12-08	4058419.27	880	\N	5	880
2242	36	2024-10-13	2025-11-21	5051945.27	879	\N	5	879
2243	35	2024-08-17	2026-03-09	5124879.80	825	\N	5	825
2244	36	2024-01-24	2026-03-11	8748.18	515	\N	5	515
2245	18	2024-12-13	2025-08-05	6277451.12	376	\N	5	376
2246	37	2024-01-21	2026-07-14	5865942.47	382	\N	5	382
2247	19	2024-11-04	2026-12-21	1143217.19	144	\N	5	144
2248	20	2024-12-07	2025-06-28	849131.24	771	\N	5	771
2249	19	2024-05-11	2026-10-26	3714265.17	505	\N	5	505
2250	34	2024-03-12	2026-04-19	4034781.37	516	\N	5	516
2251	19	2024-12-15	2025-11-05	1707729.49	62	\N	5	62
2252	34	2024-03-27	2026-10-20	5630453.51	136	\N	5	136
2253	37	2024-09-01	2025-11-30	1429153.20	300	\N	5	300
2254	19	2024-11-29	2026-07-15	6950948.08	569	\N	5	569
2255	20	2024-10-18	2026-11-30	5332038.74	414	\N	5	414
2256	37	2024-07-10	2026-12-05	9425667.64	67	\N	5	67
2257	35	2024-01-06	2025-10-03	547792.18	225	\N	5	225
2258	20	2024-11-23	2026-11-27	2365887.98	525	\N	5	525
2259	18	2024-10-13	2026-10-10	2787168.12	634	\N	5	634
2260	34	2024-09-13	2026-10-18	5042454.16	102	\N	5	102
2261	36	2024-11-17	2026-02-16	5187251.37	937	\N	5	937
2262	37	2024-01-05	2025-09-04	5530261.81	49	\N	5	49
2263	35	2024-11-04	2026-09-23	3444697.50	557	\N	5	557
2264	19	2024-09-04	2025-10-19	371418.51	24	\N	5	24
2265	36	2024-04-11	2025-12-18	4506607.14	304	\N	5	304
2266	19	2024-02-16	2026-07-23	5715454.31	988	\N	5	988
2267	20	2024-01-04	2026-10-08	1679442.44	680	\N	5	680
2268	34	2024-08-06	2026-04-19	6901565.63	687	\N	5	687
2269	35	2024-02-23	2026-06-09	5260233.54	449	\N	5	449
2270	18	2024-06-03	2025-07-27	481905.91	171	\N	5	171
2271	36	2024-09-19	2026-10-30	1175851.63	434	\N	5	434
2272	20	2024-05-14	2026-10-12	6562999.63	498	\N	5	498
2273	19	2024-04-04	2026-08-08	6681261.11	685	\N	5	685
2274	19	2024-05-09	2025-06-18	6958393.72	253	\N	5	253
2275	20	2024-10-03	2025-10-21	9303662.57	466	\N	5	466
2276	34	2024-04-23	2025-11-11	800024.54	591	\N	5	591
2277	20	2024-05-12	2026-04-21	7783668.33	423	\N	5	423
2278	17	2024-03-31	2025-08-17	2706037.83	493	\N	5	493
2279	18	2024-10-12	2026-03-16	165764.38	970	\N	5	970
2280	17	2024-11-26	2026-06-26	5654589.07	647	\N	5	647
2281	36	2024-04-27	2025-09-18	1389210.56	722	\N	5	722
2282	34	2024-03-17	2025-08-29	5553223.06	631	\N	5	631
2283	36	2024-05-25	2026-06-27	4200942.45	108	\N	5	108
2284	35	2024-07-12	2026-07-12	1998031.19	781	\N	5	781
2285	35	2024-01-04	2026-10-22	4515704.44	630	\N	5	630
2286	20	2024-06-10	2026-06-18	6206335.17	289	\N	5	289
2287	34	2024-07-25	2026-10-20	7575518.05	777	\N	5	777
2288	34	2024-01-19	2026-08-20	2514610.73	962	\N	5	962
2289	20	2024-11-30	2025-12-22	1764123.18	325	\N	5	325
2290	17	2024-12-24	2026-08-27	7960802.36	526	\N	5	526
2291	18	2024-03-14	2025-06-26	2342989.08	883	\N	5	883
2292	36	2024-12-02	2026-02-26	4227167.67	573	\N	5	573
2293	18	2024-07-10	2026-09-15	840494.16	36	\N	5	36
2294	17	2024-10-28	2026-04-24	3699097.31	881	\N	5	881
2295	36	2024-01-07	2025-07-04	5568616.12	759	\N	5	759
2296	19	2024-06-20	2025-12-25	6723818.47	873	\N	5	873
2297	36	2024-01-23	2026-10-27	451678.90	650	\N	5	650
2298	34	2024-04-09	2026-03-06	5875754.94	391	\N	5	391
2299	18	2024-11-17	2026-08-03	3343351.28	47	\N	5	47
2300	17	2024-10-23	2026-10-20	3498983.62	484	\N	5	484
2301	20	2024-01-27	2026-11-24	5724816.77	383	\N	5	383
2302	36	2024-07-27	2025-12-10	1984296.84	553	\N	5	553
2303	19	2024-08-08	2026-02-17	422922.37	252	\N	5	252
2304	20	2024-07-16	2025-10-13	8417207.20	767	\N	5	767
2305	36	2024-07-07	2026-09-29	1802817.03	897	\N	5	897
2306	35	2024-08-16	2025-11-30	5648688.69	302	\N	5	302
2307	35	2024-07-22	2026-08-04	2959996.87	395	\N	5	395
2308	17	2024-04-05	2025-09-16	8349813.06	239	\N	5	239
2309	19	2024-01-28	2026-03-14	7341956.79	606	\N	5	606
2310	20	2024-10-02	2026-01-15	708129.32	811	\N	5	811
2311	37	2024-10-19	2026-02-28	3888052.82	203	\N	5	203
2312	20	2024-03-03	2026-01-11	2922536.93	89	\N	5	89
2313	34	2024-12-18	2025-06-26	6675476.20	464	\N	5	464
2314	35	2024-06-18	2025-11-22	3305115.70	945	\N	5	945
2315	18	2024-02-24	2026-04-15	8099624.55	18	\N	5	18
2316	34	2024-04-11	2026-06-16	2892328.20	565	\N	5	565
2317	35	2024-08-21	2026-03-09	5990303.12	814	\N	5	814
2318	20	2024-03-27	2025-08-08	5788100.99	106	\N	5	106
2319	18	2024-04-04	2026-06-12	3295111.32	30	\N	5	30
2320	19	2024-03-30	2026-05-09	6239463.86	67	\N	5	67
2321	36	2024-07-22	2025-11-06	5094448.27	913	\N	5	913
2322	36	2024-03-08	2026-09-16	1166094.55	26	\N	5	26
2323	20	2024-01-13	2026-01-19	2299432.58	334	\N	5	334
2324	36	2024-05-11	2025-11-11	8209042.37	125	\N	5	125
2325	34	2024-05-08	2026-05-25	549338.75	113	\N	5	113
2326	34	2024-03-05	2026-03-19	8041045.67	975	\N	5	975
2327	34	2024-04-28	2026-10-09	1221948.96	135	\N	5	135
2328	34	2024-08-21	2026-03-05	6181463.52	623	\N	5	623
2329	35	2024-07-15	2026-11-14	3261777.15	623	\N	5	623
2330	34	2024-02-23	2026-11-09	5619936.90	690	\N	5	690
2331	20	2024-06-10	2026-05-13	7084529.44	365	\N	5	365
2332	34	2024-04-09	2026-12-18	8086353.46	358	\N	5	358
2333	18	2024-07-06	2026-06-25	7196544.17	452	\N	5	452
2334	35	2024-05-13	2025-12-28	311373.33	434	\N	5	434
2335	17	2024-09-13	2026-08-18	9862410.25	676	\N	5	676
2336	37	2024-08-21	2026-04-22	5587691.73	986	\N	5	986
2337	34	2024-06-30	2025-07-27	9811238.19	576	\N	5	576
2338	18	2024-02-25	2026-01-31	5310973.51	528	\N	5	528
2339	35	2024-07-30	2026-05-27	9559532.77	95	\N	5	95
2340	19	2024-11-21	2025-08-11	1443625.67	970	\N	5	970
2341	20	2024-10-06	2026-04-28	9680611.56	549	\N	5	549
2342	20	2024-11-30	2026-07-13	1432095.65	108	\N	5	108
2343	37	2024-05-01	2026-12-25	5295555.44	251	\N	5	251
2344	17	2024-10-28	2026-05-30	5046857.68	398	\N	5	398
2345	17	2024-09-26	2026-05-27	4607761.42	417	\N	5	417
2346	20	2024-06-20	2025-12-31	792619.04	490	\N	5	490
2347	19	2024-02-01	2025-11-17	7681162.45	396	\N	5	396
2348	37	2024-07-23	2026-02-13	780191.86	693	\N	5	693
2349	34	2024-08-25	2026-01-18	3458792.48	266	\N	5	266
2350	18	2024-05-08	2026-07-31	9455510.23	527	\N	5	527
2351	18	2024-09-05	2026-03-23	7927382.21	137	\N	5	137
2352	37	2024-10-18	2026-05-18	8449038.77	428	\N	5	428
2353	17	2024-10-07	2026-08-25	2822628.10	868	\N	5	868
2354	34	2024-09-25	2026-06-07	1548442.00	619	\N	5	619
2355	17	2024-11-05	2026-04-05	7846630.81	392	\N	5	392
2356	18	2024-01-14	2025-11-20	5949452.46	572	\N	5	572
2357	35	2024-10-24	2026-01-26	3542739.29	27	\N	5	27
2358	34	2024-11-10	2026-07-17	7192934.36	176	\N	5	176
2359	35	2024-10-31	2025-12-21	3767854.35	253	\N	5	253
2360	19	2024-05-16	2025-08-23	7718752.66	366	\N	5	366
2361	37	2024-10-03	2025-07-06	8782748.84	40	\N	5	40
2362	34	2024-10-05	2026-04-01	6395654.73	550	\N	5	550
2363	35	2024-12-13	2026-03-21	7341269.87	36	\N	5	36
2364	34	2024-01-25	2026-03-04	1391853.57	947	\N	5	947
2365	17	2024-11-10	2025-09-17	3603709.77	728	\N	5	728
2366	35	2024-09-30	2025-09-03	3345537.04	699	\N	5	699
2367	37	2024-07-25	2025-12-01	2268719.75	74	\N	5	74
2368	35	2024-07-28	2026-10-15	3320193.55	390	\N	5	390
2369	34	2024-07-23	2026-08-16	5738614.95	211	\N	5	211
2370	20	2024-01-10	2026-04-26	8329412.41	461	\N	5	461
2371	37	2024-11-20	2026-06-18	5134901.05	690	\N	5	690
2372	37	2024-03-20	2026-07-29	9245298.29	270	\N	5	270
2373	20	2024-02-14	2025-09-19	3405528.28	267	\N	5	267
2374	20	2024-04-02	2025-09-27	7951413.36	188	\N	5	188
2375	37	2024-12-11	2026-02-03	6322187.36	676	\N	5	676
2376	19	2024-11-12	2026-02-13	6802503.31	204	\N	5	204
2377	19	2024-07-23	2025-11-11	6720078.78	565	\N	5	565
2378	37	2024-05-07	2026-06-27	553779.20	781	\N	5	781
2379	34	2024-01-02	2025-11-11	3114879.13	829	\N	5	829
2380	17	2024-07-21	2026-08-13	9165969.31	353	\N	5	353
2381	35	2024-02-11	2025-07-25	6539442.61	534	\N	5	534
2382	36	2024-01-04	2025-12-27	5781100.84	299	\N	5	299
2383	20	2024-12-25	2026-09-21	710864.31	668	\N	5	668
2384	20	2024-02-11	2026-03-08	9466849.49	386	\N	5	386
2385	36	2024-01-12	2026-07-17	2748757.04	621	\N	5	621
2386	37	2024-12-07	2026-05-02	9050872.16	534	\N	5	534
2387	20	2024-01-05	2025-07-02	8023084.45	794	\N	5	794
2388	20	2024-04-26	2026-05-14	5568589.49	879	\N	5	879
2389	17	2024-04-24	2025-08-05	1265441.71	822	\N	5	822
2390	20	2024-06-21	2026-03-27	1321747.28	447	\N	5	447
2391	35	2024-01-10	2026-03-22	6001650.11	613	\N	5	613
2392	18	2024-03-03	2026-03-05	4574543.43	640	\N	5	640
2393	20	2024-04-18	2026-09-17	1669649.49	572	\N	5	572
2394	37	2024-09-04	2025-08-13	713129.98	984	\N	5	984
2395	20	2024-04-20	2026-01-15	1376807.80	322	\N	5	322
2396	20	2024-04-05	2026-10-18	456903.16	105	\N	5	105
2397	37	2024-01-06	2026-04-05	3766130.18	766	\N	5	766
2398	36	2024-12-24	2026-09-11	8727038.63	111	\N	5	111
2399	19	2024-07-22	2026-04-12	3570240.53	669	\N	5	669
2400	18	2024-11-17	2025-12-07	9287523.65	93	\N	5	93
2401	35	2024-10-09	2025-12-19	4677519.05	37	\N	5	37
2402	17	2024-07-31	2025-07-31	6194812.04	390	\N	5	390
2403	35	2024-06-23	2026-04-18	3579622.65	299	\N	5	299
2404	20	2024-04-30	2026-06-05	9524410.50	49	\N	5	49
2405	35	2024-06-25	2026-04-26	9636670.80	360	\N	5	360
2406	20	2024-02-12	2025-07-10	1943687.55	305	\N	5	305
2407	35	2024-11-28	2026-01-06	8321837.07	410	\N	5	410
2408	37	2024-10-02	2026-08-07	8945287.23	578	\N	5	578
2409	19	2024-09-28	2026-01-31	3000484.14	136	\N	5	136
2410	36	2024-04-10	2026-03-17	3633885.18	69	\N	5	69
2411	36	2024-11-05	2025-11-20	1836226.06	71	\N	5	71
2412	34	2024-10-03	2026-05-25	9445340.26	310	\N	5	310
2413	20	2024-04-26	2025-10-23	4123894.98	295	\N	5	295
2414	18	2024-02-23	2026-08-18	9907509.53	182	\N	5	182
2415	35	2024-02-05	2026-04-26	640647.26	634	\N	5	634
2416	18	2024-09-04	2026-06-26	8761810.74	346	\N	5	346
2417	34	2024-07-08	2026-10-05	3303836.10	793	\N	5	793
2418	37	2024-12-25	2026-12-21	8323431.97	240	\N	5	240
2419	18	2024-08-13	2026-12-12	4227179.20	725	\N	5	725
2420	37	2024-05-30	2026-01-04	5832263.37	128	\N	5	128
2421	36	2024-08-07	2026-08-15	8321778.36	651	\N	5	651
2422	36	2024-07-27	2026-11-17	8252021.58	57	\N	5	57
2423	35	2024-11-11	2025-08-12	552780.91	599	\N	5	599
2424	18	2024-09-25	2025-09-07	3040489.89	666	\N	5	666
2425	18	2024-12-11	2025-11-03	409914.26	883	\N	5	883
2426	34	2024-06-10	2026-01-16	9242320.48	212	\N	5	212
2427	35	2024-05-24	2025-06-30	1583240.17	875	\N	5	875
2428	36	2024-04-07	2026-04-12	5777358.49	127	\N	5	127
2429	20	2024-09-22	2026-11-26	9309814.61	358	\N	5	358
2430	34	2024-03-22	2026-05-29	5151197.34	333	\N	5	333
2431	34	2024-09-01	2026-01-17	2047072.92	645	\N	5	645
2432	37	2024-01-10	2026-06-08	6103202.39	156	\N	5	156
2433	37	2024-12-28	2025-06-09	4870228.45	251	\N	5	251
2434	18	2024-08-20	2025-09-19	116175.50	385	\N	5	385
2435	17	2024-07-09	2026-01-24	2587502.64	52	\N	5	52
2436	20	2024-05-14	2026-04-15	8512837.57	684	\N	5	684
2437	36	2024-11-27	2025-11-03	5232641.52	534	\N	5	534
2438	35	2024-09-25	2026-05-09	3008752.02	4	\N	5	4
2439	18	2024-04-02	2026-09-14	4871013.47	148	\N	5	148
2440	19	2024-09-04	2026-07-16	7376298.08	163	\N	5	163
2441	17	2024-08-07	2026-11-01	8802812.43	919	\N	5	919
2442	35	2024-01-21	2026-02-15	7986540.59	135	\N	5	135
2443	19	2024-02-27	2025-09-22	6653073.47	885	\N	5	885
2444	34	2024-06-20	2026-10-14	6991964.88	399	\N	5	399
2445	18	2024-04-07	2026-06-03	3542077.91	835	\N	5	835
2446	18	2024-12-02	2026-12-23	5582426.55	181	\N	5	181
2447	35	2024-08-07	2025-12-26	2430619.69	818	\N	5	818
2448	35	2024-09-29	2025-07-31	9690677.78	448	\N	5	448
2449	34	2024-04-27	2026-12-18	6441991.84	668	\N	5	668
2450	34	2024-12-03	2025-10-04	6702849.22	899	\N	5	899
2451	34	2024-11-02	2025-11-11	2750337.64	372	\N	5	372
2452	37	2024-02-17	2025-10-23	8550632.11	405	\N	5	405
2453	34	2024-05-26	2025-12-29	7935281.94	465	\N	5	465
2454	37	2024-07-16	2025-09-15	3151380.10	454	\N	5	454
2455	37	2024-02-14	2025-10-20	9631649.93	322	\N	5	322
2456	34	2024-02-04	2026-08-23	7499112.56	574	\N	5	574
2457	20	2024-09-27	2026-02-27	7356519.52	814	\N	5	814
2458	36	2024-09-10	2026-04-09	5075221.04	908	\N	5	908
2459	17	2024-01-04	2026-11-26	7052495.60	58	\N	5	58
2460	36	2024-01-16	2025-11-28	4733768.63	894	\N	5	894
2461	34	2024-10-02	2026-07-25	339841.60	91	\N	5	91
2462	18	2024-04-05	2026-06-21	2744971.78	487	\N	5	487
2463	37	2024-09-04	2026-06-10	9347343.16	199	\N	5	199
2464	18	2024-12-12	2026-12-08	5320670.45	800	\N	5	800
2465	35	2024-06-25	2026-08-22	168921.07	643	\N	5	643
2466	20	2024-01-15	2026-10-21	1258170.53	305	\N	5	305
2467	35	2024-07-30	2026-11-06	7977652.96	887	\N	5	887
2468	20	2024-12-05	2025-12-13	4171097.65	488	\N	5	488
2469	36	2024-10-24	2026-06-29	5044476.42	182	\N	5	182
2470	37	2024-06-22	2026-02-13	4955120.71	77	\N	5	77
2471	36	2024-12-12	2026-09-11	1217504.79	937	\N	5	937
2472	20	2024-02-06	2026-06-13	6904864.88	248	\N	5	248
2473	37	2024-10-12	2026-04-19	7508338.70	384	\N	5	384
2474	18	2024-06-10	2025-11-12	7102586.98	470	\N	5	470
2475	34	2024-09-15	2025-07-21	4722787.38	93	\N	5	93
2476	34	2024-05-17	2026-12-30	4754778.58	585	\N	5	585
2477	19	2024-11-08	2026-08-10	7488409.35	47	\N	5	47
2478	35	2024-05-03	2026-02-18	1283399.47	366	\N	5	366
2479	19	2024-08-23	2025-06-09	596280.31	877	\N	5	877
2480	35	2024-09-22	2026-02-25	3893379.85	808	\N	5	808
2481	34	2024-09-02	2025-07-16	7240553.49	766	\N	5	766
2482	20	2024-11-16	2025-12-23	8987834.26	136	\N	5	136
2483	35	2024-07-09	2026-09-24	3365948.41	254	\N	5	254
2484	37	2024-10-15	2025-12-11	974310.07	551	\N	5	551
2485	17	2024-04-01	2026-08-30	8992615.37	274	\N	5	274
2486	36	2024-11-30	2026-02-15	4752041.40	304	\N	5	304
2487	35	2024-03-17	2025-12-25	6429180.45	351	\N	5	351
2488	20	2024-01-08	2026-02-09	9543359.85	698	\N	5	698
2489	20	2024-05-28	2026-12-26	2030495.50	495	\N	5	495
2490	20	2024-09-06	2026-02-25	3347582.68	18	\N	5	18
2491	20	2024-07-22	2026-02-17	576132.04	631	\N	5	631
2492	19	2024-05-01	2026-10-06	7199750.99	729	\N	5	729
2493	35	2024-08-14	2026-12-16	1183620.49	958	\N	5	958
2494	20	2024-03-22	2026-12-31	9356632.78	836	\N	5	836
2495	18	2024-02-26	2026-11-20	7829459.59	47	\N	5	47
2496	34	2024-05-03	2026-09-17	5022101.12	465	\N	5	465
2497	35	2024-11-24	2026-03-05	1245285.38	360	\N	5	360
2498	37	2024-11-05	2026-01-16	7188564.44	526	\N	5	526
2499	18	2024-09-13	2026-04-13	1385506.91	873	\N	5	873
2500	18	2024-12-01	2026-11-27	750435.81	35	\N	5	35
2501	18	2024-04-28	2026-07-11	7856273.81	973	\N	5	973
2502	18	2024-05-13	2026-06-23	3138804.84	313	\N	5	313
2503	34	2024-07-09	2026-01-01	8989192.51	602	\N	5	602
2504	36	2024-07-14	2025-08-06	5012799.85	478	\N	5	478
2505	20	2024-03-29	2026-09-23	5063118.95	968	\N	5	968
2506	17	2024-12-15	2026-05-16	1367211.65	78	\N	5	78
2507	17	2024-04-25	2026-06-15	8119178.60	361	\N	5	361
2508	18	2024-06-24	2026-01-20	5727699.11	748	\N	5	748
2509	37	2024-01-18	2026-01-23	5488838.95	823	\N	5	823
2510	35	2024-03-28	2026-01-28	6585208.34	792	\N	5	792
2511	18	2024-11-22	2025-06-24	7185266.21	540	\N	5	540
2512	36	2024-01-15	2026-09-02	4291097.23	318	\N	5	318
2513	36	2024-04-18	2025-10-23	2603413.08	299	\N	5	299
2514	34	2024-09-15	2026-05-30	3622006.96	334	\N	5	334
2515	37	2024-12-18	2026-11-08	5182650.24	252	\N	5	252
2516	36	2024-01-29	2026-02-14	1200767.22	727	\N	5	727
2517	36	2024-07-22	2025-10-07	1461260.29	90	\N	5	90
2518	36	2024-12-11	2026-07-09	2595284.00	884	\N	5	884
2519	18	2024-10-19	2026-03-06	6793344.91	294	\N	5	294
2520	37	2024-09-19	2026-06-27	233917.04	763	\N	5	763
2521	34	2024-05-18	2026-06-18	9696975.13	265	\N	5	265
2522	37	2024-09-29	2025-11-16	8899373.96	341	\N	5	341
2523	35	2024-08-04	2026-12-10	192770.95	158	\N	5	158
2524	37	2024-03-01	2026-10-16	7683015.86	918	\N	5	918
2525	19	2024-09-10	2026-02-17	9516028.39	556	\N	5	556
2526	19	2024-09-03	2026-11-13	4084831.91	590	\N	5	590
2527	35	2024-01-12	2025-07-19	7509755.45	743	\N	5	743
2528	17	2024-11-13	2026-03-08	1429259.21	321	\N	5	321
2529	35	2024-11-13	2026-05-18	3524921.51	729	\N	5	729
2530	35	2024-05-06	2025-10-17	7457108.12	342	\N	5	342
2531	37	2024-07-16	2025-10-18	3569058.11	628	\N	5	628
2532	36	2024-09-23	2025-09-12	5829012.07	740	\N	5	740
2533	37	2024-11-15	2025-08-17	253756.28	916	\N	5	916
2534	18	2024-06-29	2025-07-07	8998741.80	49	\N	5	49
2535	37	2024-03-14	2025-11-20	5188921.98	908	\N	5	908
2536	19	2024-07-31	2025-06-24	7253573.79	404	\N	5	404
2537	17	2024-08-30	2026-10-01	9271809.38	448	\N	5	448
2538	37	2024-12-04	2026-10-01	324215.70	731	\N	5	731
2539	34	2024-08-15	2026-02-16	8818026.50	173	\N	5	173
2540	35	2024-05-29	2026-11-18	4154775.51	303	\N	5	303
2541	34	2024-03-13	2026-08-07	145250.25	682	\N	5	682
2542	17	2024-04-28	2026-09-23	7057691.62	589	\N	5	589
2543	34	2024-11-23	2026-06-25	7667905.59	714	\N	5	714
2544	37	2024-01-05	2026-07-21	8106637.13	722	\N	5	722
2545	35	2024-02-24	2026-07-03	2976439.80	119	\N	5	119
2546	19	2024-08-22	2026-08-23	581542.90	915	\N	5	915
2547	37	2024-04-03	2025-10-25	88373.52	48	\N	5	48
2548	20	2024-10-12	2025-12-07	7796015.27	688	\N	5	688
2549	17	2024-03-29	2026-09-10	4419542.02	660	\N	5	660
2550	37	2024-12-15	2026-04-26	8555909.40	657	\N	5	657
2551	36	2024-08-17	2025-10-25	3453471.82	114	\N	5	114
2552	18	2024-05-09	2026-10-03	911600.00	419	\N	5	419
2553	37	2024-04-29	2026-07-18	7245146.35	230	\N	5	230
2554	36	2024-02-08	2026-04-25	4334288.39	805	\N	5	805
2555	17	2024-12-02	2026-12-30	1938578.24	522	\N	5	522
2556	36	2024-12-20	2026-01-05	3424052.35	30	\N	5	30
2557	37	2024-04-18	2026-12-10	6483781.98	627	\N	5	627
\.


--
-- Data for Name: customer; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.customer (customer_id, full_name, gender, date_of_birth, phone, email, member_points, rank, registration_date, password, last_active_at, status) FROM stdin;
514	Emmeline MacHostie	M	1991-07-28	6134592101	emachostie0@qq.com	503	\N	2021-09-24	bO4/%pBy#mJs(C	2024-01-05	active
515	Merla Sapena	F	2004-06-03	9805776775	msapena1@dailymail.co.uk	1831	\N	2020-01-18	tO0_Ju|6qq	2024-07-31	active
516	Don Gerholz	F	1985-09-18	2171873691	dgerholz2@theatlantic.com	1841	\N	2021-12-30	fL4&}43?=FX{	2024-12-23	active
517	Shanta Astall	F	1994-08-25	6795334817	sastall3@pbs.org	2365	\N	2020-07-15	pN0,WiuM9=jNFl,b	2024-11-18	active
518	Oliy Challender	F	1988-05-01	4743380969	ochallender4@google.com	4306	\N	2022-05-08	mN7_)Qq(zKQQ	2024-08-04	active
519	Meryl Degue	M	1983-06-14	4325403843	mdegue5@joomla.org	1359	\N	2022-02-02	pS5=w_"+sj`Yi	2024-06-21	active
520	Joane Feckey	F	1993-11-09	4463972586	jfeckey6@gov.uk	2421	\N	2021-02-12	pV9`JBr36b8vsp	2024-10-28	active
521	Ardenia Wettern	M	1989-08-30	5675425703	awettern7@mozilla.org	3458	\N	2021-09-21	jL6|E+AgZgsz=i	2024-05-04	active
522	Harriott Rimer	F	1996-10-25	9696190628	hrimer8@goo.gl	4387	\N	2020-05-31	gC8&J4d$bx	2024-04-04	active
523	Vernor Antonietti	F	1989-04-07	8865111840	vantonietti9@washingtonpost.com	3954	\N	2021-08-08	dL1@B=qjn()Ayb{l	2024-02-01	active
524	Chilton Monday	F	1987-05-10	7357742697	cmondaya@youtube.com	2242	\N	2022-05-12	mM6=CG!fJun<&>6	2024-08-15	active
525	Whittaker McKelvey	M	2001-04-27	8045411092	wmckelveyb@adobe.com	2851	\N	2020-08-28	oU4$iO=}&BsGB`	2024-05-14	active
526	Chariot Whelpton	M	1985-06-06	9833229877	cwhelptonc@stanford.edu	1153	\N	2021-01-16	bJ5?dVt|P+cI<)	2024-09-13	active
527	Granville Cavanagh	F	2002-06-08	1444967850	gcavanaghd@mapy.cz	3594	\N	2021-05-25	uN9,S0Eq|D	2024-01-23	active
528	Felecia Burdell	F	1999-09-03	4395129512	fburdelle@cargocollective.com	3149	\N	2021-07-12	vP5!S8#_E+BNUhk	2024-04-19	active
529	Paddie Dahlback	F	1990-08-03	6157166469	pdahlbackf@deliciousdays.com	3478	\N	2021-11-21	nH9&=(&V~uOJS0@M	2024-12-24	active
530	Reube Sprowles	F	1984-01-26	6861503638	rsprowlesg@cnn.com	2848	\N	2021-04-02	eS0<)PY*>FE_	2024-08-13	active
531	Ruthanne Jekel	F	1999-12-24	7041687368	rjekelh@indiatimes.com	732	\N	2022-03-18	dE7!hZKrSDe)nI#	2024-01-06	active
532	Winnie Keneforde	F	1985-08-17	9005631247	wkenefordei@answers.com	4953	\N	2021-07-30	iV7`KtP|Va>Y@u	2024-04-10	active
533	Keane Callendar	F	1982-03-23	1112556996	kcallendarj@epa.gov	1572	\N	2020-09-05	lN4/5DzusPTeIFa	2024-12-16	active
534	Raf Pelos	M	2000-06-06	1833051246	rpelosk@china.com.cn	2738	\N	2022-04-05	aZ9@HN`<)84..l	2024-05-26	active
535	Belvia Swinford	F	1982-08-14	5761296787	bswinfordl@google.es	4404	\N	2020-03-05	kN7~H4x}S>Hm4BSt	2024-01-31	active
536	Reeba Haselgrove	F	1994-04-18	2451599607	rhaselgrovem@devhub.com	1468	\N	2020-01-05	xB0\\UKnXET(k*uU	2024-08-14	active
537	Cissy Cusiter	M	1999-08-22	5136187133	ccusitern@digg.com	366	\N	2021-09-11	xJ9<.WodYILgt08	2024-10-02	active
538	George Rodinger	M	1985-07-26	5659423889	grodingero@woothemes.com	3182	\N	2020-02-23	uB6)~j>d9.f	2024-10-31	active
539	Zsazsa Kimmince	F	1982-10-24	4927855057	zkimmincep@discuz.net	1315	\N	2020-06-18	kF7}jDq<ydy)nd	2024-04-24	active
540	Bambie Mewes	F	1986-08-15	6558891201	bmewesq@cloudflare.com	171	\N	2020-09-30	cQ4'*Si3An"dfdS	2024-05-30	active
541	Silas Reedick	F	1984-12-28	1288582852	sreedickr@google.com	4806	\N	2022-12-13	fH6)#o*N4a	2024-12-09	active
542	Marline Baldazzi	M	1982-10-06	9847226489	mbaldazzis@icio.us	2778	\N	2021-08-17	uB0<wo}fuYbQ	2024-03-06	active
543	Oliy Basant	F	2004-02-18	8503115129	obasantt@hhs.gov	3742	\N	2020-01-16	kD7"W$hlX\\*3qe.	2024-10-19	active
544	Jessy Althrope	F	1981-09-20	8805831003	jalthropeu@newyorker.com	1250	\N	2020-01-13	bB0@pl"I	2024-06-02	active
545	Joye Rodge	M	1991-07-17	9029023729	jrodgev@apache.org	1277	\N	2022-11-03	xM0#Mo~T`ms3G>*	2024-12-12	active
546	Broderick Le Provest	F	1996-07-13	2213243633	blew@hp.com	3687	\N	2022-11-11	aG0.Y64L6`<01hGI	2024-12-23	active
547	Hobard Offell	F	1992-10-11	7024402861	hoffellx@wp.com	1574	\N	2021-02-28	xG7?nk<nHrU8	2024-12-06	active
548	Alfredo Mandeville	M	1986-12-21	7015138505	amandevilley@indiatimes.com	1315	\N	2020-01-07	pF8)=&Ta+cBJ	2024-12-26	active
549	Becca Bagniuk	F	2003-07-04	2357279607	bbagniukz@drupal.org	3115	\N	2020-03-22	hA3,H\\8?6a3r#V&	2024-08-20	active
550	Leonid Colam	F	1992-10-06	8828648564	lcolam10@behance.net	310	\N	2021-04-19	rD2~B"tWP*q	2024-12-14	active
551	Bowie Boorne	M	1985-12-04	1044089253	bboorne11@statcounter.com	2143	\N	2022-07-27	wM1)8Xr/+@!	2024-05-17	active
552	Patricio Abramovitch	M	1992-10-18	8075491826	pabramovitch12@devhub.com	753	\N	2022-04-16	vK2?q/|ViI!J8u46	2024-05-03	active
553	Fallon Waggatt	F	1981-08-02	3806357581	fwaggatt13@flavors.me	1628	\N	2020-07-06	kL1@d('8	2024-04-21	active
554	Luis Ewells	F	1988-08-13	5169444188	lewells14@photobucket.com	3515	\N	2021-05-08	bM3+YP!RwU	2024-01-18	active
555	Deborah Youle	M	2002-11-17	6548361461	dyoule15@51.la	3727	\N	2020-02-13	kN7=?Z!CD	2024-12-04	active
556	Gardener Lorenzetti	F	2002-07-05	1787698323	glorenzetti16@engadget.com	1988	\N	2020-11-30	dI7~k!DY9>sOl	2024-05-26	active
557	Debra Sizland	M	1984-10-16	5736060282	dsizland17@jimdo.com	3728	\N	2022-12-09	lL2@f=76IUH	2024-08-06	active
558	Syd Dellenbroker	M	1985-08-05	3789854424	sdellenbroker18@umn.edu	2119	\N	2021-11-11	aX9{Ya,yyx.	2024-12-24	active
559	Lyn O'Moylan	F	1991-11-24	1957005475	lomoylan19@microsoft.com	1345	\N	2020-03-07	oY6?`e?S64o	2024-11-19	active
560	Craggie Butner	M	1998-01-19	8283385562	cbutner1a@pagesperso-orange.fr	4306	\N	2020-03-17	sT3&h#=e*@,'	2024-10-06	active
561	Karoline Coaten	F	1982-11-25	3037344988	kcoaten1b@wufoo.com	2945	\N	2021-06-11	uE6_3T/a'=h$A@	2024-09-09	active
562	Patrizio Scurrey	F	1986-02-05	7417128632	pscurrey1c@addtoany.com	3958	\N	2022-04-12	yX6?zd+`6)55P~	2024-09-03	active
563	Edi Blas	F	1995-03-15	9298587859	eblas1d@comsenz.com	1070	\N	2022-02-10	zB6%@ap4BHjn6'(	2024-02-27	active
564	Elnore Cogdon	F	1998-02-22	2532152858	ecogdon1e@samsung.com	765	\N	2021-11-09	mE7=2ym35Er35p	2024-11-24	active
565	Cristi Klaff	F	1992-11-16	9608483875	cklaff1f@ibm.com	4673	\N	2021-03-15	nE2~6M2K#.#{LSf	2024-02-29	active
566	Elwin Book	F	1997-03-02	7453926059	ebook1g@w3.org	349	\N	2021-05-16	tV7*hM3`|,zrpVi	2024-08-20	active
567	Fidelia Phetteplace	M	2000-10-13	4342178365	fphetteplace1h@amazon.com	221	\N	2022-01-28	kG2)r8OLlb@Z$_	2024-01-11	active
568	Erica Girdler	M	2003-06-04	4069232339	egirdler1i@slashdot.org	3258	\N	2022-03-25	wD8~!6t{	2024-07-02	active
569	Boniface Clayborn	F	2002-03-22	5595860374	bclayborn1j@facebook.com	4983	\N	2022-07-09	qQ9*H_=P<	2024-05-17	active
570	Shaylah Blindmann	F	1996-04-14	4393848807	sblindmann1k@marriott.com	4959	\N	2022-07-14	fO0&)%@Q=cd	2024-05-01	active
1	Nguyen Van A	M	1990-01-01	0901000001	a.nguyen@email.com	21	silver	2024-06-01	password1	2025-06-01	active
2	Tran Thi B	F	1992-02-02	0901000002	b.tran@email.com	21	silver	2024-06-02	password2	2025-06-01	active
3	Le Van C	M	1988-03-03	0901000003	c.le@email.com	21	silver	2024-06-03	password3	2025-06-01	active
571	Ally Renzo	M	1995-11-09	7345636600	arenzo1l@sciencedaily.com	400	\N	2021-03-29	dF5&&ZU}k|NKh	2024-10-18	active
572	Daron Hadleigh	F	1985-10-19	6657366151	dhadleigh1m@mapquest.com	4291	\N	2021-11-05	bD0?v6)y	2024-10-08	active
573	Llewellyn Merigot	F	1991-09-30	3507086573	lmerigot1n@example.com	811	\N	2022-10-14	oB2#KG6F{u	2024-02-23	active
574	Burch Akitt	M	1985-03-20	4532745255	bakitt1o@icq.com	1511	\N	2020-11-17	kA8~8$KQS_.z|T	2024-10-06	active
575	Camel Anneslie	F	1992-06-04	1441332751	canneslie1p@cocolog-nifty.com	3656	\N	2021-10-07	iG6$eWo8.WhJ513}	2024-01-12	active
576	Willabella Henker	F	1993-04-16	1938309369	whenker1q@quantcast.com	4804	\N	2021-07-04	qS3/VDS.o"rv}=<m	2024-09-21	active
577	Meredith Yoselevitch	M	1994-10-27	1338848426	myoselevitch1r@howstuffworks.com	1847	\N	2020-07-21	cT1'MEgu\\Tdg*	2024-05-11	active
578	Desmond Napolitano	F	1996-07-04	9718499429	dnapolitano1s@hud.gov	2247	\N	2022-11-05	xZ5'L=1_7gksUu|r	2024-08-28	active
579	Arie Folan	M	1988-01-26	5012280520	afolan1t@europa.eu	1584	\N	2022-02-01	aZ3(#H*|kDO8	2024-01-29	active
580	Orton Ianitti	M	1983-03-03	5653779474	oianitti1u@chronoengine.com	4879	\N	2020-11-09	uN4&c<sgxMsz>)	2024-02-14	active
581	Maurizia Quiney	M	1982-04-25	4423895832	mquiney1v@amazon.de	2231	\N	2022-06-18	sT8<QZS}k	2024-01-29	active
582	Kary Jachimak	M	1982-07-26	7335688284	kjachimak1w@oakley.com	1250	\N	2022-08-05	qG7&"'{i.SVUd0F*	2024-06-13	active
583	Stanford Kedie	F	1985-05-23	2412281247	skedie1x@usa.gov	1056	\N	2022-01-03	rU0'9hE<	2024-09-21	active
584	Pryce Ever	M	1980-12-25	9508138115	pever1y@twitpic.com	4141	\N	2022-10-21	sX2`1(\\(DjL	2024-10-21	active
585	Stanleigh Few	F	1990-05-11	8255619200	sfew1z@mozilla.org	4358	\N	2021-04-13	wJ0`l'!yEi>I(@nh	2024-12-18	active
586	Gabriella Oliva	M	1996-03-10	6377896969	goliva20@earthlink.net	149	\N	2021-07-13	eS0'Nc&73.V+f2B	2024-08-23	active
587	Nealy Ranger	F	2001-03-01	6704129396	nranger21@webeden.co.uk	2587	\N	2021-05-22	yW0@!)ppP9A	2024-01-22	active
588	Porter Tatchell	M	1987-11-30	9799717559	ptatchell22@seattletimes.com	3298	\N	2022-12-08	nJ3('e+})k	2024-08-06	active
589	Lissy Corkel	F	1981-04-16	9852729742	lcorkel23@friendfeed.com	4969	\N	2021-12-26	aX9{mm`O)5h&u5	2024-04-22	active
590	Gerek Neal	M	1980-12-14	1852780275	gneal24@jimdo.com	1008	\N	2022-02-20	lA8{Y>6{(kM7?+D	2024-07-31	active
591	Domenic Fanthome	M	1982-03-27	8766455669	dfanthome25@weather.com	4715	\N	2020-08-20	oS6#(RtlN	2024-11-23	active
592	Sheffield Syder	M	1980-02-03	5821619517	ssyder26@addthis.com	4152	\N	2021-09-29	aB9%EknfMeT	2024-12-08	active
593	Grenville Stacey	M	1981-11-03	4212662686	gstacey27@intel.com	1512	\N	2021-03-16	dL8{PlD`@~I7ARVZ	2024-12-29	active
594	Hillard Duggan	F	1994-04-07	6477109658	hduggan28@imageshack.us	1319	\N	2020-04-09	bZ5>O.?b!Vcu@*_	2024-10-14	active
595	Turner Redmell	F	1999-11-25	2924226409	tredmell29@adobe.com	109	\N	2021-10-31	wN4@r7ev	2024-12-16	active
596	Carmine Sowersby	M	1981-09-01	7356778122	csowersby2a@mozilla.org	57	\N	2022-11-02	gE6&g\\PY|	2024-06-16	active
597	Ilse Fenners	F	1980-01-20	1359897503	ifenners2b@stumbleupon.com	1353	\N	2022-03-09	zX9`vkLu>naAn"}V	2024-09-19	active
598	Ransell Braybrooks	M	1986-12-05	3749488816	rbraybrooks2c@trellian.com	811	\N	2022-10-05	uE6~y_Uq(0M>3l~l	2024-02-12	active
599	Sada Foresight	M	1994-10-06	3994129998	sforesight2d@soup.io	3604	\N	2021-12-28	xV3'#AhQDT	2024-05-30	active
600	Gray Ambrosetti	F	1987-07-12	1129374073	gambrosetti2e@independent.co.uk	3261	\N	2022-03-25	mV9(#@2Q	2024-01-08	active
601	Teirtza Jeandel	F	2001-01-15	9854957402	tjeandel2f@barnesandnoble.com	3166	\N	2020-02-23	cQ4_nztXI~x\\5\\	2024-06-13	active
602	Eberto Ansell	M	1992-02-09	7191198076	eansell2g@eepurl.com	156	\N	2022-10-30	iU7#H4<xn7JPYwD	2024-01-29	active
603	Brian Jesper	F	1991-09-30	6524589101	bjesper2h@earthlink.net	1910	\N	2021-11-17	mV2.wo@`	2024-11-14	active
604	Cale Ruzic	M	1987-03-03	2107962996	cruzic2i@eepurl.com	2580	\N	2022-05-18	kR5$OvM0mQ?P0N	2024-04-11	active
605	Verney Seagrave	F	1989-01-07	9364908828	vseagrave2j@multiply.com	1073	\N	2020-05-04	hN8%VN|t	2024-07-21	active
606	Tess Furmagier	F	1991-03-23	9172888348	tfurmagier2k@github.io	4733	\N	2020-08-07	oN2`6c53#	2024-10-23	active
607	Lesley Killingsworth	M	1996-08-10	3771711222	lkillingsworth2l@comsenz.com	1047	\N	2020-09-10	uB3.#)6T%_	2024-01-14	active
608	Gregoor Dresser	M	1990-07-28	4479157998	gdresser2m@nsw.gov.au	3806	\N	2022-09-10	mY7&m{QdU$VX	2024-09-20	active
609	Verne Huffy	M	1987-12-20	7821466995	vhuffy2n@wordpress.com	3997	\N	2022-06-04	mX6`podoar_TuF	2024-08-31	active
610	Gran Paggitt	M	1980-03-23	3797364822	gpaggitt2o@meetup.com	3462	\N	2020-11-26	tW0/t")Fld!N	2024-05-24	active
611	Natassia Accombe	F	1996-05-23	6817991098	naccombe2p@clickbank.net	2059	\N	2020-04-22	oZ9_|U7\\PBt`_ge	2024-02-20	active
612	Davine Lever	F	1998-08-02	3502539052	dlever2q@wsj.com	890	\N	2020-09-21	sO2<2X#|K<=	2024-03-27	active
613	Hailee Lawrenz	M	1993-03-19	8367510497	hlawrenz2r@apache.org	336	\N	2020-08-13	uZ3_j&`db*.8	2024-07-26	active
614	Reginauld Le Friec	M	1988-11-06	3474202802	rle2s@ca.gov	2815	\N	2021-07-26	nJ8}4ugG4	2024-08-21	active
615	Ardelle Mountney	F	1996-09-24	4355262069	amountney2t@nhs.uk	1275	\N	2020-06-05	eP3$!ky*1BLD1?@k	2024-12-06	active
616	Alford Reyner	M	2004-09-03	6138642709	areyner2u@hao123.com	4793	\N	2020-08-08	pK0`mLCka6j/Y#	2024-04-21	active
617	Deni Petch	F	1980-07-27	9645510732	dpetch2v@etsy.com	787	\N	2022-10-01	kF6##Sk1	2024-09-13	active
618	Nickey Habishaw	F	1996-08-07	8556881612	nhabishaw2w@squidoo.com	4268	\N	2022-10-16	sK3}dn3M?~)C|YJ+	2024-11-08	active
619	Rozamond Hauxwell	F	1993-07-19	5096131569	rhauxwell2x@goodreads.com	1892	\N	2021-02-13	cZ5'=}j~,pU|	2024-01-24	active
620	Celle Berndt	M	2001-05-14	7584907217	cberndt2y@symantec.com	3040	\N	2021-09-15	gM5&FOJwtTsD	2024-10-17	active
621	Megan Munby	F	1992-07-01	6564552825	mmunby2z@free.fr	2213	\N	2020-03-28	eA1?SXw>lnP	2024-08-26	active
622	Richmound Whittuck	F	2000-10-22	9064103522	rwhittuck30@examiner.com	4736	\N	2022-01-14	tQ7\\{1!S1fP|~	2024-08-25	active
623	Melina Baylis	M	1999-03-09	3945750683	mbaylis31@addtoany.com	2920	\N	2020-07-09	wB8&vNKD}7l3}OW{	2024-07-19	active
624	Halimeda Jakoubec	M	1988-04-20	8086105627	hjakoubec32@foxnews.com	4127	\N	2020-04-19	mU1/h~IXJ$7YG6	2024-04-18	active
625	Minta Baudichon	M	2000-09-22	9215253512	mbaudichon33@microsoft.com	1959	\N	2020-10-16	hE3@yr+y.	2024-09-29	active
626	Dmitri Haime	M	1997-07-15	7092607965	dhaime34@ebay.co.uk	112	\N	2021-09-21	eW9_/#H+Y	2024-08-16	active
627	Cart Odgers	F	1988-12-16	8195924399	codgers35@quantcast.com	2802	\N	2021-09-04	gM7_dk!2{2U{7	2024-03-13	active
628	Lacey Lascell	F	1988-04-23	2688454791	llascell36@twitter.com	1710	\N	2022-08-12	jH1=V_9km	2024-12-01	active
629	Sherilyn Timcke	M	1994-11-19	9189773686	stimcke37@gov.uk	264	\N	2020-12-01	wC9",k"i}tF3M	2024-01-31	active
630	Cherie Cluely	M	1988-04-09	3927441497	ccluely38@intel.com	4938	\N	2020-10-17	hA5+fH0A8	2024-01-26	active
631	Katerina Burlingham	F	2004-07-16	6609401092	kburlingham39@stanford.edu	2264	\N	2020-06-16	aN5(4,_"rJ)n&	2024-12-27	active
632	Cleopatra Baskeyfield	M	2002-03-30	4986630581	cbaskeyfield3a@earthlink.net	231	\N	2022-08-15	eM6>C'aw	2024-01-13	active
633	Nicky Merrikin	F	1987-11-25	1136049698	nmerrikin3b@merriam-webster.com	4439	\N	2020-08-10	fC8<QRrI.5fH?CV	2024-09-19	active
634	Liliane Oxherd	F	1984-05-12	7103789890	loxherd3c@privacy.gov.au	4363	\N	2020-05-25	uR5`l\\K@CrXRw6K7	2024-11-26	active
635	Marina Seaking	F	1983-01-28	4515993038	mseaking3d@huffingtonpost.com	262	\N	2021-04-23	sF7#(_`ObD	2024-03-09	active
636	Kamillah Garnson	F	1989-07-03	1209470964	kgarnson3e@amazon.com	949	\N	2021-04-03	jS6`@REn	2024-06-30	active
637	Kaia Bewshaw	F	1992-06-15	2356759357	kbewshaw3f@sina.com.cn	2524	\N	2021-03-03	xF5{!Z20/)30kXP?	2024-06-30	active
638	Albrecht Birchner	M	1987-11-29	5257439872	abirchner3g@acquirethisname.com	601	\N	2022-11-23	cT9)EF,Gq%	2024-03-08	active
639	Clemente Foad	F	1994-07-16	9357330221	cfoad3h@wsj.com	2118	\N	2021-08-26	gO7~90"t%	2024-01-11	active
640	Sheffie Strode	M	1982-10-12	2012188652	sstrode3i@artisteer.com	2973	\N	2021-11-10	mV3=a98\\Me	2024-02-26	active
641	Mickey Giacubbo	F	1993-01-19	2365714335	mgiacubbo3j@statcounter.com	4674	\N	2022-10-05	rL9@{tqm_eZ,uzOY	2024-03-04	active
642	Bowie Careswell	F	1989-07-15	4675083529	bcareswell3k@51.la	3396	\N	2021-04-03	pV3{B%NO}BZ	2024-06-05	active
643	Sheilakathryn Sawell	F	1982-02-21	7806227478	ssawell3l@goo.gl	2937	\N	2020-11-09	oX4#MvCYOe	2024-11-30	active
644	Gwenore Rapkins	M	1998-11-03	3925859642	grapkins3m@cbslocal.com	2252	\N	2020-06-06	hF5#<tGttfI0X	2024-12-18	active
645	Chick Clemintoni	F	1982-01-21	8846322245	cclemintoni3n@meetup.com	2469	\N	2022-08-21	iN7.QSE8r3{ow3	2024-05-29	active
646	Xever Foxon	F	2002-09-21	5687174874	xfoxon3o@google.ru	4037	\N	2022-12-30	iZ1}UF}d(p{JIFcc	2024-07-15	active
647	Silvia Gissop	F	1985-10-15	3045685532	sgissop3p@irs.gov	1613	\N	2022-03-07	eD0&N~oN%7	2024-08-16	active
648	Henriette Rosenzveig	F	2001-05-14	3855730794	hrosenzveig3q@dell.com	3209	\N	2020-10-02	gE9'9)jdUJ	2024-04-05	active
649	Ekaterina Chittleburgh	M	1982-02-02	6545919617	echittleburgh3r@csmonitor.com	1576	\N	2021-01-03	iW0*>siTG<Ef4Gw	2024-05-09	active
650	Rivi Strand	M	1981-02-26	9791143989	rstrand3s@xing.com	731	\N	2021-01-03	yW0*l=mvvwzCElk	2024-11-12	active
651	Prentiss MacGahy	F	2003-07-31	9617514920	pmacgahy3t@meetup.com	3750	\N	2022-09-11	pN7>_{8Qh	2024-06-06	active
652	Arlette Purrier	F	1995-11-27	9103948806	apurrier3u@barnesandnoble.com	4320	\N	2022-12-21	zH8\\/<@dn==_	2024-02-19	active
653	Hayward Middle	M	1992-07-02	1251766801	hmiddle3v@livejournal.com	2819	\N	2021-11-20	xI2|}.Y9VF/n#M	2024-05-22	active
654	Charlotte Freke	F	1998-05-13	4509455765	cfreke3w@indiatimes.com	4760	\N	2020-09-15	tT5##"}C)4*0	2024-09-05	active
655	Nikoletta Blockey	M	1986-06-13	6695785427	nblockey3x@weibo.com	3948	\N	2022-11-26	wU8'cE8k|+	2024-11-24	active
656	Jerome Tippell	F	1991-10-30	4659550674	jtippell3y@1688.com	2449	\N	2021-07-31	jW0%JbPh3	2024-01-23	active
657	Filia Stainsby	M	1992-08-01	6067512045	fstainsby3z@house.gov	473	\N	2022-07-24	dA7`X&RS_/Uo	2024-06-22	active
658	Ivonne Drei	F	2003-09-05	2917589640	idrei40@pagesperso-orange.fr	1088	\N	2020-03-06	fK2&z)leo*	2024-05-30	active
659	Pamela MacCollom	F	1994-09-30	3506673651	pmaccollom41@tripadvisor.com	3727	\N	2020-12-12	fV5~K66"&Eu	2024-08-14	active
660	Kahlil Lowery	F	1988-09-09	9651186797	klowery42@t-online.de	2821	\N	2021-04-25	nB6`#Nx*cU'mtU	2024-12-27	active
661	Rudie Baxstar	M	1997-10-03	4769499941	rbaxstar43@ucla.edu	4752	\N	2022-05-11	pL2{hEmUz.&	2024-07-01	active
662	Ilyse Tarren	F	1987-12-24	4493540021	itarren44@stanford.edu	4085	\N	2020-06-09	sI6"(4je8Mirf	2024-07-05	active
663	Roger Rogans	M	1985-08-14	5217882877	rrogans45@nbcnews.com	4793	\N	2021-01-15	yL9@qU07Ye~C5+	2024-12-31	active
664	Leroy Lammerich	F	1986-01-03	7761463056	llammerich46@aboutads.info	3013	\N	2020-03-11	uT1%1P~+K	2024-10-24	active
665	Pansie Haxell	F	1992-12-15	1222195586	phaxell47@newsvine.com	4341	\N	2020-12-29	jD4\\5J+a	2024-12-06	active
666	Chauncey Boden	M	1995-01-29	3389182901	cboden48@nytimes.com	3252	\N	2022-06-25	mC5{Y?Ce	2024-12-03	active
667	Valerye Davidy	M	1990-11-21	7297062324	vdavidy49@com.com	1981	\N	2022-10-28	kO4?i/jh	2024-02-18	active
668	Chandal Wytchard	M	2001-04-08	7824160334	cwytchard4a@360.cn	57	\N	2022-08-05	lN4=AEBy8hK	2024-11-27	active
669	Hannah Bilam	F	1992-10-24	3397386333	hbilam4b@yolasite.com	2164	\N	2021-08-13	lF9\\T,ddGegFM%	2024-04-17	active
670	Bord Mockler	M	1982-03-09	6555820417	bmockler4c@ibm.com	3104	\N	2022-12-24	zF1\\iH_u#!	2024-09-28	active
671	Lorne Skotcher	M	1986-07-30	4311975294	lskotcher4d@ucoz.com	3732	\N	2020-02-07	aR8%6P+a9K	2024-03-25	active
672	Margarethe Borris	F	1993-09-14	3408273443	mborris4e@cnbc.com	223	\N	2021-08-10	oS8=\\FYv~Z}"_YFI	2024-11-25	active
673	Neila Kraut	F	1984-02-29	6226447268	nkraut4f@shutterfly.com	2875	\N	2022-10-15	oY7&g/prp0"J9V&	2024-05-14	active
674	Glenine Lanegran	F	2004-02-24	5992610330	glanegran4g@privacy.gov.au	4793	\N	2021-04-05	aF9!4G<>r	2024-08-08	active
675	Alphonse Tracey	M	2000-02-20	2093902426	atracey4h@hugedomains.com	1377	\N	2020-07-06	zA3'(|k&uN18/	2024-05-23	active
676	Dulsea Seyers	F	1996-05-29	8564746651	dseyers4i@google.es	3263	\N	2022-09-30	bS1/1Eb_Yv9x&/b	2024-11-07	active
677	Cheryl Rebillard	M	2004-08-06	8347788316	crebillard4j@deliciousdays.com	4028	\N	2021-02-02	mL0!_WxSI_65,Vo7	2024-11-01	active
678	Pammie McCourtie	F	1996-03-28	7748934799	pmccourtie4k@businessinsider.com	410	\N	2020-07-17	vB3}{=8'/	2024-12-29	active
679	Sky Growden	M	1984-06-12	7504182654	sgrowden4l@qq.com	2471	\N	2020-01-01	xW8`EhTaL1s<<3xa	2024-08-20	active
680	Chariot Mighele	F	1986-02-19	1683323559	cmighele4m@amazon.com	1883	\N	2021-11-13	bM0.xon_uNn~%CTi	2024-05-01	active
681	Dolorita Stiff	F	1981-08-07	4796486994	dstiff4n@princeton.edu	4446	\N	2022-12-09	rS5"d.*"N"fY@z#+	2024-06-07	active
682	Levy Leonida	F	2004-04-16	8503249549	lleonida4o@ezinearticles.com	2203	\N	2022-02-02	gQ3=WBRhmKx"9`mi	2024-04-09	active
683	Camey Mulder	F	1981-04-29	4854192852	cmulder4p@example.com	1411	\N	2021-05-30	kY4.'|}8=s6whvNv	2024-06-16	active
684	Cassius Dunkerton	F	1990-03-18	8088961562	cdunkerton4q@dyndns.org	2934	\N	2022-06-02	gN6|`Hx8g3&PP@	2024-06-05	active
685	Codi Chalke	M	1995-08-04	1771235627	cchalke4r@shinystat.com	407	\N	2021-02-21	cR9_e>XeCT(6a	2024-08-27	active
686	Poul Panketh	F	1992-11-07	4259992932	ppanketh4s@nba.com	4508	\N	2022-04-20	hZ8.IGdz/	2024-06-23	active
687	Gleda Yearnes	M	1990-07-15	7448717486	gyearnes4t@mit.edu	4815	\N	2020-02-28	qA4%i?6AOCP'zv	2024-02-23	active
688	Andree Larchier	F	2002-02-23	9264491140	alarchier4u@wiley.com	1426	\N	2022-11-07	cP5(<./ZJC"3	2024-09-20	active
689	Esther McMurraya	F	1981-12-03	9217711332	emcmurraya4v@samsung.com	941	\N	2021-07-22	rK5<"_8s	2024-02-19	active
690	Kalila Carriage	F	1982-11-19	8997560772	kcarriage4w@wisc.edu	4548	\N	2022-10-28	kK8(67JKCT	2024-11-08	active
691	Levy Lamey	M	1990-07-08	9793584854	llamey4x@creativecommons.org	240	\N	2022-08-22	kX0+sQT|	2024-06-15	active
692	Demeter Cribbott	F	1982-11-06	9157862382	dcribbott4y@webeden.co.uk	1690	\N	2021-10-25	oY0>7yC&oHNU}j	2024-10-15	active
693	Clarie Chart	M	2000-07-01	4038824347	cchart4z@icq.com	4595	\N	2020-10-07	xJ0}=P<Z@S)|	2024-12-29	active
694	Cece Castella	F	1985-03-22	5349228992	ccastella50@alibaba.com	2302	\N	2020-04-19	kM6=1kT#d	2024-08-20	active
695	Donal Conibere	M	1981-06-10	7204334370	dconibere51@blogs.com	4779	\N	2022-11-06	lF6*ya(3\\>'	2024-10-12	active
696	Phylys Beyn	F	2002-03-20	6096083091	pbeyn52@a8.net	4214	\N	2021-10-14	qW9(et)IZ{r1%R\\	2024-03-09	active
697	Angela Gives	M	1995-04-02	7033587759	agives53@gnu.org	4598	\N	2020-12-05	bV7}2t")|YZ\\`k{	2024-03-20	active
698	Trina Yoseloff	M	1985-02-13	4186044585	tyoseloff54@mozilla.org	3123	\N	2021-12-16	mQ8@>o,_EN	2024-06-02	active
699	Ogdon Elgar	M	2004-10-20	9604386944	oelgar55@csmonitor.com	1060	\N	2022-11-19	vM2)@,C`&I0|$O7	2024-05-20	active
700	Matthieu Buffin	M	2001-03-23	1376013477	mbuffin56@samsung.com	314	\N	2021-03-19	rU1/F"z`	2024-02-02	active
701	Laurette Shambroke	F	1995-06-22	6605271740	lshambroke57@stumbleupon.com	1551	\N	2021-08-09	wW4'$xu<l?I0	2024-10-18	active
702	Lissie Cossor	M	1990-05-05	2766247865	lcossor58@theglobeandmail.com	3431	\N	2022-03-20	aC8#T.XJmsS8+)6	2024-08-20	active
703	Vasilis Duer	M	1996-11-29	2073322700	vduer59@squarespace.com	4936	\N	2021-01-14	cH8.iMW=	2024-02-19	active
704	Ambrosio Hacard	M	1995-01-12	4963739659	ahacard5a@goodreads.com	4630	\N	2021-12-11	lF0\\XDFl9_&ZJf	2024-04-07	active
705	Shermie Gilfoy	M	2003-02-23	8669757325	sgilfoy5b@blog.com	3078	\N	2021-02-01	eM2(4vW|oCI%}4>	2024-07-16	active
706	Jemie Cuberley	F	2000-11-21	4316257761	jcuberley5c@reference.com	3127	\N	2020-09-01	qC0"8MK91Z	2024-04-25	active
707	Nick MacCrossan	M	1987-07-13	9414910544	nmaccrossan5d@google.com.br	783	\N	2021-03-17	lG4@tE4"8Y	2024-08-21	active
708	Stormy Petrelli	M	1983-06-17	1252913410	spetrelli5e@last.fm	1754	\N	2021-09-02	lK6*VeT,#Yo,V	2024-03-17	active
709	Willem Weymont	M	1985-05-05	3478159922	wweymont5f@nba.com	4035	\N	2022-04-15	fO0!0+hHY0g=i?_	2024-01-25	active
710	Ware Scyone	F	1988-03-17	3147769076	wscyone5g@github.io	4672	\N	2021-05-17	zJ1*idtbb	2024-01-16	active
711	Dukey Jorge	M	1983-01-09	9624570943	djorge5h@boston.com	3786	\N	2022-10-08	cL0?}%HW9h=SrV=(	2024-10-24	active
712	Winston Matuskiewicz	F	1994-12-14	7787113451	wmatuskiewicz5i@bloglines.com	2336	\N	2020-07-25	eX2{H9d`nF	2024-08-24	active
713	Quintana Liddon	F	2001-08-22	5213834018	qliddon5j@nifty.com	3339	\N	2020-10-30	nD5(ef&R(RL	2024-08-12	active
714	Cristobal Abramsky	M	1985-11-19	4039788880	cabramsky5k@illinois.edu	2880	\N	2020-02-11	tF8.LyM$@9$WMPP'	2024-12-04	active
715	Lucinda Hurne	M	1983-05-21	9844877309	lhurne5l@printfriendly.com	114	\N	2022-05-21	mG8/8DW7	2024-06-30	active
716	Eloise Chaloner	M	1982-03-29	4436630023	echaloner5m@house.gov	4502	\N	2021-11-10	iL7>|U1l	2024-06-09	active
717	Truda McCleary	F	2000-09-16	5853151570	tmccleary5n@ustream.tv	4842	\N	2021-02-15	eS1.Gl+AE5oS	2024-07-13	active
718	Mellie Helis	F	1986-02-27	4124405602	mhelis5o@bloglines.com	4607	\N	2021-05-02	tI7`$VpX	2024-10-08	active
719	Barron Deering	F	2000-03-09	1508107127	bdeering5p@php.net	4784	\N	2022-01-07	jO2*VF9'MgGSDKDk	2024-07-26	active
720	Janaye Winteringham	M	1984-05-18	1375952332	jwinteringham5q@sogou.com	4367	\N	2021-09-18	iC4`8dm%ug|G5	2024-03-20	active
721	Fedora Telling	F	1989-08-19	1666518378	ftelling5r@fotki.com	618	\N	2021-08-27	oV1'{(_nU8u\\P1p	2024-12-01	active
722	Rod Pretswell	M	1981-08-23	7836536595	rpretswell5s@patch.com	1499	\N	2022-09-07	jP4'1W9Vr%gb8.@	2024-04-07	active
723	Rayshell Dufaire	F	1999-04-18	3291449162	rdufaire5t@paginegialle.it	3079	\N	2021-10-17	dY9.Gbku	2024-11-08	active
724	Benji Sinkin	M	1992-12-07	4128241370	bsinkin5u@harvard.edu	2842	\N	2021-09-04	eW9)P@hcO!GU	2024-04-05	active
725	Tracie Tschierasche	M	1980-02-23	8997816203	ttschierasche5v@yellowpages.com	4656	\N	2022-09-03	hR7}q+yw	2024-11-06	active
726	Harley Mathias	F	1985-10-12	1076983847	hmathias5w@dropbox.com	1991	\N	2021-11-30	gM9}`wMxWw}'ep	2024-06-29	active
727	Rhianon Atte-Stone	M	1991-10-26	8664063082	rattestone5x@constantcontact.com	249	\N	2021-02-15	gE0$1%SLf~(	2024-06-05	active
728	Isak Dunseath	F	1994-06-23	7026876022	idunseath5y@vinaora.com	2873	\N	2020-08-25	mW2"2!~LL	2024-05-09	active
729	Ives Kinmond	M	2000-04-10	6915186325	ikinmond5z@w3.org	1746	\N	2022-05-01	sX8`bpQoAQS	2024-11-04	active
730	Barb Colliss	F	2003-03-10	5137432236	bcolliss60@yahoo.com	462	\N	2020-03-03	kW6$gFy~vY	2024-02-10	active
731	Milton Mayo	M	1999-01-08	7756217736	mmayo61@ehow.com	1704	\N	2021-01-05	kC7/#czf#f	2024-03-08	active
732	Verna Fleetwood	F	1980-09-07	1147670123	vfleetwood62@unicef.org	2761	\N	2022-12-30	rK0>U,xR!	2024-04-29	active
733	Harri Derby	M	1989-10-13	8834254018	hderby63@wunderground.com	2718	\N	2020-01-27	qV7~J4C3	2024-10-29	active
734	Clair Breckell	F	1993-11-26	6066064966	cbreckell64@ameblo.jp	837	\N	2021-06-27	gN7'+9LMwMK	2024-01-15	active
735	Eveline Sneezum	M	1981-08-28	8426102048	esneezum65@studiopress.com	4684	\N	2022-01-03	zV8{|rh@"M2	2024-11-22	active
736	Angil Acland	M	1993-03-07	3676063714	aacland66@nydailynews.com	1550	\N	2021-05-21	mJ1%|N|h_lC*	2024-02-11	active
737	Aubrie Dennitts	M	2001-02-08	9372195026	adennitts67@webmd.com	3963	\N	2020-09-26	rC2=x4DE!vptW	2024-05-01	active
738	Dugald Coatham	F	2002-09-24	4011091734	dcoatham68@admin.ch	1530	\N	2021-01-11	vL4~@JnS	2024-05-24	active
739	Silvia Cicchinelli	F	2001-11-11	3053563130	scicchinelli69@twitter.com	4308	\N	2020-07-17	gG3"W9}u4l	2024-11-15	active
740	Gwendolin Yeardsley	F	1997-04-10	8486577991	gyeardsley6a@nyu.edu	3476	\N	2020-09-24	tL0<RM`Nd	2024-05-28	active
741	Raquel Dow	F	2003-07-13	7984116115	rdow6b@wufoo.com	1776	\N	2022-02-21	uB5\\ELeMhQ(	2024-06-25	active
742	Chev Rootes	F	2003-02-12	8422505468	crootes6c@google.co.jp	2390	\N	2020-10-12	oI8/*>(PJ,M`R@_X	2024-06-29	active
743	Blanche Maccree	F	1990-03-11	3847743194	bmaccree6d@chron.com	3000	\N	2022-10-17	jX1`_C'Fv3jG0	2024-03-12	active
744	Ruttger Meachem	F	1991-09-07	2178390976	rmeachem6e@independent.co.uk	1241	\N	2021-01-21	fP0%cY4'6i4	2024-04-19	active
745	Charlena Fallowes	M	1996-07-12	5564442257	cfallowes6f@tripadvisor.com	1192	\N	2020-04-08	wO8%gzrE'eZ	2024-12-29	active
746	Lexie Biddlecombe	F	1985-04-05	6396375727	lbiddlecombe6g@issuu.com	3055	\N	2022-04-01	mN6`s=hC@>	2024-09-28	active
747	Tanhya Jiruch	F	1996-02-21	6843841249	tjiruch6h@163.com	2076	\N	2022-11-17	gH8~6m10Dg	2024-01-14	active
748	Lamar Quinnette	F	1981-04-17	8261231852	lquinnette6i@whitehouse.gov	4916	\N	2022-04-02	lU7_CN6{	2024-06-05	active
749	Delila Lonergan	M	1998-08-03	1763909009	dlonergan6j@timesonline.co.uk	649	\N	2021-02-04	aI2%*dVyRx}I_t	2024-02-03	active
750	Mead Birdsey	M	2001-01-14	1918022061	mbirdsey6k@weebly.com	731	\N	2021-02-17	lW3,*Q@Tt$<	2024-01-27	active
751	Erminia Dunn	F	1998-01-27	3933394937	edunn6l@etsy.com	2714	\N	2022-02-04	hV3|R(Fk	2024-03-17	active
752	Weber Aloigi	F	2001-06-30	3319562338	waloigi6m@amazonaws.com	2869	\N	2022-12-30	mN7##w}6P+\\&	2024-12-11	active
753	Gustav Pauletto	F	1981-07-23	5756449324	gpauletto6n@reddit.com	916	\N	2022-09-25	lI7//qY1	2024-07-09	active
754	Nanni Greenrod	F	1991-08-23	2908766769	ngreenrod6o@exblog.jp	3652	\N	2020-03-31	hG4$RkY4lc7	2024-02-08	active
755	Gerladina Benoix	F	1994-04-23	8001327830	gbenoix6p@go.com	2550	\N	2021-09-14	pH9)sOb,+u#p3Rk$	2024-06-22	active
756	Dexter Manners	M	1983-04-05	2051807376	dmanners6q@hostgator.com	4409	\N	2022-04-19	iW7(PVU=	2024-08-31	active
757	Sean Dettmar	F	2000-07-27	9382572772	sdettmar6r@timesonline.co.uk	966	\N	2020-09-23	aG9{ZB"RJi/'NS?C	2024-03-03	active
758	Marja De Mico	M	1991-08-05	6826577718	mde6s@earthlink.net	4210	\N	2020-07-11	sO2.w}Omu%F`	2024-01-05	active
759	Carol Bernard	M	2003-09-24	6743961635	cbernard6t@ning.com	129	\N	2022-01-06	sV7.>V(e<lt44WH	2024-09-27	active
760	Hanny Tennock	M	2002-08-22	8146383898	htennock6u@cpanel.net	3332	\N	2022-07-19	lS1`xE3m'aztqj	2024-01-16	active
761	Martha McGerraghty	F	2004-02-05	4123740736	mmcgerraghty6v@theguardian.com	860	\N	2020-07-08	oG0{y?2s	2024-12-13	active
762	Carson Faragan	M	1987-01-10	1466266233	cfaragan6w@macromedia.com	4945	\N	2021-02-14	iL7\\kh8|U&zLg~1>	2024-04-27	active
763	Justinn Bodill	M	1987-03-31	1017293430	jbodill6x@123-reg.co.uk	507	\N	2020-03-26	cC9_u%.=1NS	2024-02-17	active
764	Charlotte Theunissen	M	2002-05-22	5138025794	ctheunissen6y@t-online.de	2256	\N	2022-03-23	jY0.gjlz	2024-03-29	active
765	Joshuah Shackleford	M	1985-07-30	7523739164	jshackleford6z@sphinn.com	3855	\N	2021-01-01	qP2"J`AMxZpEsw	2024-05-29	active
766	Sara Harkes	M	1992-01-18	8184408888	sharkes70@dmoz.org	3583	\N	2022-09-02	aC2}p$6{&	2024-07-12	active
767	Keri Martinovic	M	1991-03-14	5305468348	kmartinovic71@amazon.co.uk	3874	\N	2020-10-21	tJ5#q&kPSK	2024-09-19	active
768	Lem Burroughes	F	2001-06-22	4135314840	lburroughes72@amazon.co.uk	4865	\N	2022-09-05	rZ5/jCV7#?pu#z(	2024-07-11	active
769	Andrea Boulsher	F	1991-09-25	5348090846	aboulsher73@amazonaws.com	1896	\N	2022-09-03	zC6(=uf.+wo	2024-12-21	active
770	Rolph Presnail	M	2000-04-07	9612325985	rpresnail74@cmu.edu	3112	\N	2022-12-14	kI3%WAhplSml3	2024-11-12	active
771	Sadye Belsey	F	2000-12-06	1921510740	sbelsey75@meetup.com	625	\N	2020-03-24	eM1&VaHb~uMn`&	2024-10-20	active
772	Bren Frensch	M	1986-11-27	8761001515	bfrensch76@storify.com	2422	\N	2022-08-31	cH5@=LJ6y(Cn.D)8	2024-11-13	active
773	Joscelin Fairlem	M	1987-06-24	6613010875	jfairlem77@wikimedia.org	372	\N	2022-02-01	jA6(Td/R3pO	2024-12-15	active
774	Pauletta Cucuzza	M	1988-02-26	5293766070	pcucuzza78@geocities.com	323	\N	2021-08-06	bU8*vG=WY|)egr$3	2024-06-28	active
775	Carmen Lawlie	F	1983-06-11	5845395769	clawlie79@prweb.com	1352	\N	2020-07-23	xH6{%A4rU6	2024-06-03	active
776	Cooper Moodie	F	1981-07-11	5319504714	cmoodie7a@dmoz.org	1154	\N	2022-01-23	bK7}cubjL0xH$n#	2024-04-27	active
777	Ilaire Faulo	F	1986-04-01	4283431128	ifaulo7b@google.it	219	\N	2022-12-19	xD5"<f5fxz<	2024-01-01	active
778	Trever Biss	F	1996-06-25	6628297968	tbiss7c@gmpg.org	1963	\N	2021-06-17	yK5@a//*i.@,jMq	2024-08-31	active
779	Evey Bretelle	M	1990-03-06	7894220368	ebretelle7d@reuters.com	504	\N	2020-07-10	iO2'"AjW(	2024-11-26	active
780	Essa Jarrel	M	1999-09-21	4946062441	ejarrel7e@home.pl	2282	\N	2020-06-18	yV9.rYX`EYl*FKAx	2024-10-15	active
781	Burk De Mattia	F	1986-07-29	3709636548	bde7f@icq.com	2494	\N	2020-01-09	vQ4"1r+!=x"L	2024-09-19	active
782	Kenon Blasius	M	1986-10-10	2106234881	kblasius7g@soup.io	1580	\N	2020-09-13	tU8"tPd8	2024-01-06	active
783	Janenna Challenor	M	1982-03-20	5431950653	jchallenor7h@wisc.edu	4338	\N	2020-06-18	xS2$uNoPq*w5frqr	2024-09-12	active
784	Early MacCrackan	F	1993-09-15	4744634402	emaccrackan7i@nps.gov	340	\N	2021-06-14	lT5{#\\,"EOX	2024-09-10	active
785	Travus Meus	M	1997-02-05	5014051494	tmeus7j@economist.com	964	\N	2022-04-26	hN0~'7\\L=	2024-03-14	active
786	Donovan Douglass	F	1985-09-07	8687906791	ddouglass7k@tripod.com	2332	\N	2021-06-10	nY2!JaD9dU	2024-06-14	active
787	Elladine Olner	F	2002-06-09	3284254698	eolner7l@google.com.au	2268	\N	2021-02-22	fU9_PlLGJ	2024-11-24	active
788	Nan Cockerill	M	1989-12-27	2707645431	ncockerill7m@loc.gov	3921	\N	2021-03-20	sZ0<2C2O	2024-07-05	active
789	Izzy McIleen	F	1980-10-20	3023888643	imcileen7n@yahoo.co.jp	2862	\N	2020-11-06	nF4{CHa9k%m?(15	2024-01-08	active
790	Amie Ghiriardelli	M	1985-01-30	3242906000	aghiriardelli7o@a8.net	966	\N	2020-12-30	vW9'!Y}LhLC\\nu	2024-12-08	active
791	Coralyn Renshell	F	1980-11-23	2459096524	crenshell7p@alibaba.com	3507	\N	2021-07-19	mR5|Xgtl	2024-01-08	active
792	Alberto Critoph	F	1990-12-09	1077623226	acritoph7q@latimes.com	3625	\N	2021-03-31	pH8.|QqTp	2024-02-08	active
793	Alana Towe	F	2003-06-04	8152497316	atowe7r@wiley.com	3612	\N	2021-03-17	hP9(<uE{@/mv(O5	2024-03-29	active
794	Dud Beedle	F	1991-12-11	3947291376	dbeedle7s@nydailynews.com	2451	\N	2022-09-25	kK9&UCwV2*qi	2024-04-18	active
795	Madella Mallison	M	1995-09-23	4004955167	mmallison7t@sciencedirect.com	2169	\N	2022-01-07	bW8!<4\\y	2024-08-21	active
796	Niccolo McFeate	M	2001-12-15	4583138587	nmcfeate7u@intel.com	4112	\N	2021-04-22	pE6'=$`fSIK	2024-04-20	active
797	Allan Twallin	F	1992-09-17	6691949811	atwallin7v@slideshare.net	3222	\N	2021-08-24	yA8\\Z#XW9I*{G	2024-12-03	active
798	Adamo Mustoo	M	2001-02-21	2204119065	amustoo7w@alibaba.com	285	\N	2021-11-18	dH3{~?g|	2024-04-06	active
799	Gerrilee Siemantel	F	1987-07-11	9978925032	gsiemantel7x@salon.com	3429	\N	2021-11-12	tI3~+'/Sfo1g	2024-07-10	active
800	Cynthia Rolf	F	1992-08-17	8348407364	crolf7y@imgur.com	2381	\N	2020-10-06	wP7!qfEWbk	2024-01-04	active
801	Pall Rolse	F	1998-01-08	7997857784	prolse7z@ftc.gov	3106	\N	2020-09-19	lG1_&4mr}_7(&w	2024-12-12	active
802	Andree Pardue	M	2000-04-27	7221302305	apardue80@foxnews.com	4576	\N	2020-07-07	fR8,Hlf7qNvjn	2024-01-09	active
803	Pooh Cow	F	1991-09-12	8669195912	pcow81@amazon.com	3127	\N	2022-01-19	wO3?FX<&|	2024-04-02	active
804	Wally Astle	F	1989-11-06	9827204147	wastle82@360.cn	3032	\N	2021-08-22	iS1'G/K{eN	2024-09-07	active
805	Harland Gorner	M	2002-06-19	9376850661	hgorner83@buzzfeed.com	3517	\N	2022-05-14	uQ5$gy&\\k	2024-11-08	active
806	Janela Fireman	F	2001-05-25	4533571312	jfireman84@newsvine.com	4013	\N	2022-07-06	fS4}6?krv0wb(	2024-06-04	active
807	Lavinia Verling	F	2000-08-03	6233082619	lverling85@cbc.ca	2585	\N	2022-10-29	eN2|h*<{PS	2024-03-06	active
808	Vivianna Frowd	F	1985-06-26	8588587910	vfrowd86@booking.com	4823	\N	2021-08-21	bT2=fi7GB	2024-01-25	active
809	Christophe Sillars	F	1993-10-30	9034462302	csillars87@census.gov	1868	\N	2021-06-10	tN1{_9o@Q?EeK5<	2024-07-30	active
810	Shannan Gabbott	F	1984-05-02	6563003703	sgabbott88@tiny.cc	1975	\N	2020-02-03	cZ6`,Rq2q7*}6#	2024-07-24	active
811	Shandeigh Pendry	F	2004-12-01	9168891808	spendry89@globo.com	996	\N	2021-05-26	iX2*S&cz&Ebn2	2024-10-04	active
812	Misha Austick	F	1993-12-12	5978683554	maustick8a@aboutads.info	3434	\N	2022-05-29	iA4~aDyl6f	2024-08-04	active
813	Estel Hellwing	M	1988-04-07	5986293414	ehellwing8b@ycombinator.com	4635	\N	2021-08-28	bR8/M"`I|O	2024-12-31	active
814	Deva Greystoke	M	1999-07-29	1856573204	dgreystoke8c@goo.gl	1051	\N	2020-01-19	jN5.fG0EB>fp#mZR	2024-05-08	active
815	Patti Breeder	M	2000-06-18	9868646715	pbreeder8d@amazon.de	1538	\N	2021-08-12	vQ1&%/<P	2024-12-15	active
816	Murdoch Yeld	F	2000-07-26	3585446381	myeld8e@joomla.org	3124	\N	2020-01-04	rS4#>%g_"S2*S	2024-03-15	active
817	Harold Lathe	M	1998-03-30	5606684183	hlathe8f@irs.gov	3070	\N	2020-01-29	sJ2#LDz|vnHF	2024-03-08	active
818	Celestyna Feldbrin	F	1996-07-31	8057814898	cfeldbrin8g@bing.com	616	\N	2022-02-14	rW5&pP+"Y.n)2k\\(	2024-02-08	active
819	Stepha Northrop	M	1995-01-05	8273453502	snorthrop8h@merriam-webster.com	3779	\N	2022-07-17	aK8)&'A<5	2024-02-03	active
820	Elle Huey	F	1997-02-18	4471024042	ehuey8i@list-manage.com	3169	\N	2021-06-16	fB1.r2K%51s	2024-04-25	active
821	Mirabel Chasson	M	1983-06-19	9858244644	mchasson8j@sfgate.com	1342	\N	2022-10-10	kD4)mEk'$k	2024-11-10	active
822	Van Farfolomeev	M	2001-05-31	2669894112	vfarfolomeev8k@globo.com	4910	\N	2021-06-19	bS2?5#lAEPM.8l3I	2024-03-22	active
823	Corinne Arkill	M	2004-06-29	3664299711	carkill8l@blogspot.com	4414	\N	2020-04-18	rS6'Z!'L	2024-06-14	active
824	Sandi Steinson	M	1997-05-06	6094481507	ssteinson8m@w3.org	2069	\N	2021-02-19	kL5_,7B0W2U	2024-12-03	active
825	Jessie Tunno	F	1982-03-14	7752892328	jtunno8n@miibeian.gov.cn	4045	\N	2021-07-05	lI5.mY1,l?i8ZpJ	2024-04-29	active
826	Gertrudis Hazelhurst	F	1990-06-07	4016395206	ghazelhurst8o@china.com.cn	4091	\N	2020-11-04	oX6(V1WTS	2024-08-31	active
827	Michale Giffon	F	2002-12-23	9257310969	mgiffon8p@sfgate.com	661	\N	2022-11-21	bC7,pqU>0	2024-02-04	active
828	Harwilll Lasham	F	1980-01-25	6899001301	hlasham8q@phoca.cz	4050	\N	2020-08-21	jA1$M.jO`O	2024-03-09	active
829	Elton Croyser	M	1982-03-17	3147619064	ecroyser8r@wikia.com	2553	\N	2020-07-11	xO5|Vk=T's	2024-11-22	active
830	Melvyn Moakson	F	1990-12-28	6699780036	mmoakson8s@is.gd	4491	\N	2020-03-16	nK8/IBeum26R}Yb|	2024-10-16	active
831	Kathlin Grigoroni	M	1994-03-11	3946306400	kgrigoroni8t@sina.com.cn	401	\N	2022-12-03	dQ9}TZ*b	2024-08-27	active
832	Mora Lamprecht	F	1986-05-31	3086407024	mlamprecht8u@youku.com	1454	\N	2021-12-13	pV3}Qy.4R,P0	2024-09-21	active
833	Monro Guarnier	F	2002-10-06	2353398558	mguarnier8v@live.com	3129	\N	2021-01-26	xO7=?jdd1dQX	2024-06-20	active
834	Erinn McShirie	M	1987-09-25	2885498102	emcshirie8w@reuters.com	3344	\N	2022-07-08	gG2+n*91fPnpM9E	2024-09-21	active
835	Mersey Pinner	F	1982-07-06	3422391837	mpinner8x@vk.com	3476	\N	2020-01-13	bQ7<Y'z=	2024-01-26	active
836	Harley Immins	M	2003-10-05	6033918175	himmins8y@discovery.com	4692	\N	2022-10-22	rJ3?e`EcmS,kgO	2024-01-27	active
837	Cirstoforo Jest	M	1991-02-27	5984396670	cjest8z@hatena.ne.jp	3541	\N	2020-12-23	hV7*xFE`	2024-11-15	active
838	Rosalinda Porkiss	F	1984-01-12	2755134970	rporkiss90@cmu.edu	1253	\N	2021-10-14	aN1>D@Dz{_d	2024-01-08	active
839	Wilt Pala	F	1981-02-07	6242877514	wpala91@nsw.gov.au	4017	\N	2020-12-17	cV7"H,nv?	2024-05-11	active
840	Eugenio Covotti	F	1986-03-01	1217942953	ecovotti92@yandex.ru	453	\N	2022-01-29	zH2'3bJ%7#	2024-09-10	active
841	Jelene Marriner	F	1982-02-14	6946554226	jmarriner93@shareasale.com	1201	\N	2020-12-15	xW0>yw\\ti9?Ww	2024-12-06	active
842	Karlen Parlor	M	1994-09-13	9295323413	kparlor94@narod.ru	1975	\N	2020-10-22	hK5,18ifEZ5	2024-10-03	active
843	Stephi Gorwood	F	1992-04-05	6203858446	sgorwood95@forbes.com	4717	\N	2020-08-15	fC4"\\CvJSfD`oWwB	2024-11-15	active
844	Rebeca Hatwells	F	1986-04-25	5316922699	rhatwells96@blogger.com	2287	\N	2021-05-21	bB4!KY7Al07n`O	2024-09-05	active
845	Norrie Fransewich	F	1989-11-09	3609086856	nfransewich97@home.pl	3233	\N	2020-05-08	fZ1'byi1K4XVsJ1	2024-06-19	active
846	Chelsey Sperrett	M	1993-02-23	7496410262	csperrett98@123-reg.co.uk	100	\N	2022-08-13	lK9+o2J+|l	2024-08-23	active
847	Urbanus Broadbear	M	1984-11-02	8979949662	ubroadbear99@craigslist.org	1964	\N	2021-04-18	kN6)dIhQn_<9qT	2024-02-22	active
848	Zarah De Bruin	F	1997-06-11	1883011969	zde9a@about.me	3876	\N	2021-04-26	zD1+nwN2J(&	2024-04-04	active
849	Maggy Lampet	M	1993-01-09	6535549317	mlampet9b@yahoo.com	590	\N	2022-11-17	lX2}wo##O!ha	2024-04-22	active
850	Gardner Wheeler	F	2002-09-06	7908191608	gwheeler9c@lulu.com	2425	\N	2022-02-14	bP4%wcU~p	2024-07-07	active
851	Jefferey Antuk	M	1984-02-03	6131180450	jantuk9d@meetup.com	4178	\N	2021-08-31	cA1{XI!rW\\(j/	2024-01-11	active
852	Jerrilyn Bunnell	M	2004-11-22	1194837260	jbunnell9e@ustream.tv	1355	\N	2022-07-31	fQ9\\RM!ca	2024-11-21	active
853	Brien Philippet	F	1985-03-06	7875907102	bphilippet9f@g.co	1596	\N	2021-06-10	oO7?bSXQsM	2024-05-16	active
854	Napoleon Braybrooks	F	1992-02-29	9311123477	nbraybrooks9g@theguardian.com	2349	\N	2022-04-06	rN3*zga8KS>	2024-05-13	active
855	Phillipe Igonet	M	1994-04-11	3477823840	pigonet9h@opera.com	2481	\N	2020-03-11	dR5|O6?@d	2024-09-07	active
856	Myles Portriss	M	1998-09-09	9989417564	mportriss9i@friendfeed.com	4419	\N	2020-06-13	cV8}DlsZ"	2024-12-21	active
857	Ragnar Stratford	M	2003-05-26	2275295840	rstratford9j@bbb.org	454	\N	2021-04-04	uZ3?>C(.mw	2024-02-04	active
858	Alys Playden	M	1991-07-16	9023345180	aplayden9k@google.com.hk	3936	\N	2022-03-25	nF5>2tb*=+yb7f	2024-05-21	active
859	Jake Paxton	F	1985-02-17	1796455853	jpaxton9l@pinterest.com	2400	\N	2021-09-21	iK8=&jvz	2024-07-15	active
860	Reggis Chisnall	M	1983-05-29	3134941183	rchisnall9m@over-blog.com	2121	\N	2020-12-11	uM3<=KE46bG<m	2024-07-28	active
861	Giorgio Calrow	M	1988-10-31	2299595375	gcalrow9n@wix.com	1245	\N	2020-12-24	jW9!PR7@KpZ5)i2p	2024-03-02	active
862	Justinn Pelos	F	2002-12-31	1384173835	jpelos9o@google.es	3359	\N	2022-09-27	aS6(%~gsx	2024-11-10	active
863	Abigale Jacqueme	M	1992-12-28	1793605620	ajacqueme9p@wsj.com	3678	\N	2022-07-13	fS7=H9,8wa	2024-02-06	active
864	Earl Thaxton	F	1999-12-06	5127540019	ethaxton9q@over-blog.com	3811	\N	2021-12-02	qI3"i$<R(>QK~A7	2024-09-07	active
865	Willy Botcherby	M	2004-07-01	3389318871	wbotcherby9r@blogspot.com	4743	\N	2021-07-28	nR4,y.eY	2024-10-23	active
866	Sasha Bedrosian	F	1992-10-14	2617572545	sbedrosian9s@delicious.com	413	\N	2020-05-07	hS5/be$ygc	2024-11-19	active
867	Alika Breeder	M	2002-01-02	3935943625	abreeder9t@uol.com.br	2105	\N	2022-11-11	nY0"%Z?T	2024-11-25	active
868	Gualterio Obbard	F	1993-05-06	6801597113	gobbard9u@opensource.org	4815	\N	2020-10-26	pL6~K4"jtVys.ab	2024-04-17	active
869	Alexina Dominichelli	F	1987-11-25	6935329753	adominichelli9v@163.com	3697	\N	2020-10-01	dB3$QJBk+w	2024-02-04	active
870	Torrance Van Waadenburg	M	1994-04-23	9921233929	tvan9w@skype.com	4719	\N	2022-03-12	sJ3*2U#DHtxL	2024-11-04	active
871	Myer Holleworth	M	1992-07-06	8311845096	mholleworth9x@oaic.gov.au	4288	\N	2021-01-08	gI5#(_QU8r%zzY	2024-06-30	active
872	Chet Shewan	M	1993-11-27	3016113895	cshewan9y@ebay.com	400	\N	2021-05-17	iG8}/&xzBdq	2024-09-07	active
873	Alyce Harmes	F	1985-02-13	9321058404	aharmes9z@deliciousdays.com	4797	\N	2020-10-18	vW4~x~M6	2024-11-14	active
874	Dael Ruggs	M	1998-05-09	1655221907	druggsa0@slideshare.net	11	\N	2020-02-21	aP7/EY'/jA`P"3	2024-01-16	active
875	Christophe Willford	M	1988-02-22	6086743209	cwillforda1@etsy.com	2386	\N	2022-07-12	oJ5!pe}|>$5'2	2024-08-20	active
876	Nina Stanyforth	F	1983-08-13	9113836102	nstanyfortha2@quantcast.com	1236	\N	2021-05-30	sY5|z1Bq'xF~"12	2024-12-23	active
877	Marleen Seabert	M	2002-11-18	4095894815	mseaberta3@amazon.de	4505	\N	2022-08-08	hX1$tmW<PL,h*Iu	2024-07-02	active
878	Whitney Dupre	M	1988-09-26	6823618862	wduprea4@thetimes.co.uk	635	\N	2020-12-09	lT8(|~Q+Y78wjhZ0	2024-10-08	active
879	Brier Canny	F	1989-06-26	5738725223	bcannya5@nytimes.com	3781	\N	2021-02-05	aR6~K5yo9ntysC5	2024-03-14	active
880	Oralla Davenport	F	1984-12-18	1299281493	odavenporta6@ifeng.com	33	\N	2020-10-20	vX5,%CFugg7F	2024-07-15	active
881	Faun Pepall	F	1988-03-27	6936705064	fpepalla7@tuttocitta.it	1298	\N	2021-12-11	fP4{4%"{4U'QlK?|	2024-07-22	active
882	Maritsa Trusler	F	1984-04-14	1236059170	mtruslera8@opensource.org	306	\N	2022-08-05	pH7$Cp}36Ty#AjMW	2024-02-24	active
883	Peterus Mutlow	M	2003-08-17	8807645849	pmutlowa9@rediff.com	968	\N	2021-03-15	jH4.Y&{~	2024-10-28	active
884	Barbabra Heugh	M	1998-10-24	7192648292	bheughaa@senate.gov	4516	\N	2021-12-10	hB6@a_VlW%w/ki	2024-02-29	active
885	Laurie Raatz	M	1999-09-18	2573593141	lraatzab@pagesperso-orange.fr	643	\N	2020-02-26	qH5?%dE{2	2024-03-09	active
886	Leon Chomicki	M	1987-04-01	3221500501	lchomickiac@umich.edu	1318	\N	2022-01-12	hF7?J.8I8U	2024-12-28	active
887	Chicky D'Andrea	M	2000-01-20	7146625101	cdandreaad@example.com	2465	\N	2020-06-09	iM7<+u*a5rN	2024-04-23	active
888	Franciska Pearl	F	2001-10-10	6744356763	fpearlae@addtoany.com	1372	\N	2020-11-02	sN5/LS/8(&L'C	2024-01-16	active
889	Elenore Beall	M	1986-07-24	5696535226	ebeallaf@engadget.com	983	\N	2020-06-19	uA8,b\\m_8s._o*lh	2024-11-21	active
890	Lilas Bourdas	M	1984-02-28	5699193145	lbourdasag@free.fr	3924	\N	2022-02-05	tZ8%Na(xZ1xL	2024-04-27	active
891	Leopold Cheatle	F	1980-05-27	7702483130	lcheatleah@wired.com	1693	\N	2020-11-12	sV4`=,GcWJjM	2024-02-03	active
892	Kamila Lamport	M	1985-08-20	5202342622	klamportai@163.com	3350	\N	2020-01-09	bU8_6bNbz/B	2024-05-08	active
893	Harbert Tuxwell	F	1996-12-09	8255523016	htuxwellaj@ezinearticles.com	4036	\N	2020-07-19	iD9*+I&0d!/_(*	2024-11-17	active
894	Lory Gozzard	M	1983-10-07	7408322043	lgozzardak@dedecms.com	3387	\N	2021-03-01	rH7'UAmHp	2024-02-20	active
895	Krista Tunder	F	2002-05-20	7028336735	ktunderal@cmu.edu	560	\N	2020-12-14	oW5=?rW53)gzbG	2024-05-05	active
896	Ali Smallpiece	F	1998-07-22	3355000848	asmallpieceam@gnu.org	2669	\N	2020-07-26	iE9*cZf#(0T	2024-03-16	active
897	Charmain Costain	F	1980-09-15	5573354654	ccostainan@apple.com	4447	\N	2020-04-15	dY2#KdN?#t6/M~a	2024-04-15	active
898	Gordie Sawtell	F	1987-06-04	9438397291	gsawtellao@1688.com	3762	\N	2022-09-30	aV7=Xt\\j%GJ4	2024-06-26	active
899	Niki Beauvais	M	2001-05-15	9336708948	nbeauvaisap@icio.us	2753	\N	2022-02-01	yM0+hySf&!Y0W"	2024-07-20	active
900	Ibrahim Charity	M	1995-01-26	3242692043	icharityaq@shareasale.com	3436	\N	2021-10-10	cA7"KT*y8YzT}n'	2024-11-27	active
901	Tracie Gravet	F	2004-01-15	6972638479	tgravetar@tripadvisor.com	4208	\N	2020-07-14	gP1,gvr}u1RQ	2024-10-20	active
902	Page McCool	M	1985-01-01	9647225485	pmccoolas@wp.com	46	\N	2020-10-21	gJ7)IB&o%oT	2024-08-02	active
903	Kamilah Maffioni	M	2002-04-15	4295256276	kmaffioniat@alexa.com	4022	\N	2021-06-16	jB8=jczn>7G%'&	2024-08-06	active
904	Herman Ash	M	1987-04-17	2523104182	hashau@artisteer.com	2410	\N	2022-03-18	sI1_d*x!	2024-01-20	active
905	Paloma Gammet	F	1990-05-24	6082813939	pgammetav@com.com	2060	\N	2022-07-12	tB6_ikw?ZXo}cO	2024-01-22	active
906	Madelina McLellan	F	1983-02-05	5835954446	mmclellanaw@squidoo.com	2002	\N	2021-02-21	xF6,=oIw4oy	2024-11-06	active
907	Philomena Carlucci	F	1999-09-09	7162173229	pcarlucciax@hc360.com	3356	\N	2022-09-24	zA5>6>e{V+	2024-03-06	active
908	Joceline Godin	M	1998-09-21	8865401682	jgodinay@whitehouse.gov	3275	\N	2022-01-03	eJ3{("po>xQP	2024-03-28	active
909	Noreen Savile	M	1980-06-17	9189668372	nsavileaz@homestead.com	2657	\N	2022-01-18	mI6*R|LM~"(W>I	2024-04-10	active
910	Bonni Calterone	F	2000-04-26	8845068492	bcalteroneb0@prlog.org	1685	\N	2021-10-08	gM1|{2D67*?u	2024-11-24	active
911	Cindie Ducker	M	1987-06-05	6742853310	cduckerb1@weather.com	3553	\N	2022-01-04	pT4_HV~GjaD0c_c<	2024-10-23	active
912	Packston Burbury	F	2004-11-10	9653798995	pburburyb2@ucoz.ru	4887	\N	2022-03-29	aG2=I)11S	2024-12-30	active
913	Wye Sandbatch	M	2002-06-06	7463179669	wsandbatchb3@marriott.com	950	\N	2022-11-14	dM7@O<AwBU	2024-07-11	active
914	Shep Fernando	M	1995-11-28	5236090832	sfernandob4@123-reg.co.uk	3744	\N	2022-04-07	kE3*WYrB\\AXw	2024-08-19	active
915	Bobbie Oppery	M	1984-03-27	9365333908	bopperyb5@java.com	3564	\N	2022-10-04	yC8<0>=IXm%F~iq	2024-05-15	active
916	Dela Storror	M	1997-12-27	3016154665	dstorrorb6@goodreads.com	4801	\N	2022-03-04	uH7`dTdi*O%AF.	2024-02-06	active
917	Loni Iiannone	M	2001-07-27	7444138060	liiannoneb7@rakuten.co.jp	976	\N	2022-08-30	cZ8,/ZMj&	2024-09-04	active
918	Bobbie Hulls	M	1992-08-10	2039072069	bhullsb8@tripadvisor.com	275	\N	2022-12-18	cU4<o/3xb"%{	2024-07-21	active
919	Dewey Roisen	M	1985-04-08	6584878882	droisenb9@arizona.edu	855	\N	2022-05-26	oV8#j"c1fK2}$c	2024-12-31	active
920	Eve Eastham	F	1984-12-07	9107872533	eeasthamba@tumblr.com	3916	\N	2020-08-07	zQ3.rDMCy	2024-06-30	active
921	Lanny Semark	M	2004-03-10	5207247905	lsemarkbb@com.com	1659	\N	2022-10-23	qU9|rODQuZ1rjE2	2024-10-09	active
922	Tanhya Jacobsson	M	1999-03-13	1166349037	tjacobssonbc@deliciousdays.com	4756	\N	2020-12-14	bQ5\\y?Q~m2bao"3	2024-10-28	active
923	Phillis Reide	F	1996-11-30	9157905359	preidebd@fastcompany.com	4393	\N	2022-03-11	pU6{9m9r|)K)RFW/	2024-04-17	active
924	Burnaby O'Regan	M	1987-05-30	1946430661	boreganbe@skyrock.com	3675	\N	2021-11-09	uP5}TcOE%4(UXz>	2024-04-25	active
925	Ree Gentreau	M	1983-08-26	2232607701	rgentreaubf@delicious.com	3174	\N	2021-01-13	hW8(4MgIr{x{Df	2024-03-09	active
926	Daryn Sillars	F	1998-10-28	3164902709	dsillarsbg@ovh.net	2852	\N	2020-10-15	yZ9@$+|PC3)YP	2024-08-29	active
927	Briana Ansty	F	1990-03-17	3199901814	banstybh@chicagotribune.com	2657	\N	2022-07-28	jU9~#GDHm@#onZI	2024-04-22	active
928	Raf Solomonides	F	1995-02-16	6429290349	rsolomonidesbi@upenn.edu	2560	\N	2022-11-02	yW2&q$5&9r?Iy#R	2024-04-28	active
929	Modestine Zmitrovich	M	1991-11-23	6738802351	mzmitrovichbj@who.int	486	\N	2022-03-15	nX4>_.w<8=7d\\~Ej	2024-05-28	active
930	Gisele Duckit	F	1993-06-30	5003051014	gduckitbk@ebay.com	551	\N	2021-02-28	uM6+c'qF)x(S	2024-09-07	active
931	Salomon Flewin	F	1990-01-10	1786452217	sflewinbl@youtube.com	3236	\N	2020-01-06	sH9\\l61lN1Yv	2024-06-19	active
932	Nari Gouldstraw	M	1982-09-29	1889590154	ngouldstrawbm@blogspot.com	763	\N	2022-01-09	zR2*m~u/V5	2024-10-10	active
933	Trudie Reyes	F	1991-01-30	4103332636	treyesbn@about.me	3074	\N	2022-10-10	dI0>xj4Vc	2024-01-03	active
934	Licha Shacklady	M	2001-08-24	7089872656	lshackladybo@4shared.com	1411	\N	2022-09-14	eY0'8ShL0{<3*2Q	2024-12-08	active
935	Zachary Kiehne	M	1998-08-11	2561468429	zkiehnebp@multiply.com	2774	\N	2022-11-17	vU5!t+&y1,{	2024-04-16	active
936	Cecilio Aloshikin	F	1986-06-13	2277276626	caloshikinbq@mashable.com	4249	\N	2020-12-02	uN8$>aEep.$VR+'	2024-05-17	active
937	Cosette Farrance	M	1984-10-15	5038819514	cfarrancebr@china.com.cn	3550	\N	2020-03-26	aD2|'>}q8QG	2024-11-11	active
938	Kelly Cogle	F	1990-03-11	1472436334	kcoglebs@cisco.com	1558	\N	2021-04-02	eD5/?|c@Lg,8Y|6	2024-04-29	active
939	Hadria McCreadie	M	1988-12-21	1604340955	hmccreadiebt@whitehouse.gov	1896	\N	2020-09-06	oC6{5jE,Q5B	2024-03-18	active
940	Ted Barette	M	1988-09-08	8155709884	tbarettebu@cbc.ca	2285	\N	2020-02-14	eN7?KtBu0FfJ|#	2024-11-03	active
941	Yank Snawdon	M	1992-06-01	2828198198	ysnawdonbv@boston.com	2976	\N	2021-12-31	zX2@KzS#G2$"A	2024-05-04	active
942	Timofei Thaim	M	2001-02-10	2752519440	tthaimbw@ask.com	3237	\N	2022-10-24	sV7,Z&={@2|	2024-02-12	active
943	Beniamino Noel	M	1992-10-04	6915580651	bnoelbx@dailymotion.com	1875	\N	2022-11-18	bI8>$2.=tm!J/	2024-01-11	active
944	Matteo Upjohn	M	1997-01-11	1851400795	mupjohnby@edublogs.org	2895	\N	2022-01-16	jX2+TTD.a)Y_	2024-07-17	active
945	Eugenia Tytler	F	1992-06-03	4161403338	etytlerbz@columbia.edu	4064	\N	2020-05-28	iH2_tb2LIulU	2024-05-24	active
946	Lorne Francom	F	1986-10-30	2684508165	lfrancomc0@nhs.uk	2177	\N	2022-02-03	rK1$peWqh5_E\\{b	2024-10-15	active
947	Oran Frankum	F	2003-10-23	6418121967	ofrankumc1@dailymotion.com	724	\N	2021-02-13	vF8|i#dd@#v	2024-02-24	active
948	Chere Sarginson	F	1989-06-04	9616167260	csarginsonc2@histats.com	4733	\N	2021-07-22	jF7{}1SF	2024-09-12	active
949	Ryun Fontenot	M	2003-04-02	8576656475	rfontenotc3@ocn.ne.jp	1775	\N	2020-08-30	fI1=19\\g{0*~12	2024-02-09	active
950	Ivy Tidd	M	1981-02-07	1107342357	itiddc4@barnesandnoble.com	3193	\N	2021-04-30	cX8`M2E9	2024-05-11	active
951	Nealy Ghiroldi	M	1997-03-13	6544996599	nghiroldic5@behance.net	4974	\N	2022-01-27	rE0{PVWU/	2024-01-09	active
952	Kylen De Carlo	F	1986-02-12	2161268989	kdec6@wufoo.com	2718	\N	2021-12-08	eA6{n(iElF	2024-11-12	active
953	Diandra Millott	M	1989-01-15	8641632305	dmillottc7@princeton.edu	1898	\N	2022-10-10	uR8`5<%zgwCM'7r=	2024-12-04	active
954	Neel Armsby	F	2003-04-26	5576254307	narmsbyc8@bloomberg.com	1594	\N	2022-10-08	iM5/TKPc?QvNtV3#	2024-05-03	active
955	Helaina Corteis	F	1995-07-07	4844548361	hcorteisc9@businessweek.com	2804	\N	2022-07-06	qH5%\\|,H/Jt/(M</	2024-09-25	active
956	Stearne Cund	F	1993-02-14	7375807045	scundca@over-blog.com	3230	\N	2022-04-24	oS1%.1Xg<@@!'9U}	2024-05-14	active
957	Nicola Hinrichsen	M	2000-11-02	9029694048	nhinrichsencb@samsung.com	525	\N	2020-04-17	eP4#iI}m&Xw9	2024-09-18	active
958	Laryssa Bevens	F	1987-11-12	3571179085	lbevenscc@businessweek.com	2920	\N	2021-01-31	cA6_HnZ!zN!yY%,v	2024-12-17	active
959	Aggie Kayne	M	2004-04-02	2358033138	akaynecd@phpbb.com	2409	\N	2020-06-23	yP3&NeT|<pt	2024-11-21	active
960	Rudyard Castell	M	1984-12-12	1525197160	rcastellce@mozilla.com	2495	\N	2020-04-11	iX2'%cfTi|}'JQ|I	2024-12-04	active
961	Ricca Maycey	M	1987-11-20	9049227305	rmayceycf@opensource.org	3050	\N	2022-04-30	wQ9=.(G!	2024-07-01	active
962	Devan Hughesdon	M	1981-12-21	6243430419	dhughesdoncg@squarespace.com	2787	\N	2020-10-16	jV1!7x)v	2024-12-29	active
963	Laure Verden	M	1996-01-19	5821148978	lverdench@sun.com	3677	\N	2020-12-27	pS4=301BhEw\\LAA	2024-02-23	active
964	Tallulah Dumingo	M	1990-10-05	5787031934	tdumingoci@ihg.com	1894	\N	2021-02-10	fI0#fPhbvM`1Xp#L	2024-02-14	active
965	Barrie Broader	F	1988-03-29	6262250608	bbroadercj@wiley.com	728	\N	2021-05-31	aW0"?Dz<M~`	2024-03-02	active
966	Eal Tidbold	M	1980-01-13	6444660603	etidboldck@linkedin.com	2792	\N	2022-09-21	sL7{dv+sq0GV$e>	2024-08-04	active
967	Heida Bridgwater	F	1993-05-27	2663024844	hbridgwatercl@sakura.ne.jp	4248	\N	2021-06-28	nA9?ySwNA=LnKs	2024-01-04	active
968	Marcello Moles	M	2003-04-13	7952002853	mmolescm@1688.com	1794	\N	2021-09-02	sF2~iau8	2024-08-15	active
969	Bing Woolger	M	1992-07-09	2673458136	bwoolgercn@e-recht24.de	3541	\N	2021-06-10	rY6>\\lw$x'6+@sq	2024-05-22	active
970	Helenelizabeth Blues	F	2000-05-10	5748004323	hbluesco@indiatimes.com	3866	\N	2022-11-21	kI7&d+X2&n"2./se	2024-08-19	active
971	Davine Loddon	M	1999-02-17	8466145651	dloddoncp@fc2.com	2968	\N	2021-07-27	nQ3%U}?0P=eTR	2024-11-26	active
972	Bink Audus	M	2002-08-12	1452468410	bauduscq@deviantart.com	2347	\N	2020-12-28	eY2+fV83!*c>_	2024-01-15	active
973	Myrvyn Broske	M	1982-07-22	4607468157	mbroskecr@telegraph.co.uk	4601	\N	2021-09-19	nK3"\\s\\bn<xuS	2024-07-05	active
974	Pierrette Lagne	M	1991-02-03	1983417391	plagnecs@census.gov	4831	\N	2020-06-09	yU6.QAZF	2024-07-15	active
975	Maison Dhenin	F	1995-02-21	3189903387	mdheninct@squidoo.com	867	\N	2020-09-28	kL8(DXt4E>9(.r	2024-01-26	active
976	Austine Thurman	M	2002-12-01	5986596650	athurmancu@google.com	1964	\N	2022-05-14	hZ5,&4I\\a9_sI	2024-03-03	active
977	Catlaina Houlworth	F	1995-02-24	4804982672	choulworthcv@ca.gov	3735	\N	2020-05-01	uC3=osH/N	2024-01-13	active
978	Lion Worssam	F	1982-11-17	9086593536	lworssamcw@hexun.com	765	\N	2022-03-31	wP3~>JB'Fif|zf{H	2024-09-04	active
979	Rorke Goulbourne	F	1993-02-16	7377868541	rgoulbournecx@ocn.ne.jp	1727	\N	2021-10-03	pJ7!#0pn(}h	2024-04-03	active
980	Laurel Chorley	M	1989-03-24	4231674119	lchorleycy@accuweather.com	787	\N	2022-08-05	cS6(jMOCRt5	2024-05-18	active
981	Moyna Swire	M	1991-11-23	3399621903	mswirecz@com.com	4998	\N	2022-11-05	uF2.gd#c&gC	2024-12-11	active
982	Austin Merle	M	1991-12-25	4556037812	amerled0@icq.com	569	\N	2022-11-20	oI4?3L+d	2024-06-09	active
983	Jorge Piotrowski	F	1986-10-02	3256992672	jpiotrowskid1@macromedia.com	3485	\N	2021-05-21	xZ3$Ls8Y<	2024-02-01	active
984	Zachary McNeely	F	1982-10-11	4532579564	zmcneelyd2@marriott.com	4097	\N	2022-10-12	kS4$b0T<od	2024-12-04	active
985	Tilda Kwietek	F	1997-11-03	7434525692	tkwietekd3@toplist.cz	3001	\N	2022-01-09	oB9|Fi47QNE4+l+	2024-01-06	active
986	Leona Babcock	M	2001-06-03	6969152038	lbabcockd4@washingtonpost.com	2385	\N	2020-03-05	pZ7?'?aIh	2024-09-22	active
987	Laurella Duly	F	1988-06-29	6515643338	ldulyd5@indiatimes.com	2755	\N	2020-07-29	zL4\\ves>J0si+	2024-06-28	active
988	Kary Eddicott	M	2000-04-26	7769683074	keddicottd6@springer.com	1640	\N	2022-07-22	qZ1%EK!4LO	2024-07-02	active
989	Darn McIlraith	F	1993-05-02	9941088667	dmcilraithd7@miibeian.gov.cn	955	\N	2021-03-06	fP7~>WIqU.0goEo	2024-01-23	active
990	Woodrow Carriage	F	1994-01-08	4577987150	wcarriaged8@weather.com	551	\N	2022-05-10	xB5'O>v_v	2024-07-02	active
991	Lurlene Osbaldeston	M	1988-12-23	3486394991	losbaldestond9@twitter.com	1171	\N	2022-01-19	fX3@Go>L<VxdN	2024-07-31	active
992	Koral Ruilton	F	1981-05-28	9879256197	kruiltonda@webeden.co.uk	4287	\N	2022-03-16	hH0_U>L3Qc_Uig4"	2024-06-16	active
993	Bern Handrick	M	1986-08-01	6071700339	bhandrickdb@multiply.com	1687	\N	2022-07-10	gL3,dUOg	2024-08-29	active
994	Wilt Scamadin	M	1983-09-11	4455401338	wscamadindc@homestead.com	3234	\N	2022-03-29	iU2_+>>Jmf	2024-07-12	active
995	Dudley Krzyzaniak	F	1984-09-19	2058220909	dkrzyzaniakdd@themeforest.net	1484	\N	2021-01-28	jN8`=G%868u{MB	2024-12-20	active
996	Lisabeth Becke	M	1992-08-01	9044818973	lbeckede@prlog.org	2029	\N	2021-06-03	mL1*fJ|)p`eRA%D	2024-12-08	active
997	Dorey Mueller	M	1997-03-27	3312011797	dmuellerdf@ezinearticles.com	3468	\N	2022-09-27	bJ4|W03=eU\\f7=	2024-07-25	active
998	Wynne Westney	F	1998-10-19	3153863309	wwestneydg@google.ru	2849	\N	2022-08-15	wK7}oz=|V9	2024-03-21	active
999	Juditha Gillow	M	2004-03-09	9263804872	jgillowdh@google.fr	3420	\N	2021-05-07	cK9+c&"kLJ}tZ	2024-08-15	active
1000	Betty Reiglar	F	2003-08-23	2581700823	breiglardi@state.tx.us	3928	\N	2021-01-12	hG7_\\8j&8s~	2024-03-26	active
1001	Florrie Cornelisse	F	1990-03-11	3539043870	fcornelissedj@go.com	3524	\N	2020-02-01	aO8%sqrNU`	2024-07-11	active
1002	Shelia Rawstron	F	1992-07-24	2346107935	srawstrondk@google.co.jp	4370	\N	2020-09-27	nU9<A_M/Xce	2024-02-26	active
1003	Lisetta Smallridge	F	2003-02-12	9211956056	lsmallridgedl@netlog.com	4119	\N	2020-03-01	pC9##62KPc	2024-03-26	active
1004	Marena Devinn	M	2004-05-16	2545503238	mdevinndm@ed.gov	2553	\N	2020-08-07	rS7+ZtP+	2024-04-24	active
1005	Rici Tarquinio	M	2003-04-18	7005480450	rtarquiniodn@example.com	1831	\N	2020-12-07	xZ4/5EAWfVcKG*	2024-06-27	active
1006	Cally Sarfati	F	1989-10-24	4641689647	csarfatido@eepurl.com	3355	\N	2022-08-28	kZ5&{Gg9	2024-09-30	active
1007	Sandye Rubenchik	F	1990-08-02	7514392878	srubenchikdp@usatoday.com	3613	\N	2021-03-25	bZ0_ZUB71t	2024-06-28	active
1008	Roscoe Wavish	F	1992-07-14	2576460946	rwavishdq@biblegateway.com	4770	\N	2020-11-23	iJ9|hldL7q	2024-08-16	active
1009	Alli Wenham	M	1991-05-18	7711542504	awenhamdr@wix.com	2168	\N	2022-02-10	bK5<KY.6p/W+L|%U	2024-01-13	active
1010	Pearle Brunsden	M	2004-09-28	2283770172	pbrunsdends@naver.com	223	\N	2021-04-25	jE1=czqh	2024-01-26	active
1011	Filberte Yarham	M	2003-02-26	3114280681	fyarhamdt@time.com	2735	\N	2021-03-01	xQ2+2VxrMlvl`OM	2024-04-28	active
1012	Josepha Jallin	F	1998-06-17	9686261128	jjallindu@nyu.edu	2855	\N	2021-09-26	aM3!`Lb5L'	2024-06-13	active
1013	Hill Camoys	M	1989-11-08	9316384027	hcamoysdv@opensource.org	447	\N	2020-08-20	jJ5`|BHu0yp|=>X	2024-07-05	active
1014	Ingaberg Marchetti	F	1986-02-26	5346282335	imarchettidw@ftc.gov	4199	\N	2020-05-12	tS7{PuH_yr	2024-01-22	active
1015	Judie Richardes	F	2000-06-25	9061521071	jrichardesdx@paypal.com	2322	\N	2020-07-19	lM6_VaTt	2024-04-14	active
1016	Fons Ryce	F	1984-01-26	3846316065	frycedy@myspace.com	3732	\N	2022-10-20	kI4|Nf>+	2024-11-21	active
1017	Seana Mertel	F	1994-08-17	9702480500	smerteldz@ning.com	2147	\N	2022-12-04	pT2$a3eWEM3/NR	2024-01-16	active
1018	Fredia Vittori	M	1995-03-26	3425697414	fvittorie0@reddit.com	4421	\N	2022-08-12	tR8*d8snH	2024-12-06	active
1019	Ambrosi Casbolt	M	1986-01-23	4999904923	acasbolte1@ucsd.edu	1507	\N	2021-09-30	lT0\\F(C58+%$X4	2024-05-12	active
1020	Bette-ann Cardenas	F	1997-07-06	4728786764	bcardenase2@goo.ne.jp	3391	\N	2022-01-16	mQ7,y&<A	2024-10-15	active
1021	Edee Kearn	M	1981-03-27	3615168155	ekearne3@photobucket.com	458	\N	2021-06-03	tY8=8S$1E	2024-12-28	active
1022	Orazio Haylett	F	1998-05-25	5082958824	ohaylette4@vk.com	811	\N	2020-10-20	iW0>KGK(	2024-10-10	active
1023	Meir Eglington	M	1986-03-23	8829218792	meglingtone5@cbc.ca	2843	\N	2020-01-27	dB0#G'@t2a47	2024-05-12	active
1024	Ola Boulton	M	1989-11-19	4484855226	oboultone6@businessweek.com	1974	\N	2020-01-19	rN1\\}IHcTvv	2024-01-09	active
1025	Gabriello Pratten	F	1991-08-17	9509917103	gprattene7@hatena.ne.jp	4963	\N	2022-09-05	yM4_qciQYpWsEKF	2024-11-21	active
1026	Gretal Chastelain	M	2001-09-25	4139486240	gchastelaine8@51.la	4089	\N	2020-02-15	qG3=R{JtA%>}	2024-11-13	active
1027	Margaretha Medley	F	2004-11-08	4851647108	mmedleye9@qq.com	4204	\N	2020-05-17	xU6+!OK@\\="nG	2024-01-13	active
1028	Ophelia Allicock	F	2004-05-09	8817666253	oallicockea@vkontakte.ru	4093	\N	2021-09-28	kZ5~nze*9/l	2024-04-14	active
4	Pham Thi D	F	1995-04-04	0901000004	d.pham@email.com	21	silver	2024-06-04	password4	2025-06-01	active
6	Bui Thi F	F	1991-06-06	0901000006	f.bui@email.com	21	silver	2024-06-06	password6	2025-06-01	active
7	Doan Van G	M	1989-07-07	0901000007	g.doan@email.com	21	silver	2024-06-07	password7	2025-06-01	active
9	Pham Van I	M	1994-09-09	0901000009	i.pham@email.com	21	silver	2024-06-09	password9	2025-06-01	active
5	Vo Minh E	M	1993-05-05	0901000005	e.vo@email.com	21	silver	2024-06-05	password5	2025-06-02	active
10	Tran Thi J	F	1997-10-10	0901000010	j.tran@email.com	21	silver	2024-06-10	password10	2025-06-01	active
8	Dang Thi H	F	1996-08-08	0901000008	h.dang@email.com	21	silver	2024-06-08	password8	2025-06-02	active
1029	Blaine Coverdill	M	2004-07-11	1094296032	bcoverdilleb@engadget.com	3432	\N	2022-10-12	mY0$|HpOOnQr1zz?	2024-09-10	active
1030	Giles Jenson	M	1998-10-01	2613533671	gjensonec@buzzfeed.com	2550	\N	2022-07-14	kW9|SAFd},Y*gUw	2024-08-19	active
1031	Franchot Avarne	M	1993-08-14	3615429898	favarneed@g.co	1714	\N	2020-10-22	cQ9=x+,BO1	2024-08-19	active
1032	Leeland Fanning	F	1982-01-29	5635111287	lfanningee@uol.com.br	4868	\N	2021-09-22	iL3+0MiRX|Z>	2024-08-24	active
1033	Almira Brunon	M	1994-10-09	2976350970	abrunonef@prlog.org	1235	\N	2021-03-09	yF6`f$oxqg1.	2024-11-07	active
1034	Flossie Heinzler	M	2003-05-11	2494269497	fheinzlereg@amazonaws.com	4378	\N	2020-09-30	mL7)0F8rx|`.C1?/	2024-06-19	active
1035	David Horstead	F	1991-12-10	9772077700	dhorsteadeh@friendfeed.com	2445	\N	2022-06-03	jH5~"+7oD!?m	2024-08-09	active
1036	Joceline Cutting	F	1984-03-15	8535530073	jcuttingei@nps.gov	3339	\N	2022-07-06	dA6{yi2fGk)F5	2024-04-07	active
1037	Calvin McConnal	M	1998-10-07	4886571960	cmcconnalej@ameblo.jp	1220	\N	2022-05-19	aS4<(+xf''0I	2024-04-04	active
1038	Janice Parley	F	1982-04-18	8983327679	jparleyek@over-blog.com	2734	\N	2021-04-27	iE9@|b@MRHC	2024-11-28	active
1039	Denni Gully	M	1983-01-03	6869051814	dgullyel@cargocollective.com	634	\N	2021-07-30	bV5"o@gXm0I	2024-02-20	active
1040	Claude Brickner	F	1983-05-19	6634231847	cbricknerem@gnu.org	4817	\N	2022-01-20	xA5,)Udw&BPu4(W	2024-06-15	active
1041	Aurea Bertl	F	1994-06-06	1795800528	abertlen@slideshare.net	4523	\N	2020-05-06	yS5+fs,{c47bMCOw	2024-09-19	active
1042	Tamra Clabburn	F	1992-06-28	4017914493	tclabburneo@europa.eu	1038	\N	2022-10-20	aU3.eA\\4NG	2024-03-16	active
1043	Ermengarde Necolds	M	1981-09-25	2932896411	enecoldsep@newsvine.com	3290	\N	2022-07-07	oM8#`D#K%	2024-09-11	active
1044	Mervin Giacobini	M	1991-09-28	9919239777	mgiacobinieq@blogs.com	3593	\N	2022-08-11	jW6(qDE`16{F	2024-08-06	active
1045	Andrej MacKibbon	M	1990-11-16	7421073836	amackibboner@wikipedia.org	2378	\N	2020-05-13	uU5%r8eZNs#2}t	2024-12-29	active
1046	Bank Bascomb	F	1992-06-07	3852015617	bbascombes@pagesperso-orange.fr	1925	\N	2022-07-07	pA5,{zLosOPzS{	2024-04-13	active
1047	Haskell Coenraets	F	2002-07-11	9434474914	hcoenraetset@flickr.com	558	\N	2022-07-02	fO1*Mi@?P.1Lk7	2024-01-14	active
1048	Gaye Ceresa	M	1988-02-22	3712189537	gceresaeu@amazon.com	2746	\N	2021-02-24	lI4}\\i{/~jte	2024-12-02	active
1049	Daveen Essam	M	1985-07-21	7405040194	dessamev@blogtalkradio.com	3486	\N	2020-08-20	qK8>l(%>%=0	2024-02-18	active
1050	Meredithe Extill	F	1988-08-20	5097971802	mextillew@ca.gov	3230	\N	2020-06-24	aJ6`wA/e@T%KIc*	2024-12-22	active
1051	Teodorico Ascroft	M	1981-08-29	2892815084	tascroftex@nature.com	1002	\N	2020-11-03	dC2|&Dra?t@XnbMW	2024-03-23	active
1052	Cassandra Burnip	F	1984-06-15	8197463335	cburnipey@icq.com	1205	\N	2021-12-08	qO6%g9W#B	2024-03-12	active
1053	Yuma Wainscoat	F	1993-10-30	3488419644	ywainscoatez@adobe.com	722	\N	2020-05-31	yF3=ZYC6Rk'	2024-06-11	active
1054	Faun Bidwell	M	1989-03-05	4633784993	fbidwellf0@nytimes.com	4760	\N	2021-09-14	dA6~`pdYC~o/	2024-07-28	active
1055	Mirabella Saxon	M	1980-04-20	2863539303	msaxonf1@businesswire.com	1836	\N	2022-03-23	zC3_"tRd&@\\WBqb	2024-04-15	active
1056	Shelagh Liddell	F	1999-08-06	2569136331	sliddellf2@zimbio.com	4288	\N	2021-07-14	fF1|&bTPht'yQ	2024-04-01	active
1057	Jaclin Grubbe	M	1996-07-15	4851138220	jgrubbef3@hubpages.com	3664	\N	2021-07-12	cD0_EWTF	2024-04-18	active
1058	Doyle O'Calleran	F	1980-11-05	1426487897	docalleranf4@dropbox.com	564	\N	2021-03-23	mJ6=#HZc}H"S?AfH	2024-10-13	active
1059	Marvin Sauvage	F	1987-12-14	3284512983	msauvagef5@sfgate.com	2447	\N	2020-08-18	vD3~z?gGgU	2024-01-06	active
1060	Becca Cavalier	F	1997-01-22	2106229406	bcavalierf6@wix.com	3889	\N	2022-10-04	zW7(A!>|E6VW=Wz	2024-08-12	active
1061	Letty Danielut	M	1983-09-24	1198264371	ldanielutf7@sciencedirect.com	608	\N	2022-03-30	bR9._w0P	2024-01-10	active
1062	Karalee Godspede	F	1996-12-23	9267063942	kgodspedef8@washingtonpost.com	4898	\N	2020-05-24	uI6#L\\h$Fa80sN~	2024-07-06	active
1063	Prescott Downage	M	1995-01-31	7877009147	pdownagef9@slideshare.net	734	\N	2022-11-14	pZ6!/Ydi|}	2024-06-23	active
1064	Johan Monck	F	1995-06-20	5947562089	jmonckfa@addthis.com	4387	\N	2020-01-24	rD5/DD`.FEJ	2024-03-15	active
1065	Zilvia O'Shields	F	1985-06-23	3809052191	zoshieldsfb@trellian.com	777	\N	2021-05-17	nE1{H8Sq	2024-12-31	active
1066	Chastity Dosdell	F	1987-07-04	7681219232	cdosdellfc@mozilla.com	4488	\N	2022-03-17	cP3{{3J6	2024-07-03	active
1067	Artemis Simonetti	F	1982-05-04	8002477510	asimonettifd@dailymail.co.uk	2667	\N	2022-09-17	eK1>%.eREJ@`z	2024-07-23	active
1068	Morlee Flay	M	1980-05-18	5477615749	mflayfe@wikipedia.org	769	\N	2021-03-05	kO2+G#h5!NYP,1O	2024-08-02	active
1069	Teodoor Ponnsett	M	1981-11-20	4384205940	tponnsettff@vk.com	4345	\N	2020-01-18	wU7\\&,fl9gfQ	2024-12-02	active
1070	Lorita Quarton	F	1981-10-30	2741216244	lquartonfg@hexun.com	415	\N	2020-10-06	gK3~@n<j	2024-03-02	active
1071	Jarrad Renison	M	2000-06-07	1466464991	jrenisonfh@reverbnation.com	4245	\N	2022-06-27	xN9}IGOqnB2VnXKf	2024-04-06	active
1072	Raviv Geibel	F	1994-06-14	7375970618	rgeibelfi@ustream.tv	1970	\N	2021-10-27	nY3'R*_%	2024-11-18	active
1073	Augustine Pobjoy	M	1997-11-06	6565715589	apobjoyfj@nyu.edu	1556	\N	2020-11-18	qV3/)soc)>7A,	2024-02-06	active
1074	Raimondo Hainning	F	1983-01-25	2132257624	rhainningfk@goo.ne.jp	451	\N	2020-06-16	tJ8)Zz|ba,.55	2024-09-15	active
1075	Kean Stirton	F	1996-07-09	3441784143	kstirtonfl@tinyurl.com	1304	\N	2020-03-04	iJ1>Y~NKGGVrrWmj	2024-03-16	active
1076	Aubry Stollsteiner	F	1995-10-27	3352418811	astollsteinerfm@4shared.com	56	\N	2021-09-25	oX8{&OMHh!=2o	2024-02-13	active
1077	Stafford Clarey	F	1980-12-02	8641384488	sclareyfn@prlog.org	1641	\N	2022-07-12	qR6{`yF~5	2024-05-16	active
1078	Rodger Camplen	F	1998-12-04	5952116077	rcamplenfo@archive.org	1058	\N	2020-05-17	yY8*c|4MdN1Qq}{a	2024-03-28	active
1079	Thorn Yacobsohn	M	1994-04-01	3897272045	tyacobsohnfp@nifty.com	1471	\N	2021-08-29	dI2}_{c!Y{'tOv&2	2024-08-26	active
1080	Stearne Klas	M	1980-04-06	8017975680	sklasfq@discovery.com	3578	\N	2021-07-18	qQ8>,%P_h	2024-09-02	active
1081	Scarlett Puve	F	1982-08-15	7864079487	spuvefr@pbs.org	3248	\N	2020-07-25	cH7\\x_kbaL/*{7*?	2024-01-09	active
1082	Sunshine Lethibridge	F	1984-02-15	2891466015	slethibridgefs@google.it	4481	\N	2021-03-11	jW8|=Qh*`'c	2024-03-13	active
1083	Reginald Ramme	F	1990-02-13	2077287976	rrammeft@foxnews.com	1267	\N	2021-05-05	cW2\\EMOD`arwMBO	2024-07-14	active
1084	Clerc Hurndall	F	2002-06-28	4627733743	churndallfu@photobucket.com	2271	\N	2020-03-28	hB0_+jB/R`'~8&	2024-10-10	active
1085	Leo Elmore	M	1991-08-30	3344163874	lelmorefv@fc2.com	311	\N	2022-10-11	aI4?d>Qmx@/	2024-12-21	active
1086	Leigha Phalp	M	1985-12-01	2087395373	lphalpfw@usda.gov	2454	\N	2021-06-02	jZ1$ouo"REK$	2024-02-20	active
1087	Donella Kusick	F	1996-12-23	8502564234	dkusickfx@comcast.net	1737	\N	2022-03-01	iA4`Iv,+H)jnVX	2024-11-02	active
1088	Adolpho Wixey	F	2004-09-14	2883626066	awixeyfy@instagram.com	2644	\N	2021-10-08	zX4&6q3(N!x	2024-12-12	active
1089	Aloisia Tukesby	F	2001-01-08	1031868325	atukesbyfz@wunderground.com	2301	\N	2022-07-09	nO8!bJ?|guQXh	2024-12-29	active
1090	Gerik Le Pine	M	1996-11-04	5856317318	gleg0@naver.com	1432	\N	2020-08-19	sP2(oKLo	2024-12-10	active
1091	Ardine Barhem	M	2002-06-11	1963959489	abarhemg1@wisc.edu	1746	\N	2022-03-29	dB7)yhn<cQ_@l,	2024-10-07	active
1092	Violante Coomes	M	1980-11-30	5352463404	vcoomesg2@mysql.com	82	\N	2021-07-04	wD3*CO.Me*	2024-07-30	active
1093	Romy Kloska	F	1997-12-08	3123464708	rkloskag3@istockphoto.com	491	\N	2021-03-02	yJ2(j9NUR3E4	2024-12-20	active
1094	Nikolaus Shyram	F	1984-07-14	9654427543	nshyramg4@typepad.com	3575	\N	2020-10-07	gV0=`v81'B	2024-08-16	active
1095	Pat Tatlowe	F	1987-09-09	7125284358	ptatloweg5@abc.net.au	4359	\N	2022-08-24	cX8=Q*_,G3eZ=	2024-07-20	active
1096	Trace Kershaw	M	1991-06-01	1215953826	tkershawg6@comsenz.com	4888	\N	2021-04-23	eS0>Zp"t5oTf_"	2024-10-30	active
1097	Alvina Saintpierre	F	1987-05-09	4701851714	asaintpierreg7@macromedia.com	4885	\N	2020-10-07	wP9,qE!t	2024-05-09	active
1098	Knox Lanham	M	2001-10-19	2138386926	klanhamg8@google.it	4471	\N	2020-07-09	dS7*PkA%AD	2024-12-18	active
1099	Betsy Danshin	M	1991-06-19	2634819307	bdanshing9@instagram.com	782	\N	2021-07-10	qL3!=Tdi,!{J'|F	2024-12-13	active
1100	Feliks Croneen	M	1992-05-23	5196170335	fcroneenga@freewebs.com	53	\N	2020-04-05	aB2(CX/N",`p|	2024-06-02	active
1101	Sally Sprull	F	2004-10-27	3997651741	ssprullgb@mac.com	1255	\N	2020-02-18	qI4>4`?oj(	2024-06-27	active
1102	Huey Carbery	M	1986-12-03	7739944395	hcarberygc@fema.gov	4645	\N	2020-10-31	bG3,0YuZt	2024-01-03	active
1103	Alene Burd	F	1991-10-16	6606954155	aburdgd@domainmarket.com	1089	\N	2022-09-25	wH4\\2+f0!'Yr8	2024-04-18	active
1104	Danit Flode	M	1993-05-01	9177946412	dflodege@mit.edu	2466	\N	2022-07-06	lT4?9bPm	2024-08-11	active
1105	Gabbie Mackerel	M	1983-11-02	3744250626	gmackerelgf@exblog.jp	877	\N	2021-09-13	vP3/0DQ1	2024-06-23	active
1106	Dill Folbig	M	2002-05-12	6221344840	dfolbiggg@illinois.edu	2176	\N	2021-04-09	fQ8!qbZPfxottI	2024-09-16	active
1107	Brande Hritzko	M	2001-09-22	2463405964	bhritzkogh@wikimedia.org	1129	\N	2020-06-02	gP0>B0%yQ`2Ws4	2024-08-07	active
1108	Ninnette Beckey	F	1982-02-15	7958407612	nbeckeygi@vimeo.com	4801	\N	2022-12-30	vO8*?6BlDw7	2024-01-15	active
1109	Ev Longfut	F	1984-04-12	8012012930	elongfutgj@google.com.au	826	\N	2022-04-25	eV5~Y|P&//>8+	2024-06-24	active
1110	Gavrielle Rickert	M	2001-06-12	8721999637	grickertgk@indiatimes.com	3903	\N	2020-03-10	sQ3|CgS0	2024-04-18	active
1111	Claybourne Croll	M	1980-05-22	5788817531	ccrollgl@eepurl.com	132	\N	2022-09-16	sM2,oFNHuk	2024-07-18	active
1112	Minerva Scoyles	M	2000-04-10	4951719262	mscoylesgm@springer.com	1476	\N	2020-01-16	uY0*/s%kX=t.	2024-05-04	active
1113	Joell Molan	F	1992-01-03	9104530939	jmolangn@arizona.edu	2064	\N	2021-10-23	nJ8*|C#,tzx	2024-11-03	active
1114	Suellen Woodcraft	M	1991-01-03	5259741052	swoodcraftgo@mlb.com	4392	\N	2020-06-12	hS8@DCixJi``j)T	2024-10-15	active
1115	Shaylyn Scurr	F	1986-04-24	4781695865	sscurrgp@cbslocal.com	814	\N	2022-03-30	gE2}G57XoQd`	2024-01-16	active
1116	Devan Grzes	M	1995-03-19	9372269337	dgrzesgq@netscape.com	3787	\N	2020-01-17	fA7>*9YI&g1a	2024-05-07	active
1117	Boy Burness	F	2004-12-28	5142033154	bburnessgr@businessinsider.com	1234	\N	2022-03-13	pR2`F&IeJ\\P!*G12	2024-05-05	active
1118	Tana Snap	M	1983-05-31	4419034560	tsnapgs@bigcartel.com	3508	\N	2022-03-10	fX6`%j>H'3%}z	2024-05-12	active
1119	Ilaire Kretschmer	F	2000-01-21	7142820016	ikretschmergt@ed.gov	1249	\N	2020-08-23	xQ9>a\\GaWDb5	2024-01-27	active
1120	Ruy Dunsmuir	M	1999-09-02	6256025886	rdunsmuirgu@oakley.com	1294	\N	2021-03-04	xT5}0virP%zGZng>	2024-02-02	active
1121	Barb Vowden	F	1992-03-07	4093500785	bvowdengv@theglobeandmail.com	236	\N	2021-05-08	aL8_WOXi)|rNe	2024-04-19	active
1122	Eunice Jurkiewicz	M	1994-02-05	4501432250	ejurkiewiczgw@chron.com	1827	\N	2021-06-16	xS4>aqIoZs~	2024-12-18	active
1123	Kaitlyn Steeden	F	2001-09-13	6424873306	ksteedengx@imgur.com	301	\N	2020-07-03	gI2#UA_kNkKwRkG	2024-05-02	active
1124	Jacquetta Early	F	1999-11-10	2331460104	jearlygy@lulu.com	4474	\N	2022-10-25	nM4#+2Ncv3NVS	2024-03-16	active
1125	Sascha Carverhill	M	1994-10-23	2582251624	scarverhillgz@businessweek.com	1056	\N	2021-01-12	dY6,}lLBYg/l	2024-08-29	active
1126	Madlen Sellman	M	2002-08-27	3539759442	msellmanh0@ebay.co.uk	959	\N	2021-07-25	jN0/GegT	2024-07-06	active
1127	Page Sexon	M	1980-03-22	6468335432	psexonh1@latimes.com	1249	\N	2022-03-24	hG2/#y$dN8W3P	2024-03-28	active
1128	Antony Cordsen	M	1983-05-09	5905991817	acordsenh2@zimbio.com	4505	\N	2022-06-25	kR3=/e*pyTNO	2024-10-21	active
1129	Hercules Asprey	F	1981-06-07	1525921833	haspreyh3@amazon.com	4401	\N	2020-12-20	nT3@P(eJ!S_}N{	2024-03-26	active
1130	Kylen Copsey	F	1993-05-13	4664199492	kcopseyh4@edublogs.org	2958	\N	2021-06-20	zA2+!o+J@>w,(	2024-11-13	active
1131	Chrysler Gotcher	F	1998-09-30	4884658610	cgotcherh5@chicagotribune.com	3057	\N	2022-09-27	kB0=)pSXoQn@Z%r9	2024-06-30	active
1132	Anatol Joret	F	1999-02-06	5687135510	ajoreth6@army.mil	1047	\N	2021-02-28	kT9_pgFZfda{viK	2024-07-26	active
1133	Lynne Edards	F	2003-11-29	5753564529	ledardsh7@google.co.jp	1855	\N	2020-05-21	vR3`_)o+n)qE+<rG	2024-07-21	active
1134	Stefa Garrick	M	2000-04-14	5856777649	sgarrickh8@mit.edu	1985	\N	2022-11-25	mJ6$Dl8ach'	2024-08-01	active
1135	Jud Tomik	M	2001-07-02	9764945009	jtomikh9@dell.com	1739	\N	2021-10-19	hZ9!0P1'	2024-03-07	active
1136	Clark Gilstoun	M	2002-04-11	9337656899	cgilstounha@shop-pro.jp	3333	\N	2022-11-29	zV4>Ca<!V)cO	2024-06-20	active
1137	Cristian Acheson	M	1980-09-14	2236950409	cachesonhb@slate.com	341	\N	2020-10-11	jK0@i@d<iFN	2024-11-27	active
1138	Daryl Rosenblath	M	2002-12-05	6273895852	drosenblathhc@aol.com	3388	\N	2020-08-26	yA3_{j,@9AmW	2024-10-17	active
1139	Maitilde Jorczyk	F	2002-07-18	8787051560	mjorczykhd@tripod.com	2951	\N	2022-10-22	aS8.F_zSSEAh	2024-06-20	active
1140	Vilhelmina Gillfillan	F	1999-01-12	9717823779	vgillfillanhe@blogtalkradio.com	3445	\N	2021-06-26	lH1~W}nrbKy(cgy/	2024-02-10	active
1141	Marnie Plane	F	2001-02-08	4875061121	mplanehf@about.com	1549	\N	2022-01-12	xO4|9#?N9fm	2024-02-17	active
1142	Shelbi Newing	M	2002-07-15	4602133731	snewinghg@answers.com	1929	\N	2022-02-26	jD7)bF_YROxlvB)	2024-11-02	active
1143	Louis Peach	F	1983-01-18	6716126722	lpeachhh@digg.com	2617	\N	2020-10-22	pB6.<hW8V	2024-10-14	active
1144	Marthe Ferryman	M	1986-07-06	7061161813	mferrymanhi@imgur.com	3060	\N	2020-10-02	bQ6&)$3&<	2024-06-03	active
1145	Mauricio O'Noulane	M	1983-07-10	6989710825	monoulanehj@prnewswire.com	4247	\N	2020-07-20	yX1~7%3|Wmvfl	2024-05-27	active
1146	Sallyann Trenear	M	1997-10-06	4847258215	strenearhk@xrea.com	4678	\N	2020-04-09	aA8!fLgQ6)y	2024-01-09	active
1147	Marion Roft	M	1999-08-22	8886887471	mrofthl@theglobeandmail.com	10	\N	2022-05-23	tL2<rO!,>r	2024-08-16	active
1148	Ashil Pairpoint	F	2004-12-24	5511604997	apairpointhm@usatoday.com	1999	\N	2022-11-26	zF7%%IftMTcq!~9	2024-01-17	active
1149	Debera Adamek	F	1990-06-04	4005897834	dadamekhn@answers.com	4889	\N	2021-04-21	qP1*B`BT	2024-11-17	active
1150	Kenn Peer	F	2001-07-26	8809466766	kpeerho@i2i.jp	1896	\N	2020-12-25	tE8.|X)T	2024-02-28	active
1151	Waylan Redding	M	1981-07-29	9813396245	wreddinghp@mit.edu	4143	\N	2020-05-13	sY0`)>JD3b	2024-09-05	active
1152	Lark Campe	F	1985-12-21	5487813903	lcampehq@ihg.com	62	\N	2022-10-28	xI9+knHj)1	2024-11-14	active
1153	Lacey Hillborne	F	1983-09-25	2565253066	lhillbornehr@bbc.co.uk	2658	\N	2020-08-01	mZ0#E1?Biz1_"'	2024-02-02	active
1154	Deeann De Pietri	M	1983-11-12	6036744800	ddehs@reference.com	267	\N	2020-11-08	zS8'zrWl8g%s6(Z5	2024-11-30	active
1155	Ignazio Choulerton	F	1991-10-20	8883407615	ichoulertonht@state.tx.us	2802	\N	2022-01-16	sE1&*TuG$T4	2024-03-30	active
1156	Edouard MacElane	M	1983-12-13	8642849040	emacelanehu@feedburner.com	83	\N	2020-07-13	sY0$c>4u+licUX	2024-02-05	active
1157	Jacynth Hambleton	M	1997-03-28	7852537338	jhambletonhv@geocities.com	1104	\N	2021-02-03	nO7_!Lf\\7{dtc	2024-05-03	active
1158	Jessey Tarbard	M	1997-12-31	6998609250	jtarbardhw@cbslocal.com	3311	\N	2021-12-31	qH2&ZYTh	2024-01-25	active
1159	Penni Byers	F	1985-11-08	6098474430	pbyershx@yolasite.com	4639	\N	2020-07-26	cK7@R&@H@	2024-04-07	active
1160	Elbertine Yuryaev	F	2002-06-29	7407654550	eyuryaevhy@last.fm	2871	\N	2021-06-08	fF9_fTwkWS!w$)	2024-01-23	active
1161	Ty Weben	F	1990-05-04	4097650256	twebenhz@nasa.gov	2699	\N	2021-10-15	eZ3'/jdX0yE	2024-05-16	active
1162	Simonne Makepeace	F	1990-12-03	2636651582	smakepeacei0@liveinternet.ru	2901	\N	2022-05-04	dI3+I`15	2024-07-06	active
1163	Harriet Trower	F	1992-02-13	9096200801	htroweri1@ted.com	4247	\N	2022-11-18	yQ0&Q=UFi`ATw	2024-09-03	active
1164	Adrian Weitzel	F	1995-11-19	7477768822	aweitzeli2@so-net.ne.jp	2407	\N	2021-11-24	sP6<&(i0h	2024-03-20	active
1165	Myrle Wiggam	M	2004-04-04	2219416504	mwiggami3@reddit.com	2026	\N	2020-04-09	hZ1|YzM,	2024-11-28	active
1166	Starla Sturdy	M	2000-05-16	2298772813	ssturdyi4@odnoklassniki.ru	4805	\N	2022-03-22	hN8+sZgTq}E	2024-12-26	active
1167	Silas Wondraschek	F	1989-09-04	8292872312	swondrascheki5@adobe.com	4874	\N	2021-07-07	kW6`e14SmO4g|+d	2024-07-30	active
1168	Benedicto Snellman	F	1994-07-20	2508712109	bsnellmani6@shutterfly.com	3852	\N	2020-06-05	nG0"ooB(d	2024-06-09	active
1169	Javier Stiling	F	2003-08-15	2295060840	jstilingi7@fastcompany.com	1608	\N	2021-09-04	hO1|zt2%+lL9wZ}	2024-04-23	active
1170	Dallon McCurley	F	1997-08-10	2335322236	dmccurleyi8@rediff.com	4784	\N	2022-07-04	mG3/hNloV6	2024-03-09	active
1171	Beitris Beaufoy	M	2001-02-24	8771501710	bbeaufoyi9@youtube.com	1300	\N	2020-06-29	cV1"om!fslO}	2024-07-06	active
1172	Cris Hickeringill	M	1990-01-06	1065120177	chickeringillia@ftc.gov	4305	\N	2021-12-09	mC6{%g3SKxZ+{V*	2024-06-28	active
1173	Suzanna Crighten	F	1986-03-14	9719356666	scrightenib@php.net	3823	\N	2022-08-29	eG8$%TlsZ	2024-05-04	active
1174	Phillis Pengilly	M	1984-06-25	7494727170	ppengillyic@google.ru	2348	\N	2021-06-22	qS2.(TGud3#aOR@	2024-09-20	active
1175	Lynnet Wabey	F	1983-12-04	5078787530	lwabeyid@washington.edu	3758	\N	2021-04-04	fE8,`oCu5	2024-04-22	active
1176	Genvieve Merfin	M	1987-10-28	1513364301	gmerfinie@chron.com	3607	\N	2021-03-20	uU9?/@fXPgO	2024-11-10	active
1177	Ally Pimlock	M	1980-11-03	7015679894	apimlockif@sciencedirect.com	2647	\N	2021-01-15	cE2)'.KJbHcN|87B	2024-01-25	active
1178	Anatollo Kleinber	F	2004-02-28	9964115637	akleinberig@fotki.com	4282	\N	2020-01-05	pV9})njKI}7"A	2024-06-08	active
1179	Alastair Pidcock	F	1994-12-02	3257815753	apidcockih@php.net	843	\N	2021-09-08	hW4/'u$Y	2024-08-07	active
1180	Karole Twaits	M	1983-09-15	1582325547	ktwaitsii@bravesites.com	131	\N	2020-10-31	zX8{Nl")_b@Mj.h	2024-09-03	active
1181	Trevor Cutbirth	F	1980-03-07	4064709346	tcutbirthij@storify.com	1557	\N	2020-09-11	bA8|#d#h	2024-06-09	active
1182	Danika De Maine	M	1985-04-12	7518512347	ddeik@netvibes.com	3248	\N	2020-04-18	hJ4#,?BY17uV4	2024-11-24	active
1183	Bessie Bemlott	M	1997-03-16	6292307459	bbemlottil@senate.gov	4806	\N	2022-06-26	dU0`+0!b	2024-03-31	active
1184	Ethelred Pringer	F	2000-06-20	6216518083	epringerim@hatena.ne.jp	2740	\N	2022-04-29	pM9=?4b3kxJ1	2024-10-27	active
1185	Donny Capron	M	1990-12-09	2364044609	dcapronin@loc.gov	4810	\N	2020-05-05	cY8*sjtJ+V@7	2024-11-29	active
1186	Tessie Bagger	F	1994-07-31	7062861903	tbaggerio@ustream.tv	20	\N	2020-08-06	dH0|g}qxT"Y'+2~n	2024-01-05	active
1187	Eolande Khotler	F	2000-03-24	1522342363	ekhotlerip@pagesperso-orange.fr	215	\N	2020-12-19	uX6*DYi)_mR@j8	2024-06-11	active
1188	Katharina Shakelade	M	1991-02-04	1406673271	kshakeladeiq@aol.com	490	\N	2020-03-20	cC2$_W2eHA2wii0Y	2024-08-04	active
1189	Leigha Milmoe	F	1985-02-10	2045970552	lmilmoeir@cargocollective.com	4379	\N	2022-11-15	aY5"%"mWi??%dX	2024-08-05	active
1190	Erminia Southcott	M	1982-11-30	6911386246	esouthcottis@gmpg.org	1813	\N	2022-06-08	hH7~2$wq>	2024-09-13	active
1191	Even Lidell	M	1989-10-20	2511804128	elidellit@fda.gov	613	\N	2021-02-14	yH6}jIFy#	2024-07-28	active
1192	Olvan Dunston	M	1992-11-01	7239559853	odunstoniu@t-online.de	3341	\N	2020-09-01	nI9.Y?>q	2024-12-24	active
1193	Eleanor Eronie	F	1988-08-23	6744735237	eeronieiv@hubpages.com	1702	\N	2021-01-18	mE1(ywmH,	2024-11-08	active
1194	Ludvig Kirsche	F	2002-11-02	3214708768	lkirscheiw@oracle.com	872	\N	2021-08-23	qQ5<Zk.lOcFKGE+5	2024-03-23	active
1195	Christy Kears	F	1981-04-04	2699136215	ckearsix@linkedin.com	891	\N	2020-09-24	cG2~3UF.DTX#4#D	2024-05-29	active
1196	Dawna Semper	M	1992-11-08	5702926724	dsemperiy@about.me	1088	\N	2022-05-20	bY2+`2WGLH47S_GI	2024-07-02	active
1197	Becca Bathow	M	1998-02-04	1839227967	bbathowiz@ucoz.com	4166	\N	2021-06-18	hT9@EL\\.KdVp	2024-02-26	active
1198	Cort Boothby	M	1997-12-07	5743726796	cboothbyj0@desdev.cn	2527	\N	2021-02-07	iK1?.hU}M?z`GY	2024-12-17	active
1199	Basilius Sadler	F	1985-01-11	8876051383	bsadlerj1@delicious.com	4744	\N	2020-08-18	bJ8/zf8mMPr	2024-09-01	active
1200	Cos Belly	M	1996-06-13	6339911975	cbellyj2@merriam-webster.com	2298	\N	2020-05-22	vN5/&OiNYz_F	2024-08-23	active
1201	Leslie Morgan	M	1996-04-10	1838426446	lmorganj3@mozilla.com	1759	\N	2021-09-14	yM7@3pq!6C{	2024-08-02	active
1202	Frederik Whitland	F	2000-08-18	8074040740	fwhitlandj4@acquirethisname.com	2789	\N	2021-08-01	eW0"hY42	2024-12-10	active
1203	Adria Diment	M	1996-10-23	4662637896	adimentj5@boston.com	4012	\N	2022-08-12	vW2'P*bWFJ(`CXEG	2024-01-20	active
1204	Kiah Donoher	M	1997-03-10	8691627728	kdonoherj6@geocities.jp	4057	\N	2020-02-18	aH9@t`#sA}f16&.	2024-05-06	active
1205	Tobe Gealle	M	2002-07-25	9525565331	tgeallej7@nydailynews.com	2702	\N	2022-10-31	xR5#.y!"	2024-07-26	active
1206	Leoine Weighell	F	1987-04-23	2132224303	lweighellj8@jigsy.com	3052	\N	2021-07-03	cS1`>3Y/	2024-08-29	active
1207	Elva Debill	F	2004-09-12	1823515610	edebillj9@bloglovin.com	2874	\N	2022-12-16	iJ0>$.5LRap	2024-09-19	active
1208	Marnia Hearsey	F	1980-12-13	1435720728	mhearseyja@sakura.ne.jp	1927	\N	2020-11-17	uI8$9?q4n#z`9C	2024-02-27	active
1209	Deborah Richards	M	1995-03-06	7482240239	drichardsjb@cdc.gov	4477	\N	2022-03-08	vU6"d?Fs@<v	2024-05-28	active
1210	Bennie McKelvey	M	1980-08-03	1365861464	bmckelveyjc@google.co.jp	2492	\N	2020-03-15	pS0,r9@W%ddj`+7	2024-07-13	active
1211	Bard Peerman	F	1989-03-22	8313669674	bpeermanjd@yahoo.co.jp	4716	\N	2020-03-16	yA0@0O&r7$EY	2024-08-14	active
1212	Roseanna Hewertson	F	1988-03-03	8603358688	rhewertsonje@tuttocitta.it	1954	\N	2021-07-31	qI3,?qE\\s	2024-06-26	active
1213	Zulema Killbey	F	1982-12-31	4072284782	zkillbeyjf@businesswire.com	1964	\N	2022-07-17	xO5"Cbhh'e1i	2024-09-21	active
1214	Misty Grzeskowski	F	2004-02-06	5176126162	mgrzeskowskijg@soundcloud.com	423	\N	2020-08-05	iE5=OZtc	2024-05-30	active
1215	Konstanze Kirkness	F	1980-06-24	3812077944	kkirknessjh@sogou.com	2423	\N	2021-05-29	hL8\\8a7Q5)Qrr\\8	2024-04-06	active
1216	Cy Gookes	F	1984-12-02	6488273794	cgookesji@google.ru	1962	\N	2020-10-03	sO8$bX!!9'>%1	2024-08-11	active
1217	Cal Keeler	M	1980-07-15	7711990052	ckeelerjj@forbes.com	11	\N	2021-03-18	tO2''4`D	2024-06-09	active
1218	Eilis Swaysland	F	2001-05-13	7737983207	eswayslandjk@sbwire.com	1692	\N	2021-02-18	bU8<&LH$8A	2024-12-09	active
1219	Prue Springthorpe	M	2000-05-30	9041395514	pspringthorpejl@yolasite.com	2930	\N	2021-12-05	bL3_O@DOx@n	2024-10-17	active
1220	Shannan Morman	F	2004-12-17	1901398607	smormanjm@msn.com	4434	\N	2022-12-18	qT4&2qi"<0PQ	2024-04-23	active
1221	Josias Syfax	M	1987-05-14	5007403761	jsyfaxjn@mayoclinic.com	4379	\N	2020-01-29	bE8<%OTKqx$?	2024-02-21	active
1222	Garold Wheowall	M	1995-03-06	2304574118	gwheowalljo@tumblr.com	3698	\N	2020-07-14	zZ5&8QTMAhX@mV	2024-11-20	active
1223	Yolanthe Dalgarnocht	F	1983-07-02	9639526909	ydalgarnochtjp@ask.com	4280	\N	2021-11-30	vL5+hVMHu<==	2024-12-09	active
1224	Tyrone Broomfield	M	1992-02-18	8361194698	tbroomfieldjq@wisc.edu	4362	\N	2022-10-03	cY4+\\N,xd.KoX	2024-11-27	active
1225	Melita Eudall	F	1995-12-09	8994624817	meudalljr@163.com	3882	\N	2020-07-21	xA3`SC40cxA@RK"	2024-09-27	active
1226	Wadsworth Nisot	M	2001-06-27	3017514378	wnisotjs@ftc.gov	1644	\N	2022-01-19	iN6/acB7eC*LxBQA	2024-03-10	active
1227	Donovan Dufaire	M	1980-10-24	8453370581	ddufairejt@berkeley.edu	466	\N	2021-08-05	yW6(xU=D	2024-08-22	active
1228	Pooh Sterrie	M	2004-08-05	7201487121	psterrieju@state.gov	3651	\N	2022-04-06	fB1|yXe<zO)YL	2024-03-25	active
1229	Bobbette Jefford	F	2004-01-24	5794670836	bjeffordjv@odnoklassniki.ru	4855	\N	2020-03-09	mW2=<R.(gSP	2024-07-02	active
1230	Vita Chalke	M	1985-08-23	5385970424	vchalkejw@upenn.edu	2875	\N	2020-11-30	aZ4}CkuXma=O	2024-08-07	active
1231	Sheree Scarth	F	1989-11-23	1933721081	sscarthjx@xrea.com	1092	\N	2022-04-11	aT2\\.j+_ctHcL9p5	2024-12-03	active
1232	Neda McGaraghan	F	1988-05-06	3322512898	nmcgaraghanjy@tinypic.com	4100	\N	2021-07-07	rY6>RkpP9X7Lw*	2024-05-13	active
1233	Dannye Tomlins	M	2001-03-30	5953517923	dtomlinsjz@ehow.com	1073	\N	2020-08-31	aY7~}/ntXn	2024-03-13	active
1234	Marcella Braham	F	1993-06-22	2369212474	mbrahamk0@miibeian.gov.cn	2436	\N	2021-01-23	aT1?D(Lix#4}$7v	2024-11-22	active
1235	Feodor Boneham	F	1989-01-12	3566713258	fbonehamk1@bing.com	390	\N	2022-08-02	yJ6?CJam039.	2024-06-15	active
1236	Birdie Benza	M	2000-03-24	8947724049	bbenzak2@mac.com	4843	\N	2020-04-09	mL5}Oi47%?/	2024-02-24	active
1237	Courtnay Dullard	F	2000-10-01	6916849907	cdullardk3@scientificamerican.com	1709	\N	2020-05-27	gZ4|Oj@zb	2024-11-25	active
1238	Drusilla Langtree	M	1990-07-30	9391878271	dlangtreek4@barnesandnoble.com	2614	\N	2020-12-04	pQ4}o%bLZ0yA"	2024-08-26	active
1239	Pier Kegley	M	1998-12-13	4171289801	pkegleyk5@pen.io	3243	\N	2022-12-01	vL2,7=%YzLY\\\\	2024-07-13	active
1240	Serene Rispin	M	1985-10-25	8824223577	srispink6@epa.gov	168	\N	2022-09-24	mJ1,%0%)(1W!	2024-04-29	active
1241	Johnath Dranfield	F	2003-11-30	3504597161	jdranfieldk7@si.edu	1705	\N	2021-09-11	iF8<o"SX	2024-04-05	active
1242	Darlleen Calton	M	2003-03-06	9255901065	dcaltonk8@businessinsider.com	606	\N	2022-07-31	pO2@X<DxMQjX	2024-01-30	active
1243	Kylie Savins	F	1987-09-30	1295923226	ksavinsk9@state.tx.us	4250	\N	2021-04-24	jY0\\49,q'1	2024-07-27	active
1244	Janot Grouvel	M	2002-06-16	9959543746	jgrouvelka@facebook.com	3677	\N	2020-02-07	yN2&pNs"228osS%	2024-08-22	active
1245	Nev Andrejs	F	1988-03-04	1929512352	nandrejskb@google.ru	3940	\N	2021-03-10	mJ6{3A+Ad.>H	2024-08-12	active
1246	Bryant Mateev	M	1986-02-18	5375049886	bmateevkc@gizmodo.com	4001	\N	2021-12-24	xQ7?L\\TyxK{	2024-10-14	active
1247	Stefano Lorenzetti	F	1986-04-07	3056350002	slorenzettikd@naver.com	4172	\N	2022-01-28	gJ0!IcgGp	2024-05-02	active
1248	Ainslee McGaughie	F	1990-12-19	5967727310	amcgaughieke@miibeian.gov.cn	3012	\N	2021-01-30	iM6{j6"=#*	2024-08-02	active
1249	Ludwig Pirrone	F	1983-05-01	4179992784	lpirronekf@sciencedaily.com	3566	\N	2020-10-23	hV9#=D(Rdv3D{	2024-03-23	active
1250	Donavon Tiesman	M	1986-11-08	7017513759	dtiesmankg@yolasite.com	520	\N	2022-11-16	uH8`79k)	2024-02-21	active
1251	Livia Brindley	F	1999-05-15	2084157237	lbrindleykh@a8.net	1259	\N	2020-01-05	pR5+){BLfQgW	2024-05-02	active
1252	Petra Yurtsev	F	1985-08-23	2812307224	pyurtsevki@dedecms.com	3558	\N	2020-09-19	gW8>#<&ITP)g	2024-11-21	active
1253	Josy Van Zon	M	1991-10-22	7613427045	jvankj@ucsd.edu	2296	\N	2022-09-24	bV9)HIzLnbAF	2024-09-26	active
1254	Olivero Paliser	M	1989-02-26	4104424817	opaliserkk@de.vu	1048	\N	2022-06-08	uV4'nAgJ0g)$	2024-06-09	active
1255	Giff Hritzko	M	1987-03-06	4623186331	ghritzkokl@trellian.com	4979	\N	2022-05-30	yT3\\H!&+1A>e_	2024-03-26	active
1256	Reagen Prozescky	M	1992-08-19	8763626819	rprozesckykm@google.it	3304	\N	2020-11-07	wV1$4n4j+sywEL	2024-05-31	active
1257	Leonhard Orchart	F	1989-04-10	4769644356	lorchartkn@npr.org	1401	\N	2021-12-22	pO4+VUlPb3	2024-04-23	active
1258	Renate Forman	F	2000-05-20	1208850038	rformanko@un.org	2821	\N	2020-01-28	mW5<hK~8Wed>0'	2024-06-05	active
1259	Elwira Verty	F	1999-02-12	1729953387	evertykp@google.co.uk	3565	\N	2022-09-13	pA3,IZ\\hr_xe	2024-02-10	active
1260	Albertine Maleham	M	1996-06-11	5561043103	amalehamkq@livejournal.com	4816	\N	2020-03-08	pP4@AR5?QFb	2024-12-30	active
1261	Elie Wakely	M	1981-02-12	6152453870	ewakelykr@symantec.com	3394	\N	2021-11-03	oP3(C\\Yrj|	2024-06-01	active
1262	Tish Connop	F	1987-11-30	8615724732	tconnopks@naver.com	4512	\N	2021-03-29	rB8&FngMx	2024-06-20	active
1263	Madelena Ferrierio	M	1997-01-30	1387184946	mferrieriokt@ihg.com	952	\N	2021-10-24	jB4.Wi\\f>S7aV	2024-03-02	active
1264	Art Pilch	F	1992-08-15	2936858157	apilchku@discuz.net	3187	\N	2021-12-17	jE6*PQCA	2024-05-19	active
1265	Mendel Wortman	F	1991-01-19	8056420152	mwortmankv@purevolume.com	3333	\N	2022-12-01	bX4#Qw3e'|nX	2024-09-26	active
1266	Umeko Zecchetti	F	2001-12-20	5503204943	uzecchettikw@google.fr	69	\N	2021-12-19	mT9}@}ao2~r	2024-09-08	active
1267	Sophi Ffoulkes	M	1989-11-08	3427632910	sffoulkeskx@xinhuanet.com	2727	\N	2021-04-04	kQ9=qgf>@{81e2Wq	2024-12-18	active
1268	Tades Skoate	F	1989-07-09	2916477932	tskoateky@flickr.com	2141	\N	2021-02-02	xE3`cJJx	2024-03-10	active
1269	Gilberta McBratney	M	2004-02-13	7337032214	gmcbratneykz@joomla.org	2685	\N	2022-07-19	mW8~EwE7s=,<lg2X	2024-08-30	active
1270	Paulie Ballam	F	1981-08-05	1394411019	pballaml0@mtv.com	3796	\N	2021-06-03	oG0>rYt<$$d_Z	2024-07-16	active
1271	Rici Gilhouley	F	1995-04-01	1725084709	rgilhouleyl1@yale.edu	4482	\N	2020-02-04	cQ7{`cclkb	2024-12-07	active
1272	Andie Adamini	M	1994-06-17	1975671016	aadaminil2@list-manage.com	769	\N	2022-12-12	tK0)bm}4+AtnQH	2024-12-07	active
1273	Petra Tootell	M	1987-03-28	7296227718	ptootelll3@statcounter.com	2362	\N	2021-05-29	jE8(X}%zQI	2024-02-28	active
1274	Burl Garr	M	1988-11-26	6405223516	bgarrl4@wsj.com	50	\N	2020-07-02	gW6&Cd(}Htc4	2024-09-11	active
1275	Misti Dunge	F	1991-11-29	2644124329	mdungel5@squarespace.com	1422	\N	2022-01-22	aY1@0U/{s	2024-10-19	active
1276	Carolan Ebbles	M	1997-11-10	5129091188	cebblesl6@auda.org.au	1743	\N	2022-07-24	kU1{132<DhZYq7O	2024-09-17	active
1277	Sharl Pagnin	F	1987-04-27	1081631601	spagninl7@ezinearticles.com	3088	\N	2020-03-10	pG6"d{WrA	2024-12-27	active
1278	Allie Largen	F	1993-07-25	9953071095	alargenl8@abc.net.au	4755	\N	2020-05-09	jA3%Wo6~PO	2024-06-03	active
1279	Janaye Napper	F	1982-12-09	3887007018	jnapperl9@freewebs.com	482	\N	2022-05-16	uH9_U?!whL}zp	2024-09-04	active
1280	Sigvard Fardell	F	2004-05-20	1791589300	sfardellla@parallels.com	3173	\N	2022-02-18	pY2+9Q4I8&QS_BS	2024-08-24	active
1281	Alecia Calcut	M	1996-03-17	8127923021	acalcutlb@theguardian.com	4206	\N	2021-10-26	vG5//xfZH_C1Y8r	2024-02-09	active
1282	Fabiano Balaison	M	1987-06-08	6931205615	fbalaisonlc@deviantart.com	2243	\N	2020-02-17	vT9%YaRN3GRG	2024-01-31	active
1283	Rodolfo Watton	M	1996-04-08	2756028364	rwattonld@about.com	4249	\N	2022-11-29	zM3$R{z,hY	2024-02-22	active
1284	Wilie Enefer	M	2001-09-18	4175135333	weneferle@newyorker.com	1882	\N	2020-07-16	wV2$qUb'=q@9	2024-03-04	active
1285	Evania Heathcoat	F	1998-06-28	7148987820	eheathcoatlf@senate.gov	2314	\N	2021-06-30	wT2!MMWd0A}T	2024-04-09	active
1286	Abigael Marking	F	1982-12-06	1177046563	amarkinglg@paginegialle.it	3799	\N	2022-07-24	wU6{TS~YK)Oj?6|{	2024-12-15	active
1287	Florina Allenby	M	1982-08-23	7621577126	fallenbylh@washingtonpost.com	4222	\N	2022-04-01	hL9?=wdQI3'/=	2024-11-04	active
1288	Terrye Rizon	M	1983-11-01	5078332815	trizonli@ycombinator.com	3920	\N	2021-04-22	fI6?p,@j\\+kzz"	2024-06-20	active
1289	Matthiew MacGarrity	F	1999-01-26	9187150479	mmacgarritylj@mozilla.com	769	\N	2021-09-30	kK0_ZG8|lluVW$%w	2024-10-12	active
1290	Dal Ellsbury	M	1997-11-28	5052979194	dellsburylk@joomla.org	2581	\N	2022-06-20	bO5'BIDcDQ9kjL	2024-12-08	active
1291	Daphene Markushkin	F	1982-10-11	3539089609	dmarkushkinll@sakura.ne.jp	3535	\N	2020-07-30	rG7&4o3kc0	2024-07-08	active
1292	Leta Lalevee	M	1985-03-10	4474603010	llaleveelm@patch.com	1176	\N	2022-03-20	pR7.T(9"_242S	2024-07-13	active
1293	Ursula Staddart	M	1985-01-05	6383127957	ustaddartln@behance.net	4033	\N	2022-06-05	bY5,BNopB(|	2024-04-29	active
1294	Gene Squires	F	1986-09-27	5003233152	gsquireslo@digg.com	3133	\N	2020-10-04	eT0)&|yMn@U,rft	2024-06-27	active
1295	Gabbie Fritchly	F	1997-08-25	2112937849	gfritchlylp@berkeley.edu	1145	\N	2021-01-19	tH5++rivQZ@!N	2024-11-04	active
1296	Delora Rennock	M	1999-03-19	7395894027	drennocklq@twitpic.com	274	\N	2022-08-24	vG7>{GZj9Rn|0mja	2024-09-23	active
1297	Holly Champe	F	1986-03-15	6159188237	hchampelr@mit.edu	3302	\N	2022-02-17	aY7,Xr,FneVIM	2024-02-08	active
1298	Kelcey Monnery	F	1991-07-10	6007811814	kmonneryls@acquirethisname.com	3150	\N	2020-01-27	hW9_"cz9cj#Hz{/?	2024-10-08	active
1299	Denise Crews	M	1988-05-11	4236503192	dcrewslt@sakura.ne.jp	2737	\N	2020-06-07	aH5$XDq7DpBQ\\*f	2024-01-08	active
1300	Robinetta Ledster	F	1985-10-21	7603995933	rledsterlu@hatena.ne.jp	4354	\N	2020-12-20	zW6!%yV'aJ%L`0+	2024-01-26	active
1301	Silvie Dable	M	1983-05-31	8231075072	sdablelv@freewebs.com	1913	\N	2021-10-15	iY9@&mPmN#$	2024-04-13	active
1302	Woodrow De Dei	F	2002-05-01	3217702660	wdelw@ibm.com	2915	\N	2020-04-25	nL8"c>gF	2024-11-22	active
1303	Codie Gerretsen	M	2002-11-15	3083411378	cgerretsenlx@ftc.gov	4452	\N	2021-12-07	zC1*4wPY2/	2024-10-31	active
1304	Amalle Orrey	F	2003-07-01	7836338057	aorreyly@dedecms.com	4880	\N	2021-08-09	gM9(W/p"c5ChES	2024-05-02	active
1305	Geneva De Ambrosi	M	2000-04-22	7035131355	gdelz@forbes.com	4403	\N	2022-12-13	wB6|g)pQ	2024-04-19	active
1306	Pierce Andreia	F	1987-02-16	5529889266	pandreiam0@google.cn	2173	\N	2021-09-12	aM6>dQtwyz?TdQ	2024-10-07	active
1307	Billy Happert	F	1986-04-12	9496737780	bhappertm1@reverbnation.com	1311	\N	2020-10-16	yF8"LE*T	2024-11-14	active
1308	Aland Cornish	M	1983-06-15	4463908818	acornishm2@mapy.cz	3652	\N	2021-12-05	nG8"%5>tajuSS\\1m	2024-12-17	active
1309	Dallon McEnteggart	F	1986-10-10	8303008126	dmcenteggartm3@forbes.com	3258	\N	2021-11-19	xY1&t}Eb?Lq	2024-01-23	active
1310	Karrah Baldack	F	1998-01-04	3806480412	kbaldackm4@usda.gov	3847	\N	2021-09-04	gC3!vXCGa	2024-12-21	active
1311	Lilas Ragdale	M	1996-04-08	9847661577	lragdalem5@prweb.com	3670	\N	2020-04-04	mJ9>83OpH	2024-11-14	active
1312	Dania Ebenezer	F	1993-11-19	7166956154	debenezerm6@cnet.com	875	\N	2020-06-27	rW1_Jn'o<Yk?2	2024-05-16	active
1313	Claretta Camell	M	2001-10-10	4556559291	ccamellm7@mlb.com	2704	\N	2021-08-30	lM1_,*yh!!`	2024-06-10	active
1314	Minerva Fennessy	F	1995-10-20	6408698476	mfennessym8@cdc.gov	3842	\N	2021-08-24	eX8/anoR)t	2024-04-03	active
1315	Hugo Brandacci	M	1985-10-15	5493910554	hbrandaccim9@go.com	2986	\N	2020-12-01	fN4}KW4ZR7/	2024-05-13	active
1316	Millard Castleton	M	1996-10-24	2631247109	mcastletonma@unc.edu	4539	\N	2022-04-06	iI1@ur6!{Ubh=#	2024-10-17	active
1317	Beatrice Wix	M	2002-10-01	7856399684	bwixmb@cpanel.net	1082	\N	2020-03-08	mT0?qvVs	2024-04-17	active
1318	Henriette Perrottet	M	2002-01-16	3956145928	hperrottetmc@ucoz.com	501	\N	2022-12-01	uP3#pgZp	2024-11-10	active
1319	Ricky Jelley	M	2003-07-13	4558844399	rjelleymd@hud.gov	4224	\N	2022-07-22	dD1(a_T3QN&Sq'r	2024-06-03	active
1320	Rosabella Castellet	F	1990-06-13	2701964857	rcastelletme@networksolutions.com	4556	\N	2021-01-29	lA2",jL}BCW/AY,	2024-04-06	active
1321	Dylan Peteri	M	1988-08-06	7261890081	dpeterimf@xinhuanet.com	4026	\N	2022-07-21	hV5~V&3AJ.Y	2024-09-04	active
1322	Tulley Offill	M	1996-09-25	5099993910	toffillmg@paginegialle.it	2660	\N	2021-03-26	dU0|hztqljZ_	2024-03-04	active
1323	Aili Mandy	F	1993-01-06	6441568231	amandymh@shareasale.com	4972	\N	2021-09-03	bZ0$bO36Yw_."G*	2024-04-04	active
1324	Mata Svanetti	F	2000-10-05	1052788233	msvanettimi@msu.edu	4571	\N	2021-04-21	fR8#y`4Se'0	2024-03-21	active
1325	Stefania Axup	F	1995-08-17	9537842897	saxupmj@marketwatch.com	1126	\N	2022-05-17	tU9_yc<@Q	2024-05-29	active
1326	Lauren Pretious	M	1994-09-27	1005958868	lpretiousmk@quantcast.com	1598	\N	2020-07-12	eB7_C%?p1rIEjrJ	2024-06-17	active
1327	Nehemiah Frosdick	M	1993-02-01	8885460523	nfrosdickml@mac.com	1470	\N	2021-12-14	iL8<o*u}r1m>KK	2024-03-27	active
1328	Joyce Walduck	F	2002-03-06	5442892928	jwalduckmm@bizjournals.com	4187	\N	2021-03-21	lA8$upll	2024-09-28	active
1329	Bernhard Smallshaw	M	1999-10-30	5164333459	bsmallshawmn@techcrunch.com	1346	\N	2020-02-21	vK7<xjXb	2024-09-07	active
1330	Ad Plimmer	F	1996-12-02	2882807934	aplimmermo@xinhuanet.com	4008	\N	2020-06-02	gE4(9fhSu	2024-09-21	active
1331	Lind Brahan	M	1981-02-21	8001731267	lbrahanmp@merriam-webster.com	335	\N	2021-05-21	pA2=d.eXuo%,P	2024-03-19	active
1332	Ula Baser	M	1983-03-30	8477551897	ubasermq@cargocollective.com	460	\N	2020-10-14	eA7*{)UT	2024-08-03	active
1333	Allissa McMakin	M	1986-09-28	2856076758	amcmakinmr@creativecommons.org	542	\N	2022-02-14	sH3)s/MI	2024-04-08	active
1334	Ellyn Westney	F	2001-04-04	6196401108	ewestneyms@odnoklassniki.ru	1260	\N	2020-07-02	dA4&<,Or1a,m	2024-07-28	active
1335	Ugo Hasker	F	1993-02-17	4935207196	uhaskermt@geocities.jp	2369	\N	2022-11-15	fI7%MWF_	2024-02-22	active
1336	Neville Darch	M	1985-11-12	8724472970	ndarchmu@europa.eu	2562	\N	2022-07-07	wF9>pSbt1<@,#@	2024-01-20	active
1337	Noel Toulmin	M	1993-05-08	1969607900	ntoulminmv@yellowbook.com	77	\N	2022-02-21	uD9=}|x5	2024-11-18	active
1338	Milka Annett	M	1984-07-09	7873799114	mannettmw@barnesandnoble.com	1780	\N	2020-04-28	aJ7@BI(|ds=rd	2024-04-27	active
1339	Jodee De Vaan	F	1989-04-12	6438303544	jdemx@wisc.edu	1791	\N	2022-09-30	lM9)q9K*=M%0	2024-05-05	active
1340	Selig Finicj	M	2000-02-17	9626641957	sfinicjmy@state.gov	1800	\N	2021-12-15	cQ0(UUb1g/7)	2024-12-25	active
1341	Horton Witling	F	1981-11-24	1854270465	hwitlingmz@china.com.cn	4172	\N	2020-12-02	iE2`.{uRkB'Xy2	2024-03-10	active
1342	Priscilla Blythin	M	1993-11-25	5611158494	pblythinn0@sourceforge.net	3296	\N	2022-11-01	fS5.Wp&TsaEO9S,p	2024-02-06	active
1343	Milzie Porker	F	1997-04-18	9863484999	mporkern1@freewebs.com	1048	\N	2021-01-13	gN6+)P0y~	2024-05-20	active
1344	Melita Conechie	F	1982-09-04	6748768630	mconechien2@sourceforge.net	1045	\N	2020-12-30	qR2+k/MX6ys(\\+_p	2024-02-15	active
1345	Marcelia Burle	F	2001-07-05	4219309956	mburlen3@themeforest.net	2322	\N	2022-06-06	iJ3={Hxn>	2024-04-01	active
1346	Celene Cavee	F	1981-05-09	6634363176	ccaveen4@ox.ac.uk	422	\N	2022-02-24	zF4"kJ`fmYmH1`n)	2024-08-22	active
1347	Kathlin Beardmore	F	1982-03-23	4627713148	kbeardmoren5@java.com	1572	\N	2022-10-15	iJ7|WI7VD'$_	2024-03-02	active
1348	Rakel MacAscaidh	F	1993-10-05	3251595682	rmacascaidhn6@hatena.ne.jp	2522	\N	2020-04-21	bR0=S&&q!CgjTd	2024-01-10	active
1349	Nelie Brownsmith	M	1992-09-11	3814254767	nbrownsmithn7@google.de	547	\N	2021-04-10	gR3+$jov5se+&	2024-07-06	active
1350	Alisha Wellbelove	M	1989-06-08	6652239175	awellbeloven8@homestead.com	2146	\N	2020-03-03	qV5,%Jl)X=	2024-11-06	active
1351	Erik Theodore	F	2004-10-19	8848596841	etheodoren9@amazon.co.jp	4184	\N	2020-11-19	lR1+C,BeE1Cs	2024-07-25	active
1352	Lanae Barwack	M	1996-01-24	9033095059	lbarwackna@liveinternet.ru	2268	\N	2022-12-22	dN1'K5v4JiJeo,	2024-12-17	active
1353	Tiebout Murie	M	1991-09-16	6849832856	tmurienb@zdnet.com	4722	\N	2021-04-13	kF3#s{s5ef)J9Ob	2024-03-15	active
1354	Jonas Jachimczak	F	1998-04-04	6054622872	jjachimczaknc@si.edu	4574	\N	2020-11-27	xE7!C%8jffr/oVy	2024-07-16	active
1355	Clemence McGavin	F	1988-08-28	5027537433	cmcgavinnd@auda.org.au	4938	\N	2022-09-30	vL6(O08z	2024-08-13	active
1356	Mary Furst	M	1980-01-12	7176692169	mfurstne@noaa.gov	4056	\N	2020-09-13	oW5%0EfD=dYaR	2024-01-16	active
1357	Savina Wozencroft	F	1990-06-27	3982819739	swozencroftnf@stanford.edu	2014	\N	2021-06-16	uQ2"{H"86{/JfHI	2024-05-10	active
1358	Harris McClintock	M	1995-10-01	6389561489	hmcclintockng@meetup.com	477	\N	2020-12-16	iI5/?3Iu\\	2024-05-14	active
1359	Eugene Buttel	F	1999-05-26	4863684078	ebuttelnh@npr.org	616	\N	2022-11-25	xN1)>(UyN)$!.}g	2024-12-24	active
1360	Eberhard Everist	F	1983-09-11	2201486654	eeveristni@w3.org	2654	\N	2021-02-06	rX6<93c=Z>	2024-04-16	active
1361	Heddie Saxon	M	1981-07-14	6112018890	hsaxonnj@uiuc.edu	3379	\N	2021-04-29	fV0=9e5Q{6DiMR?	2024-10-30	active
1362	Joly Wellstead	F	1997-12-04	6894071733	jwellsteadnk@163.com	2072	\N	2021-06-20	tB6%C0pp@_2+R|Si	2024-09-20	active
1363	Cybill Linton	F	1995-07-04	1498741619	clintonnl@edublogs.org	2593	\N	2022-03-26	lA0"MnHzg*S	2024-01-20	active
1364	Englebert Bellany	M	1989-06-05	9065516956	ebellanynm@t.co	2228	\N	2021-02-27	xK3>@vHSYS7x	2024-02-03	active
1365	Gweneth Limon	F	1997-09-19	3144134962	glimonnn@narod.ru	4465	\N	2020-05-03	qP1$GSQ`OnE>|AI	2024-03-01	active
1366	Allin Glasman	F	1996-11-19	3998111617	aglasmanno@qq.com	1011	\N	2022-11-24	zY1'!>Eg/vpbR413	2024-11-03	active
1367	Barron Braisher	M	2003-01-01	1579144117	bbraishernp@engadget.com	3068	\N	2021-07-23	vG4{$t7aFdvm3	2024-11-22	active
1368	Job Beldam	M	2002-03-04	3336428298	jbeldamnq@oracle.com	4109	\N	2021-07-14	kR6&,RmF	2024-01-16	active
1369	Jaclin Imison	F	1990-03-01	5277480159	jimisonnr@aol.com	1305	\N	2022-07-16	pR7{yB'>x1n	2024-09-19	active
1370	Celestia Wickwarth	M	1988-12-31	9738917103	cwickwarthns@google.co.uk	2101	\N	2021-08-15	qB9`&r8B?g&UR	2024-11-05	active
1371	Ferdy Spini	F	2003-10-22	1323187625	fspinint@theatlantic.com	813	\N	2022-08-15	bT1+Q,xI8`C"9m	2024-04-26	active
1372	Salomo Druitt	F	1984-02-06	9498390521	sdruittnu@slashdot.org	4779	\N	2022-09-28	jF4,_BT9K	2024-05-26	active
1373	Eartha Densey	F	1992-02-28	7249281394	edenseynv@nymag.com	643	\N	2022-11-08	rO1*3{'_	2024-03-27	active
1374	Giselbert Pohlak	F	1987-03-10	9855512412	gpohlaknw@scientificamerican.com	1945	\N	2021-07-10	bP1@"JxZ	2024-11-14	active
1375	Noellyn Scroggs	M	1992-05-19	7968748996	nscroggsnx@auda.org.au	1969	\N	2022-05-29	hZ7|xI8ypT7	2024-06-04	active
1376	Mic Kerr	M	2003-02-15	4882570441	mkerrny@microsoft.com	219	\N	2020-02-02	fH9?%wzLNl.d$gVE	2024-12-02	active
1377	Ericka Nano	M	1992-04-20	6977001380	enanonz@sun.com	784	\N	2021-01-02	hR0!eIjlW}@X	2024-11-06	active
1378	Brandyn Kayzer	M	2000-04-22	1494678257	bkayzero0@usa.gov	2959	\N	2022-12-23	xR7,$a|*9{Qe*l.	2024-11-30	active
1379	Jamesy Cundy	M	2000-06-02	8125851638	jcundyo1@sohu.com	2895	\N	2021-07-07	jB1=aEC,W&q	2024-05-01	active
1380	Nanci Gilroy	M	1998-02-19	6535492656	ngilroyo2@mashable.com	3773	\N	2022-12-31	bC3%rlc|QPJrZ}	2024-02-17	active
1381	Tobiah Portch	F	1982-08-11	6658478061	tportcho3@paginegialle.it	1327	\N	2021-07-25	sT7!su?=P	2024-02-08	active
1382	Virge Coughlan	M	1994-06-23	9468899428	vcoughlano4@bluehost.com	378	\N	2021-07-28	nX9+UjwRE\\N!p	2024-08-06	active
1383	Roberto Neiland	M	1987-04-13	5529625562	rneilando5@auda.org.au	48	\N	2022-08-27	yX7(!UgX{+%1eX'q	2024-03-10	active
1384	Lacee Aronowitz	M	1988-09-09	1562095256	laronowitzo6@homestead.com	3636	\N	2021-01-26	qQ8}6(nB?F	2024-05-01	active
1385	Elsy Boerderman	M	1986-07-21	3119211186	eboerdermano7@alibaba.com	539	\N	2021-07-29	zF9&4lx5M&F2q_y	2024-01-26	active
1386	Emmye Georgelin	F	1987-07-14	8798463837	egeorgelino8@tripod.com	4954	\N	2020-07-04	uZ5.yS%>b{2"G	2024-02-15	active
1387	Linet Staniland	F	1999-03-07	3589100630	lstanilando9@dedecms.com	3724	\N	2022-11-23	rS7.gErDU	2024-05-13	active
1388	Brittni Honig	F	2004-03-02	7727186054	bhonigoa@trellian.com	3553	\N	2022-04-07	yX9<G55N<r!C8+6	2024-07-14	active
1389	Enoch Prophet	F	1981-02-08	2345095543	eprophetob@ustream.tv	2836	\N	2021-11-28	cV6}dg_Ia"	2024-06-09	active
1390	Gavra Burkill	M	1989-09-03	7473701315	gburkilloc@mail.ru	4295	\N	2021-11-07	rA8&v0<J	2024-12-03	active
1391	Anjela Gummow	F	1994-07-07	8597346033	agummowod@mashable.com	4793	\N	2021-11-20	hR2.W{vqFI4	2024-07-28	active
1392	Marietta Feares	F	2000-10-16	1283669816	mfearesoe@bizjournals.com	163	\N	2022-08-22	yU4.v#Kx!5F>	2024-10-30	active
1393	Sheena Grastye	F	1991-01-17	8938942962	sgrastyeof@oracle.com	2580	\N	2021-03-06	eE8()/dkqsq=d	2024-08-25	active
1394	Marcille Celli	M	1984-11-07	9051167999	mcelliog@mashable.com	214	\N	2021-07-01	fL9{H<DVNV	2024-10-06	active
1395	Danica Gopsill	M	1997-01-24	5814577368	dgopsilloh@intel.com	3056	\N	2022-11-11	aU8(O7|4ELE	2024-03-08	active
1396	Nicolle Fossey	F	2001-12-30	4713156516	nfosseyoi@yelp.com	4229	\N	2022-02-17	hI2'2wMV(7L	2024-08-03	active
1397	Leela Webb-Bowen	M	1986-12-09	5248687973	lwebbbowenoj@weebly.com	1710	\N	2022-01-30	hP7_=JLfla!*zShy	2024-05-23	active
1398	Francyne Seally	M	1997-07-01	7166561589	fseallyok@photobucket.com	3703	\N	2021-07-31	fG1_a$sa	2024-08-08	active
1399	Audrey Mac Giany	F	2003-11-25	7471442893	amacol@csmonitor.com	3838	\N	2020-05-14	wH7(vKbX_	2024-08-09	active
1400	Jesus Ranby	F	1980-08-05	8266109972	jranbyom@intel.com	1233	\N	2021-05-24	aQ5/{P.QFh_	2024-11-07	active
1401	Reynolds Litchmore	F	1993-04-29	4003190978	rlitchmoreon@oaic.gov.au	1360	\N	2022-03-04	zE3_)},7gQ&1h7tj	2024-10-24	active
1402	Auberon Fuxman	F	1999-07-23	1758769802	afuxmanoo@about.me	609	\N	2021-07-04	gY2}l0tz,`Vv	2024-04-19	active
1403	Eziechiele Gilliam	F	2004-11-16	9868873738	egilliamop@kickstarter.com	3251	\N	2022-06-11	dQ3?b_xhiX0R`Sg	2024-02-09	active
1404	Keri Eldrett	F	2001-11-18	5645682335	keldrettoq@flavors.me	1992	\N	2021-04-29	pC9/MRz21\\I	2024-09-14	active
1405	Grannie Winnard	M	1980-06-23	4444286586	gwinnardor@cornell.edu	4047	\N	2020-05-07	iL4!yAgmNbx	2024-04-30	active
1406	Tracy Rahill	F	1996-12-01	5213983167	trahillos@lulu.com	4218	\N	2021-06-15	cN6?!KUy~~	2024-03-27	active
1407	Nikolia Antcliffe	M	1982-11-24	2884710101	nantcliffeot@ameblo.jp	4799	\N	2020-04-22	iS7@pOV+py}iU	2024-10-09	active
1408	Holli Treversh	F	1992-10-26	5855211429	htrevershou@cam.ac.uk	3431	\N	2020-08-25	rT0'T{P&@sKJz{A	2024-04-22	active
1409	Farleigh Kneesha	F	1993-10-07	7893335473	fkneeshaov@liveinternet.ru	4412	\N	2021-02-11	kF2|W9kR_~L5	2024-06-02	active
1410	Brent Dockree	F	1993-02-28	8479639148	bdockreeow@technorati.com	4514	\N	2022-09-10	bT9/5,oMO+i0	2024-06-14	active
1411	Daffy Ochterlonie	M	1990-04-14	8984990194	dochterlonieox@fema.gov	293	\N	2021-10-15	vJ4,#asEq3	2024-05-29	active
1412	Gaven D'Onise	M	1980-02-11	8444620106	gdoniseoy@twitter.com	1670	\N	2020-05-06	fE9_Lh6Twg`c	2024-09-20	active
1413	Cob Taylot	F	1993-10-15	8771856374	ctaylotoz@businessweek.com	1869	\N	2020-11-19	lW9.8+`+M"sxT.'7	2024-03-23	active
1414	Wallie Pummell	M	1998-09-20	8947209098	wpummellp0@issuu.com	4207	\N	2022-09-05	hP2)Q|bmP8ihX	2024-09-19	active
1415	Reece Cinnamond	M	1993-02-12	5932651625	rcinnamondp1@blinklist.com	1133	\N	2022-07-12	mT6.Zm?5+t<bQ'*?	2024-10-29	active
1416	Alexandra Astridge	M	1999-08-11	3538060273	aastridgep2@disqus.com	290	\N	2020-05-21	yC7%B$m%sKgy	2024-01-24	active
1417	Edwina D'Aulby	M	1999-02-13	4712642757	edaulbyp3@livejournal.com	4182	\N	2021-02-13	mM8&layMJMfd)ki	2024-01-05	active
1418	Alf deKnevet	F	1983-06-10	8185116453	adeknevetp4@nih.gov	4840	\N	2020-03-30	dF6$oi\\D+6+P`tf	2024-08-12	active
1419	Larissa Gifford	M	1993-08-20	1981014673	lgiffordp5@springer.com	3569	\N	2022-01-31	vI9>IRQFAB|a}!	2024-01-08	active
1420	Melisa Elam	F	1999-06-28	3191366336	melamp6@oracle.com	3169	\N	2021-07-04	kS0?<.DV#H~f~$_.	2024-11-12	active
1421	Callie Peoples	F	1989-06-29	9396728317	cpeoplesp7@about.com	1988	\N	2021-12-16	fC2!v8&mG#XB'f%	2024-05-28	active
1422	Tonye Selbie	F	1995-07-17	3808483549	tselbiep8@friendfeed.com	1703	\N	2020-06-09	zW3$>',?9	2024-02-20	active
1423	Urbain Alderson	M	1998-08-20	4292670365	ualdersonp9@redcross.org	598	\N	2020-12-26	uN2{.2O9@7u3fvxE	2024-06-30	active
1424	Yalonda Yallowley	F	1988-10-16	4472817374	yyallowleypa@pagesperso-orange.fr	52	\N	2020-04-16	eA1)GVndOu	2024-08-07	active
1425	Tracey Chimes	F	1982-05-30	1136657448	tchimespb@springer.com	525	\N	2021-05-14	uG3$6m3uFH>94/	2024-07-27	active
1426	Arturo Young	F	1984-09-28	4706192739	ayoungpc@sfgate.com	1795	\N	2022-12-08	kF3$D%kiXXFA	2024-11-23	active
1427	Gavrielle Valentin	M	2000-04-12	2549917965	gvalentinpd@mashable.com	1912	\N	2021-05-10	vP5&Bw?.	2024-05-10	active
1428	Merv Peirson	F	1995-09-17	1887181633	mpeirsonpe@zdnet.com	2635	\N	2022-06-07	yA8_?A!Mzx#	2024-02-09	active
1429	Jojo Strover	F	2001-04-29	1786089686	jstroverpf@columbia.edu	114	\N	2022-02-28	fJ0=y.qlW'	2024-06-12	active
1430	Vinita MacGillavery	F	1991-09-23	2028781230	vmacgillaverypg@example.com	2651	\N	2022-05-02	sU5&h#r`3	2024-02-12	active
1431	Kikelia Braizier	F	1991-10-27	6706063181	kbraizierph@elpais.com	1668	\N	2022-06-15	hT0|'67u{	2024-10-09	active
1432	Jessalin Collcott	F	1993-06-01	2791952526	jcollcottpi@yolasite.com	707	\N	2021-08-20	pY3$)`ZqPn	2024-05-20	active
1433	Vikky Le Breton	F	1995-06-06	7842474693	vlepj@reverbnation.com	3228	\N	2022-05-10	mX5%*5$vL!p	2024-06-29	active
1434	Harrie Dodle	M	1998-09-30	3089904981	hdodlepk@wordpress.com	2987	\N	2021-07-29	iJ4<K9)GVzJ%F	2024-08-15	active
1435	Cindee Olivie	F	1993-08-21	6854231972	coliviepl@quantcast.com	4993	\N	2020-12-14	nH3{r&jQV(Q*	2024-10-22	active
1436	Stella Sloley	F	1994-04-19	4837016126	ssloleypm@miibeian.gov.cn	486	\N	2022-11-14	yR8*9Ij4C	2024-01-14	active
1437	Erminia Balkwill	M	2004-10-28	6583111445	ebalkwillpn@de.vu	4368	\N	2020-10-24	uD0_ZPTX9HTqdd}E	2024-11-13	active
1438	Marietta Serris	M	2002-12-11	5958589151	mserrispo@gmpg.org	1660	\N	2021-05-14	jW3{A.\\U5q	2024-09-25	active
1439	Erminia Olford	M	1996-05-25	8398100807	eolfordpp@surveymonkey.com	3705	\N	2021-02-18	gJ5?}bR,X	2024-07-12	active
1440	Kerrie Pauleau	M	1990-07-06	7043498724	kpauleaupq@usda.gov	1327	\N	2021-05-26	rK5!V{)refU(g#}	2024-01-09	active
1441	Cleo Fischer	M	1994-12-06	4172597983	cfischerpr@techcrunch.com	19	\N	2021-01-27	yV4_t?Kk`6w7%wm	2024-01-19	active
1442	Christophorus Giocannoni	F	1999-02-21	9445075271	cgiocannonips@cam.ac.uk	858	\N	2020-11-20	eU2*{W+FZ1mhm	2024-10-10	active
1443	Mil Grassin	F	1994-10-17	1774730905	mgrassinpt@dot.gov	1278	\N	2020-04-27	zI1|K(9j/9W*L	2024-06-04	active
1444	Cody Symons	M	2002-04-25	4854275805	csymonspu@symantec.com	3916	\N	2022-10-06	uH2)>T_@6M	2024-09-10	active
1445	Bucky McCrackan	F	1986-09-10	6959040687	bmccrackanpv@state.tx.us	3780	\N	2021-05-05	bZ8<{od{.}ZOk4=	2024-07-28	active
1446	Erena Offin	M	1988-05-23	6506712972	eoffinpw@prlog.org	2798	\N	2022-08-09	kM2}K()zmqh>u	2024-07-30	active
1447	Llywellyn Ortes	M	1995-08-05	1297794481	lortespx@slashdot.org	3497	\N	2020-03-15	vF9\\VV#hFwKA/a	2024-03-29	active
1448	Eudora Prendiville	F	1994-02-10	8542542065	eprendivillepy@imgur.com	4977	\N	2020-09-01	eU6.<f9q1V	2024-09-19	active
1449	Doro Badham	M	1992-07-20	2716876899	dbadhampz@com.com	4796	\N	2020-06-09	aQ4"Lg3IflHf3	2024-09-23	active
1450	Bevvy Mattersley	M	2004-12-20	8983704646	bmattersleyq0@zimbio.com	632	\N	2021-09-03	nP5'RMqP'vs%4Y	2024-08-20	active
1451	Asa Ivamy	F	1994-07-29	8134751169	aivamyq1@usgs.gov	4437	\N	2020-07-26	tI8@ZU~B<iS	2024-09-17	active
1452	Yoshiko Walak	M	1997-12-16	3853187966	ywalakq2@dedecms.com	425	\N	2021-12-20	sH0{,{Q6b0O$ho	2024-12-02	active
1453	Ara Wallett	F	1997-08-08	3901642298	awallettq3@last.fm	4473	\N	2021-06-07	lI4~Rr$!,P>	2024-03-09	active
1454	Gallard Habard	M	2001-10-17	6758208431	ghabardq4@opensource.org	1702	\N	2021-09-24	aP9$e=`<Tuo%,dk%	2024-03-17	active
1455	Lura Ruberry	F	1983-07-30	3508191618	lruberryq5@adobe.com	3085	\N	2020-02-08	oF2"`v)7r/*HBj3	2024-05-11	active
1456	Tadeo Tomasino	M	1982-03-23	4763490179	ttomasinoq6@ask.com	4967	\N	2022-03-13	oA4=<9<Su5090z~	2024-11-13	active
1457	Jinny Blaksland	F	1997-03-11	4781323441	jblakslandq7@privacy.gov.au	3626	\N	2021-03-10	dK4!adduuAp~#	2024-04-05	active
1458	Thorvald Harrower	F	2002-08-11	7652236704	tharrowerq8@people.com.cn	4182	\N	2021-10-18	eF8$Hhcixq	2024-07-21	active
1459	Stanleigh Fores	F	1983-02-21	3006952367	sforesq9@bloglines.com	1146	\N	2020-02-28	jG9=*'66	2024-12-11	active
1460	Mara Digger	M	1999-12-05	8733804875	mdiggerqa@cloudflare.com	794	\N	2020-12-05	lI6<MP"QGsar~p	2024-06-01	active
1461	Henry Dary	M	1988-02-27	3504043384	hdaryqb@addthis.com	2019	\N	2021-09-01	yZ3>ZwJl	2024-11-18	active
1462	Alana MacGilmartin	F	1994-03-18	3087957464	amacgilmartinqc@alibaba.com	1788	\N	2020-08-03	oS5.Wf=\\,x.	2024-08-17	active
1463	Barn Robinson	M	1991-09-05	7349473664	brobinsonqd@addtoany.com	345	\N	2022-01-16	mX2"!n$y*c#A_l=r	2024-09-15	active
1464	Jayme Cammacke	F	1987-12-28	5908675968	jcammackeqe@go.com	4018	\N	2020-01-25	oX7|/!He&I3	2024-01-07	active
1465	Gery Alenichicov	F	1991-10-12	1378757175	galenichicovqf@discuz.net	4005	\N	2021-05-26	yZ8#VgJEv1G8.	2024-06-26	active
1466	Eileen Fullwood	M	1990-07-01	1199057539	efullwoodqg@google.nl	4306	\N	2022-04-14	jO5)G{X$	2024-12-01	active
1467	Carmine Courcey	F	1981-06-13	6013399374	ccourceyqh@auda.org.au	1884	\N	2022-12-10	nC7`O"zSgy	2024-01-13	active
1468	Danika Cheesworth	M	1986-01-01	8482183431	dcheesworthqi@disqus.com	606	\N	2020-12-15	oM8)fTp"GE	2024-06-02	active
1469	Hersch Jozsika	F	1996-08-14	3979854518	hjozsikaqj@theguardian.com	3110	\N	2020-05-02	vF7.8`0_+	2024-03-08	active
1470	Eldredge Tod	M	1998-06-17	5058833602	etodqk@angelfire.com	495	\N	2020-12-05	bO4)~jEE#myT#q/	2024-06-18	active
1471	Robin Lamers	M	1992-06-09	4985013157	rlamersql@blogspot.com	724	\N	2021-02-24	pR6?U7Dpvdz	2024-12-01	active
1472	Sarita Voak	M	1988-06-22	7592432424	svoakqm@icq.com	3157	\N	2022-01-30	aF0)6QoK	2024-06-01	active
1473	Corrinne Kyte	F	2003-03-06	6447023512	ckyteqn@wikipedia.org	2344	\N	2020-06-05	mL1&SruK,	2024-10-02	active
1474	Cynde Loades	M	1999-07-09	4401840134	cloadesqo@chron.com	2856	\N	2022-10-22	eJ4*9~!<$cT#&vd	2024-12-12	active
1475	Selie Wanderschek	F	1984-07-04	1733600907	swanderschekqp@tmall.com	3790	\N	2022-08-01	wU3%B/bT!7	2024-06-25	active
1476	Colette Catherine	F	1996-01-10	1816059515	ccatherineqq@cam.ac.uk	4306	\N	2022-05-19	dV0+V7d}/Pr,O|Gv	2024-05-14	active
1477	Nessa Klamman	M	2001-12-07	6052120908	nklammanqr@fotki.com	319	\N	2020-05-27	sO3|PjKKU8	2024-06-17	active
1478	Adolphus Shubotham	F	1996-08-27	4883395024	ashubothamqs@foxnews.com	1288	\N	2021-12-04	gF2=#DH5<?v	2024-06-22	active
1479	Friedrich Tring	F	1980-02-05	2924201604	ftringqt@slideshare.net	1569	\N	2021-05-09	oE9,P'ms	2024-12-17	active
1480	Mattie Gepheart	F	2004-07-24	4042007333	mgepheartqu@wufoo.com	3936	\N	2022-10-05	wN8<JCGp2"Ri	2024-02-07	active
1481	Ilaire MacGlory	M	1986-04-10	7971842622	imacgloryqv@dyndns.org	1236	\N	2021-02-02	tH2'rb=T8t/jH5?0	2024-04-14	active
1482	Johnna Chatres	F	1994-03-31	9723493066	jchatresqw@twitpic.com	835	\N	2021-05-18	vP2\\QE)EbrpfP>9@	2024-02-28	active
1483	Verina McGlaud	M	1985-04-08	2478898885	vmcglaudqx@msu.edu	4120	\N	2022-12-06	cH0?WN|NZX373<'	2024-09-21	active
1484	Jena Friday	F	2003-06-25	5165329783	jfridayqy@skype.com	4786	\N	2020-10-14	zM4@|g$?qB0+zB	2024-12-07	active
1485	Lindi Arblaster	M	1993-08-17	2588836177	larblasterqz@usa.gov	242	\N	2022-03-07	hG0,UR@=J`my7A	2024-09-11	active
1486	Abbey Hanhard	M	1982-08-22	9878349628	ahanhardr0@feedburner.com	3842	\N	2020-09-08	tH1}D)o$)@PvLDE	2024-02-15	active
1487	Harrietta Pittle	M	1982-11-19	5745224838	hpittler1@accuweather.com	3612	\N	2021-04-27	nK2`X@@oT'Q	2024-08-18	active
1488	Phyllys Lindro	M	2004-06-14	7253695205	plindror2@mediafire.com	3299	\N	2020-12-19	eW6$s0ct'6!3du3	2024-10-16	active
1489	Fanchon Baribal	M	1988-08-04	6121787012	fbaribalr3@ucoz.com	1918	\N	2020-05-23	zD4,6`_i	2024-12-25	active
1490	Modesty Bener	M	1990-05-14	5819669470	mbenerr4@timesonline.co.uk	1711	\N	2020-10-02	iJ3$5u3ig>N1Fuv	2024-08-30	active
1491	Dody Hellwich	F	2003-03-28	7307007369	dhellwichr5@istockphoto.com	953	\N	2020-07-19	fA6*awLw}BI_dt	2024-01-18	active
1492	Teriann Preston	M	1985-10-24	1204041012	tprestonr6@amazon.com	2189	\N	2022-07-16	bL7!mV+!<`kd	2024-05-23	active
1493	Rocky Calway	F	1983-10-20	3182258053	rcalwayr7@disqus.com	2704	\N	2022-02-02	lA0|vecv6	2024-03-09	active
1494	Anne-marie Gammel	F	1989-12-25	2756582227	agammelr8@chron.com	2710	\N	2020-05-05	jH9`S(B5vB$	2024-04-17	active
1495	Rhea Sinnock	M	1986-01-27	6444382549	rsinnockr9@cdc.gov	1507	\N	2022-10-26	cO8|wvKu!)pfz	2024-05-23	active
1496	Sherrie Pabel	F	1985-02-10	8308800847	spabelra@google.co.uk	183	\N	2021-12-11	jO9?9tN"	2024-12-13	active
1497	Orelle Ayris	F	1988-06-06	1651957276	oayrisrb@un.org	3694	\N	2020-12-13	cV8|3eYoT"NVOW.(	2024-05-15	active
1498	Norma Voyce	M	1995-05-17	2574182910	nvoycerc@sciencedirect.com	3995	\N	2020-03-18	yP2'Y(0Ne	2024-03-12	active
1499	Oliver Jealous	F	1983-12-01	7585598488	ojealousrd@spotify.com	2565	\N	2022-02-07	xB7>Qs(5	2024-09-20	active
1500	Nikolaus Pengilley	F	1992-10-30	7037013940	npengilleyre@walmart.com	396	\N	2022-06-25	nG6=(!IAad/#gS}3	2024-05-27	active
1501	Hanna Stolte	F	2004-05-15	4046215403	hstolterf@microsoft.com	1275	\N	2020-02-07	sW2(9}81\\	2024-08-11	active
1502	Cyb Parlor	F	1997-11-22	4401890721	cparlorrg@comsenz.com	3977	\N	2020-03-21	hV5"1Y?`\\	2024-04-26	active
1503	Rowe Stoad	M	1997-07-30	5867170975	rstoadrh@github.com	2017	\N	2021-12-31	iG3>hEeM{F5	2024-02-09	active
1504	Delainey Bompas	M	1983-08-10	4397255412	dbompasri@stumbleupon.com	1513	\N	2021-01-12	vO8/MLq|	2024-07-19	active
1505	Emmy Emes	M	1983-11-19	7387801622	eemesrj@paypal.com	4345	\N	2021-03-23	sR3+h+/Q	2024-02-20	active
1506	Darell Fairbrass	F	1988-08-22	6717772756	dfairbrassrk@sciencedaily.com	671	\N	2021-07-01	fQ2"<U%M6ar	2024-02-24	active
1507	Carmela Blewitt	M	1996-09-01	1022289178	cblewittrl@independent.co.uk	1438	\N	2022-03-21	cT1'Mi)5	2024-01-20	active
1508	Jack Adamiak	F	1997-04-17	6774341244	jadamiakrm@mapquest.com	2396	\N	2020-11-27	uF2@Co{Rl'MLrOgb	2024-06-06	active
1509	Shani Rhys	M	1994-11-01	2446230072	srhysrn@gmpg.org	668	\N	2022-11-03	nX9@|XS4drn2!	2024-11-02	active
1510	Hilton Sawyer	M	1993-10-06	2747513652	hsawyerro@telegraph.co.uk	2615	\N	2022-12-12	dF9\\O!DUw<q	2024-02-15	active
1511	Boigie Mitcham	F	1980-02-15	3101270195	bmitchamrp@rakuten.co.jp	3762	\N	2021-12-31	uE8?+H4<ACo<H,hL	2024-10-07	active
1512	Jarrad Bauduin	M	1989-01-21	3021944893	jbauduinrq@dailymotion.com	2030	\N	2022-01-10	pS2?blF9h+eh60u	2024-06-28	active
1513	Judon Gother	F	1985-08-21	9744661179	jgotherrr@microsoft.com	4592	\N	2021-11-27	kA4|?mypk#0	2024-03-19	active
\.


--
-- Data for Name: customer_order; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.customer_order (order_id, customer_id, employee_id, delivered_at, total_amount, payment_method, order_status, note, payment_status, shipping_address) FROM stdin;
1	1	2	2025-06-01 21:29:40.507785	6400000.00	cash	canceled	\N	refunded	\N
2	2	2	2025-06-01 21:55:09.986117	6400000.00	cash	canceled	\N	unpaid	\N
5	5	3	2025-06-02 06:42:58.246201	0.00	cash	canceled	\N	unpaid	\N
3	5	2	2025-06-02 05:42:45.941878	0.00	card	canceled	\N	refunded	\N
6	5	3	2025-06-02 06:58:55.407764	3200000.00	cash	canceled	\N	refunded	\N
7	8	3	2025-06-02 07:24:47.054879	3200000.00	card	canceled	\N	refunded	\N
\.


--
-- Data for Name: employee; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.employee (employee_id, full_name, role, age, national_id, gender, address, phone, email, salary, password, employment_status) FROM stdin;
1	Alice Johnson	sales_staff	25	ID001	F	123 Main St	0123456789	alice@example.com	20654938.00	alicepass	pending
4	David Kim	sales_staff	40	ID004	M	321 South St	0123456792	david@example.com	19838649.00	davidpass	pending
8	Henry Ford	sales_staff	38	ID008	M	258 Garden Dr	0123456796	henry@example.com	43777492.00	henrypass	pending
9	Ivy Nguyen	sales_staff	27	ID009	F	369 Lake St	0123456797	ivy@example.com	9074251.00	ivypass	active
2	Bob Smith	sales_staff	30	ID002	M	456 First Ave	0123456790	bob@example.com	25232805.00	bobpass	active
7	Grace Lee	sales_staff	29	ID007	F	147 Park Blvd	0123456795	grace@example.com	15310491.00	gracepass	resigned
10	Jack White	sales_staff	31	ID010	M	753 Hill Rd	0123456798	jack@example.com	31586562.00	jackpass	pending
3	Carol Lee	manager	35	ID003	F	789 North Rd	0123456791	carol@example.com	6242429.00	carolpass	active
5	Eva Green	manager	28	ID005	F	654 West St	0123456793	eva@example.com	44320380.00	evapass	active
6	Frank Brown	sales_staff	32	ID006	M	987 East Ave	0123456794	frank@example.com	32182849.00	frankpass	active
11	Tommi Starbeck	manager	31	656344977783	F	Haidershofen, 100	5396393521	tstarbeck0@bluehost.com	23756015.00	eD6,?er)*p	pending
12	Gal Granleese	sales_staff	38	865388598439	M	Hindenburgstraáe 8	1805665687	ggranleese2@home.pl	26979851.00	cD7_34HfO)!)4	pending
13	Manolo Ingman	warehouse_staff	26	886504970067	F	86, Aiolou Str.	7073699805	mingman3@ovh.net	31922056.00	pA8)%iBq?dT	pending
14	Rina Gregorace	manager	23	190206336675	F	Credit Union House, Parnell Street, Thurles,	7253410903	rgregorace4@reverbnation.com	11177338.00	aV7)4acz9@a)J'xL	pending
15	Whitaker Blaxall	manager	37	550212153411	M	PO BOX 289	3081248110	wblaxall5@quantcast.com	20578601.00	kW1,NDtt	pending
16	Elia Josskovitz	warehouse_staff	36	264787030812	F	PO BOX 1377	7634338207	ejosskovitz6@stumbleupon.com	35969836.00	zZ1&~hGHbkwMnk	pending
17	Aidan Gregr	manager	21	693832244172	F	PIAZZA FILIPPO MEDA 4	7871939462	agregr7@google.ca	9977729.00	sM4=X#72rjL	pending
18	Letti Grassi	manager	32	260156001963	M	12 PLACE DES ETATS UNIS	6007711201	lgrassi8@bing.com	20745353.00	jD3/wOS5wb	pending
19	Dalt Cruikshanks	sales_staff	36	387490263540	M	502 W WINDSOR	2029787995	dcruikshanks9@discovery.com	31335915.00	mE5!g#v!QT7Q7o	pending
20	Kristian Lardner	manager	36	748391384524	F	MAC N9301-041	5059165136	klardnera@walmart.com	27858188.00	xF1.EM`9wy'~dIL	pending
193	Vitia Iacobetto	manager	30	428537161279	F	MAC N9301-041	6342222922	viacobetto55@phoca.cz	20859864.00	lE8{GR`%_	pending
21	Brendan Tidmas	manager	24	627086268988	F	99 NORTH STREET	3135420733	btidmasb@disqus.com	14165727.00	sU4*iQj=v>	pending
22	Nolie MacCathay	warehouse_staff	23	137054382065	M	3RD FLOOR	7562028654	nmaccathayc@goodreads.com	32614036.00	eU7.MwYd	pending
23	Belva Garioch	sales_staff	25	087721890512	M	P O BOX 70	1688894619	bgariochd@gizmodo.com	19742998.00	rI8%*ex4Ks_6y	pending
24	Lombard Higginbottam	warehouse_staff	30	556145338256	F	P7-PFSC-03-H	4784708646	lhigginbottame@spiegel.de	36428163.00	zS3#cT|'Kzt#~3w)	pending
25	Rochell Domengue	sales_staff	24	702351007552	M	436 SLATER RD	3543413298	rdomenguef@thetimes.co.uk	41797015.00	mN6{IG~{3YJcfWw	pending
26	Tabitha Hulcoop	sales_staff	32	460930104507	M	P.O. BOX 249	8593536219	thulcooph@deliciousdays.com	36831271.00	nG6\\l*cI	pending
27	Winna MacIlwrick	manager	26	305175540544	M	Hauptstraáe, 34	6901869743	wmacilwricki@yelp.com	6424405.00	jU7,L_u?*DSiv	pending
28	Erminie MacCracken	manager	21	614920210322	F	17555 NORTHEAST SACRAMENTO STREET	8124032360	emaccrackenj@go.com	40310718.00	pL7*.h0?_Zj	pending
29	Maire Trineman	manager	29	631199696729	F	VIA SAN MARCO, 11	1788279703	mtrinemank@comsenz.com	38669548.00	dZ3)`72Gn	pending
30	Grove Rutty	warehouse_staff	26	156890804778	F	203 OKLAHOMA AVE	1201799320	gruttyl@dedecms.com	19910926.00	fD3_d)VZzR6uv|P	pending
31	Lonny Rheam	warehouse_staff	20	479177189023	M	1113 SAXON BLVD	8242568683	lrheamm@intel.com	10402378.00	mC0&L)3VqqMHW%	pending
32	Cale Esmond	sales_staff	30	580366248057	F	P7-PFSC-03-H	4852000569	cesmondn@mayoclinic.com	12540087.00	zJ1{$&H`6	pending
33	Des Brangan	warehouse_staff	30	777268447424	F	Groáe Gallusstraáe 18 (Omniturm)	1595878502	dbrangano@trellian.com	32100268.00	jC4@kohV1pr=tBW	pending
34	Adrian Bynert	warehouse_staff	35	591528103100	M	200 W CONGRESS ST	4463969974	abynertp@earthlink.net	5966149.00	vT1/mWRG%	pending
35	Clayton Wadham	warehouse_staff	38	371619368898	M	320 EAST MAIN	3575382309	cwadhamq@eepurl.com	21995743.00	nO5$HB#<u0$6{v	pending
36	Gabriele Mazzilli	manager	38	342619701575	F	Wiesenau 1	3798555131	gmazzillir@blog.com	49162157.00	kG3#~vj%BxG	pending
37	Astra Clendening	warehouse_staff	24	449086501268	F	14 RUE LOUIS TARDY	7495937191	aclendenings@yelp.com	30655800.00	cE2=7i!38Ud\\g@4W	pending
38	Berthe Pentelo	warehouse_staff	24	526042795676	F	CL DR. BERENGUER, 4	5678610658	bpentelot@xing.com	36321514.00	lG0}FSC~UL?Pj<	pending
39	Delaney Esposi	sales_staff	26	633386092424	F	VIA VITTORIO EMANUELE S.N.C.	4875806820	desposiu@ibm.com	23197961.00	xE8}f_zrJu"Gu9	pending
40	Doro Guichard	warehouse_staff	40	438159856594	M	Hofmark 14	2368336329	dguichardv@xing.com	25300206.00	vO6?mHhTN+o	pending
41	Anet Lavalle	manager	27	070762852260	M	PO DRAWER 789	7257496635	alavallew@163.com	19830673.00	bL1"LibJu26/	pending
42	Kelly McKennan	manager	36	352562209511	F	An der Netter Heide 1	5993384564	kmckennanx@slate.com	40006751.00	gM8=A8(S&M_o"/9	pending
43	Rebecka Slisby	manager	39	562697811880	M	James Finton Lawlor Avenue, Portlaoise,	4218690892	rslisbyy@so-net.ne.jp	10037301.00	tE8">_\\+Oq	pending
44	Lianna Heinzler	warehouse_staff	23	185782142742	M	80 SUGAR CREEK CENTER BLVD	9675118926	lheinzlerz@mayoclinic.com	46701216.00	yC7@7ax\\Y	pending
45	Robinet Sweetman	manager	38	146254566408	F	Donal Casey Place, Rathmore,	8659109769	rsweetman10@pinterest.com	23236000.00	uC7\\q&?6Jfqq	pending
46	Brien Giorgielli	sales_staff	30	803905749821	F	195 MARKET STREET	9412358583	bgiorgielli11@washington.edu	14885607.00	yM7\\b3o&`%HCtiVk	pending
47	Terrell Beazleigh	warehouse_staff	35	791419563870	M	102 BYPASS PLAZA	9643758671	tbeazleigh12@go.com	24920582.00	pW8{$.Q`zVp	pending
48	Aleen Blamphin	manager	31	140562047426	F	PIAZZA FILIPPO MEDA 4	7478604589	ablamphin13@bloglines.com	12024424.00	zQ0"7y~Ew#f>	pending
49	Arnuad Durrant	warehouse_staff	36	656635993989	F	115 RUE DE SEVRES	7456500378	adurrant14@homestead.com	23733269.00	qK0"eGl|r@LdVT	pending
50	Lotti Tabary	warehouse_staff	22	687870035830	M	Konstitucijos pr. 21B	4649411908	ltabary15@tuttocitta.it	27614683.00	qH9)ZDyp)?AL}89	pending
51	Jermain Corradino	manager	25	607482774090	F	111 SYLVAN AVENUE	6397546005	jcorradino16@state.tx.us	21453521.00	vF7\\vLN&2X!k	pending
52	Darryl Weldrick	manager	33	323877073781	M	24 SECOND  AVENUE	9126227365	dweldrick17@soundcloud.com	5192581.00	iR1)djzGy+eO/o	pending
53	Brit Standbridge	manager	29	779384854297	F	5900 LA PLACE COURT  SUITE 200	1897203859	bstandbridge18@craigslist.org	31389786.00	gN2.q5W82gwP!	pending
54	Olav Rawlcliffe	sales_staff	28	369859047771	F	PIAZZA FILIPPO MEDA 4	4246806207	orawlcliffe19@spiegel.de	9645830.00	qE9#\\d|z	pending
55	Adan Renols	manager	21	590803323627	F	814 MAIN STREET	4827249137	arenols1a@gizmodo.com	40871597.00	cT4@<vR&6n,<fX	pending
56	Joscelin Savoury	sales_staff	22	466671795495	M	AVENUE DE KERANGUEN	1317992983	jsavoury1b@reddit.com	20739897.00	dM0,V/?J?	pending
57	Agnola Marl	sales_staff	27	112460237501	F	PIAZZA FILIPPO MEDA 4	1527193820	amarl1c@free.fr	25309199.00	sW0.$r*vNi	pending
58	Prescott Dowthwaite	manager	29	647702607977	F	13220 S BALTIMORE AVE	7719846116	pdowthwaite1d@digg.com	45774961.00	fX4_G0.&Rw7<qS	pending
59	Sheridan Ethelstone	warehouse_staff	35	521038762833	M	Neusiedler Straáe, 33	4995758065	sethelstone1e@dot.gov	26546141.00	rP2&LlCq*yKp#~{	pending
60	Mei Zoren	manager	27	664777550102	F	PO BOX 70	2476666471	mzoren1f@columbia.edu	17123701.00	tD5&y&5NKBx6<N>	pending
61	Lanae Askell	sales_staff	37	195358363065	F	4140 EAST STATE STREET	1755032429	laskell1h@archive.org	29860829.00	xT0&iMNTb{qkEs7~	pending
62	Doralin Seden	manager	26	456503998418	M	P7-PFSC-03-H	3118432106	dseden1i@dot.gov	15619563.00	iJ6!}JQ,C{)z*.~	pending
63	Corette Jellett	warehouse_staff	22	948662766477	M	Platz der Einheit 2	9851343688	cjellett1j@php.net	34321504.00	sL8_oUV<0	pending
64	Iain Pellington	sales_staff	38	996909833912	M	SUITE 5	6891863471	ipellington1k@studiopress.com	27132530.00	uY8{n)a+BkY}	pending
65	Ammamaria Delgua	manager	28	802269035865	M	1620 DODGE STREET	9316339460	adelgua1l@sina.com.cn	19061100.00	rC6'bBYF"W38>	pending
66	Omar Scroyton	sales_staff	21	547011968821	F	110 S FERRALL STREET	9769794211	oscroyton1m@bloomberg.com	37427880.00	xT4})MK}6N6U"	pending
67	Shandra Rendle	manager	29	504094953860	F	8770 TESORO DRIVE	9137006623	srendle1n@indiegogo.com	38851330.00	yV4@|8yL,"P{3g	pending
68	Sibelle Nicely	sales_staff	37	632639135738	F	3RD FLOOR	5333589049	snicely1o@time.com	34613027.00	qP3@vxo{Mu	pending
69	Sibylla Ricardet	sales_staff	23	016483795108	F	PIAZZA FILIPPO MEDA 4	4898089691	sricardet1p@gravatar.com	5659105.00	fL9&?uZBmX,kH2&	pending
70	Aurora Du Plantier	sales_staff	22	205945883684	F	PO BOX 32282	4255684393	adu1q@spiegel.de	21040491.00	nZ8(Y$w.oW	pending
71	Tait Lannin	sales_staff	22	709861514777	F	BASISWG 32	2174045020	tlannin1r@yellowpages.com	13758643.00	bE8+7d#69#i>C?z	pending
72	Katherine Cuddehay	sales_staff	33	770777322921	F	150 ALMADEN BLVD	2143275349	kcuddehay1s@mayoclinic.com	31925097.00	sZ9~UCK_5	pending
73	Bibi Antoniou	warehouse_staff	35	128299455535	F	Ludwigstraáe 52	2194936143	bantoniou1t@latimes.com	23107748.00	eG8&SfM<)	pending
74	Sawyere Genicke	manager	35	013859894804	M	PO BOX 10	2965530549	sgenicke1u@issuu.com	15958233.00	vR0.$cK5PrAH=b/	pending
75	Nancey Tilbrook	manager	24	915993769422	M	7 PROMENADE GERMAINE SABLON	6293376323	ntilbrook1v@acquirethisname.com	21686313.00	rU6@=yziy3y	pending
76	Georgy Gilardone	sales_staff	25	699799672561	M	Neustadt 17	2219713471	ggilardone1w@dedecms.com	39378181.00	gU3>flU7iC	pending
77	Lyda Mcwhinney	warehouse_staff	34	709979378052	M	50 NORTH THIRD ST	9477104431	lmcwhinney1x@seesaa.net	5334368.00	pS4{HnJax0+5!?xT	pending
78	Adlai Robberts	manager	26	656430616693	M	3451 PRESCOTT	3533799605	arobberts1y@baidu.com	27092847.00	pX6}VO{S(AC~%	pending
79	Leodora Hunday	warehouse_staff	28	256931782906	M	R. Alexandre Herculano, 38 - Edif¡cio Quartzo	9159095817	lhunday1z@edublogs.org	9131577.00	zM2`\\WN=\\9sl2	pending
80	Damien Gwilliams	warehouse_staff	36	041917821325	M	M”nchstraáe 24	6963707946	dgwilliams20@ucoz.com	29453349.00	aX8(gGPPR<	pending
81	Tobit Dibbs	warehouse_staff	24	807418037182	M	2910 WEST JACKSON STREET	4741888801	tdibbs21@so-net.ne.jp	27506037.00	xE8~=1HX(wu	pending
82	Val MacCarrane	warehouse_staff	36	719268466548	M	43-45 Dublin Street, Balbriggan	6476031575	vmaccarrane22@hud.gov	10114767.00	wU7?3G)m{/48$POk	pending
83	Janice Cumpton	sales_staff	39	001471781320	M	110 S FERRALL STREET	1006836706	jcumpton23@elegantthemes.com	11287797.00	sL2`!"\\gv9	pending
84	Jereme Dowyer	manager	34	400427549718	M	10 RUE CALLOT CS 90710	9003627167	jdowyer24@ovh.net	27078634.00	fP8<~`kZ@s!x	pending
85	Clement Harwood	manager	28	110787980158	M	PO BOX 7005	3801870962	charwood25@joomla.org	22582948.00	sK5&$o(y<1	pending
86	Norby McManamon	manager	25	174312012723	F	5900 LA PLACE COURT SUITE 200	9867620795	nmcmanamon26@psu.edu	18698642.00	lM1`/~?(6	pending
87	Addi Sone	warehouse_staff	24	564798898065	M	1200 E WARRENVILLE ROAD	1869652530	asone27@home.pl	17226820.00	xX6{KsMQM	pending
88	Christiane Arnaudi	manager	36	168017667085	F	5611 PALMER WAY  SUITE G	7075529845	carnaudi28@unicef.org	11272006.00	iL1}*U@2O&Y	pending
89	Loreen Scurr	warehouse_staff	33	432905276182	M	PO BOX 27025	1571221821	lscurr29@bloomberg.com	39270430.00	zP5'7f+%?.j!	pending
90	Ham Ropert	warehouse_staff	38	696717291304	M	1830 MAIN	3591420601	hropert2a@fotki.com	19745487.00	jW8(SG<MAW1CM	pending
91	Nixie Wyne	warehouse_staff	33	721132475976	M	Hoveniersstraat, 29	6148308364	nwyne2b@nbcnews.com	42224684.00	lO9$yO>z{Lu\\/Z	pending
92	Leena Stallworthy	sales_staff	24	645609741158	M	1401 S 3RD STREET	8703023987	lstallworthy2c@infoseek.co.jp	28708481.00	zZ7<VZqmq)HuO8Yg	pending
93	Cati Crowe	sales_staff	39	579339067064	M	P O BOX 3619	9244500672	ccrowe2d@ifeng.com	21484255.00	lD4+R@x4uuDA!	pending
94	Veradis Crannell	sales_staff	26	835498909694	M	P7-PFSC-03-H	3125218009	vcrannell2e@sina.com.cn	19791162.00	rW8\\p,*gC|	pending
95	Walther Wilmore	warehouse_staff	26	958501677424	F	8001 VILLA PARK DRIVE	9287877098	wwilmore2f@nyu.edu	8806113.00	rH5/g4RrH>	pending
96	Babs Woolmington	manager	22	507254250007	M	PO BOX 431	1469210903	bwoolmington2g@chronoengine.com	26318416.00	pP4@Yyla	pending
97	Phillie Goodsal	warehouse_staff	29	534554262058	M	833 JULIAN AVENUE	2079469620	pgoodsal2h@google.com.au	6193393.00	oB3~X=bg	pending
98	Saundra Doylend	sales_staff	25	890114127240	M	Alleestraáe 2	9966053172	sdoylend2i@amazon.co.jp	26018779.00	mD6#2UR3qok	pending
99	Jewell Robroe	sales_staff	29	824017391324	F	16 BOULEVARD DES ITALIENS	8208254995	jrobroe2j@pcworld.com	36035240.00	bG7$@~sQ46vtV	pending
100	Clare De Pero	manager	31	956513091890	F	Kirchstraáe 2-4	3432595925	cde2k@google.cn	17473276.00	pM7`="%yfe|<d	pending
101	Remy Schruyer	warehouse_staff	34	210294415980	F	PIAZZA FILIPPO MEDA 4	9411221748	rschruyer2l@etsy.com	44168824.00	vV0%1bo_1?	pending
102	Marena Ballantine	sales_staff	27	439190599462	M	6600 PLAZA DRIVE	6196827481	mballantine2m@friendfeed.com	15110204.00	bK5`FV>tD)SLx	pending
103	Cordi Cotsford	manager	35	272060768403	M	P.O. BOX 87003	8561349639	ccotsford2n@admin.ch	17828225.00	mR4{o%Arvn\\Nh|1F	pending
104	Heall Hultberg	sales_staff	25	889237379293	F	EAST PLAZA	4874166587	hhultberg2o@nytimes.com	14990746.00	iA1)>wKbum	pending
105	Julita Lodden	sales_staff	31	959796562342	F	SUITE 5	3462314353	jlodden2p@cdbaby.com	15279957.00	yC1$|82<f	pending
106	Erinna Macvain	manager	23	075453559359	F	4140 EAST STATE STREET	4393536692	emacvain2q@dagondesign.com	25305076.00	yW7}u97Jx|E.zPm|	pending
107	Antonina Moehle	manager	34	576412087349	F	Marktplatz 1	7876524752	amoehle2r@apache.org	45306381.00	mR3{`I4i5+0_Nv$p	pending
108	Hazel Mungane	manager	31	935434536706	F	St.-P‚ray-Straáe 2-4	8279904360	hmungane2s@admin.ch	17555000.00	rH7}aP1u9q/e	pending
109	Emlynn Kohrt	warehouse_staff	32	405627328647	M	SUITE 330	5702552320	ekohrt2t@stanford.edu	35228552.00	eJ7'eE@lI	pending
110	Paulette Wardale	sales_staff	37	055167733023	M	115 E MAIN ST	4033732225	pwardale2u@taobao.com	26459316.00	lY5@eguP0'z	pending
111	Delainey Mithun	warehouse_staff	30	945009347087	F	Dudenstraáe 15	7168522627	dmithun2v@ebay.co.uk	9273259.00	yT2/({UtulN4	pending
112	Sherlock Domerque	warehouse_staff	31	875035540517	M	Evropsk  2690/17	8353817708	sdomerque2w@hubpages.com	41579111.00	hW5=xjE+_I9zp	pending
113	Sherline Foreman	sales_staff	23	247776830931	F	P.O. BOX 10566	5007375542	sforeman2x@histats.com	41718720.00	sQ2\\h8EjrVk%hyS	pending
114	Humphrey Mingauld	sales_staff	22	183473732180	M	Marktstr., 32	8221023003	hmingauld2y@wordpress.com	17398247.00	sJ9%mNu}HCVk	pending
115	Carline Zimmermanns	manager	34	664505224278	M	324 N 4TH STREET	8949412565	czimmermanns2z@sciencedaily.com	15233956.00	iQ6~4C8lH7p	pending
116	Baudoin Giurio	manager	34	084112668205	F	VA2-430-01-01	3337400498	bgiurio30@oakley.com	34822327.00	bN9"/$P3&8gNxq	pending
117	Bidget Hazell	manager	22	955839074563	M	150 ALMADEN BLVD	5628915342	bhazell31@prnewswire.com	44730560.00	tC1}TgoIal	pending
118	Almire Scorey	warehouse_staff	39	302406381498	M	3200 WILSHIRE BLVD	2461138640	ascorey32@bloomberg.com	14878151.00	dQ0!~>C=	pending
119	Orin Wieprecht	warehouse_staff	39	188103281567	M	26 WEST MONROE STREET	9369208466	owieprecht33@aol.com	30823214.00	vD6&><J(	pending
120	Hagen Sherringham	warehouse_staff	27	572476113115	M	TOUR ALLIANZ ONE 1 COURS MICHELET	3289625379	hsherringham34@springer.com	39224351.00	uJ3|Mz6m1+q13	pending
121	Larisa Endecott	sales_staff	30	279463375050	F	111 SYLVAN AVENUE	8046623485	lendecott35@meetup.com	44006047.00	zW8,*jcBCs&(	pending
122	Randell Dackombe	sales_staff	40	199626728078	M	460 SIERRA MADRE VILLA AVE	2609713277	rdackombe36@a8.net	20830338.00	fH4",+UL#F!xu#	pending
123	Querida Ilieve	manager	21	862355288275	M	VIA TURATI, 2	6725249328	qilieve37@hatena.ne.jp	12775139.00	kT7|P_vIj	pending
124	Willdon Barkworth	warehouse_staff	39	923566405543	M	Am Stadtpark, 9	8804827215	wbarkworth38@sciencedirect.com	25871961.00	pL4_u\\BfhY	pending
125	Carleton Ginn	warehouse_staff	25	116028887033	M	400 RELLA BLVD	6341044925	cginn39@google.ru	18543011.00	rY7.L}86|\\AXu	pending
126	Elwyn Bernakiewicz	sales_staff	40	103317203471	M	5900 LA PLACE COURT  SUITE 200	2873405757	ebernakiewicz3a@toplist.cz	20454381.00	bX2%F,uA|Q`@{C~9	pending
127	Prue Silby	sales_staff	38	655439995169	M	CARR. 176 KM 1.3	8965372755	psilby3b@edublogs.org	31374581.00	lZ9}s?L4I`\\sfG?	pending
128	Emily Garrard	manager	37	245256592192	F	PF-PFSC-03-H	5176636129	egarrard3c@mozilla.com	48158933.00	hD5.}V~s~Uds.`	pending
129	Cassy Mawne	sales_staff	32	544576142158	F	VIALE ALTIERO SPINELLI, 30	2019636256	cmawne3d@bizjournals.com	27504963.00	mP6(kp7Bw>RtF	pending
130	Dannel Gurdon	warehouse_staff	40	481911628133	M	44 PUBLIC SQUARE	9452149759	dgurdon3e@earthlink.net	44773778.00	yN3<<hJ.l	pending
131	Jacques Hartil	sales_staff	39	018797325257	F	Maximiliansplatz 12	2543090706	jhartil3f@economist.com	21921009.00	iG0+RH\\OO&O~H	pending
132	Orelie Barendtsen	manager	32	639649582081	M	624 MAIN	9596518252	obarendtsen3g@tamu.edu	18453537.00	eO9>CM0&hz	pending
133	Peria Brownjohn	warehouse_staff	38	912754181523	F	VIALE ALTIERO SPINELLI, 30	9415521665	pbrownjohn3h@t-online.de	28844800.00	bZ0+k_P&s,nY+	pending
134	Daffi Flewan	sales_staff	38	858747986768	F	P.O. BOX 937	3145432484	dflewan3i@soundcloud.com	42652760.00	qJ6~!3o.%n	pending
135	Flemming Bensusan	sales_staff	28	215856226392	F	P O BOX 507	3329285334	fbensusan3j@nifty.com	19509499.00	jC9.x&fFSiY!LyQ}	pending
136	Tybie Imeson	manager	31	820184941074	F	Amtgasse 2	1826102776	timeson3k@wix.com	15868008.00	eY9>MtLZsmM,U	pending
137	Ivonne Graveston	warehouse_staff	28	526768594203	F	Carl-Meinelt-Straáe 10	1095803073	igraveston3l@sbwire.com	39187150.00	fD7,APg&3(!{/Y	pending
138	Gibby Burnsyde	sales_staff	31	146736662318	M	Platz der Republik	9365282076	gburnsyde3m@tiny.cc	44398566.00	qG2}}O)PU+g	pending
139	Sonja Schubart	sales_staff	38	867593425951	F	4140 EAST STATE STREET	4094847526	sschubart3n@goo.ne.jp	45991310.00	sQ5~?9C)v#G'P.eo	pending
140	Chalmers Beekmann	sales_staff	35	511477696671	M	Untertor 9	8389450817	cbeekmann3o@about.me	41948429.00	gK1}eBCtK&xVc4	pending
141	Kirk Drynan	warehouse_staff	22	760329522763	F	AYIAS PARASKEVIS STR 20 STROVOLOS	1854297044	kdrynan3p@posterous.com	43926084.00	wW6%0<H7"t%J)P&.	pending
142	Nessi Gritland	warehouse_staff	28	219015820778	F	6, Patriarchou Ioakim and Karapanou Str.	9124002152	ngritland3q@wsj.com	30292929.00	hF4`*{9skLJbqR&	pending
143	Ring Soitoux	manager	20	807926129726	F	12 PLACE DES ETATS UNIS	5127785267	rsoitoux3r@webmd.com	36452460.00	oY7)EbDJb1Q@b`|`	pending
144	Mattie Van Baaren	warehouse_staff	37	127615856648	F	460 SIERRA MADRE VILLA AVE	1924014993	mvan3s@cloudflare.com	8574527.00	lB1|z32C	pending
145	Price Brislawn	warehouse_staff	25	451978917736	F	CORSO GARIBALDI, 49/51	6789297220	pbrislawn3t@purevolume.com	6183662.00	kS5/c<Pil	pending
146	Harriet Rumin	sales_staff	27	983969637818	M	110 EAST RACE STREET	2985457909	hrumin3u@canalblog.com	46609210.00	zK6&75K0g	pending
147	Marylou Robillart	sales_staff	39	231576656865	F	Kungstr„dg†rdsgatan 8	3697042824	mrobillart3v@tinyurl.com	30098153.00	mX5\\3mvE6	pending
148	Herbie Gristock	warehouse_staff	28	291339912020	F	Pz de San Nicol s, 4	3288245173	hgristock3w@dagondesign.com	17546327.00	yY2@\\*mka	pending
149	Jasper Edmondson	warehouse_staff	34	451707678845	F	P.O. BOX 4506	6573995640	jedmondson3x@umich.edu	46301658.00	cS0\\*|a@	pending
150	Gay Saturley	sales_staff	29	691929128395	F	Kornmarkt 9	9027482391	gsaturley3y@ameblo.jp	33000709.00	bP4~)l(+K17{	pending
151	Eric Brady	warehouse_staff	40	973145694561	M	ul. Grodzka 3	2647242512	ebrady3z@yelp.com	12812792.00	zN6!iY_yBt	pending
152	Ynes Rottger	sales_staff	40	591498345611	F	200 W CONGRESS ST	9262254164	yrottger40@cafepress.com	20012276.00	fU7)o|IdmD{9QP	pending
153	Ferrell Lorden	sales_staff	37	346628928958	M	Mittelstraáe 54	2674086005	florden41@canalblog.com	36341930.00	jQ0<?_qZ	pending
154	Farrell Kanwell	manager	33	778738201047	F	Braunauer Straáe, 22	5358071555	fkanwell42@imdb.com	13267226.00	gG7"'(4PHg%!3he.	pending
155	Maighdiln Mathan	warehouse_staff	20	794747838217	M	7 PROMENADE GERMAINE SABLON	8275269024	mmathan43@cmu.edu	7745586.00	uX0.x~Is,%	pending
156	Hetty Dibling	warehouse_staff	26	973416205300	F	1 RUE ARNOLD SCHOENBERG	7846321051	hdibling44@sakura.ne.jp	11566985.00	xD8!/M>aek@	pending
157	Dirk Keeffe	sales_staff	38	505491803753	M	235 GRIFFIN ST	3743328800	dkeeffe45@behance.net	46233548.00	oI9%L~)v"d"%l	pending
158	Broddy Mabb	sales_staff	35	006499197183	M	P O BOX 32552	5438603802	bmabb46@weather.com	9909402.00	uS4#{Bbyz0Sto=	pending
159	Cyril Vallance	manager	24	889366252135	F	VIALE ALTIERO SPINELLI, 30	7988096927	cvallance47@wunderground.com	34827021.00	vM8?94Y7Z)Ct~L?	pending
160	Shayna Eatherton	warehouse_staff	34	757802811243	F	P.O. BOX 111	4139481663	seatherton48@va.gov	27230410.00	aY9@3)uB|ux@T50	pending
161	Gloriana Dorbin	manager	33	467929996211	M	Ps de la Castellana 29	7363321586	gdorbin49@nytimes.com	10831514.00	mS1=K/R_+J~eVx	pending
162	Umberto Risborough	manager	38	047429516250	M	Schillerplatz 6	3104703518	urisborough4a@liveinternet.ru	48014369.00	rN6$yg&c1o0v~EB	pending
163	Shelia How	sales_staff	26	823727203216	M	SUITE 823	7187770351	show4b@smh.com.au	49914651.00	pS2,*~"s,q@v!Q	pending
164	Freemon Weldrake	warehouse_staff	37	994820423682	F	PIAZZA FILIPPO MEDA 4	8553888898	fweldrake4c@quantcast.com	26783099.00	rE6+?M)tdiK`"YW	pending
165	Kelsey Claus	manager	29	779787125884	M	VIA DELL'AGRICOLTURA, 1	2674391021	kclaus4d@linkedin.com	7853121.00	pY0(n7Qs9M	pending
166	North Crich	manager	23	407130158925	F	3451 PRESCOTT	9255960905	ncrich4e@shareasale.com	45471308.00	gG1)+YX#`h.c	pending
167	Porty Simmen	manager	40	479622221103	F	Wiesenau 1	6443409334	psimmen4f@bigcartel.com	12533639.00	wS3>x6{+MEG2	pending
168	Atlanta Janning	warehouse_staff	40	674025322232	M	7 PROMENADE GERMAINE SABLON	8966561098	ajanning4g@deviantart.com	16985177.00	mD4.wmaOB,uTUVU	pending
169	Freedman Eaddy	warehouse_staff	28	859990613713	F	5820 82ND STREET	2945537035	feaddy4h@spiegel.de	26949317.00	kL9=ibPp%=7	pending
170	Vitoria Babcock	warehouse_staff	21	493733874642	F	Depenau 2	1848184789	vbabcock4i@oakley.com	35223076.00	sY8{,Q~Z5vO	pending
171	Raymund Danit	manager	22	160874559454	F	5050 KINGSLEY DRIVE	8406324476	rdanit4j@fastcompany.com	30164378.00	bD6+83I\\`,S<o	pending
172	Meredithe McBrady	manager	27	112029839531	F	Pfauengasse 1	4719176681	mmcbrady4k@cargocollective.com	36677777.00	yK1~=uECEF$2+0	pending
173	Emelina Charnley	manager	31	059173272137	F	Bahnhofstraáe 11	8726693652	echarnley4l@t-online.de	27552913.00	tP1)0mu81r`(L"	pending
174	Moyna Beekmann	warehouse_staff	21	392311877625	M	SYNERGIE PARK 6 RUE NICOLAS APPERT	7966633479	mbeekmann4m@theglobeandmail.com	13032407.00	eX8=$4HD	pending
175	Karim FitzGilbert	sales_staff	37	192014757326	M	1905 STEWART AVE	6881640109	kfitzgilbert4n@feedburner.com	43518237.00	hY6~oF4uC@L	pending
176	Carine Boulder	manager	33	048404517723	M	PIAZZA FILIPPO MEDA 4	2693646856	cboulder4o@canalblog.com	48242278.00	bF1)M9dH95f	pending
177	Xenia Mawson	manager	28	185525067243	F	4140 EAST STATE STREET	4787108276	xmawson4p@europa.eu	26762389.00	hV4`1*9iVYS	pending
178	Vicki Riatt	manager	27	057459711585	F	P.O. BOX 1009	8281498880	vriatt4q@ameblo.jp	12420631.00	vG6,QmC6#}fCblay	pending
179	Catrina Fishley	warehouse_staff	39	306442631381	M	Ludwig-Weimar-Gasse 5	8984613121	cfishley4r@zimbio.com	28493544.00	vJ5>aBKRaVfKi@)	pending
180	Dominik Chattaway	sales_staff	22	099284883009	M	117 W 1ST STREET	1246167437	dchattaway4s@ox.ac.uk	33244392.00	aT6#g'TO{E2OrY	pending
181	Staffard Broderick	manager	25	390791537872	M	16 BOULEVARD DES ITALIENS	6258966230	sbroderick4t@nbcnews.com	32200262.00	xU9"0_q<d	pending
182	Cornall Meeson	warehouse_staff	28	829176230928	M	PIAZZA FILIPPO MEDA 4	7223489081	cmeeson4u@woothemes.com	33326492.00	lA6?*o>mTI*L5	pending
183	Selle Yankishin	manager	38	351132996164	F	Bijlmerdreefÿ106	2834211101	syankishin4v@aboutads.info	24178759.00	tF5%Zc2%A	pending
184	Georgi Provis	sales_staff	23	041535595120	M	PIAZZA FANTI, 17	3051515543	gprovis4w@diigo.com	20363151.00	jQ4*7\\Y<	pending
185	Idette Herculson	warehouse_staff	38	392467516927	F	PIAZZA FILIPPO MEDA 4	2803658412	iherculson4x@sciencedaily.com	24993657.00	qQ8>h7"JuiiSa?	pending
186	Moss Petranek	sales_staff	31	518251872977	M	Lange Straáe 74	1378301351	mpetranek4y@slashdot.org	17523605.00	fZ8<.O~T7	pending
187	Dall Schultes	sales_staff	30	978851296274	F	P.O. BOX 1377	3764510394	dschultes4z@phoca.cz	47934136.00	mZ1@Hhn~\\mWG	pending
188	Jacinta Winsor	sales_staff	34	877134187758	F	Kungstr„dg†rdsgatan 20	9757851708	jwinsor50@google.ca	45899961.00	fN0?p/?D(G8<Y	pending
189	Dusty Grainge	warehouse_staff	38	232919754031	M	436 SLATER RD	9375398172	dgrainge51@usatoday.com	17667394.00	rO9.X*H%"ES	pending
190	Gleda Kilbane	manager	38	668804822886	F	ACH OPERATIONS 100-99-04-10	8826817126	gkilbane52@hatena.ne.jp	36973030.00	dI6@)O<0Pp	pending
191	Finlay Fink	manager	34	625958319772	F	MAC N9301-041	2637971853	ffink53@wikispaces.com	12165006.00	pM0'EKege03Qy0	pending
192	Moore Bushell	warehouse_staff	37	039963717795	F	ONE COMMUNITY PLACE	3136853709	mbushell54@mapquest.com	35609665.00	eT8}7p8SM"r	pending
194	Cully Walmsley	sales_staff	38	449997261223	M	SECOND FLOOR	7789434541	cwalmsley56@timesonline.co.uk	9680632.00	nW5\\7w_)Nl	pending
195	Sheridan Klaaassen	sales_staff	31	664046012515	F	24010 PARTNERSHIP BOULEVARD	6807322791	sklaaassen57@twitter.com	49128295.00	vC2&2t<Tj	pending
196	Ellene Lejeune	warehouse_staff	28	954991116164	M	201 N. WASHINGTON ST.	2409985198	elejeune58@chronoengine.com	15856402.00	fF3,OGg$%clo8rt	pending
197	Jud Lucian	manager	22	833292177172	F	3RD FLOOR	2109174540	jlucian59@archive.org	9958942.00	wR1_b`~_9Xx>p	pending
198	Gussie Humberstone	manager	28	414414575625	F	18 RUE SALVADOR ALLENDE CS 50307	3322530959	ghumberstone5a@flavors.me	41425236.00	pT9(3"dd"`	pending
199	Tad MacAndie	manager	23	531254818835	F	17555 NORTHEAST SACRAMENTO STREET	2916166121	tmacandie5b@canalblog.com	26872824.00	pR7!2?vu>4	pending
200	Eduino Blanchflower	manager	28	065251720221	M	1 AVENUE DE LA LIBERATION	9773304363	eblanchflower5c@princeton.edu	34902013.00	lJ4~uc|z17NqV	pending
201	Grethel Raeside	warehouse_staff	31	998864098704	F	2, Boulevard de la Foire	1711921849	graeside5d@accuweather.com	27315202.00	mY5+4MuV	pending
202	Alexander Laird-Craig	sales_staff	39	473280283720	F	Cl Pintor Sorolla 2-4	5386030629	alairdcraig5e@imageshack.us	29485698.00	oZ6|D!l(Js	pending
203	Giordano Tapton	warehouse_staff	35	725055354971	M	PO BOX 30886	8133587900	gtapton5f@chronoengine.com	8456013.00	wF1/a1D!!}B$Jc+	pending
204	Berty Thomas	sales_staff	24	438238735092	F	R. Alexandre Herculano, 38 - Edif¡cio Quartzo	6868065481	bthomas5g@chicagotribune.com	48253877.00	dU4{EG&KSI0uLaK8	pending
205	Mellisent Peplay	sales_staff	35	143956236229	F	16 BOULEVARD DES ITALIENS	7267377552	mpeplay5h@umn.edu	8766977.00	kK5{`Eos	pending
206	Damon Pelfer	sales_staff	20	704961070628	F	Kleiner Markt	5976852475	dpelfer5i@a8.net	37163335.00	bE8,W+<TsPaH	pending
207	Merrielle Filipputti	warehouse_staff	29	698747027040	F	Hauptstraáe, 9	5427577500	mfilipputti5j@mapy.cz	14255898.00	qZ6}Wn,!f!	pending
208	Nellie Baistow	warehouse_staff	29	625436572118	M	Komturhof 2	3937782376	nbaistow5k@umn.edu	10357694.00	yV8*@bW*eogr84"	pending
209	Nevile Davidsohn	warehouse_staff	20	198860892118	M	P7-PFSC-03-H	3658538239	ndavidsohn5l@buzzfeed.com	39273885.00	hR5}rHS)mD"wj	pending
210	Amble Dare	manager	23	255719234757	F	PIAZZA FILIPPO MEDA 4	2229645879	adare5m@devhub.com	17415474.00	tP6&i4@x+xv?K	pending
211	Garrot Heinke	warehouse_staff	40	756404938484	M	P.O. BOX 1037	5911166988	gheinke5n@cdbaby.com	7923779.00	tN8@Q/e}U	pending
212	Scarface Chiddy	manager	30	271173467070	F	Cl Pintor Sorolla 2-4	8473812979	schiddy5o@aboutads.info	37274001.00	lC6!Bo6Zar3	pending
213	Jess Heining	warehouse_staff	25	072765724014	M	VIA GIUSEPPE MAZZINI, 52	6201832865	jheining5p@sphinn.com	7665152.00	bO3+hGa.`yDifJ	pending
214	Nyssa Fransoni	sales_staff	27	570103754322	M	Karspeldreefÿ6 A	9908284625	nfransoni5q@homestead.com	30361952.00	oP9?M00r2OU9YUE{	pending
215	Pinchas Stickins	warehouse_staff	27	228663881499	F	MAC N9301-041	2861225787	pstickins5r@about.com	38859410.00	oT7$),md4	pending
216	Irma D'Alesio	manager	29	165812433664	M	Hauptstraáe 68	3141963012	idalesio5s@google.ru	45231420.00	lU9~*fRU	pending
217	Kain Bardill	manager	35	789259668931	F	Taunusanlage 12	6617701130	kbardill5t@hostgator.com	36682412.00	jO7#lCRf2cCZ	pending
218	Whittaker Gaynesford	sales_staff	30	288848486374	M	1200 E WARRENVILLE RD	4341504899	wgaynesford5u@slideshare.net	36538887.00	uM0?_)#XA8a#y	pending
219	Mervin Pert	manager	23	117346351430	M	4140 EAST STATE STREET	3384919866	mpert5v@webmd.com	35500088.00	gG3{10.~	pending
220	Pippo Boyles	warehouse_staff	29	977992347894	M	Convent Lane, Mohill,	1352527413	pboyles5w@boston.com	22973916.00	aI5_7|$?"	pending
221	Laural McKernon	manager	22	811178174773	F	Ukmerges g. 223-4	5317749406	lmckernon5x@flavors.me	49836484.00	nO7%|9I`	pending
222	Dew Wesker	sales_staff	40	240903680779	M	Point Road, Crosshaven,	4654090476	dwesker5y@amazonaws.com	41859037.00	kS1<W6sy7	pending
223	Gusta Alliker	manager	38	057606175461	M	3731 WILSHIRE BLVD STE 1000	1262619367	galliker5z@apache.org	34005891.00	rP1\\=r1Z%Ttvt	pending
224	Quintus Jans	warehouse_staff	35	441989199654	M	Bahnhofstraáe 20	6629918940	qjans60@dailymotion.com	35749211.00	iM3)gH=.	pending
225	Happy Branca	manager	31	802518362241	F	Winkeler Straáe 64a	8748425876	hbranca61@webs.com	37819527.00	dH2!$+>w+0	pending
226	Humbert Neaverson	sales_staff	27	470518089651	M	PO BOX 30	9456001786	hneaverson62@t-online.de	9235519.00	cB7.WKl3W>	pending
227	Earlie Arangy	warehouse_staff	35	162119669939	M	EAST PLAZA	9107061471	earangy63@github.io	30471021.00	qX2)6U4e6pHOZz'x	pending
228	Lindsay Margetts	warehouse_staff	26	896089726678	M	Bd. Ion Mihalache nr.1-7, sector 1	9871296855	lmargetts64@tiny.cc	5512946.00	kS5`Ts,1U.J	pending
229	Dorothee Wadly	warehouse_staff	36	892150463925	F	NY-31-17-0119	2174144801	dwadly65@google.nl	22015380.00	yX5|Q!suYlj=\\4	pending
230	Nicoline Lloyds	warehouse_staff	32	150981701022	F	Main Street, Roscrea,	1552861450	nlloyds66@typepad.com	28328840.00	kO8"~1L"S?6kog	pending
231	Germayne Tillman	warehouse_staff	30	245335798286	M	245 BELGRADE AVE	5841959773	gtillman67@tinyurl.com	13472589.00	aY1%_)tINs(x)D(	pending
232	Raine Anelay	warehouse_staff	32	016721350993	M	CITE DE L AGRICULTURE CHEMIN DE LA BRETEQUE	7985611063	ranelay68@gravatar.com	21300441.00	hW5&kR'I	pending
233	Matteo Piwall	manager	25	337844505879	M	P.O. BOX 85139	2583655611	mpiwall69@blogger.com	26264478.00	uS0`4Y)gh!mj\\@b	pending
234	Johannes Dudmesh	sales_staff	34	475561951343	M	Kurtalstraáe 2	2016600991	jdudmesh6a@ft.com	48222247.00	rW4%|<Vn~9k*8,f	pending
235	Mata Goggins	manager	25	732214676292	F	900 BROAD STREET	7779157066	mgoggins6b@patch.com	9571109.00	pJ9>$\\~`kT	pending
236	Lina Bubbins	manager	35	298887509611	M	Raiffeisenstraáe 8	8577567776	lbubbins6c@goo.gl	35642068.00	rZ6/=PJy32	pending
237	Laina Saull	warehouse_staff	37	486500482609	F	333 E MAIN STREET	3758760679	lsaull6d@google.com.au	13457783.00	wN7+pwS(k	pending
238	Paton Perigeaux	manager	38	490250036356	F	PIAZZA FILIPPO MEDA 4	6141403094	pperigeaux6e@wired.com	9714478.00	mB0$q4zk'JXP	pending
239	Brennen Newlove	sales_staff	33	146104239514	M	Depenau 2	8212266699	bnewlove6f@goodreads.com	30256578.00	zL7!Q1,id>l2Z1m=	pending
240	Stafani Metzig	warehouse_staff	28	889792224310	F	PIAZZA FILIPPO MEDA 4	2651534240	smetzig6g@yellowpages.com	33457374.00	jF7\\ZYa_	pending
241	Haley Strattan	manager	29	897326824224	M	P O BOX 681	5724827439	hstrattan6h@google.pl	20383810.00	nC0+6qO!zm5c"*	pending
242	Mead Feely	manager	29	561351211339	F	833 JULIAN AVENUE	7184145401	mfeely6i@rediff.com	5245929.00	jA7?~<\\~	pending
243	Sidonnie Kiley	sales_staff	30	408991307454	F	P7-PFSC-03-H	6033323471	skiley6j@ameblo.jp	44945123.00	tR6_K?GbMi!lZ	pending
244	Hoebart Rand	manager	25	447038163633	F	Meerg„ssle 1	1079810580	hrand6k@telegraph.co.uk	20341882.00	uS2"6oqb	pending
245	Jobey Baccup	sales_staff	30	825286310888	M	1008 OAK STREET	6051803179	jbaccup6l@mit.edu	42099813.00	bP0~udYI9~d%@)K	pending
246	Ninetta Cubbino	manager	29	592615992894	M	1 CITIZENS DRIVE ROP440	8839167390	ncubbino6n@discuz.net	23083172.00	kQ1>rU&nt`r	pending
247	Inger Gissing	sales_staff	36	128038177471	F	Schupstraat, 18-20	8684435975	igissing6o@nydailynews.com	29240548.00	xO6{l~DuWMrBoloe	pending
248	Brynna Steer	manager	21	376378702839	F	P.O. BOX 27025	5456704642	bsteer6p@creativecommons.org	33128422.00	wY3{T>wX	pending
249	Forster Houseman	manager	39	992288060341	M	255 2ND AVENUE SOUTH  MAC N9301-041	5242790199	fhouseman6q@xing.com	19169601.00	sQ5+0UZ2@C$\\Bp	pending
250	Lionel aManger	manager	37	494152735470	M	9300 FLAIR DRIVE, 4TH FLOOR	7362397903	lamanger6r@ihg.com	42099338.00	wO4`d$pk(\\V#$	pending
251	Charmion Esslement	manager	30	832373428744	M	18 Drumcondra Road Upper, Drumcondra	4224543307	cesslement6s@hc360.com	14717077.00	fT2==UZk,	pending
252	Delainey Calton	manager	29	172821699425	F	PO BOX 870	6845974878	dcalton6t@goo.gl	9690791.00	vG1,yRY?=)VD<	pending
253	Rodge Mycock	warehouse_staff	33	020373118956	F	Neue Mainzer Straáe 75	1627579431	rmycock6u@disqus.com	25717470.00	kI6\\/s!q1%T{=rC	pending
254	Gideon Brecon	manager	39	666635716067	M	R k¢czi £t 70-72.	1311093257	gbrecon6v@go.com	25716537.00	bY0"L"=0Vf=l	pending
255	Marney Vandenhoff	warehouse_staff	29	237597990334	F	PIAZZA FILIPPO MEDA 4	8854270890	mvandenhoff6w@tmall.com	43980136.00	gZ9)9m$K	pending
256	Levi Emanueli	warehouse_staff	32	932753113221	M	MAC N9301-041	7024975905	lemanueli6x@addthis.com	36464515.00	iB5"NNn?X	pending
257	Dulsea Vallis	warehouse_staff	26	917892911928	F	200 W CONGRESS STREET	4556170916	dvallis6y@netscape.com	27000277.00	aE4>U.1&`0Fv%G	pending
258	Jeane Gresser	sales_staff	32	935332194294	M	Vodickova 701/34	3613856393	jgresser6z@wikimedia.org	24384894.00	wF9<6O!&>I.,r<<	pending
259	Kassie Lain	manager	20	037534218435	M	110 EAST RACE STREET	3749114902	klain70@addthis.com	6281590.00	fU9!rN1L#r.Eg(\\%	pending
260	Cyrillus Klesl	manager	22	173865137667	M	Stadtforum, 1	5418835398	cklesl71@intel.com	39633295.00	sQ4\\5"l>	pending
261	Vernor Gretton	sales_staff	26	873307590106	F	502 W WINDSOR	3383273277	vgretton72@gravatar.com	6963162.00	jO9?ke1i9Hk"y	pending
262	Lisha Handrik	manager	37	750990282549	M	80 SUGAR CREEK CENTER BLVD	5525787376	lhandrik73@reverbnation.com	10682635.00	pJ4<AToN	pending
263	Tamma Gribben	manager	22	595173874317	F	Seestraáe, 1	5897920980	tgribben74@youku.com	45028966.00	yE1%!!IK	pending
264	Jsandye Marchand	manager	30	004049650749	F	PIAZZA FILIPPO MEDA 4	6699521813	jmarchand75@narod.ru	22387249.00	pV2~p*YgUC#	pending
265	Bibbye Harkus	warehouse_staff	26	275539658803	M	717 WAYNE ST	2605868882	bharkus76@yelp.com	46500680.00	lI6!R>Zr1ilB6OTd	pending
266	Ellissa Slora	manager	30	850641071356	M	CORSO DELLA REPUBBLICA, 126	1843436257	eslora77@livejournal.com	43695643.00	sQ0_j`KRy	pending
267	Florencia Shoebotham	warehouse_staff	28	995195969181	F	214 S 1ST ST	8712213173	fshoebotham78@ftc.gov	17496575.00	gO4,0/j{J'Kl7	pending
268	Granny Feild	warehouse_staff	27	123727671364	M	Rathausplatz 2	8878373531	gfeild79@google.es	25353581.00	kP2`KL$NAD	pending
269	Haze Wiersma	warehouse_staff	40	413331748085	F	MAC N9301-041	8746543879	hwiersma7c@thetimes.co.uk	27501650.00	dF5)m,)ah`t'j	pending
270	Jenny Shinn	warehouse_staff	40	966440457004	M	PO BOX 2508	6102094948	jshinn7d@biblegateway.com	42479018.00	mQ9"w`ncdYRQ5	pending
271	Roosevelt Buscombe	warehouse_staff	28	034621847015	F	Sparkassenplatz 1	9011687429	rbuscombe7e@timesonline.co.uk	35153712.00	mZ3)&"h)_2	pending
272	Chic Fere	warehouse_staff	40	687101923669	F	Darmst„dter Straáe 62	9366747423	cfere7f@stanford.edu	49762060.00	fC7{&2?yO	pending
273	Robena Lamborne	sales_staff	36	247498722805	M	1927 GREENSBURG CROSSING	4455411950	rlamborne7g@imageshack.us	44546109.00	qM2*P!cvb=sygGNR	pending
274	Keelia Slaight	warehouse_staff	29	341454053256	M	100 SOUTH MAIN	6382454833	kslaight7h@shop-pro.jp	17371951.00	mV1'J1FR5f!`8#L	pending
275	Jaquith Knudsen	warehouse_staff	38	668740952527	M	140, boulevard de la P‚trusse	1371534091	jknudsen7i@cpanel.net	22400415.00	bY7#Fua?	pending
276	Phillipp Pechold	sales_staff	28	576686026875	F	1800 WASHINTON AVENUE	5348889703	ppechold7j@g.co	19963273.00	uP8?jmw_	pending
277	Kynthia Yosifov	warehouse_staff	33	706168850882	F	ACH OPERATIONS 100-99-04-10	1141848421	kyosifov7k@over-blog.com	29856893.00	tF0/Y@9KdISyt}	pending
278	Robbi Klampk	manager	31	925445994961	M	20544 HUSKER DR	7246118668	rklampk7l@berkeley.edu	22303115.00	hW4*U/XC	pending
279	Kathryn Corradetti	sales_staff	29	900090464041	M	EP-MN-WN1A	5131452368	kcorradetti7m@typepad.com	34831917.00	tI7.cI9ZP	pending
280	Helena Menendez	sales_staff	32	510838965637	M	P. O. BOX 677	9382533901	hmenendez7n@miibeian.gov.cn	8317756.00	nE5$z_.{	pending
281	Brocky Bolin	sales_staff	24	818605930488	F	6TH FLOOR	6162777866	bbolin7o@themeforest.net	9465586.00	gJ5>9yuTk@5i.l	pending
282	Adelice MacKey	sales_staff	21	365673454539	F	12345 WEST COLFAX AVENUE	2005952769	amackey7p@delicious.com	24447194.00	pR8\\'6Yyy/6tnN	pending
283	Vonni Macieiczyk	sales_staff	38	264635112513	F	25 GATEWATER ROAD	7509001097	vmacieiczyk7q@sun.com	32650008.00	tZ1"nl3#rD	pending
284	Zabrina Loachhead	sales_staff	20	590890137786	M	245 COMMERCIAL STREET	4511754251	zloachhead7r@reference.com	42320779.00	dR9)%EgA8}X	pending
285	Taite Rous	manager	31	170726409926	M	EP-MN-WN1A	9131971093	trous7s@sina.com.cn	20565152.00	yY9%h~C}25)A	pending
286	Janelle Brydson	manager	36	277029642035	M	PO BOX 27025	5986752616	jbrydson7t@dagondesign.com	20709110.00	sE8#BzcIN	pending
287	Annice Blundon	warehouse_staff	20	624405175961	F	304 E MAIN STREET	6227437571	ablundon7u@epa.gov	34050649.00	nD3}."l,3hVGSn"	pending
288	Margalit Grieg	sales_staff	23	154699114548	M	PO BOX 27025	4987994809	mgrieg7v@de.vu	22357516.00	dH7~yUlBZ	pending
289	Idette Cartlidge	warehouse_staff	36	111972712623	F	SUITE 600	5266399477	icartlidge7w@booking.com	22469052.00	bG6<b)d&it,jodr9	pending
290	Nancy Eaklee	sales_staff	22	714563129346	F	P.O. BOX 27025	5132152468	neaklee7x@jimdo.com	33709017.00	yY3"`Lb@|AR@	pending
291	Agace Zanicchelli	warehouse_staff	23	260381375405	M	1850 PEARLAND PARKWAY	5343814976	azanicchelli7y@nba.com	16021346.00	gV5$OxyNY+2gz|vM	pending
292	Nannette Snowdon	sales_staff	34	150963437452	F	Tiroler Straáe, 78	5644749488	nsnowdon7z@rediff.com	30873723.00	iY7`mpqH	pending
293	Dalis Rayworth	warehouse_staff	32	660542437366	F	3200 WILSHIRE BLVD	1278441806	drayworth80@webnode.com	47556542.00	mR8%"T)Hop&k&\\o	pending
294	Ingmar Persse	manager	30	034864260185	F	PIAZZA FILIPPO MEDA 4	7792903787	ipersse81@ning.com	47259672.00	yJ7"rFPdZ?4NB	pending
295	Lishe Richardon	manager	25	538927139112	M	Marktstraáe 31	4924158101	lrichardon82@twitpic.com	37015519.00	iX9{$kJEO	pending
296	Ansel Gouda	manager	35	707479356142	F	101 S. 3RD AVE	4341976332	agouda83@weibo.com	25522077.00	vC9<E&ergO	pending
297	Pavia McEwen	sales_staff	22	549299920281	M	Robert-Daum-Platz 1	9987614910	pmcewen84@privacy.gov.au	12430362.00	iB4${jr3?j#u	pending
298	Lezley Betser	sales_staff	33	476459580285	F	PO BOX 69	5225177347	lbetser85@cnbc.com	35742554.00	lQ4%|0WN*6J!U0'	pending
299	Scott Taylo	warehouse_staff	30	140465865039	F	VIA LUCREZIA ROMANA, 41/47	3388354862	staylo86@tuttocitta.it	26862996.00	vI8?xx`D+(Ws!XV	pending
300	Rozamond Penddreth	warehouse_staff	29	461639615734	M	SUITE 330	5581899596	rpenddreth87@youku.com	8089525.00	qR0,OJ?vNm!	pending
301	Noble Steaning	warehouse_staff	23	187087696387	M	221 THIRD ST	4489158590	nsteaning88@ezinearticles.com	19355875.00	kP4\\O175b	pending
302	Randene Kubacki	warehouse_staff	36	123212177466	M	PO BOX 431	8589352164	rkubacki89@exblog.jp	18401052.00	vJ1*7"VB!i	pending
303	Adriana Duell	sales_staff	27	285873558168	F	PO BOX 547	2671903448	aduell8a@goo.gl	15320401.00	wU6@8`1N	pending
304	Riki Glasper	warehouse_staff	23	137666315867	M	1800 S. GLENSTONE AVE	5611599432	rglasper8b@aboutads.info	5552428.00	vQ1?y'Suw	pending
305	Libbie Mallon	sales_staff	24	861345987960	F	KRYSTALLI 7A	9225236504	lmallon8c@guardian.co.uk	26495373.00	oY5}68YOB(.Jl)t	pending
306	Theodoric Gilders	manager	28	195903187341	F	Raiffeisenplatz, 1	9738519423	tgilders8d@admin.ch	27992229.00	rT9)sA"%Tu~4D?mY	pending
307	Catharine Lakeman	sales_staff	26	997164284040	F	MAC N9301-041	8001239942	clakeman8e@telegraph.co.uk	33600017.00	dX8"Zji3XZDKex	pending
308	Wynn Copplestone	manager	31	499438928108	M	1017 HARRISON	5079557230	wcopplestone8f@icio.us	42625672.00	wH9$dw#H4	pending
309	Monica Strangward	manager	35	418413940660	M	THIRD FLOOR	5732951720	mstrangward8g@google.com	20206818.00	tX9*,%PkSn'm<L,	pending
310	Nolly Gascone	warehouse_staff	24	449526849589	F	P.O. BOX 255	8431847104	ngascone8h@ucoz.com	41121791.00	vP6?t'ntG43Fk'|x	pending
311	Aaron Blackboro	warehouse_staff	24	015214160475	M	Ruhrstraáe 45	9465122795	ablackboro8i@delicious.com	11703824.00	tI2{3!iy+19`|,|z	pending
312	Alaric Petrescu	sales_staff	21	183608767982	F	SUITE 1500	9314138527	apetrescu8j@parallels.com	48198984.00	mS9(pWEIxeRq3lgY	pending
313	Blondell Di Ruggiero	warehouse_staff	29	788329092279	F	600 JAMES S MCDONNELL BLVD	7506520258	bdi8k@51.la	39635289.00	jO2@QUO@j>Wo+n3m	pending
314	Mallorie Houtby	warehouse_staff	23	987096060226	F	Bayernstraáe 9	2028244671	mhoutby8l@reuters.com	10728174.00	gL7?NH8N8"	pending
315	Jemmy Newall	warehouse_staff	35	234822668276	M	Virchowstraáe 23	6627866852	jnewall8m@nba.com	45688737.00	lC2@9+qb*`/e4	pending
316	Brannon Batsford	warehouse_staff	36	352630400760	F	Wildunger Straáe 14	3056255075	bbatsford8n@amazon.co.jp	15538465.00	jO2!@sUBYEz.*\\>	pending
317	Marji Riquet	warehouse_staff	23	143414184201	M	Bahnhofstraáe 3	1793374558	mriquet8o@issuu.com	37844083.00	iL4$J,%Qubt'JFd	pending
318	Waverly MacDuff	warehouse_staff	25	020545763482	M	436 SLATER ROAD	3566674596	wmacduff8p@ameblo.jp	49719899.00	pZ9&{Qx3m=v	pending
319	Dom Nutkin	sales_staff	21	184001903978	M	Oktoberplatz, 1	1359503163	dnutkin8q@wsj.com	23435042.00	kN5!ZszKzt	pending
320	L;urette Mole	manager	24	005302486351	F	69 AVENUE DE FLANDRE	2563093800	lmole8r@barnesandnoble.com	38061859.00	xI0&5G?wg|y	pending
321	Skelly Roddell	sales_staff	31	384955895797	M	Wildunger Straáe 14	6635200498	sroddell8s@stumbleupon.com	6571580.00	lX8"I5%bV!}tV	pending
322	Guendolen Leece	sales_staff	33	825221273105	M	P O BOX 70	2086300162	gleece8t@artisteer.com	32539244.00	cZ7_OeLT	pending
323	Emmet Arundell	warehouse_staff	35	888891725117	M	36 BOULEVARD DE LA REPUBLIQUE	8884753608	earundell8u@chron.com	6028278.00	aT6=FlPE	pending
324	Edsel Skurm	warehouse_staff	28	893385152042	F	PIAZZA GAVAZZI, 5	1448247589	eskurm8v@sourceforge.net	15957129.00	wR2.AC#rj47ryZE	pending
325	Gar Wallworth	warehouse_staff	22	085180772885	M	LOCATOR 5138	7772121787	gwallworth8w@ihg.com	39069916.00	jQ7,6RMe%5bv	pending
326	Read Avard	manager	22	239968925846	F	2910 W. JACKSON ST	8102341338	ravard8x@hud.gov	26385203.00	iR0\\zELK5*z\\n"5H	pending
327	Gale Biesterfeld	warehouse_staff	36	892506976163	M	P O BOX  6003	5769326545	gbiesterfeld8y@tinypic.com	25735767.00	xQ5`&,),`l3/g	pending
328	Yank Langford	sales_staff	36	161906904070	M	Tannenbergallee 6	4586889962	ylangford8z@51.la	18947512.00	kC8'MPKA)t@$#!	pending
329	Carr Carnelley	sales_staff	39	355633955770	F	5050 KINGSLEY DRIVE	9616711181	ccarnelley90@wired.com	24550351.00	jS6>MH&ORP	pending
330	Marney Willmett	manager	28	991817213141	M	Dudenstraáe 8	1268745890	mwillmett91@mozilla.com	12339519.00	jI3"Y)!%P(UG'	pending
331	Krista Frunks	warehouse_staff	24	752935934283	M	200 W CONGRESS ST	6567491181	kfrunks92@goodreads.com	6582757.00	iR2)RJlx8|B=	pending
332	Jervis Rustedge	manager	37	693352671533	M	17555 NE SACRAMENTO ST	3179601089	jrustedge93@hexun.com	39961164.00	yL7@FT86jHlXBC@	pending
333	Phylys Dressel	warehouse_staff	29	133599842716	M	Siedlungsstraáe, 1	5142577898	pdressel95@skyrock.com	12081077.00	vN9{%5lgH'`}	pending
334	Margarette Ible	warehouse_staff	24	048330452497	F	PRA€A DUQUE DE SALDANHA, N.§ 1, EDIFICIO ATRIUM SALDANHA, PISO 3	6926809822	mible96@nasa.gov	9116596.00	vH9!_LkP3Y\\=&=0f	pending
335	Nester Shilito	manager	21	988595786935	M	3833 EBONY ST	9362387555	nshilito97@wikispaces.com	49120293.00	tP2"NjKEC(f	pending
336	Justen Crowson	sales_staff	24	872332626720	M	106 E CLEVELAND	3702822891	jcrowson98@youku.com	26336542.00	mS0+(hd\\oMUTo&	pending
337	Nikkie Juszczak	warehouse_staff	38	574861296510	M	56 RUE DE LILLE	4514476495	njuszczak9a@boston.com	14827462.00	gW6{=(&8b<fJ	pending
338	Devondra Tolan	sales_staff	40	439630041082	M	NY-31-17-0119	1335429132	dtolan9b@mail.ru	29289341.00	cS6.CD316JR	pending
339	Wendi Quarrie	manager	36	164816918247	F	80 SUGAR CREEK CTR. BLVD	2627025308	wquarrie9c@acquirethisname.com	32995612.00	vB7}/ll>%M>Mis2M	pending
340	Redford De Brett	sales_staff	24	952205934437	M	1200 E. WARRENVILLE ROAD	6151013629	rde9d@businesswire.com	22481911.00	mV5_!QAur)	pending
341	Saunderson Riccione	sales_staff	35	885112706704	F	5900 LA PLACE COURT  SUITE 200	7241468421	sriccione9e@mayoclinic.com	10406802.00	gR4?d7n4l=rp(	pending
342	Matthew Beckenham	manager	36	792111953464	F	Hoveniersstraat, 29	8291591411	mbeckenham9f@histats.com	16688767.00	cP5*hYI7{.M|	pending
343	Dara Bampkin	warehouse_staff	40	332778687183	M	VIA EMILIA A SAN PIETRO, 4	1951133053	dbampkin9g@cbslocal.com	36116833.00	zX2"sva"	pending
344	Tiff Spybey	manager	35	313320490512	F	K„rntner Straáe, 394	2605805435	tspybey9h@wufoo.com	15633709.00	sD8}W&\\6",	pending
345	Anestassia Dominetti	manager	29	198516776210	M	4140 EAST STATE STREET	4524437741	adominetti9i@stumbleupon.com	43430125.00	zC1#>Nfy>An	pending
346	Hazel Pashba	sales_staff	22	089209977604	F	114 WEST FRONT ST	6292374378	hpashba9j@google.it	22051785.00	dL6@/`Gs\\Aj*	pending
347	Annelise Padfield	sales_staff	38	461714847309	F	PIAZZA FILIPPO MEDA 4	6743543553	apadfield9k@google.pl	22281353.00	lU7|QhGv)\\bdS1	pending
348	Jaclyn Theurer	warehouse_staff	28	310895372521	M	P.O.   BOX   105	6476502766	jtheurer9l@prlog.org	13319146.00	lL1(STc3BBLgjb<	pending
349	Ardra Gecke	warehouse_staff	35	941828983713	M	27-29 Patrick Street, Fermoy,	1339237737	agecke9m@state.tx.us	21767777.00	kW9$x3bHIKQH%8_	pending
350	Vallie Shuttleworth	sales_staff	25	942001382379	F	PO BOX 7009	4054012152	vshuttleworth9n@slideshare.net	29626941.00	hC1,d@+PVDGMEO	pending
351	Albrecht Devennie	manager	21	901618759977	M	Oktoberplatz, 1	6346868721	adevennie9o@webmd.com	36329431.00	mQ6@zNR#%@ehgR.	pending
352	Shannon Gowry	warehouse_staff	29	363840325503	F	Hauptstraáe 17	8334521554	sgowry9p@weibo.com	21502397.00	nY4{Ou~BA5g	pending
353	Sky Dunphie	manager	25	927091630287	M	P.O. BOX 567	7734467161	sdunphie9q@umn.edu	39084872.00	eA4`U=j2yJNr	pending
354	Rafi Spitaro	sales_staff	36	280361831680	F	PO BOX 10566	7789087768	rspitaro9r@nationalgeographic.com	39797231.00	lI0@fjQWPBQ>A{>{	pending
355	Marchall Aisthorpe	sales_staff	27	867730299314	M	Mannheimer Straáe 181	6624660478	maisthorpe9s@toplist.cz	47476057.00	gH4~}00C	pending
356	Davidson Powrie	manager	25	763098139588	M	Holzgraben 31	1964503815	dpowrie9t@miibeian.gov.cn	33126137.00	iL4>?#}#$ap6$t	pending
357	Broddy Warratt	warehouse_staff	28	308194941117	F	Naritawegÿ165	4541729137	bwarratt9u@opensource.org	6206242.00	vV1$`w%"='xa?	pending
358	Matti Childerhouse	sales_staff	37	797462198045	M	Croeselaanÿ18	1192920601	mchilderhouse9v@cornell.edu	43326316.00	jB3/x6m44U5DM	pending
359	Flem Brabin	warehouse_staff	34	337133124545	M	VIA ROMA, 122	2567737640	fbrabin9w@drupal.org	35692694.00	aK7'.KK,=c<	pending
360	Franklyn Crutcher	sales_staff	26	233522285754	F	P.O. BOX 87003	3738475194	fcrutcher9x@xinhuanet.com	20911702.00	eY2.W!rR	pending
361	Catha Nance	warehouse_staff	32	370338503142	M	200 EAST MAIN STREET	6497498562	cnance9y@sohu.com	48419050.00	sW9$`M_n&	pending
362	Hollie Taberner	sales_staff	34	882327493267	F	Kurtalstraáe 2	8928554482	htaberner9z@nasa.gov	27673062.00	uP9>WU!oK'	pending
363	Fancy Vines	manager	34	347614981711	M	P O BOX 507	5065783397	fvinesa0@woothemes.com	48666782.00	wT2)CnP>EIvSF5	pending
364	Gabriello Dyball	warehouse_staff	35	614019828204	F	Pfarrkirchener Straáe 16	9835913424	gdyballa1@sourceforge.net	15165593.00	cZ2*GjHm	pending
365	Lanie Spykins	sales_staff	21	854782170138	F	P.O. BOX 85139	6804759725	lspykinsa2@yale.edu	39983022.00	fM2=kp?\\GQ`Nd%	pending
366	Robby Trowl	manager	35	036518440137	M	315 N. MAIN	8819625195	rtrowla3@harvard.edu	38905043.00	gJ5<P>LBr2+)&nN	pending
367	Bonnibelle Kennedy	warehouse_staff	31	217867122926	M	P O BOX 210	3963803786	bkennedya4@is.gd	29951887.00	gM1(v`6rWEfXz$	pending
368	Lettie Chaney	warehouse_staff	29	754466265312	M	BOX 269	1358889470	lchaneya5@ucoz.com	44737938.00	oI0#+>E`Ls3QGkm	pending
369	Marijn Bellanger	warehouse_staff	29	555868288819	F	Market Street, Dundalk,	1793139783	mbellangera6@biblegateway.com	5031067.00	hI9/O}C.Ojr	pending
370	Orel Prout	sales_staff	21	179942636912	M	Auf der Idar 2	4856185461	oprouta7@netvibes.com	31619046.00	hI6%41Hk3FLras	pending
371	Chrysler Balam	sales_staff	26	093889631621	F	PS DE LA CASTELLANA, 55	7654699545	cbalama9@epa.gov	8385304.00	vI4.|||o	pending
372	Stacie Muggleston	warehouse_staff	40	422192802080	M	Hauptstraáe, 94	8644533920	smugglestonaa@nasa.gov	46146129.00	gA3'D%91Vdo	pending
373	Curcio Thrustle	manager	22	524457471197	F	245 BELGRADE AVE	3062305456	cthrustleab@free.fr	37196485.00	fX3|{fZ,ggaI`	pending
374	Pris McDuffie	warehouse_staff	38	035636537459	M	Marktplatz 7	8032303399	pmcduffieac@g.co	42291642.00	xO9$2)jUF=AGK?	pending
375	Drucy McTague	manager	36	561963741505	F	80 SUGAR CREEK CENTER BLVD.	4903323143	dmctaguead@cam.ac.uk	7849936.00	eH6?7d{+e	pending
376	Cinda Leechman	manager	36	437483212068	F	502 W WINDSOR	6722064585	cleechmanae@skype.com	39672572.00	aO6#k+2xY%>Ck6	pending
377	Prisca Kauschke	warehouse_staff	37	933426453864	M	P.O. BOX 85139	4712680668	pkauschkeaf@cyberchimps.com	21890519.00	cI4<XGrF@+Axf	pending
378	Arturo Yeldon	manager	38	739277204151	M	Niederland, 103	8533468508	ayeldonag@cocolog-nifty.com	20565168.00	iP5%ZT"KK~	pending
379	Stephie Stennings	warehouse_staff	33	812586085854	F	135 SECTION LINE ROAD	2394134315	sstenningsah@woothemes.com	6720016.00	iY9@C'Q"y	pending
380	Zelig Delahunty	warehouse_staff	27	375234572703	M	3405 N LOUISE AVE	9615366088	zdelahuntyai@accuweather.com	28214386.00	pK3,)saG~RM$#S	pending
381	Hanna Youtead	sales_staff	29	936702166272	M	Markt, 222	7439788669	hyouteadaj@scribd.com	9136298.00	tD4!&MQA	pending
382	Evin Ewbach	sales_staff	24	341797994477	M	15 ESPL BRILLAUD DE LAUJARDIERE CS 25014	3735539615	eewbachak@msu.edu	26808160.00	aO9*FIvJ8U#	pending
383	Broderic Giffen	warehouse_staff	21	265321917024	M	1 BANK PLAZA	5913641284	bgiffenal@angelfire.com	30173169.00	zK9\\&Y6`\\5wbn	pending
384	Flemming Hellings	sales_staff	35	980088304649	F	Regeringsgatan 103	4821833070	fhellingsam@nih.gov	29164218.00	vE1*)lScP	pending
385	Darcy Wyldish	sales_staff	20	613673816631	F	Hoveniersstraat, 29	1474290602	dwyldishan@lulu.com	36877976.00	nG3#ci4zE2C$g	pending
386	Michele Grzegorek	warehouse_staff	30	685216688550	M	15, avenue Emile Reuter	2604258278	mgrzegorekao@booking.com	16889333.00	bS7<tcD+uHZt	pending
387	Hector Langdon	warehouse_staff	35	361573852531	F	833 JULIAN AVENUE	9204385971	hlangdonap@histats.com	14367236.00	wM6>{X<UyRn.t8	pending
388	Wilfrid Myrkus	sales_staff	36	158263026122	M	Weseler Straáe 230	4141966620	wmyrkusaq@devhub.com	34704420.00	vF8*rpkUC,AXOu.	pending
389	Cody Philipeaux	sales_staff	33	964880776066	M	16 BOULEVARD DES ITALIENS	6384873507	cphilipeauxar@state.gov	47414943.00	gW0)G@ebs~6SF	pending
390	Merill Turnbull	warehouse_staff	25	694946513622	M	100 4TH AVENUE SE	7065769100	mturnbullas@abc.net.au	33778385.00	rZ7#Zx@qy	pending
391	Tara Jacquot	manager	23	152813106249	F	Eschenauer Straáe 5	6303483644	tjacquotat@examiner.com	40391817.00	pW6`4w}E	pending
392	Savina Fuggle	warehouse_staff	38	198422932251	M	P.O. BOX 67	7061431045	sfuggleau@so-net.ne.jp	48044910.00	zV8}yz.L+	pending
393	Tiphanie Arghent	manager	25	987116735051	F	Ballycullen Avenue, Firhouse,	9711956565	targhentav@dailymail.co.uk	48845769.00	mK3%D$<Z<|z"1a1	pending
394	Tonye Lakenton	warehouse_staff	37	103800995852	F	Klingenberg 1-5	7098952596	tlakentonaw@springer.com	20133678.00	oT5($yfO?O@lx.	pending
395	Richmound Jarnell	sales_staff	23	648642304131	F	Schrobenhausener Straáe 2	7686599942	rjarnellax@auda.org.au	43836937.00	cE7*\\R*S	pending
396	Jordan Dowsing	warehouse_staff	29	084521746599	M	1 NORTH MAIN STREET	5955311983	jdowsingay@cnn.com	42629037.00	aM5\\lDdvfq1ssnp	pending
397	Jessamyn Tomaszynski	sales_staff	28	767169204725	M	Gieáener Straáe 8	2785525904	jtomaszynskiaz@aboutads.info	25044027.00	sG5.p8VL5	pending
398	Georas Corke	sales_staff	32	812665764435	F	LOCATOR 01-5138	7035397409	gcorkeb0@squidoo.com	41155027.00	pY7%UAYVdd|rj*	pending
399	Dona Broinlich	sales_staff	25	375097477038	M	1, Place de Metz	1982370133	dbroinlichb1@livejournal.com	31459877.00	iZ5_T}G7P9r=eRI!	pending
400	Gris Breton	manager	24	512408144807	M	811 MAIN	9361497691	gbretonb2@umich.edu	15596360.00	dB3=+Tr?P&6rs6j(	pending
401	Beret Creelman	sales_staff	20	170072210428	M	1008 OAK STREET	3871062073	bcreelmanb3@sakura.ne.jp	10284588.00	pR0`OdNo<|=J	pending
402	Bronny Donativo	warehouse_staff	35	056803166922	M	Kirchbach, 12	5423553054	bdonativob4@sciencedirect.com	7461494.00	xL2\\oWd1	pending
403	Savina Littleover	manager	35	174837403416	F	7813 OFFICE PARK BLVD	5176951508	slittleoverb5@nytimes.com	28550371.00	bX6)oOC1Sv	pending
404	Gary Close	warehouse_staff	26	801860684258	M	VIA VITTORIO ALFIERI	7709588814	gcloseb6@howstuffworks.com	38759306.00	vM8<0rWG'q%$l|k	pending
405	Ben Temperton	warehouse_staff	36	991353816622	M	PIAZZA FILIPPO MEDA 4	4278611481	btempertonb7@state.gov	47649662.00	zC0.)`KR,$eJG	pending
406	Pepe Band	manager	30	825316654819	F	P.O. BOX 85139	6414653378	pbandb8@booking.com	6248094.00	tC0}*Kx/p%	pending
407	Ronnica Riddett	manager	28	115179267490	F	P O BOX 111	9518221488	rriddettb9@prlog.org	6068860.00	iE9)IAMiTZj.	pending
408	Joly Hostan	warehouse_staff	29	274140832654	M	Wittekindstraáe 17-19	6676081883	jhostanba@gmpg.org	39166189.00	qX8!>WHG=093i	pending
409	Brandi Beringer	warehouse_staff	29	784437478118	F	100 CREEK ROAD	4373611184	bberingerbb@techcrunch.com	46891129.00	sE3+?In*1j%	pending
410	Karlotte Chiene	manager	28	921152463778	M	4140 EAST STATE STREET	3267363202	kchienebc@feedburner.com	38451793.00	mP9%LP8$jlL\\DJQr	pending
411	Cesar Bayly	sales_staff	34	900838775219	M	Pz de San Nicol s, 4	4351414650	cbaylybd@cloudflare.com	49440720.00	pY6}@"w9iG<D{\\	pending
412	Darleen Orneblow	sales_staff	20	982264539908	F	ACH OPERATIONS 100-99-04-10	1864188840	dorneblowbe@msu.edu	19248650.00	pS5|8hE}.	pending
413	Kit Ditchfield	warehouse_staff	24	869217214856	M	Ostre Stationsvej 1	6507719892	kditchfieldbf@naver.com	20571507.00	mF9?s,5O3IG7	pending
414	Fayina Gertray	warehouse_staff	38	273132977255	F	235 GRIFFIN ST	6822160346	fgertraybg@opensource.org	27990269.00	iL7}03hCXBL@@	pending
415	Pacorro O'Tuohy	warehouse_staff	39	026330271534	M	2ND FLOOR	5872309225	potuohybh@marriott.com	13477254.00	lF7&7?.z,Q	pending
416	Alwyn Retchford	warehouse_staff	29	066292058242	M	CI Cant¢n Claudino Pita, 2	6054538107	aretchfordbi@so-net.ne.jp	32928007.00	vG0@HUqKHk4%/2	pending
417	Balduin Jurkiewicz	sales_staff	27	557548648972	F	80 SUGAR CREEK CENTER BLVD	4619919682	bjurkiewiczbj@themeforest.net	47266773.00	kK6")SNJ=<0#\\	pending
418	Kimble Utridge	warehouse_staff	38	783112060813	M	Warandeberg, 3	3127408482	kutridgebk@statcounter.com	30602460.00	lI2@EBBLa*<2	pending
419	Lindi Ebbotts	sales_staff	23	495175480474	M	115 N WALNUT STREET	7927172719	lebbottsbl@ning.com	45416008.00	yB2#\\%\\LYon	pending
420	Pepito Edleston	manager	33	610177977537	M	80 SUGAR CREEK CENTER BLVD	9082197998	pedlestonbm@xing.com	36549312.00	dG7((gY>4HyrwCn	pending
421	Egor Bartleman	sales_staff	38	353080554626	F	Str. Stefan cel Mare, nr. 3, parter si erajul 1, sector 1	9025913794	ebartlemanbn@virginia.edu	43431355.00	tR6,2!MyCc_}GtT2	pending
422	Datha Torald	manager	33	051004963204	F	3451 PRESCOTT	1245660228	dtoraldbo@theguardian.com	38830644.00	qU1+b2'etMu(E	pending
423	Somerset Libermore	warehouse_staff	21	032396786245	F	VA2-430-01-01	9174685673	slibermorebp@cloudflare.com	16228424.00	vL7|YR7mmTsL	pending
424	Jeromy McGeagh	warehouse_staff	24	108249217289	M	50 NORTH THIRD ST	8752899015	jmcgeaghbq@sogou.com	25868002.00	gY1#<@v{ow	pending
425	Anestassia Furlonge	sales_staff	24	149112867820	M	NY-31-17-0119	5853557043	afurlongebr@woothemes.com	45795473.00	bP4'i8Q?%s|M*C)	pending
426	Magdaia Mogford	sales_staff	25	704695477918	M	P.O. BOX 87003	2821465950	mmogfordbs@paypal.com	15779636.00	zW5?tS1uZo\\{89'Q	pending
427	Jedediah Papierz	warehouse_staff	22	063742437659	M	AV DE CANTABRIA, SN	4076198251	jpapierzbt@cnbc.com	24996300.00	mM3~eDX|rvG{H\\!	pending
428	Hartwell Nye	warehouse_staff	25	642560404527	M	PS DE LA INFANCIA, 10	2963698181	hnyebu@mapy.cz	49250513.00	cO1~25CZ"?pl	pending
429	Rochelle Gerritzen	sales_staff	39	933930725707	M	P.O. BOX 407	4624667058	rgerritzenbv@ning.com	41416865.00	wA7<qVLMO*(8"S	pending
430	Evangeline Munt	warehouse_staff	37	960593230015	F	ATTN: PAMELA HOFFERT	5231634166	emuntbw@twitpic.com	42947542.00	pY7"D/BTs@,	pending
431	Etan Breedy	sales_staff	32	678916823368	M	Georg-Dreke-Ring 62	8595396523	ebreedybx@go.com	26174798.00	wW8*k?l#(	pending
432	Arnaldo Cavendish	sales_staff	26	113864810888	M	275 SOUTHWEST THIRD STREET	3723826213	acavendishby@java.com	10301666.00	jI0@l<5$Du((	pending
433	Dulcie Ruberti	manager	23	046376944015	F	P O BOX 529	4522605088	drubertibz@hp.com	41853668.00	bJ0+5<j>!x<vy%)s	pending
434	Adolphus Meffin	sales_staff	29	708930512148	M	Neumarkt 17	3647537305	ameffinc0@cam.ac.uk	15093688.00	bD3&Ia{ue@!9aTO}	pending
435	Elvina Stoite	sales_staff	28	736684254864	M	Mannebeekstraat, 33	1751997515	estoitec1@opensource.org	41168799.00	bS1<n._''Vs"o>E%	pending
436	Harriot Garham	manager	37	450454963735	F	PIAZZA RISORGIMENTO, 16	8255536517	hgarhamc2@smugmug.com	17366721.00	iT3{kfM0rH6/&a4	pending
437	Amye Gerholz	manager	38	381670096021	M	PO BOX 469	2124656852	agerholzc3@google.co.jp	18014861.00	iV8%DCi9	pending
438	Hubie Yeoland	manager	30	570716631622	M	111 SILVAN AVENUE	1988505170	hyeolandc4@tripadvisor.com	48764899.00	cD2_vS4*XxU'g	pending
439	Erin Garmons	manager	34	985855051877	M	38 AVENUE KLEBER	8261254589	egarmonsc5@vinaora.com	34372767.00	pW7~#3"~ukj	pending
440	Hortensia Neilus	manager	32	005517850062	M	Kirchstraáe 10	3763599449	hneilusc6@4shared.com	40336103.00	zS2@I%~+9m\\.B	pending
441	Claudio Chaffen	manager	29	391234432797	M	P.O.BOX 4678	3532811314	cchaffenc7@yahoo.com	39833825.00	uS9}5x`~*ZF	pending
442	Anna-diana Rentz	manager	25	158992744984	M	MAC N9301-041	4189000730	arentzc8@businessinsider.com	33386186.00	bO6@%J!>coVPwe	pending
443	Broddie Richford	manager	28	694553053740	M	Bijlmerdreefÿ106	8191999123	brichfordc9@craigslist.org	43067971.00	sS5_(%d+t,JNHP	pending
444	Shayne Jackes	warehouse_staff	27	877654437683	M	106 W FIRST ST	3707475439	sjackesca@tinyurl.com	38950609.00	rP7<V3S4<,Jm(UBN	pending
445	Ronny Wreight	warehouse_staff	31	400270858616	M	VIALE ALTIERO SPINELLI, 30	7429405111	rwreightcb@howstuffworks.com	39215391.00	iC8"}z{N3c"5)vG@	pending
446	Putnem Melbury	sales_staff	21	709332104918	F	Raiffeisenstraáe 1	8682777879	pmelburycc@mediafire.com	44691450.00	qU7#{_CD7/	pending
447	Corrie Delete	warehouse_staff	29	291677718280	M	10430 HIGHLAND MANOR DRIVE 3RD FLOOR	2355986709	cdeletecd@reuters.com	41873692.00	eK7!&d$&U	pending
448	Ailene Dannehl	sales_staff	28	212406453094	F	ACH OPERATIONS 100-99-04-10	2397674889	adannehlce@sbwire.com	41804573.00	mU3?F5G_X'uJ	pending
449	Derrik Ough	warehouse_staff	21	131155640085	M	Hauptstraáe 188	1369587337	doughcf@e-recht24.de	10178074.00	kC6?>(9DJ%0!~k	pending
450	Lukas Hagerty	sales_staff	22	483179166260	F	100 TEMPLE AVE. S	2422748601	lhagertycg@bloglines.com	42512473.00	rO3(P`Bo9l	pending
451	Sawyer McWhin	sales_staff	39	563047654154	F	Kaiserstraáe 16 (Kaiserplatz)	2808237945	smcwhinch@domainmarket.com	15102231.00	iX7)}n&tA	pending
452	Jarred Zanettini	manager	25	841041858996	F	73 Orwell Road, Rathgar,	7822929472	jzanettinici@blogger.com	17168550.00	wB8+k"x6z96	pending
453	Amata Mushrow	manager	29	930097569618	M	921 AVENUE E	8079389244	amushrowcj@pbs.org	8424870.00	mV5=mz+U	pending
454	Rodie Pybus	sales_staff	28	777975943040	M	EP-MN-WN1A	2246431433	rpybusck@washingtonpost.com	37353994.00	vG2,L".$(!U{op	pending
455	Arlee Brett	manager	38	424928343159	F	210 E 54 HIGHWAY	7704198221	abrettcl@cdc.gov	15187265.00	uQ3%35=NDR82>T	pending
456	Meagan Hanscome	manager	22	030732396719	M	Dorfstraáe, 25	4735893734	mhanscomecm@eepurl.com	21694138.00	oT5>Q~u=c'S,L	pending
457	Licha Perkin	sales_staff	28	605957420166	M	PO BOX 549	2787584931	lperkincn@plala.or.jp	16368341.00	zJ4'dUdS}	pending
458	Franky Reicherz	warehouse_staff	40	640312810800	M	112 CORPORATE DRIVE	3021590286	freicherzco@multiply.com	29479277.00	hB8{X15=Rn69gJ*?	pending
459	Andi Popplestone	manager	26	712385691025	F	VIA NICCOLO' TOMMASEO, 7	7052539478	apopplestonecp@army.mil	17112611.00	qJ6,p~_Sx	pending
460	Elnora Petrishchev	warehouse_staff	24	490725278789	F	Kungstr„dg†rdsgatan 2	4207372904	epetrishchevcq@whitehouse.gov	42632439.00	dA2#ZMeTDy	pending
461	Theresa MacMakin	sales_staff	25	243249661867	M	5050 KINGSLEY DRIVE	8478018886	tmacmakincr@nih.gov	18419472.00	jB0!IP|,1yfA8mUA	pending
462	Kingsley Siegertsz	sales_staff	34	978737091438	M	P.O. BOX 85139	8076094596	ksiegertszcs@gov.uk	19523938.00	xM9\\x"_E	pending
463	Kaye Innott	sales_staff	36	674425704899	M	PO BOX 27025, VA2-430-01-01	6738781436	kinnottct@behance.net	22144832.00	aN7%GZRWCX"Y8	pending
464	Frederick Cuniffe	manager	27	257573951125	M	315 MAIN ST.	9534459521	fcuniffecu@scribd.com	36786006.00	yH2&X`%#h\\y	pending
465	Lou Phillps	sales_staff	39	603573971245	F	ONE PENN'S WAY	2376374172	lphillpscv@acquirethisname.com	40609490.00	gI7|?qXs	pending
466	Donia Deinert	sales_staff	23	484799923365	F	P.O. BOX 418	7675249359	ddeinertcw@cyberchimps.com	39211722.00	sB5_kPaZI	pending
467	Peggie Melarkey	warehouse_staff	33	328561256739	M	Am Stadtpark, 9	1452859196	pmelarkeycx@bing.com	28353664.00	xY9.e}<8	pending
468	Worthington Cowlam	manager	28	855642345145	F	5210 74TH ST W SUITE B	9788050257	wcowlamcy@csmonitor.com	8030667.00	rH1{!m!/P=(R"mp	pending
469	Lind Elstow	manager	27	349559651281	F	Otto-Hahn-Ring 6	2889138511	lelstowcz@shop-pro.jp	46973916.00	dZ3+@JLBi	pending
470	Sybila Hain	manager	36	892450195809	F	Tronholmen 1	9126161713	shaind0@reuters.com	33740253.00	dX1`ml?VFX,	pending
471	Elmira Chancelier	sales_staff	20	010408888746	F	Baruther Straáe 23	2425853639	echancelierd1@geocities.com	20926865.00	fT5/\\8~.#,(	pending
472	Wade Mayers	manager	36	765824759735	F	205 S SUMMIT	2291549786	wmayersd2@sciencedirect.com	15830145.00	lG4%10XO4r(	pending
473	Tiffani Joron	warehouse_staff	21	053690352296	M	Europaplatz 10-12	9101526138	tjorond3@devhub.com	32596339.00	zC6&!fSMMCP&7	pending
474	Theresina Litherborough	warehouse_staff	37	504778164498	F	CORSO DELLA REPUBBLICA, 126	5266664930	tlitherboroughd4@networkadvertising.org	14201157.00	iC7~D1NPf4h	pending
475	Kristel Troyes	manager	20	356601524183	M	PO BOX 218	8605622339	ktroyesd5@globo.com	10129546.00	nP5(iG>rL	pending
476	Carena Roke	sales_staff	34	199136939312	M	Bregenzer Straáe 29	4386128104	croked6@discovery.com	5123729.00	bM6>,+$ryq=10MC>	pending
477	Blinny Coon	manager	36	930321580325	F	VIALE ALTIERO SPINELLI, 30	5153391983	bcoond7@accuweather.com	47629705.00	lX4&o26v2i#t=YY	pending
478	Thorvald Gibling	warehouse_staff	32	717846905399	M	Market Street, Thomastown,	9709638488	tgiblingd8@rediff.com	5457187.00	vH0_SEgi.h	pending
479	Demetri Solly	sales_staff	28	086412515020	M	8 AVENUE DES CANUTS	4072485432	dsollyd9@blogger.com	5287026.00	vW2|GctY1MKU	pending
480	Maurice Handsheart	warehouse_staff	40	040765508003	F	VIA ESPERANTO, 1	4848760240	mhandsheartda@webnode.com	10261993.00	qT6/Iv?zj4Adl	pending
481	Maurizio O'Kane	manager	35	809974616254	M	941 CORPORATE CENTER DR.	2681370053	mokanedb@uol.com.br	9107311.00	rH5&+|Hdfd3dd!v	pending
482	Dory Beasley	sales_staff	40	301317120971	F	401 W TEXAS STE 315	4874277451	dbeasleydc@edublogs.org	41219749.00	hX2''UxXG,R	pending
483	Olga Ipsley	warehouse_staff	38	422281785696	F	Hauptstraáe 46	9971969430	oipsleydd@wisc.edu	49050553.00	hT1{YxuTPWl?6l	pending
484	Henriette Flamank	warehouse_staff	28	603013742585	F	Bezirksstraáe 46	1127802100	hflamankde@google.com.au	17437982.00	iD7!*tmu	pending
485	Fulton McElmurray	manager	37	182977485561	M	PO BOX 397	7546794637	fmcelmurraydf@pbs.org	18906138.00	xJ7?86%r=	pending
486	Aurthur Leonard	warehouse_staff	28	306625321052	M	122 SOUTH COMMERCIAL	8444866001	aleonarddg@omniture.com	27783286.00	lY5$_L!EP8D7e&p_	pending
487	Taddeo Prator	manager	26	071518168669	M	PO BOX 1377	2433858436	tpratordh@un.org	20711665.00	hT7#$,*}	pending
488	Lynn Spellissy	sales_staff	34	757623501759	M	Vyskocilova 1442/1b	4521781502	lspellissydi@npr.org	23813370.00	rG8$|+Bq~	pending
489	Phyllida Nund	manager	37	500174059633	F	12183 MS HWY 182	4133709455	pnunddj@studiopress.com	39226945.00	tX0.&~J`'&R8PP	pending
490	Diego McCreery	warehouse_staff	24	117282048769	F	PIAZZETTA DELLA MOSTRA, 2	4751501614	dmccreerydk@mayoclinic.com	18475742.00	mU6.HB=I=J8`8Ik9	pending
491	Drusy Edmonds	sales_staff	38	162351431330	F	414 TENTH STREET	1609336655	dedmondsdl@rambler.ru	43575400.00	oE6\\E|cyE	pending
492	Anthea Edison	sales_staff	20	823189542570	F	LOCATOR 5138	3505880706	aedisondm@disqus.com	14825536.00	mK2$bl!VH8	pending
493	Gerrilee Shercliff	manager	23	657798776680	M	P O BOX 808	2836229461	gshercliffdn@sitemeter.com	33074171.00	aK5%wlSYItG9X5	pending
494	Dirk Dando	manager	25	892677031000	M	833 JULIAN AVENUE	4701616210	ddandodo@ezinearticles.com	37630596.00	jP1}TYT(D|	pending
495	Jenny Laying	manager	34	125643994526	M	P O BOX 738	3549237936	jlayingdp@plala.or.jp	36262615.00	iL4&'Kv<	pending
496	Milissent Sergeant	manager	35	872946889786	M	899 NE ALSBURY	9483012662	msergeantdq@reddit.com	28029740.00	zD5*pneWDYwiH	pending
497	Lucas Norwich	manager	35	244204172653	M	Landstraáe 23, Postfach 10	7805911787	lnorwichdr@theguardian.com	23505890.00	dD9`NvuF	pending
498	Cord McCarlich	warehouse_staff	35	899490150943	F	Kolingasse, 4	1529581583	cmccarlichds@gmpg.org	27958154.00	fA5*>UfgPo	pending
499	Raynor Bootland	warehouse_staff	36	509502509899	M	423 MAIN STREET	1298419747	rbootlanddt@posterous.com	17452669.00	zJ0*?zN}EOb	pending
500	Finlay Morriarty	warehouse_staff	36	043098955091	M	Schillerstraáe 3	5653934012	fmorriartydu@nps.gov	16587925.00	iK5=DM3F'W	pending
501	Sylas Huntar	warehouse_staff	37	151568760279	M	Simon Carmiggeltstraat 6	2682227926	shuntardv@bigcartel.com	43249512.00	aO0!iw>Hy	pending
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
9	288	2022-01-07	\N	\N	\N	2028-03-23	2022-10-20	terminated
10	43	2024-09-29	\N	\N	\N	2026-06-23	2024-11-16	terminated
11	234	2024-03-06	\N	\N	\N	2028-07-09	2025-01-24	terminated
12	124	2022-11-13	\N	\N	\N	2027-01-26	2022-12-13	active
13	274	2024-02-17	\N	\N	\N	2027-07-18	2025-02-12	terminated
14	234	2023-07-30	\N	\N	\N	2026-09-15	2023-10-04	terminated
15	137	2021-01-21	\N	\N	\N	2026-09-16	2021-10-18	active
16	326	2023-09-24	\N	\N	\N	2028-02-25	2024-04-09	terminated
17	173	2024-04-11	\N	\N	\N	2027-08-15	2025-03-08	terminated
18	377	2023-12-22	\N	\N	\N	2026-01-06	2024-04-03	terminated
19	482	2022-02-09	\N	\N	\N	2029-08-11	2023-01-16	active
20	67	2024-01-20	\N	\N	\N	2029-11-06	2024-10-26	active
21	457	2024-04-18	\N	\N	\N	2026-02-17	2024-08-04	active
22	78	2024-12-08	\N	\N	\N	2026-05-16	2024-12-29	terminated
23	124	2024-01-18	\N	\N	\N	2026-02-11	2024-10-17	terminated
24	309	2022-11-20	\N	\N	\N	2026-10-13	2022-12-09	active
25	15	2024-10-10	\N	\N	\N	2028-03-16	2025-03-28	terminated
26	194	2023-10-24	\N	\N	\N	2026-01-22	2024-08-13	terminated
27	287	2022-05-07	\N	\N	\N	2028-08-24	2022-07-13	active
28	462	2024-07-26	\N	\N	\N	2029-07-11	2024-12-05	active
29	361	2022-08-18	\N	\N	\N	2028-09-23	2023-01-28	terminated
30	139	2021-01-04	\N	\N	\N	2028-11-05	2022-01-01	terminated
31	426	2023-09-22	\N	\N	\N	2028-12-25	2024-08-12	terminated
32	376	2020-01-09	\N	\N	\N	2029-03-22	2020-04-07	active
33	364	2021-11-30	\N	\N	\N	2026-06-06	2022-04-19	active
34	58	2020-05-22	\N	\N	\N	2029-10-18	2021-05-12	terminated
35	261	2023-03-11	\N	\N	\N	2029-01-01	2023-05-02	terminated
36	220	2020-08-26	\N	\N	\N	2026-05-05	2021-03-22	terminated
37	51	2024-03-26	\N	\N	\N	2026-06-25	2024-06-05	active
38	190	2020-03-21	\N	\N	\N	2026-04-14	2020-07-07	active
39	117	2020-03-24	\N	\N	\N	2029-12-29	2020-07-10	active
40	32	2022-08-26	\N	\N	\N	2026-07-14	2023-03-14	terminated
41	333	2020-09-27	\N	\N	\N	2028-10-08	2021-07-09	active
42	125	2022-12-16	\N	\N	\N	2028-09-22	2023-06-22	terminated
43	72	2020-05-21	\N	\N	\N	2027-03-09	2020-09-25	active
44	65	2023-09-13	\N	\N	\N	2028-05-07	2024-02-05	active
45	409	2020-08-27	\N	\N	\N	2026-08-28	2021-05-26	active
46	455	2024-09-02	\N	\N	\N	2028-09-04	2025-07-28	active
47	396	2022-03-25	\N	\N	\N	2029-09-13	2022-04-09	terminated
48	460	2023-05-07	\N	\N	\N	2028-12-10	2023-10-12	active
49	353	2024-09-21	\N	\N	\N	2027-09-24	2025-07-20	terminated
50	220	2022-12-15	\N	\N	\N	2028-03-14	2023-04-05	terminated
51	159	2022-05-15	\N	\N	\N	2028-02-26	2022-06-22	active
52	360	2020-08-23	\N	\N	\N	2027-09-18	2021-08-13	active
53	259	2024-07-01	\N	\N	\N	2029-07-06	2024-12-27	terminated
54	481	2024-12-01	\N	\N	\N	2027-12-01	2025-07-18	active
55	432	2023-10-29	\N	\N	\N	2028-12-24	2024-04-18	terminated
56	197	2020-05-31	\N	\N	\N	2027-12-31	2020-11-07	active
57	102	2023-03-13	\N	\N	\N	2027-08-02	2023-07-03	active
58	57	2020-04-01	\N	\N	\N	2028-02-04	2020-05-06	active
59	211	2022-06-07	\N	\N	\N	2028-06-29	2023-01-26	terminated
60	417	2022-02-08	\N	\N	\N	2026-10-10	2022-09-23	terminated
61	468	2020-05-20	\N	\N	\N	2028-02-10	2020-11-04	terminated
62	18	2024-11-16	\N	\N	\N	2026-10-15	2025-06-04	terminated
63	94	2023-11-13	\N	\N	\N	2028-09-27	2024-08-23	terminated
64	56	2024-11-27	\N	\N	\N	2026-12-05	2025-10-08	terminated
65	13	2021-07-28	\N	\N	\N	2029-07-06	2022-02-18	active
66	228	2024-01-28	\N	\N	\N	2029-12-30	2024-12-23	active
67	168	2021-11-03	\N	\N	\N	2029-04-18	2022-03-17	terminated
68	208	2020-11-03	\N	\N	\N	2028-10-30	2021-02-06	terminated
69	309	2023-01-14	\N	\N	\N	2029-09-23	2023-04-19	terminated
70	79	2021-02-01	\N	\N	\N	2026-07-04	2021-09-07	active
71	199	2021-07-25	\N	\N	\N	2028-01-03	2021-08-12	terminated
72	358	2021-08-20	\N	\N	\N	2028-08-16	2021-11-22	active
73	73	2022-11-08	\N	\N	\N	2027-08-15	2022-11-29	terminated
74	470	2022-10-27	\N	\N	\N	2026-07-20	2023-10-24	active
75	201	2024-04-23	\N	\N	\N	2027-04-18	2024-04-28	terminated
76	434	2021-01-15	\N	\N	\N	2028-11-20	2021-02-05	terminated
77	126	2021-01-12	\N	\N	\N	2027-07-28	2021-08-30	active
78	227	2023-12-22	\N	\N	\N	2026-11-23	2024-03-08	terminated
79	355	2023-03-09	\N	\N	\N	2029-06-30	2023-04-06	active
80	469	2020-11-10	\N	\N	\N	2027-06-16	2021-10-17	active
81	150	2024-03-10	\N	\N	\N	2028-10-10	2024-09-22	active
82	173	2020-01-15	\N	\N	\N	2028-08-26	2020-12-01	terminated
83	489	2021-06-30	\N	\N	\N	2028-05-03	2022-03-02	active
84	400	2023-11-06	\N	\N	\N	2026-12-06	2024-02-06	active
85	295	2023-11-22	\N	\N	\N	2029-12-17	2024-10-28	active
86	345	2024-06-10	\N	\N	\N	2026-03-20	2024-12-04	active
87	433	2023-09-16	\N	\N	\N	2028-09-18	2023-09-18	active
88	261	2021-04-17	\N	\N	\N	2028-06-29	2022-01-21	terminated
89	292	2021-03-21	\N	\N	\N	2029-04-11	2021-08-16	active
90	224	2020-06-15	\N	\N	\N	2027-02-23	2020-12-20	terminated
91	335	2021-11-13	\N	\N	\N	2029-12-06	2022-07-18	active
92	331	2021-12-06	\N	\N	\N	2026-01-27	2022-06-15	active
93	386	2022-02-22	\N	\N	\N	2029-02-22	2023-02-14	active
94	99	2022-12-22	\N	\N	\N	2028-05-04	2023-09-01	terminated
95	72	2022-02-17	\N	\N	\N	2026-10-23	2022-12-27	active
96	165	2024-10-18	\N	\N	\N	2028-07-08	2024-11-10	active
97	222	2021-04-22	\N	\N	\N	2029-02-11	2021-09-29	terminated
98	449	2023-02-23	\N	\N	\N	2026-09-16	2023-04-29	active
99	235	2023-11-09	\N	\N	\N	2029-11-20	2024-09-02	terminated
100	132	2021-11-11	\N	\N	\N	2028-01-19	2022-09-03	active
101	258	2023-08-12	\N	\N	\N	2029-02-08	2023-09-01	active
102	246	2022-12-27	\N	\N	\N	2026-11-16	2023-02-13	active
103	151	2020-11-26	\N	\N	\N	2029-10-17	2021-09-27	terminated
104	58	2024-02-03	\N	\N	\N	2029-06-29	2024-08-16	terminated
105	462	2023-12-03	\N	\N	\N	2026-09-10	2024-04-26	terminated
106	246	2021-04-13	\N	\N	\N	2026-12-18	2021-12-17	active
107	40	2021-06-24	\N	\N	\N	2029-10-02	2022-01-18	active
108	375	2024-10-05	\N	\N	\N	2026-10-24	2025-07-09	active
109	162	2022-06-26	\N	\N	\N	2028-03-26	2022-07-28	active
110	379	2023-03-14	\N	\N	\N	2028-06-23	2024-03-08	terminated
111	465	2022-01-17	\N	\N	\N	2026-08-22	2022-08-29	terminated
112	336	2021-12-06	\N	\N	\N	2027-10-07	2022-02-12	terminated
113	106	2024-11-09	\N	\N	\N	2027-09-27	2025-05-25	active
114	193	2022-01-11	\N	\N	\N	2029-10-19	2022-06-17	terminated
115	245	2020-12-03	\N	\N	\N	2028-06-10	2021-08-29	active
116	143	2024-05-18	\N	\N	\N	2026-07-29	2024-06-13	active
117	316	2021-10-14	\N	\N	\N	2029-05-01	2022-07-27	active
118	144	2024-11-02	\N	\N	\N	2029-10-13	2025-11-02	active
119	267	2022-09-20	\N	\N	\N	2028-07-26	2022-11-13	active
120	446	2023-09-02	\N	\N	\N	2029-08-11	2024-04-18	terminated
121	18	2022-01-13	\N	\N	\N	2028-10-13	2022-12-06	terminated
122	68	2022-09-25	\N	\N	\N	2028-09-11	2023-06-15	terminated
123	197	2024-12-02	\N	\N	\N	2028-12-04	2025-07-25	terminated
124	15	2020-04-05	\N	\N	\N	2026-09-14	2020-04-09	active
125	92	2024-11-19	\N	\N	\N	2027-05-13	2025-08-11	terminated
126	114	2023-01-07	\N	\N	\N	2029-03-30	2023-01-17	terminated
127	96	2020-06-03	\N	\N	\N	2027-03-20	2020-09-25	terminated
128	365	2022-05-17	\N	\N	\N	2028-07-27	2022-09-21	terminated
129	200	2022-09-11	\N	\N	\N	2028-04-06	2023-08-08	active
130	358	2022-10-18	\N	\N	\N	2026-12-12	2023-09-23	active
131	221	2023-11-10	\N	\N	\N	2027-02-19	2023-11-27	active
132	406	2024-01-10	\N	\N	\N	2027-05-10	2024-10-07	terminated
133	282	2021-06-26	\N	\N	\N	2027-04-14	2021-07-28	active
134	353	2024-04-30	\N	\N	\N	2027-07-15	2024-10-04	active
135	114	2024-04-08	\N	\N	\N	2026-08-28	2024-07-07	terminated
136	385	2020-08-24	\N	\N	\N	2028-08-30	2021-07-27	active
137	396	2024-09-15	\N	\N	\N	2029-07-03	2024-10-11	active
138	405	2021-11-22	\N	\N	\N	2029-12-04	2022-10-09	active
139	295	2023-08-05	\N	\N	\N	2026-12-09	2023-08-09	active
140	255	2022-11-30	\N	\N	\N	2026-02-22	2023-11-06	active
141	324	2023-05-26	\N	\N	\N	2027-09-13	2024-02-20	active
142	292	2023-05-10	\N	\N	\N	2027-10-02	2024-05-02	terminated
143	324	2021-06-07	\N	\N	\N	2027-03-05	2021-11-19	terminated
144	439	2024-07-28	\N	\N	\N	2027-05-24	2025-07-23	active
145	374	2021-07-12	\N	\N	\N	2029-03-23	2021-07-13	terminated
146	487	2021-06-25	\N	\N	\N	2029-09-05	2022-03-29	active
147	149	2022-05-04	\N	\N	\N	2028-02-21	2022-05-05	terminated
148	88	2023-12-21	\N	\N	\N	2028-12-14	2024-11-05	terminated
149	146	2022-07-23	\N	\N	\N	2026-10-10	2023-04-30	terminated
150	246	2021-08-14	\N	\N	\N	2027-11-04	2022-04-18	terminated
151	434	2022-05-24	\N	\N	\N	2026-07-28	2022-09-12	active
152	347	2023-12-02	\N	\N	\N	2029-06-20	2024-07-09	active
153	176	2023-05-25	\N	\N	\N	2027-11-20	2024-04-13	terminated
154	114	2022-10-03	\N	\N	\N	2028-06-26	2023-07-12	active
155	283	2021-07-15	\N	\N	\N	2028-01-30	2021-09-08	active
156	110	2022-01-14	\N	\N	\N	2028-09-06	2022-11-12	terminated
157	498	2023-05-14	\N	\N	\N	2029-06-06	2024-05-06	terminated
158	375	2020-10-05	\N	\N	\N	2029-06-27	2020-10-06	active
159	35	2023-01-15	\N	\N	\N	2027-08-25	2023-10-23	active
160	386	2024-08-29	\N	\N	\N	2026-09-17	2024-09-26	active
161	27	2024-10-15	\N	\N	\N	2028-01-10	2025-02-23	active
162	207	2023-07-26	\N	\N	\N	2026-01-26	2023-10-22	active
163	94	2024-03-12	\N	\N	\N	2027-06-17	2024-11-05	terminated
164	194	2021-05-14	\N	\N	\N	2028-06-12	2021-09-18	active
165	159	2023-05-24	\N	\N	\N	2026-12-01	2024-04-19	active
166	416	2024-09-29	\N	\N	\N	2029-05-13	2025-02-02	terminated
167	193	2020-02-22	\N	\N	\N	2027-05-03	2020-12-14	active
168	123	2022-11-23	\N	\N	\N	2029-06-05	2023-07-08	active
169	495	2024-06-23	\N	\N	\N	2026-02-10	2025-04-03	terminated
170	289	2020-01-11	\N	\N	\N	2027-06-15	2020-03-23	active
171	429	2024-05-19	\N	\N	\N	2029-02-14	2025-01-16	terminated
172	79	2023-08-10	\N	\N	\N	2027-09-24	2023-12-22	active
173	203	2021-08-03	\N	\N	\N	2026-09-21	2021-11-21	active
174	51	2022-04-11	\N	\N	\N	2028-07-23	2022-08-21	active
175	168	2021-01-19	\N	\N	\N	2027-06-03	2021-12-30	terminated
176	148	2024-10-02	\N	\N	\N	2026-12-09	2025-01-14	active
177	371	2021-09-20	\N	\N	\N	2029-03-08	2022-01-09	terminated
178	98	2023-06-18	\N	\N	\N	2026-01-05	2023-08-14	active
179	305	2020-09-07	\N	\N	\N	2026-01-08	2020-11-13	active
180	231	2020-10-09	\N	\N	\N	2026-11-18	2021-01-12	active
181	226	2022-06-06	\N	\N	\N	2027-10-01	2023-01-28	active
182	215	2022-05-28	\N	\N	\N	2027-05-30	2022-10-17	active
183	284	2020-11-09	\N	\N	\N	2029-09-09	2021-10-04	terminated
184	398	2022-02-19	\N	\N	\N	2026-02-06	2022-12-11	active
185	432	2022-12-08	\N	\N	\N	2028-05-31	2023-04-27	terminated
186	141	2021-02-25	\N	\N	\N	2029-04-24	2021-10-12	active
187	295	2020-09-08	\N	\N	\N	2027-09-03	2021-04-14	terminated
188	222	2022-09-24	\N	\N	\N	2029-12-05	2023-03-18	active
189	39	2021-12-22	\N	\N	\N	2029-10-29	2022-12-13	terminated
190	43	2022-07-07	\N	\N	\N	2029-06-22	2023-01-02	active
191	92	2020-05-28	\N	\N	\N	2026-01-15	2021-05-25	active
192	46	2020-02-03	\N	\N	\N	2029-07-03	2020-09-15	terminated
193	128	2020-02-04	\N	\N	\N	2028-01-03	2020-07-20	active
194	143	2024-07-29	\N	\N	\N	2026-12-26	2024-10-02	terminated
195	256	2020-09-23	\N	\N	\N	2028-01-25	2021-04-05	terminated
196	367	2022-11-02	\N	\N	\N	2028-04-20	2022-11-19	active
197	90	2021-07-29	\N	\N	\N	2027-11-03	2022-05-31	active
198	200	2023-03-11	\N	\N	\N	2026-06-16	2024-02-16	active
199	459	2021-09-06	\N	\N	\N	2026-05-10	2021-09-09	terminated
200	79	2023-08-05	\N	\N	\N	2027-03-12	2024-07-01	terminated
201	279	2024-07-12	\N	\N	\N	2028-04-21	2025-01-23	terminated
202	422	2023-03-26	\N	\N	\N	2027-09-05	2023-08-02	terminated
203	311	2024-10-15	\N	\N	\N	2027-09-28	2025-06-12	active
204	110	2022-11-05	\N	\N	\N	2026-09-30	2023-08-10	terminated
205	269	2022-09-10	\N	\N	\N	2026-04-29	2022-12-28	terminated
206	290	2021-01-09	\N	\N	\N	2028-11-28	2021-04-12	active
207	247	2022-05-09	\N	\N	\N	2027-10-29	2022-10-18	terminated
208	490	2020-01-09	\N	\N	\N	2026-08-29	2020-09-09	active
\.


--
-- Data for Name: operating_expense_log; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.operating_expense_log (log_id, expense_type, amount_paid, pay_date, note) FROM stdin;
1	other	9549046.15	2020-10-16	\N
2	water	2784757.28	2020-03-29	\N
3	tax	2820979.97	2022-10-18	\N
4	rent	4687260.56	2020-09-16	\N
5	water	2315742.32	2020-04-03	\N
6	water	2776000.60	2024-06-27	\N
7	rent	984210.42	2021-11-02	\N
8	water	6766218.79	2020-04-20	\N
9	water	4654484.38	2020-06-22	\N
10	other	9278298.20	2024-05-15	\N
11	water	3760231.56	2022-01-05	\N
12	electricity	492260.56	2021-04-24	\N
13	rent	6640364.34	2025-01-30	\N
14	tax	5176891.50	2020-02-23	\N
15	water	3193243.42	2021-04-30	\N
16	rent	4311836.84	2024-05-16	\N
17	tax	1644710.39	2024-07-25	\N
18	other	2506160.74	2024-06-09	\N
19	tax	5243168.24	2023-10-29	\N
20	water	6673165.98	2024-01-01	\N
21	rent	5304752.88	2023-06-07	\N
22	electricity	9128284.73	2025-05-05	\N
23	other	1286920.87	2022-08-12	\N
24	rent	1774928.10	2024-07-20	\N
25	water	2640028.00	2022-09-16	\N
26	water	7340282.49	2022-12-31	\N
27	electricity	9887417.09	2022-12-12	\N
28	electricity	1369764.71	2025-04-27	\N
29	tax	7551738.56	2023-11-13	\N
30	water	4356690.16	2022-10-12	\N
31	water	7762317.90	2020-12-12	\N
32	other	9228140.86	2024-11-30	\N
33	other	6071533.65	2022-01-16	\N
34	water	4364901.21	2022-01-05	\N
35	electricity	398401.51	2020-04-07	\N
36	other	6865147.99	2024-10-12	\N
37	electricity	8766930.93	2023-10-10	\N
38	electricity	3046376.89	2020-08-14	\N
39	other	653849.31	2020-09-03	\N
40	rent	8845244.69	2023-06-13	\N
41	rent	6455102.92	2020-01-25	\N
42	other	7052358.96	2024-04-27	\N
43	electricity	9522898.22	2021-10-15	\N
44	electricity	3617172.86	2024-11-23	\N
45	electricity	7510762.53	2022-01-23	\N
46	tax	3302640.87	2023-12-27	\N
47	water	8430177.24	2025-05-25	\N
48	other	5564594.74	2022-07-28	\N
49	tax	8282066.56	2020-01-11	\N
50	water	9923214.08	2020-08-23	\N
51	electricity	4364392.30	2021-03-26	\N
52	electricity	8259127.77	2024-04-19	\N
53	other	9314256.59	2020-05-30	\N
54	tax	403516.17	2020-10-17	\N
55	electricity	2064711.06	2024-02-01	\N
56	rent	7934647.86	2023-11-10	\N
57	electricity	2541585.27	2023-06-29	\N
58	rent	4678260.25	2023-01-30	\N
59	water	4901916.47	2024-07-19	\N
60	electricity	4029449.50	2020-09-13	\N
61	rent	9507032.11	2024-02-27	\N
62	rent	8029767.00	2020-05-09	\N
63	electricity	6094308.48	2024-01-24	\N
64	other	3251846.69	2023-09-18	\N
65	rent	2344612.06	2020-11-12	\N
66	electricity	9832450.00	2022-11-08	\N
67	water	7821500.31	2022-11-28	\N
68	water	8100314.21	2025-03-20	\N
69	other	6356530.10	2022-04-28	\N
70	electricity	152770.21	2024-06-12	\N
71	water	6129764.93	2022-05-19	\N
72	water	3321617.43	2023-02-11	\N
73	other	5894409.78	2024-05-23	\N
74	rent	1345864.33	2024-12-22	\N
75	electricity	7955221.65	2022-05-27	\N
76	electricity	3956913.14	2022-02-04	\N
77	water	5684762.29	2024-02-26	\N
78	rent	1854531.73	2024-02-24	\N
79	electricity	4109314.36	2024-07-29	\N
80	electricity	7281721.60	2020-12-29	\N
81	water	1437112.65	2020-11-07	\N
82	other	983993.60	2023-10-20	\N
83	tax	3911445.09	2023-03-01	\N
84	water	8160818.46	2021-11-03	\N
85	other	5601352.71	2022-05-16	\N
86	other	1148087.78	2023-02-25	\N
87	tax	3488190.59	2022-01-08	\N
88	rent	118738.09	2024-10-28	\N
89	electricity	4762836.13	2023-05-03	\N
90	water	9147647.11	2022-03-05	\N
91	electricity	6811918.85	2025-03-18	\N
92	other	3217201.88	2020-01-13	\N
93	tax	1165552.11	2021-08-02	\N
94	electricity	2312167.94	2021-06-23	\N
95	electricity	2151952.71	2023-09-28	\N
96	water	1886681.47	2023-09-05	\N
97	tax	8586930.41	2021-05-13	\N
98	electricity	4432335.67	2021-11-01	\N
99	electricity	1114634.27	2021-09-13	\N
100	other	6624987.31	2021-12-05	\N
101	water	7482775.52	2022-05-15	\N
102	other	2607354.01	2020-02-23	\N
103	tax	2037231.14	2024-11-05	\N
104	rent	9299782.21	2024-06-27	\N
105	electricity	3413317.43	2023-10-10	\N
106	other	1667723.45	2024-10-16	\N
107	water	4582980.37	2024-09-27	\N
108	electricity	1154945.27	2022-09-23	\N
109	tax	8759814.62	2020-02-04	\N
110	tax	1420354.95	2024-10-29	\N
111	rent	7347731.46	2020-02-18	\N
112	rent	1061738.06	2021-11-18	\N
113	water	4023650.69	2022-02-16	\N
114	water	3317131.44	2022-09-27	\N
115	electricity	4719577.45	2020-06-30	\N
116	tax	6896266.39	2024-06-20	\N
117	other	1553338.90	2024-01-21	\N
118	rent	1637242.30	2021-09-01	\N
119	rent	6875200.10	2022-12-05	\N
120	electricity	6842735.67	2022-07-14	\N
121	electricity	8936310.13	2020-05-22	\N
122	other	166153.12	2024-03-12	\N
123	rent	1368456.77	2020-02-12	\N
124	water	3664564.37	2024-05-30	\N
125	other	8143839.62	2024-01-31	\N
126	tax	797600.23	2024-12-11	\N
127	rent	1152313.94	2022-08-27	\N
128	other	3971205.63	2021-01-09	\N
129	tax	7611022.48	2021-08-16	\N
130	rent	6908883.84	2020-02-29	\N
131	rent	4674981.78	2022-02-17	\N
132	tax	5334209.89	2022-12-20	\N
133	water	9630617.21	2021-02-09	\N
134	electricity	1590634.45	2021-03-17	\N
135	electricity	4077788.83	2020-02-06	\N
136	tax	9206672.59	2024-04-22	\N
137	rent	5763030.59	2021-11-28	\N
138	rent	3714896.62	2021-05-07	\N
139	electricity	8699118.09	2021-01-28	\N
140	rent	7014126.06	2023-03-13	\N
141	rent	3484362.03	2021-06-08	\N
142	tax	4114263.51	2025-05-18	\N
143	tax	233164.59	2024-05-28	\N
144	other	948453.33	2024-10-24	\N
145	electricity	9227073.29	2021-07-02	\N
146	electricity	6094959.55	2022-11-13	\N
147	electricity	1121481.43	2022-06-04	\N
148	electricity	2232956.22	2021-08-17	\N
149	water	8369630.28	2023-02-16	\N
150	other	9337287.39	2022-08-25	\N
151	electricity	9880650.46	2020-04-03	\N
152	rent	5948772.80	2020-04-27	\N
153	tax	6096313.97	2021-02-08	\N
154	rent	2720687.74	2021-02-26	\N
155	water	2105124.11	2020-06-29	\N
156	electricity	9839686.92	2021-10-19	\N
157	tax	413027.53	2020-09-08	\N
158	other	510257.81	2024-05-24	\N
159	water	6668160.25	2024-03-29	\N
160	water	9395622.48	2021-11-15	\N
161	rent	7038148.67	2023-04-28	\N
162	water	168904.32	2022-02-04	\N
163	water	5475398.51	2021-10-02	\N
164	tax	9955549.61	2024-08-06	\N
165	tax	6180537.89	2021-01-13	\N
166	other	4516728.01	2024-05-17	\N
167	rent	9810452.59	2020-01-18	\N
168	other	6284797.94	2022-06-25	\N
169	electricity	6769651.26	2020-09-30	\N
170	rent	9518728.16	2023-06-16	\N
171	other	5376097.21	2020-02-10	\N
172	rent	4077086.25	2020-04-21	\N
173	electricity	3278543.72	2021-10-29	\N
174	electricity	1733034.53	2021-10-18	\N
175	electricity	1329767.03	2023-03-31	\N
176	rent	3690886.70	2024-02-02	\N
177	other	557144.70	2022-03-01	\N
178	water	5268283.38	2021-11-01	\N
179	electricity	3109100.78	2025-03-09	\N
180	rent	352224.63	2022-01-29	\N
181	water	6675411.98	2024-12-07	\N
182	other	1570661.19	2023-10-27	\N
183	electricity	4963538.26	2020-02-03	\N
184	other	9941657.93	2020-10-03	\N
185	water	6436312.51	2020-06-23	\N
186	electricity	7000931.96	2023-11-05	\N
187	rent	4924644.53	2021-01-02	\N
188	rent	8335967.36	2022-02-01	\N
189	other	7441688.37	2021-05-22	\N
190	other	6291315.49	2020-02-25	\N
191	rent	9678768.38	2024-08-28	\N
192	rent	4085140.61	2023-06-10	\N
193	water	4041595.81	2020-09-02	\N
194	other	4868194.64	2021-09-10	\N
195	other	7479828.86	2020-04-16	\N
196	water	7204189.37	2024-03-21	\N
197	water	3422180.97	2024-12-27	\N
198	rent	3891573.29	2021-02-11	\N
199	electricity	9636762.49	2022-06-20	\N
200	water	9414522.75	2022-06-05	\N
201	other	1250765.71	2020-10-18	\N
202	rent	5508742.90	2021-02-19	\N
203	tax	7004403.50	2020-08-24	\N
204	water	3865102.80	2022-09-05	\N
205	rent	8252413.10	2020-04-28	\N
206	water	3178282.83	2020-06-10	\N
207	tax	3155382.84	2021-02-06	\N
208	rent	5958041.99	2024-11-24	\N
209	electricity	7448533.81	2021-11-30	\N
210	rent	5186650.76	2023-04-09	\N
211	other	7105259.19	2021-05-31	\N
212	water	6107137.01	2020-11-04	\N
213	electricity	4210454.29	2024-10-22	\N
214	rent	468247.57	2025-02-26	\N
215	rent	8013150.00	2021-09-08	\N
216	tax	8948257.17	2024-05-30	\N
217	rent	8309372.92	2021-01-07	\N
218	electricity	5423500.90	2025-05-13	\N
219	water	8436974.66	2020-07-25	\N
220	rent	3277935.16	2022-08-16	\N
221	rent	2017875.17	2020-08-22	\N
222	other	3801561.70	2020-08-15	\N
223	water	3759340.11	2023-09-13	\N
224	water	3107615.32	2020-03-20	\N
225	electricity	1189873.05	2022-12-09	\N
226	other	2772833.36	2021-09-22	\N
227	rent	2879842.88	2022-12-05	\N
228	rent	1353229.32	2024-08-12	\N
229	tax	2970054.87	2024-07-28	\N
230	other	5568795.91	2024-11-18	\N
231	rent	7607484.81	2022-02-14	\N
232	rent	6235825.41	2024-01-17	\N
233	water	8692313.59	2020-07-31	\N
234	electricity	4973737.05	2023-10-20	\N
235	electricity	5008037.54	2022-01-11	\N
236	water	2000022.36	2024-07-17	\N
237	electricity	1793885.02	2024-05-02	\N
238	rent	2101594.82	2020-06-05	\N
239	rent	7036020.46	2021-04-25	\N
240	rent	4616152.55	2024-08-02	\N
241	tax	8378778.45	2021-02-03	\N
242	tax	7828947.70	2024-09-03	\N
243	water	7545192.35	2021-06-14	\N
244	water	1325491.00	2020-05-06	\N
245	tax	4766753.45	2021-12-23	\N
246	electricity	4255921.44	2023-07-21	\N
247	other	5342720.13	2024-09-26	\N
248	electricity	4022755.85	2022-11-04	\N
249	electricity	4266682.54	2020-03-03	\N
250	electricity	6912243.83	2024-09-24	\N
251	rent	5692532.51	2021-06-09	\N
252	rent	912602.76	2020-01-17	\N
253	other	964405.97	2022-07-22	\N
254	water	6493575.25	2021-12-02	\N
255	electricity	6995174.75	2024-12-19	\N
256	tax	7052330.15	2020-09-22	\N
257	other	1439221.15	2021-11-20	\N
258	tax	5467709.04	2021-06-24	\N
259	other	6379215.20	2020-03-04	\N
260	tax	3915321.36	2023-09-08	\N
261	tax	1913692.70	2023-06-07	\N
262	water	9181270.20	2022-12-10	\N
263	water	7644410.99	2023-12-03	\N
264	water	1843526.69	2024-01-01	\N
265	tax	6500256.77	2023-06-22	\N
266	tax	4163205.86	2024-12-19	\N
267	other	9710980.40	2024-06-17	\N
268	electricity	2013928.36	2024-12-20	\N
269	electricity	3401946.83	2020-12-23	\N
270	water	5407904.80	2020-09-03	\N
271	tax	4306513.57	2023-02-04	\N
272	tax	618084.09	2022-11-03	\N
273	rent	3346306.05	2022-08-20	\N
274	rent	942467.67	2023-03-12	\N
275	electricity	435143.99	2022-09-29	\N
276	electricity	3990964.61	2024-11-11	\N
277	tax	6651087.33	2023-01-10	\N
278	water	8891343.78	2022-09-21	\N
279	tax	8116713.42	2025-03-10	\N
280	water	2411370.90	2025-05-14	\N
281	rent	9162441.72	2024-07-20	\N
282	tax	6947098.62	2024-01-15	\N
283	electricity	2039718.55	2021-09-12	\N
284	electricity	9330144.39	2022-12-26	\N
285	tax	9706199.07	2023-01-15	\N
286	water	5389868.31	2024-12-26	\N
287	electricity	9960462.00	2021-08-15	\N
288	tax	8516743.89	2020-09-06	\N
289	tax	2109946.14	2023-11-06	\N
290	tax	4515224.18	2021-12-13	\N
291	tax	7731781.31	2024-10-10	\N
292	tax	2330905.28	2020-02-01	\N
293	water	1323899.90	2020-11-07	\N
294	other	9752479.45	2021-12-26	\N
295	rent	5314913.00	2025-01-31	\N
296	water	4587114.52	2025-05-02	\N
297	electricity	6476340.10	2020-08-16	\N
298	rent	9691074.96	2022-06-11	\N
299	other	8617882.17	2022-03-13	\N
300	water	5921091.80	2022-09-30	\N
301	tax	4865196.18	2024-04-21	\N
302	tax	8040561.65	2021-10-09	\N
303	water	8826974.03	2023-05-19	\N
304	water	800533.49	2020-09-21	\N
305	tax	6253968.36	2024-01-10	\N
306	rent	1918342.62	2024-12-16	\N
307	water	2168445.58	2020-05-25	\N
308	electricity	8148353.80	2023-02-26	\N
309	electricity	8583700.10	2024-09-25	\N
310	tax	9919479.00	2022-12-07	\N
311	electricity	7496369.06	2020-08-27	\N
312	electricity	5453425.69	2022-02-27	\N
313	other	6966001.63	2025-05-08	\N
314	other	609288.67	2022-08-17	\N
315	rent	3483069.15	2024-08-28	\N
316	other	7752196.49	2020-02-18	\N
317	electricity	4566261.13	2023-02-18	\N
318	electricity	327514.10	2025-03-23	\N
319	other	7800677.86	2020-04-10	\N
320	tax	3753437.04	2024-03-16	\N
321	tax	153019.65	2024-11-24	\N
322	tax	1993352.60	2023-07-18	\N
323	electricity	1746462.13	2021-03-09	\N
324	rent	165807.56	2024-12-12	\N
325	other	8921576.88	2024-05-13	\N
326	tax	6161846.09	2022-10-03	\N
327	electricity	4050479.74	2024-11-28	\N
328	tax	1181953.85	2023-01-07	\N
329	water	1284894.85	2023-04-12	\N
330	other	764736.21	2020-02-29	\N
331	water	1438257.19	2020-02-23	\N
332	other	6674645.51	2022-12-26	\N
333	tax	954751.39	2024-08-02	\N
334	water	3454952.60	2023-11-02	\N
335	rent	8398403.76	2024-04-30	\N
336	water	8443057.41	2021-05-18	\N
337	water	5703963.28	2020-10-27	\N
338	rent	9835255.03	2021-11-26	\N
339	other	2894347.26	2023-02-28	\N
340	water	3130197.24	2024-09-12	\N
341	electricity	7725349.81	2021-02-25	\N
342	rent	2861941.29	2021-05-14	\N
343	tax	4677168.76	2024-10-12	\N
344	water	5458395.81	2021-05-22	\N
345	tax	9115778.94	2021-07-17	\N
346	other	5330759.39	2021-03-18	\N
347	other	677649.32	2021-08-02	\N
348	tax	343253.10	2025-02-04	\N
349	water	2256610.49	2023-08-26	\N
350	rent	9716121.90	2023-02-27	\N
351	electricity	4404123.50	2020-05-14	\N
352	water	107941.09	2020-07-27	\N
353	tax	3094337.86	2021-07-09	\N
354	other	3035267.51	2024-06-17	\N
355	electricity	4010301.78	2023-10-29	\N
356	water	9675500.39	2022-08-26	\N
357	tax	7879206.52	2021-10-30	\N
358	tax	3422292.62	2020-11-13	\N
359	electricity	7777358.65	2020-08-20	\N
360	tax	9843876.33	2024-12-08	\N
361	water	5862480.50	2021-02-23	\N
362	tax	1443677.89	2021-10-19	\N
363	other	3016930.98	2023-06-24	\N
364	other	3111541.11	2020-04-04	\N
365	water	101799.42	2022-02-24	\N
366	other	6801807.40	2022-07-04	\N
367	electricity	6979052.29	2021-01-09	\N
368	water	6250760.77	2024-04-28	\N
369	rent	9169591.29	2024-12-23	\N
370	rent	943120.06	2024-02-05	\N
371	electricity	135790.58	2021-03-04	\N
372	other	6147203.02	2023-11-21	\N
373	tax	2205516.43	2023-06-07	\N
374	rent	9309858.72	2020-08-01	\N
375	rent	340372.12	2024-09-06	\N
376	other	5800040.83	2023-09-24	\N
377	water	465081.03	2022-06-18	\N
378	other	4093415.70	2022-02-26	\N
379	other	5264094.25	2024-04-09	\N
380	tax	313308.67	2024-02-11	\N
381	tax	4257080.45	2022-08-20	\N
382	rent	6275461.73	2023-09-07	\N
383	rent	7317200.94	2023-06-10	\N
384	water	857444.92	2020-09-14	\N
385	water	3653082.51	2021-12-09	\N
386	rent	8082600.80	2023-01-23	\N
387	rent	6569176.10	2022-06-07	\N
388	tax	5933279.75	2020-03-16	\N
389	electricity	357304.86	2024-06-14	\N
390	other	7897923.96	2023-05-01	\N
391	rent	2613180.25	2023-12-16	\N
392	other	6864983.12	2021-08-18	\N
393	other	1823307.98	2024-09-27	\N
394	rent	2713980.65	2024-03-10	\N
395	rent	2456285.64	2021-02-23	\N
396	electricity	5041241.77	2024-01-29	\N
397	electricity	450361.08	2024-09-06	\N
398	other	2968132.66	2023-05-03	\N
399	tax	9761818.24	2021-11-16	\N
400	electricity	4799615.54	2021-06-11	\N
401	rent	5668832.41	2023-10-07	\N
402	other	2370583.90	2022-01-12	\N
403	tax	3827249.91	2025-05-06	\N
404	rent	2650492.22	2023-02-05	\N
405	tax	3859610.64	2020-04-05	\N
406	electricity	5634643.17	2025-05-11	\N
407	water	5739500.57	2021-01-12	\N
408	electricity	2651213.68	2022-03-22	\N
409	tax	684619.23	2020-07-10	\N
410	electricity	3841635.06	2024-12-19	\N
411	rent	7013155.02	2024-06-20	\N
412	tax	9898949.64	2021-08-07	\N
413	tax	2337310.19	2020-01-07	\N
414	electricity	8476209.07	2024-02-24	\N
415	electricity	175131.41	2022-02-17	\N
416	water	1519132.13	2023-05-27	\N
417	rent	6027299.85	2021-02-26	\N
418	electricity	913110.39	2020-03-08	\N
419	tax	4820311.10	2024-12-26	\N
420	electricity	7684143.62	2023-02-21	\N
421	electricity	9910198.56	2023-06-11	\N
422	electricity	6548829.58	2021-02-17	\N
423	tax	3707632.77	2021-12-20	\N
424	other	4732939.46	2021-01-16	\N
425	rent	5628246.05	2022-10-27	\N
426	tax	6703172.53	2022-09-09	\N
427	rent	2690137.95	2020-08-14	\N
428	other	5485357.95	2024-05-07	\N
429	other	6069224.31	2020-11-10	\N
430	water	6760381.86	2020-02-22	\N
431	tax	946313.96	2025-05-03	\N
432	electricity	9582823.57	2023-01-28	\N
433	rent	3930042.21	2020-07-01	\N
434	electricity	7593606.36	2022-03-05	\N
435	tax	9815401.60	2024-02-18	\N
436	other	4644339.02	2023-07-08	\N
437	other	5259661.95	2020-05-12	\N
438	rent	2110133.56	2020-05-30	\N
439	tax	9292177.52	2025-04-30	\N
440	water	4582633.51	2023-11-15	\N
441	rent	4920896.30	2024-02-01	\N
442	tax	4698349.76	2025-03-01	\N
443	rent	4056027.63	2020-09-09	\N
444	electricity	2920766.96	2021-09-23	\N
445	electricity	2364717.27	2021-10-25	\N
446	tax	7263282.04	2025-01-29	\N
447	other	1178650.18	2024-05-15	\N
448	water	5374119.61	2024-08-05	\N
449	water	3185558.24	2021-05-05	\N
450	tax	3713606.02	2020-05-29	\N
451	rent	2467099.15	2023-03-19	\N
452	tax	3325508.60	2024-09-04	\N
453	electricity	556377.17	2020-04-07	\N
454	rent	4641727.00	2023-02-17	\N
455	other	8375602.83	2025-01-28	\N
456	other	1656955.49	2024-06-13	\N
457	tax	3025519.53	2020-03-15	\N
458	electricity	5139124.35	2020-06-17	\N
459	water	5490246.77	2020-10-18	\N
460	electricity	321770.42	2024-02-26	\N
461	rent	2060112.13	2021-06-01	\N
462	tax	4929987.19	2023-02-23	\N
463	water	2906756.72	2020-06-08	\N
464	other	7258423.48	2022-11-06	\N
465	other	8371288.77	2023-07-06	\N
466	electricity	8557824.31	2020-11-16	\N
467	electricity	7425228.24	2020-06-25	\N
468	water	618666.82	2022-08-28	\N
469	water	5931677.59	2020-05-14	\N
470	electricity	4888343.04	2023-06-05	\N
471	other	9419536.10	2021-05-05	\N
472	electricity	2841556.29	2021-01-08	\N
473	electricity	1884932.99	2023-05-05	\N
474	rent	9778994.38	2022-09-03	\N
475	tax	382433.69	2021-11-03	\N
476	rent	7319768.09	2024-12-03	\N
477	rent	6732179.55	2022-01-15	\N
478	rent	1271400.58	2023-04-12	\N
479	rent	4915416.07	2024-02-17	\N
480	electricity	1626997.89	2024-02-28	\N
481	rent	3749662.70	2025-02-11	\N
482	electricity	7512064.44	2020-02-03	\N
483	rent	952713.40	2022-03-28	\N
484	water	3205472.53	2022-03-03	\N
485	electricity	4801524.15	2023-10-04	\N
486	rent	2713812.57	2020-10-25	\N
487	electricity	5170656.86	2022-03-20	\N
488	water	4764806.31	2024-07-18	\N
489	other	5115592.70	2023-05-14	\N
490	water	5363807.13	2024-01-27	\N
491	electricity	2385848.84	2023-10-26	\N
492	electricity	2701863.34	2023-09-15	\N
493	tax	4898034.89	2022-07-09	\N
494	water	2666140.58	2023-04-09	\N
495	rent	6041320.08	2025-03-03	\N
496	other	2463936.97	2020-04-04	\N
497	tax	5571262.45	2020-12-25	\N
498	water	7090407.32	2022-01-02	\N
499	tax	2220955.71	2024-12-09	\N
500	water	6227773.76	2024-06-13	\N
501	tax	7072622.20	2023-08-25	\N
502	water	5026383.31	2023-07-18	\N
503	other	8154408.46	2022-03-16	\N
504	rent	6205399.78	2023-02-16	\N
505	rent	9461076.38	2024-03-14	\N
506	tax	5830522.40	2020-10-10	\N
507	other	830538.47	2021-07-09	\N
508	electricity	7265974.25	2020-09-25	\N
509	other	6739692.51	2020-02-06	\N
510	other	5962873.86	2023-05-27	\N
511	electricity	421328.47	2020-02-16	\N
512	other	5105591.37	2023-01-12	\N
513	electricity	174798.47	2022-05-24	\N
514	water	319418.70	2020-12-02	\N
515	other	2775313.88	2020-05-03	\N
516	water	9705761.79	2022-04-18	\N
517	electricity	183402.43	2024-09-20	\N
518	other	8294137.05	2023-01-13	\N
519	water	2000044.24	2023-11-23	\N
520	tax	9977590.56	2024-07-11	\N
521	other	5262664.61	2024-06-04	\N
522	electricity	7313492.55	2022-09-06	\N
523	tax	2795384.02	2025-04-11	\N
524	other	4397144.61	2022-10-27	\N
525	rent	9905317.31	2021-05-23	\N
526	rent	3618504.92	2022-06-16	\N
527	rent	2568565.76	2023-03-24	\N
528	rent	1039854.70	2024-04-08	\N
529	rent	557895.56	2021-02-03	\N
530	rent	7572687.65	2023-11-02	\N
531	other	8456987.29	2021-08-31	\N
532	rent	1666345.23	2023-12-01	\N
533	tax	1644737.82	2024-12-20	\N
534	rent	1220836.53	2024-03-25	\N
535	rent	2887130.88	2025-04-13	\N
536	other	1872652.83	2020-12-16	\N
537	rent	3443487.36	2024-06-14	\N
538	water	2470631.12	2021-12-30	\N
539	other	3169484.63	2024-08-04	\N
540	electricity	4085139.83	2024-03-17	\N
541	other	7509338.91	2024-09-27	\N
542	electricity	2917244.98	2021-02-12	\N
543	electricity	5386835.20	2023-12-29	\N
544	water	2371273.39	2020-02-22	\N
545	electricity	3828027.23	2020-09-24	\N
546	rent	8885592.84	2024-09-25	\N
547	other	2101809.13	2025-04-12	\N
548	tax	1319908.76	2020-05-27	\N
549	other	9121994.23	2024-10-29	\N
550	other	286719.44	2022-09-10	\N
551	other	1935937.35	2021-12-14	\N
552	rent	1789864.90	2024-04-27	\N
553	electricity	1095877.64	2021-09-08	\N
554	rent	7767390.21	2022-04-26	\N
555	electricity	7926467.55	2020-10-01	\N
556	tax	8279555.59	2024-05-23	\N
557	tax	4361437.52	2024-10-31	\N
558	other	6111746.59	2020-02-14	\N
559	electricity	4701387.30	2024-03-17	\N
560	electricity	5399261.67	2020-04-09	\N
561	other	6774596.45	2024-09-07	\N
562	rent	8805852.95	2023-10-13	\N
563	rent	3832248.39	2020-03-24	\N
564	other	6140150.19	2024-05-24	\N
565	electricity	8631473.73	2023-12-16	\N
566	water	1005832.20	2022-12-27	\N
567	rent	255187.33	2023-07-15	\N
568	electricity	2749172.11	2024-02-16	\N
569	electricity	1714897.17	2021-03-05	\N
570	electricity	5228630.10	2021-06-09	\N
571	other	9869304.60	2024-01-26	\N
572	tax	2347251.31	2022-05-11	\N
573	other	6265678.37	2022-02-02	\N
574	electricity	5307131.79	2021-05-10	\N
575	tax	6529073.09	2023-10-14	\N
576	rent	5723157.94	2023-07-29	\N
577	rent	4769233.46	2024-07-16	\N
578	water	5775892.03	2022-02-17	\N
579	electricity	4819267.30	2024-06-07	\N
580	tax	4137672.20	2023-05-30	\N
581	other	3085426.36	2023-09-02	\N
582	rent	5175148.88	2022-09-22	\N
583	water	1986933.71	2025-04-11	\N
584	electricity	863885.06	2020-04-07	\N
585	rent	3031346.90	2023-02-20	\N
586	other	5439767.44	2023-04-29	\N
587	other	2272075.50	2021-07-06	\N
588	rent	7662944.94	2022-09-26	\N
589	tax	8311965.70	2020-05-06	\N
590	rent	9475348.49	2024-12-26	\N
591	other	208223.73	2020-12-14	\N
592	rent	4766812.76	2020-10-09	\N
593	electricity	684160.47	2020-08-08	\N
594	water	4589140.93	2021-01-28	\N
595	rent	3631382.57	2023-10-11	\N
596	rent	493168.23	2022-11-01	\N
597	electricity	3762324.60	2021-03-08	\N
598	rent	907785.41	2023-06-05	\N
599	water	1916657.88	2020-07-29	\N
600	water	8273873.19	2021-08-11	\N
601	tax	2949806.97	2023-08-23	\N
602	water	161768.29	2021-01-09	\N
603	other	7184103.94	2022-02-16	\N
604	tax	8309357.43	2020-10-23	\N
605	tax	1234478.64	2025-04-22	\N
606	water	8997602.65	2023-08-16	\N
607	water	9563671.45	2022-02-26	\N
608	rent	8656458.65	2021-12-29	\N
609	water	3035868.68	2021-09-20	\N
610	electricity	8992072.51	2023-09-11	\N
611	rent	1747534.37	2022-07-27	\N
612	electricity	7370055.83	2021-12-23	\N
613	other	4784465.11	2025-03-13	\N
614	water	9745689.03	2024-06-19	\N
615	other	2768983.18	2023-05-28	\N
616	other	1770500.23	2023-11-13	\N
617	electricity	9949184.12	2020-03-03	\N
618	water	6546121.34	2023-11-09	\N
619	electricity	3099603.19	2023-12-26	\N
620	water	2146598.39	2024-08-09	\N
621	water	9398825.90	2020-06-16	\N
622	tax	9042027.49	2021-07-01	\N
623	electricity	1139735.99	2023-09-27	\N
624	water	1892147.32	2020-08-07	\N
625	tax	3268252.91	2024-11-25	\N
626	rent	2278072.58	2024-04-24	\N
627	tax	4770569.96	2024-08-15	\N
628	rent	4364793.45	2022-07-08	\N
629	other	9615771.84	2022-01-22	\N
630	electricity	5192598.41	2022-11-22	\N
631	rent	619743.25	2022-03-04	\N
632	water	2654077.71	2023-07-04	\N
633	water	3560145.14	2022-01-19	\N
634	tax	3905930.38	2025-05-14	\N
635	tax	6220901.60	2020-11-20	\N
636	electricity	6199430.21	2025-03-27	\N
637	electricity	7363535.72	2023-10-03	\N
638	other	2540948.21	2022-12-13	\N
639	tax	6627176.11	2020-12-26	\N
640	other	8250476.16	2024-11-25	\N
641	electricity	2492744.38	2024-04-16	\N
642	rent	7914565.83	2020-09-09	\N
643	water	857086.07	2020-04-30	\N
644	other	7379620.39	2021-06-22	\N
645	other	2432773.97	2021-12-14	\N
646	electricity	8612802.12	2024-09-03	\N
647	water	6294621.20	2024-07-26	\N
648	tax	3215541.34	2020-05-30	\N
649	other	2656296.46	2020-05-08	\N
650	other	8610264.05	2021-06-18	\N
651	rent	5929363.70	2024-06-20	\N
652	water	5031801.63	2023-11-01	\N
653	tax	5879336.68	2021-06-13	\N
654	tax	480663.24	2021-02-04	\N
655	tax	8237778.81	2021-02-09	\N
656	other	7473176.42	2022-04-12	\N
657	tax	4354218.85	2020-08-25	\N
658	electricity	8667783.60	2020-12-02	\N
659	tax	3476826.83	2022-04-09	\N
660	rent	3197729.20	2022-10-29	\N
661	electricity	8780769.68	2024-05-24	\N
662	electricity	2511111.81	2023-08-07	\N
663	electricity	8652667.61	2020-12-30	\N
664	electricity	2119319.60	2020-10-03	\N
665	rent	3341158.73	2024-08-06	\N
666	tax	7262780.40	2024-06-29	\N
667	electricity	2245587.07	2020-11-09	\N
668	tax	8293416.21	2025-04-27	\N
669	electricity	6189823.58	2023-01-11	\N
670	rent	4830147.67	2022-11-23	\N
671	tax	3187910.99	2020-10-28	\N
672	rent	1384808.58	2025-05-22	\N
673	water	5924306.80	2025-05-16	\N
674	electricity	6347268.30	2021-04-10	\N
675	electricity	4390135.74	2024-05-08	\N
676	other	5673978.76	2022-02-04	\N
677	electricity	1660241.44	2021-01-02	\N
678	rent	2738331.48	2021-04-06	\N
679	tax	9958113.22	2024-02-10	\N
680	electricity	4250492.99	2025-04-22	\N
681	other	4524140.18	2025-02-01	\N
682	other	3084216.15	2020-01-12	\N
683	tax	2698144.91	2021-09-04	\N
684	tax	6149438.69	2020-07-01	\N
685	rent	7029046.87	2025-03-28	\N
686	other	8592524.99	2021-05-03	\N
687	other	5962134.35	2022-08-16	\N
688	other	4947807.37	2023-01-18	\N
689	rent	4507474.91	2024-02-18	\N
690	water	3526453.01	2023-07-15	\N
691	rent	3283626.91	2021-03-07	\N
692	rent	7305143.60	2025-01-24	\N
693	tax	3808500.69	2024-05-16	\N
694	other	514303.72	2022-07-07	\N
695	rent	7445396.47	2020-06-04	\N
696	tax	1470120.60	2020-02-16	\N
697	electricity	3556329.12	2022-10-15	\N
698	water	5790840.14	2022-02-13	\N
699	rent	5401405.36	2021-05-03	\N
700	water	4855998.69	2022-01-24	\N
701	electricity	2895143.71	2020-01-29	\N
702	rent	8159220.23	2020-06-03	\N
703	water	6370089.23	2020-04-24	\N
704	tax	2448665.25	2023-11-07	\N
705	tax	8685681.75	2023-01-10	\N
706	other	7956899.82	2024-07-29	\N
707	rent	590104.93	2022-12-27	\N
708	water	7199878.64	2021-02-04	\N
709	rent	4528181.78	2023-05-18	\N
710	water	5149300.42	2020-03-15	\N
711	electricity	3265777.25	2022-10-21	\N
712	electricity	6940654.85	2024-03-27	\N
713	other	1881002.50	2024-08-24	\N
714	tax	1673227.73	2023-10-10	\N
715	other	6780413.14	2023-10-04	\N
716	other	2394495.32	2023-01-17	\N
717	tax	9423392.42	2022-03-06	\N
718	electricity	4921406.95	2021-11-08	\N
719	other	742253.95	2024-08-31	\N
720	electricity	8882938.06	2021-08-20	\N
721	tax	9146811.64	2020-08-28	\N
722	water	2698016.29	2022-01-04	\N
723	rent	4685872.81	2024-10-14	\N
724	electricity	9723869.94	2024-03-27	\N
725	electricity	3978563.51	2020-01-06	\N
726	other	5141622.75	2020-04-22	\N
727	electricity	1423525.13	2021-02-06	\N
728	tax	1619984.47	2022-10-15	\N
729	water	8769733.73	2022-10-06	\N
730	electricity	4895050.82	2022-03-03	\N
731	tax	5631335.83	2025-04-30	\N
732	water	6871852.04	2022-09-10	\N
733	rent	7943634.51	2023-11-03	\N
734	tax	1412531.91	2023-03-07	\N
735	water	2277061.74	2023-03-08	\N
736	water	6734964.02	2023-04-13	\N
737	tax	5479627.13	2022-01-05	\N
738	water	4414829.71	2023-10-06	\N
739	rent	997389.70	2023-11-14	\N
740	tax	6325117.51	2024-09-02	\N
741	tax	4574254.24	2021-02-20	\N
742	electricity	516793.34	2021-04-04	\N
743	rent	9153620.30	2024-01-22	\N
744	tax	6018398.99	2021-02-14	\N
745	water	9016278.63	2025-02-12	\N
746	tax	5968267.67	2022-04-14	\N
747	tax	249083.70	2021-01-24	\N
748	tax	6477454.25	2025-04-10	\N
749	other	214161.86	2020-10-15	\N
750	water	7631578.23	2020-08-26	\N
751	tax	9765162.66	2022-05-08	\N
752	tax	7519930.76	2022-06-27	\N
753	other	1333204.54	2022-01-13	\N
754	tax	7000555.46	2024-12-28	\N
755	tax	3856527.33	2020-11-17	\N
756	tax	1867817.81	2020-05-29	\N
757	water	3046668.60	2023-03-25	\N
758	rent	8090428.82	2022-09-13	\N
759	electricity	6568296.29	2022-10-15	\N
760	tax	524608.12	2022-02-08	\N
761	other	5896623.58	2024-06-18	\N
762	water	6082724.35	2020-07-30	\N
763	water	9107284.85	2023-03-31	\N
764	electricity	9092151.54	2024-02-09	\N
765	electricity	8186349.51	2024-04-02	\N
766	electricity	9434849.55	2025-04-16	\N
767	water	917876.68	2022-09-21	\N
768	rent	3952573.85	2024-06-09	\N
769	rent	5376995.01	2022-04-07	\N
770	water	9033388.45	2024-04-16	\N
771	other	2104842.28	2023-11-07	\N
772	water	1285571.45	2024-07-21	\N
773	electricity	6069851.08	2024-11-14	\N
774	other	6222851.63	2022-04-08	\N
775	tax	4162544.72	2021-06-21	\N
776	water	6828756.78	2022-11-20	\N
777	other	3818134.42	2020-06-02	\N
778	water	4944668.63	2024-07-07	\N
779	rent	8881586.78	2020-10-06	\N
780	tax	4503859.85	2020-11-06	\N
781	electricity	5866402.81	2022-10-14	\N
782	rent	8223425.51	2020-04-11	\N
783	electricity	7915826.91	2022-04-05	\N
784	electricity	484348.00	2023-05-22	\N
785	electricity	2748104.82	2023-02-17	\N
786	rent	913556.78	2021-12-26	\N
787	rent	3926841.85	2022-03-17	\N
788	rent	7032662.89	2025-05-09	\N
789	other	6504299.52	2020-12-08	\N
790	tax	4712883.57	2021-10-17	\N
791	other	9597274.12	2024-08-27	\N
792	water	6852446.26	2023-01-25	\N
793	rent	5267983.11	2024-02-03	\N
794	tax	8635879.53	2024-10-12	\N
795	tax	3219319.40	2024-04-27	\N
796	water	9631561.91	2021-07-22	\N
797	water	5718513.27	2021-02-28	\N
798	electricity	6382700.20	2023-08-02	\N
799	rent	9682370.35	2022-11-17	\N
800	other	7133529.79	2024-07-09	\N
801	water	7371926.11	2023-02-19	\N
802	tax	8744337.69	2020-01-10	\N
803	tax	3704142.82	2023-08-09	\N
804	electricity	8857922.76	2024-08-28	\N
805	other	5439020.77	2023-08-16	\N
806	rent	3270141.43	2020-07-12	\N
807	other	5771027.78	2024-05-25	\N
808	other	3815667.63	2021-04-09	\N
809	electricity	3192959.58	2020-05-15	\N
810	other	8203615.93	2023-05-22	\N
811	water	4752713.40	2025-01-16	\N
812	rent	5155108.76	2025-02-11	\N
813	tax	8312044.47	2021-05-13	\N
814	other	6773283.83	2023-04-27	\N
815	tax	2544436.42	2023-01-17	\N
816	tax	6050956.40	2025-05-02	\N
817	other	4992561.06	2024-06-22	\N
818	electricity	6405795.66	2021-12-23	\N
819	tax	4408747.05	2021-01-21	\N
820	rent	9691929.20	2021-02-19	\N
821	tax	4051531.49	2022-08-13	\N
822	electricity	1498446.04	2024-04-25	\N
823	electricity	4046057.90	2023-06-17	\N
824	tax	8663775.02	2020-03-25	\N
825	other	421539.42	2021-12-06	\N
826	electricity	2427694.76	2020-07-03	\N
827	other	3438620.09	2024-05-13	\N
828	electricity	4931327.91	2024-05-14	\N
829	tax	9369086.33	2020-10-26	\N
830	water	7740545.86	2024-04-09	\N
831	other	8411253.14	2021-02-20	\N
832	tax	9135196.27	2024-02-16	\N
833	water	194640.36	2021-10-12	\N
834	rent	9737983.31	2020-05-07	\N
835	other	675480.14	2023-12-12	\N
836	water	1542279.92	2021-06-25	\N
837	electricity	9500014.65	2024-03-03	\N
838	rent	1626697.58	2024-08-03	\N
839	electricity	3232755.96	2024-06-10	\N
840	rent	3873316.20	2024-07-25	\N
841	rent	713536.39	2024-03-03	\N
842	rent	5408071.37	2023-11-15	\N
843	tax	4615257.94	2023-05-10	\N
844	electricity	7313580.73	2021-12-05	\N
845	rent	3930958.09	2020-03-15	\N
846	tax	776950.00	2021-11-13	\N
847	rent	9042084.86	2024-02-27	\N
848	rent	6045654.14	2024-04-23	\N
849	tax	5516710.36	2023-05-08	\N
850	other	7155030.50	2020-10-26	\N
851	other	1208901.41	2024-06-19	\N
852	electricity	1923501.94	2024-04-17	\N
853	rent	9999844.42	2023-08-24	\N
854	rent	9709987.62	2025-03-01	\N
855	rent	3413409.77	2024-03-31	\N
856	rent	6954677.78	2022-01-28	\N
857	tax	7844154.72	2020-10-19	\N
858	electricity	8346119.77	2023-11-03	\N
859	tax	1451625.93	2023-01-24	\N
860	other	2365873.09	2023-11-26	\N
861	tax	1627476.14	2020-07-24	\N
862	tax	4540771.80	2025-03-06	\N
863	tax	8963574.28	2023-04-27	\N
864	other	7220100.61	2022-07-03	\N
865	tax	3286449.73	2021-04-27	\N
866	tax	5840623.40	2021-12-19	\N
867	electricity	7189686.85	2020-06-07	\N
868	tax	9160916.93	2024-12-19	\N
869	other	7766188.61	2023-12-29	\N
870	rent	9612258.51	2025-01-03	\N
871	water	3355372.31	2020-12-03	\N
872	rent	9737788.59	2024-12-15	\N
873	electricity	8622767.02	2024-11-02	\N
874	rent	6325866.74	2022-06-06	\N
875	electricity	3441603.40	2024-08-06	\N
876	electricity	5685521.44	2022-03-17	\N
877	tax	2868271.73	2024-02-12	\N
878	electricity	9903885.15	2021-11-23	\N
879	tax	2336220.50	2022-01-05	\N
880	water	9848523.47	2022-03-03	\N
881	other	9578347.35	2020-12-25	\N
882	other	3459262.54	2021-10-05	\N
883	water	5565882.27	2024-06-18	\N
884	tax	430517.88	2025-05-16	\N
885	tax	8467031.17	2023-08-31	\N
886	tax	8715792.25	2024-08-26	\N
887	water	6910879.77	2023-11-10	\N
888	tax	3855523.53	2021-08-31	\N
889	electricity	7597570.77	2023-05-30	\N
890	tax	533893.04	2025-04-28	\N
891	water	4594398.59	2023-08-02	\N
892	tax	2030467.38	2023-04-11	\N
893	electricity	6960475.83	2024-03-29	\N
894	other	9151755.63	2021-08-25	\N
895	water	224015.18	2022-10-13	\N
896	electricity	8235896.67	2022-12-03	\N
897	other	3346629.59	2023-12-27	\N
898	water	4427473.58	2020-05-11	\N
899	tax	4072381.92	2023-09-22	\N
900	water	9411471.67	2024-10-25	\N
901	tax	1451354.03	2020-03-02	\N
902	rent	1889813.41	2023-06-25	\N
903	electricity	8798274.84	2021-04-06	\N
904	other	8644274.57	2024-03-17	\N
905	tax	339146.32	2024-01-07	\N
906	other	7309341.11	2023-04-02	\N
907	rent	810666.85	2024-03-23	\N
908	tax	8578209.56	2024-04-20	\N
909	tax	9314900.71	2025-04-15	\N
910	water	5163411.75	2021-03-24	\N
911	other	3905599.11	2023-12-04	\N
912	water	2982106.52	2022-01-09	\N
913	other	9178058.04	2023-09-20	\N
914	other	5076062.63	2022-02-20	\N
915	electricity	3338836.35	2020-05-30	\N
916	tax	630632.13	2025-02-12	\N
917	water	5837493.03	2024-06-22	\N
918	rent	2042528.65	2022-03-21	\N
919	tax	8779558.20	2021-08-29	\N
920	water	5416709.38	2024-12-22	\N
921	tax	2390358.23	2023-10-21	\N
922	other	4053112.41	2020-04-21	\N
923	tax	1336555.00	2020-08-09	\N
924	electricity	8974271.13	2022-09-10	\N
925	other	1759026.18	2023-08-16	\N
926	electricity	2590978.34	2020-05-02	\N
927	rent	9431695.21	2021-05-22	\N
928	rent	2199711.19	2024-02-12	\N
929	tax	7865989.42	2023-08-17	\N
930	tax	5681442.14	2024-12-06	\N
931	rent	5232686.63	2022-09-29	\N
932	rent	7209323.95	2023-09-09	\N
933	electricity	7181677.34	2020-04-30	\N
934	tax	3009434.14	2021-02-20	\N
935	water	2806843.84	2022-05-19	\N
936	rent	120894.89	2023-09-15	\N
937	rent	888186.96	2022-07-15	\N
938	water	2694685.95	2024-11-30	\N
939	tax	4931869.05	2020-05-19	\N
940	rent	1146222.80	2024-03-25	\N
941	tax	8171043.96	2022-08-02	\N
942	electricity	6562354.69	2024-02-15	\N
943	tax	7024856.82	2024-09-01	\N
944	water	4671616.96	2023-05-25	\N
945	other	6269631.50	2022-11-03	\N
946	electricity	3119717.40	2022-10-17	\N
947	other	9463485.72	2024-02-15	\N
948	other	1506304.11	2021-10-27	\N
949	water	5228255.33	2021-07-09	\N
950	tax	482197.95	2025-03-25	\N
951	tax	2044351.43	2022-06-29	\N
952	water	4582876.89	2020-02-24	\N
953	tax	966945.01	2020-04-04	\N
954	tax	5341050.50	2024-06-04	\N
955	water	1305465.04	2021-08-16	\N
956	water	8422809.91	2020-05-03	\N
957	water	2498328.13	2020-04-08	\N
958	rent	389778.35	2025-02-25	\N
959	other	1612109.43	2020-07-11	\N
960	electricity	3543186.30	2021-02-09	\N
961	rent	5998054.11	2024-12-14	\N
962	rent	3249389.86	2024-12-03	\N
963	tax	514218.49	2020-04-09	\N
964	other	9613098.74	2021-11-16	\N
965	water	8377416.60	2023-02-13	\N
966	rent	899571.73	2021-05-20	\N
967	other	5615156.20	2023-02-10	\N
968	water	1169254.48	2022-08-31	\N
969	rent	7582221.13	2024-12-27	\N
970	water	1164299.44	2020-11-29	\N
971	other	2195511.69	2022-09-13	\N
972	rent	7329381.33	2023-03-14	\N
973	electricity	7121448.22	2021-04-03	\N
974	electricity	4144293.38	2024-11-12	\N
975	water	9846425.98	2022-05-02	\N
976	electricity	8582701.30	2020-04-09	\N
977	water	9622661.11	2022-11-15	\N
978	electricity	762848.40	2024-04-24	\N
979	other	6994137.20	2025-01-28	\N
980	tax	2507687.28	2022-05-08	\N
981	tax	2622806.62	2024-12-27	\N
982	rent	4915986.45	2020-03-28	\N
983	water	667657.52	2020-08-26	\N
984	water	1984821.91	2021-10-01	\N
985	other	4661937.03	2021-05-19	\N
986	water	3073907.33	2024-11-11	\N
987	electricity	7255889.71	2020-06-29	\N
988	water	2264884.35	2020-09-29	\N
989	other	7519841.52	2024-04-16	\N
990	tax	3865849.48	2023-01-30	\N
991	water	9289534.77	2022-07-14	\N
992	water	2439381.67	2020-12-08	\N
993	electricity	3439604.12	2021-07-15	\N
994	other	2497869.16	2020-06-20	\N
995	electricity	4549760.39	2024-03-23	\N
996	rent	7906325.22	2021-12-02	\N
997	rent	6491596.97	2022-12-13	\N
998	other	5597174.66	2021-07-05	\N
999	other	3234346.64	2022-09-12	\N
1000	water	4754362.71	2022-12-27	\N
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
1	319	2020-04	salary	14631139.63	2020-04-28	\N
2	429	2021-08	bonus	18693209.75	2021-08-11	\N
3	200	2021-04	bonus	13993065.50	2021-04-21	\N
4	16	2024-02	penalty	30573219.30	2024-02-03	\N
5	287	2023-10	bonus	44069551.39	2023-10-12	\N
6	261	2025-02	bonus	35873470.46	2025-02-12	\N
7	1	2024-04	penalty	39613595.43	2024-04-09	\N
8	492	2023-07	bonus	36619999.77	2023-07-07	\N
9	378	2025-01	bonus	43231590.61	2025-01-19	\N
10	340	2021-02	penalty	32653767.41	2021-02-27	\N
11	229	2022-02	salary	41968367.30	2022-02-23	\N
12	34	2024-10	penalty	14087533.00	2024-10-06	\N
13	49	2024-08	bonus	13093302.83	2024-08-19	\N
14	140	2024-10	salary	3614601.93	2024-10-04	\N
15	466	2024-10	salary	24685208.18	2024-10-26	\N
16	463	2025-01	bonus	42666812.94	2025-01-28	\N
17	244	2025-04	bonus	5958199.77	2025-04-05	\N
18	383	2022-12	penalty	2434134.40	2022-12-28	\N
19	290	2022-04	salary	5438225.33	2022-04-26	\N
20	45	2021-09	penalty	2180322.61	2021-09-04	\N
21	448	2024-02	salary	15642040.96	2024-02-14	\N
22	98	2022-10	bonus	10434561.23	2022-10-21	\N
23	312	2022-03	salary	44908209.13	2022-03-26	\N
24	13	2023-11	bonus	10850648.39	2023-11-23	\N
25	479	2020-04	penalty	41476997.15	2020-04-30	\N
26	352	2022-03	bonus	43792999.98	2022-03-17	\N
27	477	2024-05	bonus	10661182.90	2024-05-03	\N
28	269	2020-04	salary	2832102.02	2020-04-14	\N
29	316	2021-06	salary	17261072.30	2021-06-15	\N
30	264	2024-07	penalty	36183464.66	2024-07-10	\N
31	170	2021-03	penalty	13553699.40	2021-03-11	\N
32	71	2021-08	penalty	48683183.65	2021-08-07	\N
33	293	2021-09	bonus	26036546.63	2021-09-12	\N
34	35	2024-04	salary	36637717.31	2024-04-01	\N
35	299	2020-12	bonus	31125238.09	2020-12-05	\N
36	203	2024-08	bonus	5481648.11	2024-08-01	\N
37	391	2022-05	penalty	13427877.90	2022-05-13	\N
38	488	2025-02	penalty	48668559.46	2025-02-15	\N
39	252	2024-02	penalty	25302607.44	2024-02-06	\N
40	245	2020-11	penalty	25759382.70	2020-11-10	\N
41	210	2021-01	bonus	35917477.82	2021-01-21	\N
42	498	2021-12	salary	18703226.75	2021-12-04	\N
43	270	2020-08	bonus	16679804.71	2020-08-07	\N
44	300	2024-10	salary	20823483.53	2024-10-17	\N
45	426	2021-11	penalty	32059980.25	2021-11-24	\N
46	201	2023-09	salary	35067882.61	2023-09-14	\N
47	253	2022-03	salary	47133415.58	2022-03-10	\N
48	93	2021-12	bonus	33433409.73	2021-12-21	\N
49	409	2021-03	penalty	4900346.86	2021-03-03	\N
50	90	2023-01	bonus	19607414.54	2023-01-02	\N
51	365	2024-12	bonus	47014250.63	2024-12-29	\N
52	490	2023-10	bonus	18479415.66	2023-10-19	\N
53	212	2020-09	salary	18122451.88	2020-09-28	\N
54	86	2021-01	bonus	40888650.75	2021-01-12	\N
55	310	2024-11	bonus	49715007.73	2024-11-27	\N
56	113	2021-08	penalty	13396074.20	2021-08-06	\N
57	156	2022-10	salary	21184197.20	2022-10-10	\N
58	375	2023-04	bonus	2443062.19	2023-04-28	\N
59	442	2022-10	bonus	5162319.32	2022-10-30	\N
60	55	2025-04	salary	42609458.53	2025-04-11	\N
61	97	2022-10	bonus	14151384.61	2022-10-05	\N
62	382	2024-09	bonus	19851615.14	2024-09-25	\N
63	352	2022-02	penalty	43317181.32	2022-02-23	\N
64	157	2023-02	bonus	9732641.64	2023-02-04	\N
65	52	2021-05	penalty	2229532.79	2021-05-05	\N
66	499	2020-07	bonus	24397569.71	2020-07-18	\N
67	71	2025-02	bonus	6504976.90	2025-02-02	\N
68	211	2021-12	salary	15513619.69	2021-12-02	\N
69	468	2021-07	bonus	47118991.86	2021-07-19	\N
70	468	2023-06	penalty	32924301.03	2023-06-17	\N
71	193	2022-12	salary	15306356.24	2022-12-22	\N
72	404	2022-10	penalty	46860816.92	2022-10-24	\N
73	86	2023-05	salary	26750278.64	2023-05-07	\N
74	130	2024-12	bonus	46305442.85	2024-12-24	\N
75	1	2024-01	bonus	48496132.37	2024-01-19	\N
76	224	2021-02	bonus	11108032.16	2021-02-19	\N
77	432	2023-06	penalty	6375203.70	2023-06-21	\N
78	86	2020-03	salary	23656216.30	2020-03-19	\N
79	333	2021-11	bonus	43538858.31	2021-11-18	\N
80	389	2023-02	bonus	24789780.53	2023-02-04	\N
81	245	2021-07	bonus	3474876.09	2021-07-03	\N
82	364	2022-09	penalty	1482018.92	2022-09-14	\N
83	140	2020-02	penalty	19362710.26	2020-02-29	\N
84	309	2020-04	bonus	49514481.27	2020-04-09	\N
85	407	2021-08	salary	34444046.40	2021-08-24	\N
86	351	2024-10	salary	35364700.79	2024-10-06	\N
87	198	2020-08	salary	38808150.37	2020-08-27	\N
88	196	2024-11	penalty	7774377.37	2024-11-07	\N
89	461	2020-10	bonus	13947108.62	2020-10-09	\N
90	217	2022-02	penalty	23417112.03	2022-02-20	\N
91	411	2020-10	penalty	37109764.99	2020-10-01	\N
92	109	2023-11	bonus	44097896.70	2023-11-25	\N
93	353	2020-01	bonus	4977333.84	2020-01-05	\N
94	301	2022-02	salary	18910277.67	2022-02-10	\N
95	148	2021-07	bonus	908499.09	2021-07-30	\N
96	32	2022-01	salary	27475982.43	2022-01-09	\N
97	245	2020-10	salary	10110354.19	2020-10-13	\N
98	71	2022-08	salary	24532407.78	2022-08-23	\N
99	238	2023-07	bonus	33111992.38	2023-07-31	\N
100	448	2020-01	penalty	48747055.96	2020-01-17	\N
101	276	2020-09	bonus	17572633.15	2020-09-08	\N
102	37	2021-10	penalty	44415895.82	2021-10-31	\N
103	168	2023-02	penalty	48680560.85	2023-02-22	\N
104	440	2020-07	bonus	19868595.43	2020-07-17	\N
105	149	2021-10	bonus	18541945.41	2021-10-26	\N
106	178	2022-12	bonus	33590173.15	2022-12-17	\N
107	478	2024-10	bonus	40690921.39	2024-10-24	\N
108	386	2021-08	bonus	13756404.29	2021-08-08	\N
109	414	2020-04	penalty	14890722.64	2020-04-29	\N
110	266	2020-04	bonus	38464323.45	2020-04-09	\N
111	385	2022-10	penalty	15754851.09	2022-10-27	\N
112	60	2021-01	bonus	23666660.00	2021-01-18	\N
113	258	2022-05	salary	32684625.48	2022-05-05	\N
114	483	2023-07	salary	12496843.51	2023-07-27	\N
115	319	2023-03	penalty	2838944.53	2023-03-31	\N
116	327	2020-03	penalty	5358156.33	2020-03-04	\N
117	165	2020-10	salary	25911188.24	2020-10-24	\N
118	247	2022-12	penalty	29456541.72	2022-12-03	\N
119	401	2021-07	penalty	32916916.55	2021-07-16	\N
120	393	2022-02	bonus	26529762.99	2022-02-26	\N
121	63	2025-02	salary	19548748.59	2025-02-14	\N
122	108	2023-12	bonus	34447110.56	2023-12-05	\N
123	401	2021-11	penalty	46993901.02	2021-11-17	\N
124	385	2023-05	salary	48014007.64	2023-05-29	\N
125	51	2020-12	salary	32086198.68	2020-12-01	\N
126	274	2024-05	penalty	18523987.87	2024-05-07	\N
127	410	2023-08	salary	49335911.02	2023-08-01	\N
128	188	2023-03	bonus	37803906.36	2023-03-11	\N
129	46	2021-08	penalty	46792676.52	2021-08-02	\N
130	304	2025-04	salary	46477974.97	2025-04-28	\N
131	325	2025-04	bonus	45233551.94	2025-04-07	\N
132	306	2021-11	bonus	33053515.52	2021-11-26	\N
133	388	2022-01	bonus	6280834.01	2022-01-22	\N
134	39	2025-05	salary	49816888.19	2025-05-16	\N
135	255	2023-06	bonus	1404485.00	2023-06-13	\N
136	377	2023-05	penalty	49446255.61	2023-05-05	\N
137	155	2023-05	penalty	49445045.23	2023-05-02	\N
138	480	2023-06	salary	43252919.17	2023-06-20	\N
139	106	2021-06	bonus	8812801.22	2021-06-18	\N
140	340	2021-06	bonus	45488985.11	2021-06-14	\N
141	368	2020-10	penalty	13717414.66	2020-10-29	\N
142	470	2024-04	bonus	22145599.57	2024-04-06	\N
143	340	2022-03	bonus	19617123.99	2022-03-16	\N
144	29	2020-07	salary	27286667.56	2020-07-31	\N
145	500	2024-04	penalty	15360850.03	2024-04-04	\N
146	326	2023-07	penalty	38213621.36	2023-07-11	\N
147	231	2024-07	bonus	11657934.32	2024-07-22	\N
148	441	2021-05	bonus	6675837.28	2021-05-22	\N
149	120	2022-07	salary	40031465.40	2022-07-19	\N
150	488	2022-10	salary	42277426.27	2022-10-27	\N
151	273	2021-07	bonus	25441235.85	2021-07-19	\N
152	242	2023-08	penalty	9727356.58	2023-08-15	\N
153	363	2020-07	penalty	3325245.57	2020-07-24	\N
154	271	2025-05	bonus	46977107.11	2025-05-11	\N
155	485	2023-08	penalty	3581852.30	2023-08-30	\N
156	155	2024-09	bonus	26309233.21	2024-09-28	\N
157	207	2024-04	penalty	8508209.21	2024-04-28	\N
158	80	2020-12	salary	4980040.41	2020-12-19	\N
159	362	2022-08	penalty	15594515.08	2022-08-23	\N
160	76	2022-06	penalty	23782400.13	2022-06-02	\N
161	28	2024-03	bonus	41268487.71	2024-03-04	\N
162	404	2022-08	bonus	48208263.93	2022-08-12	\N
163	261	2024-06	penalty	17866591.22	2024-06-08	\N
164	212	2021-12	salary	34322361.55	2021-12-20	\N
165	273	2021-03	bonus	47907468.43	2021-03-29	\N
166	87	2024-12	salary	34219772.01	2024-12-10	\N
167	81	2023-12	bonus	6606792.23	2023-12-10	\N
168	250	2021-08	bonus	3247627.74	2021-08-03	\N
169	345	2022-01	bonus	13336112.62	2022-01-14	\N
170	275	2022-04	penalty	20780789.45	2022-04-05	\N
171	245	2023-01	penalty	48067451.71	2023-01-10	\N
172	26	2023-08	bonus	12008413.69	2023-08-04	\N
173	353	2021-11	penalty	7251551.60	2021-11-18	\N
174	21	2025-01	penalty	30659203.67	2025-01-25	\N
175	223	2020-10	penalty	14480407.17	2020-10-26	\N
176	188	2024-04	bonus	44161807.63	2024-04-14	\N
177	40	2022-06	penalty	44781220.20	2022-06-01	\N
178	330	2024-06	penalty	17624424.44	2024-06-18	\N
179	297	2022-03	bonus	25984174.41	2022-03-07	\N
180	2	2023-06	penalty	19222050.57	2023-06-28	\N
181	473	2023-12	bonus	4121906.27	2023-12-10	\N
182	474	2024-11	bonus	24392520.62	2024-11-09	\N
183	293	2021-05	penalty	38580274.63	2021-05-01	\N
184	498	2020-04	salary	16433422.50	2020-04-15	\N
185	314	2022-01	salary	14963197.89	2022-01-25	\N
186	430	2022-09	penalty	26525071.72	2022-09-07	\N
187	112	2024-04	penalty	23719738.27	2024-04-12	\N
188	16	2021-04	salary	7222350.92	2021-04-16	\N
189	448	2021-09	penalty	16421846.92	2021-09-13	\N
190	365	2025-03	salary	14967531.63	2025-03-19	\N
191	247	2024-02	salary	24832281.17	2024-02-09	\N
192	446	2024-10	bonus	27909535.68	2024-10-26	\N
193	336	2023-04	penalty	3130281.84	2023-04-19	\N
194	134	2024-03	bonus	25890281.25	2024-03-11	\N
195	60	2023-06	penalty	33949102.12	2023-06-19	\N
196	462	2022-04	penalty	28521802.11	2022-04-06	\N
197	458	2023-02	salary	45303502.66	2023-02-25	\N
198	294	2020-07	salary	38310546.02	2020-07-15	\N
199	64	2020-11	bonus	35898834.01	2020-11-04	\N
200	112	2023-12	bonus	28264999.25	2023-12-19	\N
201	230	2020-03	salary	39392797.81	2020-03-27	\N
202	211	2020-03	bonus	20346485.34	2020-03-21	\N
203	436	2024-08	penalty	31388231.08	2024-08-11	\N
204	46	2020-02	penalty	30248197.97	2020-02-25	\N
205	99	2022-12	salary	14348127.78	2022-12-20	\N
206	315	2021-11	bonus	20581540.32	2021-11-10	\N
207	52	2024-08	salary	42419985.64	2024-08-28	\N
208	313	2020-07	salary	15769113.83	2020-07-13	\N
209	499	2021-03	bonus	44859445.91	2021-03-02	\N
210	315	2020-12	salary	46901643.51	2020-12-26	\N
211	322	2023-09	penalty	7917121.92	2023-09-16	\N
212	383	2020-05	penalty	3808949.67	2020-05-07	\N
213	309	2020-12	bonus	36821662.48	2020-12-03	\N
214	30	2021-07	salary	33928400.17	2021-07-05	\N
215	196	2021-01	penalty	27660523.87	2021-01-23	\N
216	430	2025-01	penalty	11928529.08	2025-01-20	\N
217	401	2021-05	salary	32853971.06	2021-05-11	\N
218	300	2024-03	penalty	42063146.20	2024-03-19	\N
219	156	2022-07	penalty	788071.77	2022-07-04	\N
220	312	2022-04	penalty	24492059.07	2022-04-15	\N
221	30	2022-05	salary	28113436.56	2022-05-22	\N
222	174	2024-03	salary	25833265.53	2024-03-22	\N
223	157	2023-06	bonus	41520245.17	2023-06-22	\N
224	142	2020-09	salary	5984712.43	2020-09-16	\N
225	456	2021-07	bonus	5622045.70	2021-07-18	\N
226	376	2021-03	salary	18771343.79	2021-03-19	\N
227	174	2025-03	bonus	41398855.90	2025-03-16	\N
228	305	2020-05	salary	38733237.16	2020-05-01	\N
229	286	2020-10	penalty	4249724.58	2020-10-07	\N
230	251	2023-08	penalty	48817302.26	2023-08-22	\N
231	228	2021-10	salary	39280110.76	2021-10-16	\N
232	10	2023-05	salary	15717836.89	2023-05-14	\N
233	203	2023-08	salary	34554632.60	2023-08-14	\N
234	67	2022-03	penalty	30224759.05	2022-03-20	\N
235	465	2020-11	bonus	22227964.84	2020-11-18	\N
236	367	2022-02	salary	9443711.54	2022-02-16	\N
237	152	2023-06	bonus	17397016.27	2023-06-22	\N
238	482	2024-12	salary	16720649.02	2024-12-04	\N
239	117	2020-01	penalty	28482581.88	2020-01-15	\N
240	413	2022-01	bonus	7476388.03	2022-01-10	\N
241	353	2022-01	salary	32617517.14	2022-01-19	\N
242	301	2021-01	salary	38813608.52	2021-01-02	\N
243	255	2021-08	penalty	9725708.29	2021-08-28	\N
244	397	2022-02	salary	24538167.39	2022-02-06	\N
245	487	2024-03	salary	44630051.71	2024-03-10	\N
246	345	2023-08	salary	30307917.29	2023-08-19	\N
247	194	2023-10	bonus	17747410.64	2023-10-22	\N
248	271	2020-10	bonus	29037331.83	2020-10-12	\N
249	200	2022-11	salary	6753227.14	2022-11-10	\N
250	482	2020-08	salary	38303198.97	2020-08-27	\N
251	234	2022-03	salary	19333882.09	2022-03-18	\N
252	458	2023-08	salary	45628650.81	2023-08-22	\N
253	371	2022-03	salary	36584080.66	2022-03-12	\N
254	476	2022-06	penalty	40743355.96	2022-06-26	\N
255	357	2022-02	penalty	29634696.36	2022-02-17	\N
256	283	2023-07	penalty	22651046.33	2023-07-21	\N
257	294	2024-06	penalty	44228010.96	2024-06-27	\N
258	389	2024-11	penalty	28017092.42	2024-11-21	\N
259	117	2021-07	bonus	40052932.73	2021-07-14	\N
260	69	2022-06	salary	1713484.40	2022-06-04	\N
261	42	2020-11	bonus	37380745.36	2020-11-29	\N
262	426	2020-01	salary	26891009.53	2020-01-20	\N
263	78	2023-08	penalty	22608046.91	2023-08-29	\N
264	246	2023-09	penalty	33272882.18	2023-09-03	\N
265	331	2020-10	penalty	8089460.78	2020-10-28	\N
266	450	2021-04	bonus	45867987.73	2021-04-09	\N
267	393	2020-12	penalty	47366738.73	2020-12-26	\N
268	86	2024-02	penalty	48899943.87	2024-02-26	\N
269	293	2024-12	salary	9325545.12	2024-12-01	\N
270	65	2025-05	bonus	29657148.25	2025-05-27	\N
271	227	2024-11	salary	47986563.88	2024-11-22	\N
272	216	2024-02	salary	48628300.19	2024-02-01	\N
273	144	2020-06	penalty	4921874.73	2020-06-23	\N
274	366	2024-11	penalty	25052611.90	2024-11-01	\N
275	301	2025-04	penalty	34525094.19	2025-04-30	\N
276	401	2024-06	penalty	9689124.81	2024-06-21	\N
277	242	2024-11	salary	41951735.42	2024-11-24	\N
278	95	2020-09	salary	17536072.53	2020-09-01	\N
279	145	2021-02	bonus	2614949.43	2021-02-07	\N
280	53	2021-11	salary	40736505.67	2021-11-14	\N
281	230	2021-06	salary	35763402.01	2021-06-27	\N
282	75	2021-10	penalty	28016440.28	2021-10-04	\N
283	196	2020-09	penalty	42072982.81	2020-09-25	\N
284	179	2024-06	bonus	34955173.12	2024-06-04	\N
285	56	2022-09	bonus	1087680.17	2022-09-16	\N
286	113	2020-06	salary	28089055.18	2020-06-25	\N
287	133	2020-03	bonus	44290886.71	2020-03-14	\N
288	439	2022-11	penalty	40623699.35	2022-11-08	\N
289	443	2021-10	bonus	2636240.20	2021-10-08	\N
290	390	2023-08	salary	6333381.56	2023-08-30	\N
291	264	2021-07	penalty	30834570.25	2021-07-11	\N
292	1	2023-05	penalty	19962463.20	2023-05-31	\N
293	102	2025-05	salary	8242357.96	2025-05-15	\N
294	463	2022-10	bonus	41349589.73	2022-10-30	\N
295	347	2022-07	penalty	15690267.13	2022-07-08	\N
296	145	2024-06	salary	30543737.64	2024-06-06	\N
297	87	2023-07	bonus	19465118.28	2023-07-24	\N
298	232	2024-03	bonus	39977065.34	2024-03-04	\N
299	462	2021-10	penalty	35204238.21	2021-10-11	\N
300	228	2023-11	bonus	30666617.95	2023-11-01	\N
301	409	2020-12	bonus	30252664.93	2020-12-21	\N
302	345	2023-12	penalty	31061610.56	2023-12-20	\N
303	146	2022-04	penalty	25858724.39	2022-04-14	\N
304	17	2023-01	salary	48279615.60	2023-01-17	\N
305	105	2022-06	bonus	17875301.94	2022-06-28	\N
306	139	2021-07	bonus	35680402.19	2021-07-15	\N
307	332	2024-05	penalty	45430441.14	2024-05-01	\N
308	265	2022-05	penalty	47167661.24	2022-05-07	\N
309	315	2022-09	salary	43279820.37	2022-09-03	\N
310	467	2022-09	bonus	42965160.60	2022-09-05	\N
311	110	2024-05	bonus	4324919.58	2024-05-01	\N
312	324	2020-11	penalty	570139.82	2020-11-20	\N
313	485	2024-07	bonus	34852533.72	2024-07-09	\N
314	298	2024-02	penalty	29353558.34	2024-02-29	\N
315	135	2022-11	salary	19709550.49	2022-11-16	\N
316	386	2023-04	salary	28256169.96	2023-04-20	\N
317	277	2020-12	bonus	13483936.31	2020-12-04	\N
318	311	2025-04	salary	32981836.35	2025-04-30	\N
319	427	2023-11	salary	48890161.48	2023-11-23	\N
320	20	2023-09	bonus	20668303.05	2023-09-09	\N
321	301	2025-05	salary	41491669.47	2025-05-25	\N
322	318	2021-11	penalty	45125422.51	2021-11-10	\N
323	159	2023-08	penalty	11748332.85	2023-08-23	\N
324	471	2022-01	bonus	12550074.14	2022-01-23	\N
325	60	2022-09	salary	29114690.49	2022-09-17	\N
326	66	2025-05	salary	42135562.28	2025-05-07	\N
327	18	2023-11	bonus	6688637.45	2023-11-01	\N
328	398	2020-07	salary	22356164.07	2020-07-16	\N
329	67	2025-03	bonus	39702905.30	2025-03-20	\N
330	44	2024-02	salary	13199446.61	2024-02-28	\N
331	136	2023-01	penalty	34042362.81	2023-01-19	\N
332	345	2021-12	penalty	23656737.41	2021-12-11	\N
333	291	2025-01	salary	49892934.78	2025-01-24	\N
334	499	2022-08	bonus	13296952.79	2022-08-01	\N
335	113	2022-10	bonus	20750004.30	2022-10-10	\N
336	143	2021-04	penalty	37301455.42	2021-04-10	\N
337	313	2022-11	penalty	21139506.35	2022-11-30	\N
338	435	2022-01	salary	21849399.75	2022-01-22	\N
339	136	2022-07	penalty	37570928.04	2022-07-11	\N
340	369	2020-05	bonus	46392726.12	2020-05-15	\N
341	304	2024-01	salary	26320366.99	2024-01-20	\N
342	473	2021-07	bonus	14444424.11	2021-07-15	\N
343	407	2020-11	salary	24234197.79	2020-11-14	\N
344	40	2024-01	bonus	40531424.23	2024-01-22	\N
345	268	2022-02	penalty	10962769.72	2022-02-16	\N
346	468	2024-09	bonus	38642103.65	2024-09-25	\N
347	413	2020-08	salary	9483119.73	2020-08-13	\N
348	292	2022-12	penalty	6358726.19	2022-12-05	\N
349	341	2021-04	penalty	13743017.79	2021-04-12	\N
350	209	2020-10	penalty	3305876.93	2020-10-24	\N
351	244	2022-08	salary	38433067.78	2022-08-15	\N
352	170	2024-10	salary	31437381.58	2024-10-04	\N
353	184	2024-02	bonus	33080239.74	2024-02-08	\N
354	450	2022-03	salary	44477815.99	2022-03-25	\N
355	479	2020-01	bonus	22316238.05	2020-01-16	\N
356	195	2024-02	salary	29405208.53	2024-02-20	\N
357	46	2022-04	penalty	33487387.85	2022-04-03	\N
358	388	2024-05	bonus	44635765.39	2024-05-31	\N
359	90	2024-08	penalty	10441100.95	2024-08-16	\N
360	492	2022-07	penalty	7881096.18	2022-07-30	\N
361	289	2023-07	penalty	12499464.14	2023-07-29	\N
362	484	2023-10	bonus	20416777.67	2023-10-14	\N
363	299	2021-08	bonus	9172091.46	2021-08-26	\N
364	460	2024-02	salary	17828702.79	2024-02-29	\N
365	322	2020-06	bonus	15289514.62	2020-06-11	\N
366	333	2025-02	penalty	10238793.88	2025-02-12	\N
367	189	2024-06	bonus	30046376.49	2024-06-06	\N
368	204	2020-04	salary	37913394.41	2020-04-20	\N
369	206	2020-06	bonus	42743363.35	2020-06-03	\N
370	201	2024-06	bonus	20636536.14	2024-06-29	\N
371	171	2023-04	salary	19018908.14	2023-04-30	\N
372	171	2024-02	salary	23144648.41	2024-02-06	\N
373	158	2023-09	salary	7272966.96	2023-09-01	\N
374	127	2024-04	bonus	38940536.08	2024-04-01	\N
375	490	2021-01	bonus	47186657.76	2021-01-03	\N
376	43	2021-12	salary	45843207.96	2021-12-06	\N
377	371	2025-05	salary	522664.67	2025-05-25	\N
378	435	2022-07	penalty	41888861.29	2022-07-08	\N
379	252	2023-05	salary	22725158.84	2023-05-23	\N
380	120	2020-06	salary	45684332.00	2020-06-24	\N
381	50	2024-11	penalty	10042279.56	2024-11-21	\N
382	357	2022-06	bonus	648605.48	2022-06-09	\N
383	172	2021-09	penalty	32783591.41	2021-09-23	\N
384	126	2022-06	bonus	48523929.39	2022-06-12	\N
385	450	2020-07	salary	49156359.48	2020-07-12	\N
386	132	2024-10	salary	44333398.10	2024-10-19	\N
387	253	2022-03	salary	6349710.84	2022-03-08	\N
388	288	2022-03	penalty	10891132.68	2022-03-23	\N
389	481	2020-09	penalty	43569429.36	2020-09-07	\N
390	92	2022-05	penalty	1387795.82	2022-05-03	\N
391	282	2025-05	penalty	25795982.55	2025-05-10	\N
392	417	2024-05	bonus	40720057.42	2024-05-16	\N
393	95	2022-11	penalty	47733044.39	2022-11-20	\N
394	32	2025-02	bonus	9909973.88	2025-02-18	\N
395	211	2020-01	penalty	17672645.10	2020-01-08	\N
396	22	2024-05	salary	29449056.44	2024-05-16	\N
397	458	2020-02	salary	20842897.56	2020-02-03	\N
398	220	2020-06	salary	35288698.64	2020-06-07	\N
399	231	2025-03	penalty	20885448.39	2025-03-26	\N
400	350	2024-12	bonus	41953194.06	2024-12-02	\N
401	360	2025-05	penalty	24489273.89	2025-05-15	\N
402	115	2020-07	salary	41110428.36	2020-07-16	\N
403	7	2021-04	bonus	33945865.74	2021-04-08	\N
404	334	2021-02	penalty	48068457.38	2021-02-07	\N
405	298	2022-03	bonus	22174554.04	2022-03-19	\N
406	363	2021-07	bonus	24375069.22	2021-07-25	\N
407	297	2024-08	bonus	9604436.77	2024-08-10	\N
408	6	2024-12	salary	39583666.12	2024-12-08	\N
409	378	2022-01	penalty	17517604.40	2022-01-07	\N
410	15	2023-02	bonus	12693992.85	2023-02-11	\N
411	384	2021-05	penalty	41651631.59	2021-05-25	\N
412	493	2020-02	bonus	24934650.38	2020-02-07	\N
413	455	2025-01	salary	29123992.94	2025-01-03	\N
414	173	2020-08	bonus	38531278.00	2020-08-22	\N
415	94	2021-02	bonus	18307859.52	2021-02-20	\N
416	261	2022-01	salary	24193115.89	2022-01-22	\N
417	151	2024-09	bonus	46169081.81	2024-09-23	\N
418	249	2025-01	salary	4350534.77	2025-01-05	\N
419	492	2021-02	penalty	32430060.47	2021-02-24	\N
420	95	2020-06	bonus	26352422.61	2020-06-02	\N
421	13	2021-02	penalty	38030214.07	2021-02-16	\N
422	404	2024-04	penalty	40345552.14	2024-04-24	\N
423	487	2024-01	bonus	46071274.69	2024-01-26	\N
424	136	2021-08	salary	29075648.40	2021-08-17	\N
425	167	2023-12	salary	1962211.36	2023-12-08	\N
426	189	2025-04	penalty	5216150.41	2025-04-21	\N
427	289	2023-11	salary	34027312.80	2023-11-15	\N
428	213	2022-01	penalty	49317622.99	2022-01-05	\N
429	46	2021-07	penalty	4221401.31	2021-07-21	\N
430	381	2021-07	penalty	40954074.47	2021-07-09	\N
431	294	2024-09	salary	32378871.51	2024-09-20	\N
432	254	2023-07	bonus	17896676.58	2023-07-11	\N
433	426	2022-09	penalty	17347839.33	2022-09-24	\N
434	42	2022-07	penalty	45234552.59	2022-07-08	\N
435	370	2022-04	penalty	16717669.05	2022-04-03	\N
436	164	2023-08	penalty	41237050.82	2023-08-20	\N
437	88	2023-06	salary	7872306.76	2023-06-12	\N
438	283	2022-06	penalty	47282634.07	2022-06-23	\N
439	206	2021-07	bonus	31719325.06	2021-07-15	\N
440	13	2022-07	salary	13481424.44	2022-07-18	\N
441	4	2021-08	bonus	41018378.94	2021-08-30	\N
442	244	2024-08	penalty	29786142.28	2024-08-17	\N
443	313	2022-04	penalty	43657876.01	2022-04-28	\N
444	472	2024-04	penalty	4177516.21	2024-04-16	\N
445	422	2023-03	penalty	38713393.95	2023-03-21	\N
446	143	2025-04	penalty	35244782.57	2025-04-14	\N
447	240	2025-05	penalty	10993483.85	2025-05-16	\N
448	338	2024-07	bonus	47617766.16	2024-07-28	\N
449	51	2024-05	bonus	33264208.64	2024-05-31	\N
450	163	2022-08	bonus	10455200.96	2022-08-03	\N
451	426	2021-08	penalty	36878884.35	2021-08-25	\N
452	479	2022-05	penalty	31863427.80	2022-05-11	\N
453	454	2020-03	penalty	31018061.16	2020-03-10	\N
454	335	2023-09	salary	18840476.73	2023-09-06	\N
455	21	2021-08	bonus	49049385.87	2021-08-20	\N
456	154	2020-12	bonus	45054688.25	2020-12-17	\N
457	366	2025-05	salary	7565297.80	2025-05-29	\N
458	320	2022-05	bonus	1213829.90	2022-05-31	\N
459	317	2023-11	bonus	46544840.36	2023-11-11	\N
460	277	2021-09	salary	7026228.76	2021-09-17	\N
461	242	2020-04	penalty	24470500.76	2020-04-05	\N
462	132	2020-01	bonus	44311180.76	2020-01-20	\N
463	179	2022-05	bonus	42429240.78	2022-05-31	\N
464	459	2020-04	salary	14123997.23	2020-04-15	\N
465	210	2024-04	bonus	42590855.10	2024-04-19	\N
466	416	2021-05	bonus	29876512.65	2021-05-02	\N
467	337	2025-01	penalty	34420659.20	2025-01-24	\N
468	200	2020-07	bonus	32830946.50	2020-07-25	\N
469	128	2024-07	bonus	48143046.83	2024-07-28	\N
470	362	2020-12	bonus	6968036.38	2020-12-12	\N
471	105	2025-01	salary	48558353.33	2025-01-08	\N
472	437	2020-04	penalty	7551866.96	2020-04-03	\N
473	65	2020-02	salary	1993161.25	2020-02-17	\N
474	328	2021-03	penalty	22418320.18	2021-03-23	\N
475	68	2020-07	penalty	10653529.10	2020-07-28	\N
476	236	2021-03	penalty	1056068.92	2021-03-17	\N
477	177	2023-08	salary	22917725.34	2023-08-27	\N
478	186	2022-07	bonus	12494102.86	2022-07-27	\N
479	331	2020-08	bonus	27729449.40	2020-08-20	\N
480	209	2023-11	bonus	25809595.48	2023-11-09	\N
481	413	2020-12	penalty	4000003.39	2020-12-17	\N
482	192	2024-10	penalty	22569973.60	2024-10-29	\N
483	267	2020-09	bonus	41217081.78	2020-09-20	\N
484	167	2020-05	bonus	30139545.64	2020-05-14	\N
485	338	2020-09	salary	13538566.47	2020-09-25	\N
486	324	2022-09	bonus	8404106.58	2022-09-10	\N
487	206	2023-02	bonus	12496048.69	2023-02-13	\N
488	135	2020-08	penalty	15982798.06	2020-08-22	\N
489	107	2024-04	bonus	11957840.30	2024-04-19	\N
490	166	2022-11	penalty	32763727.38	2022-11-18	\N
491	88	2021-08	penalty	17050800.17	2021-08-01	\N
492	40	2021-02	penalty	41770742.77	2021-02-17	\N
493	459	2020-07	penalty	33144476.06	2020-07-11	\N
494	383	2024-10	bonus	37593969.06	2024-10-29	\N
495	226	2022-01	bonus	22131326.60	2022-01-21	\N
496	464	2020-02	penalty	27582372.67	2020-02-12	\N
497	307	2023-08	bonus	31096688.93	2023-08-30	\N
498	377	2020-08	salary	2312128.25	2020-08-02	\N
499	111	2023-06	penalty	29471490.25	2023-06-15	\N
500	477	2020-12	bonus	10150631.62	2020-12-24	\N
501	250	2020-02	penalty	15795898.50	2020-02-20	\N
502	36	2021-06	bonus	30998317.00	2021-06-23	\N
503	131	2021-07	penalty	18967689.65	2021-07-30	\N
504	200	2020-04	bonus	16242016.24	2020-04-22	\N
505	310	2021-08	salary	17713641.98	2021-08-06	\N
506	376	2025-04	penalty	47819687.61	2025-04-23	\N
507	488	2021-11	salary	8870874.37	2021-11-02	\N
508	216	2021-07	salary	34263227.10	2021-07-21	\N
509	12	2021-02	bonus	4214623.45	2021-02-24	\N
510	12	2024-07	salary	21969392.52	2024-07-11	\N
511	267	2022-02	salary	49016968.76	2022-02-03	\N
512	499	2021-10	penalty	26179526.56	2021-10-21	\N
513	213	2024-10	salary	42730943.22	2024-10-06	\N
514	80	2022-11	bonus	24994036.99	2022-11-11	\N
515	60	2020-02	salary	28800396.12	2020-02-23	\N
516	294	2020-09	bonus	45373632.39	2020-09-10	\N
517	5	2020-02	penalty	10813074.63	2020-02-15	\N
518	383	2021-05	penalty	24613470.89	2021-05-17	\N
519	174	2024-03	bonus	35456663.97	2024-03-24	\N
520	198	2024-04	penalty	23067358.88	2024-04-23	\N
521	62	2023-07	penalty	21109674.05	2023-07-08	\N
522	364	2022-11	salary	28301595.93	2022-11-26	\N
523	121	2022-04	salary	43674374.09	2022-04-20	\N
524	23	2023-03	penalty	42126185.30	2023-03-11	\N
525	57	2023-11	bonus	34868813.73	2023-11-09	\N
526	386	2020-01	salary	18038218.16	2020-01-24	\N
527	394	2020-11	penalty	49448373.59	2020-11-24	\N
528	163	2023-04	penalty	11943036.88	2023-04-19	\N
529	146	2020-12	salary	49954885.91	2020-12-13	\N
530	330	2021-09	bonus	8586212.51	2021-09-22	\N
531	300	2023-06	penalty	14004151.71	2023-06-03	\N
532	459	2022-06	bonus	45436509.07	2022-06-27	\N
533	66	2020-08	salary	30862850.28	2020-08-23	\N
534	151	2025-04	bonus	38000715.04	2025-04-20	\N
535	360	2022-09	salary	1594937.65	2022-09-16	\N
536	92	2024-01	penalty	33148276.58	2024-01-16	\N
537	196	2021-02	bonus	2944464.74	2021-02-16	\N
538	185	2023-07	penalty	49428005.97	2023-07-19	\N
539	286	2020-08	bonus	20382681.75	2020-08-28	\N
540	294	2022-05	bonus	34035836.75	2022-05-06	\N
541	460	2021-12	bonus	8560918.85	2021-12-23	\N
542	494	2020-08	bonus	22168192.94	2020-08-25	\N
543	271	2021-04	penalty	6792931.53	2021-04-21	\N
544	230	2020-06	salary	8694830.46	2020-06-16	\N
545	136	2023-12	penalty	49035536.06	2023-12-09	\N
546	13	2020-05	penalty	45064648.58	2020-05-13	\N
547	77	2021-02	salary	18438983.25	2021-02-07	\N
548	243	2020-11	penalty	29338727.50	2020-11-03	\N
549	117	2020-07	salary	45163203.53	2020-07-13	\N
550	285	2021-06	salary	11068313.33	2021-06-14	\N
551	208	2022-02	salary	22750245.13	2022-02-07	\N
552	349	2023-03	penalty	20722056.53	2023-03-01	\N
553	401	2021-07	bonus	33822715.26	2021-07-18	\N
554	353	2024-09	bonus	11589665.33	2024-09-22	\N
555	324	2024-07	bonus	36539862.51	2024-07-31	\N
556	6	2023-01	bonus	23343729.29	2023-01-30	\N
557	481	2021-05	salary	20274500.11	2021-05-26	\N
558	14	2025-03	bonus	38940384.74	2025-03-09	\N
559	391	2022-11	salary	38668818.02	2022-11-28	\N
560	284	2020-08	salary	42376256.44	2020-08-26	\N
561	347	2024-05	bonus	44335391.92	2024-05-01	\N
562	404	2024-07	bonus	13414622.78	2024-07-18	\N
563	104	2020-06	bonus	609180.29	2020-06-02	\N
564	414	2024-11	penalty	21846418.33	2024-11-17	\N
565	448	2020-09	salary	4381989.22	2020-09-03	\N
566	64	2022-04	penalty	12660594.41	2022-04-16	\N
567	441	2024-03	penalty	8493575.75	2024-03-05	\N
568	388	2024-01	penalty	22328434.53	2024-01-20	\N
569	436	2023-02	penalty	30255379.78	2023-02-24	\N
570	47	2021-01	bonus	23757075.26	2021-01-07	\N
571	492	2022-10	penalty	42306085.62	2022-10-19	\N
572	229	2020-12	bonus	40849867.29	2020-12-21	\N
573	470	2020-08	salary	22535360.93	2020-08-04	\N
574	428	2021-11	salary	18805561.69	2021-11-23	\N
575	471	2022-12	penalty	25985237.93	2022-12-24	\N
576	52	2020-05	salary	28924303.70	2020-05-10	\N
577	267	2022-08	bonus	945451.53	2022-08-17	\N
578	274	2023-08	salary	26671946.94	2023-08-09	\N
579	46	2022-05	salary	10985270.74	2022-05-29	\N
580	412	2021-05	bonus	22078361.35	2021-05-26	\N
581	27	2023-10	salary	8120965.84	2023-10-21	\N
582	303	2023-10	penalty	17929486.51	2023-10-09	\N
583	175	2024-02	salary	38780040.77	2024-02-23	\N
584	264	2020-04	penalty	12385535.53	2020-04-15	\N
585	280	2020-03	penalty	38772050.95	2020-03-27	\N
586	452	2023-07	penalty	22272781.06	2023-07-28	\N
587	150	2021-08	penalty	39097202.02	2021-08-04	\N
588	390	2024-10	salary	27514427.60	2024-10-07	\N
589	424	2023-02	salary	7421225.75	2023-02-24	\N
590	21	2022-01	bonus	45598497.16	2022-01-25	\N
591	309	2022-12	penalty	25012843.19	2022-12-09	\N
592	108	2024-12	salary	44714909.98	2024-12-16	\N
593	94	2021-03	bonus	17181082.35	2021-03-05	\N
594	299	2022-09	salary	5387302.08	2022-09-14	\N
595	428	2022-04	salary	4802602.51	2022-04-08	\N
596	1	2021-01	bonus	33408874.14	2021-01-11	\N
597	41	2021-07	salary	21296828.00	2021-07-10	\N
598	24	2023-02	bonus	31833915.94	2023-02-28	\N
599	412	2023-12	salary	11902307.03	2023-12-25	\N
600	274	2020-01	bonus	32379412.46	2020-01-24	\N
601	11	2023-09	salary	16023129.73	2023-09-04	\N
602	117	2023-05	penalty	16858978.40	2023-05-05	\N
603	55	2025-04	salary	24644153.43	2025-04-26	\N
604	156	2023-12	bonus	38503772.62	2023-12-19	\N
605	337	2021-09	penalty	24601524.06	2021-09-15	\N
606	441	2024-03	bonus	32311697.71	2024-03-04	\N
607	32	2024-07	penalty	30554232.19	2024-07-31	\N
608	473	2020-03	penalty	25047015.79	2020-03-18	\N
609	148	2024-03	penalty	17015139.19	2024-03-14	\N
610	99	2020-10	salary	11228015.78	2020-10-01	\N
611	155	2024-11	penalty	12616955.92	2024-11-15	\N
612	350	2023-08	salary	43146374.12	2023-08-13	\N
613	100	2022-04	penalty	7857850.97	2022-04-24	\N
614	487	2025-05	bonus	42808272.43	2025-05-05	\N
615	406	2020-02	penalty	26438245.05	2020-02-03	\N
616	358	2020-11	salary	23692956.56	2020-11-14	\N
617	18	2022-02	bonus	36459842.88	2022-02-18	\N
618	97	2024-12	salary	1606027.50	2024-12-08	\N
619	67	2020-03	penalty	23171139.68	2020-03-08	\N
620	304	2021-08	salary	41411690.46	2021-08-28	\N
621	80	2020-02	salary	1000206.50	2020-02-23	\N
622	171	2020-05	salary	21915172.60	2020-05-27	\N
623	212	2024-04	bonus	24330393.97	2024-04-22	\N
624	362	2022-01	salary	44649843.90	2022-01-06	\N
625	85	2021-01	bonus	34606867.77	2021-01-08	\N
626	208	2023-08	bonus	31495800.00	2023-08-12	\N
627	328	2020-02	bonus	17519696.11	2020-02-18	\N
628	279	2021-01	penalty	15977101.48	2021-01-31	\N
629	209	2023-01	salary	46580400.83	2023-01-07	\N
630	358	2024-10	bonus	16627457.94	2024-10-31	\N
631	405	2021-02	penalty	2751403.26	2021-02-22	\N
632	433	2024-09	penalty	28066955.64	2024-09-21	\N
633	347	2022-11	bonus	22733366.01	2022-11-23	\N
634	206	2024-01	bonus	2773102.95	2024-01-24	\N
635	252	2023-12	salary	22353837.43	2023-12-13	\N
636	421	2024-10	bonus	48022047.61	2024-10-09	\N
637	342	2024-07	penalty	28599358.62	2024-07-13	\N
638	45	2020-02	bonus	29384992.19	2020-02-16	\N
639	379	2022-08	salary	14941188.96	2022-08-03	\N
640	341	2023-03	salary	8353382.42	2023-03-19	\N
641	179	2023-04	penalty	10133573.98	2023-04-27	\N
642	386	2020-12	bonus	13100073.40	2020-12-21	\N
643	490	2020-11	salary	45032861.66	2020-11-15	\N
644	386	2023-09	salary	27383064.23	2023-09-14	\N
645	181	2024-09	salary	40786731.55	2024-09-09	\N
646	204	2022-11	penalty	18415713.06	2022-11-25	\N
647	283	2022-05	bonus	2589648.51	2022-05-31	\N
648	483	2022-04	bonus	44213048.78	2022-04-11	\N
649	80	2020-04	bonus	43808672.00	2020-04-29	\N
650	274	2022-11	penalty	41952029.97	2022-11-08	\N
651	76	2022-02	salary	8459208.36	2022-02-12	\N
652	496	2020-06	penalty	43034465.11	2020-06-13	\N
653	204	2020-10	salary	24730703.49	2020-10-06	\N
654	25	2023-09	salary	38720179.92	2023-09-03	\N
655	248	2020-07	bonus	8214166.72	2020-07-16	\N
656	130	2024-02	bonus	4672067.00	2024-02-29	\N
657	114	2024-09	salary	3593277.86	2024-09-21	\N
658	222	2020-12	penalty	47382876.49	2020-12-01	\N
659	170	2025-03	bonus	38513370.92	2025-03-14	\N
660	318	2022-08	penalty	7491600.36	2022-08-02	\N
661	96	2024-03	penalty	49772287.43	2024-03-30	\N
662	232	2021-10	penalty	47961169.97	2021-10-07	\N
663	49	2024-08	penalty	13476346.03	2024-08-07	\N
664	85	2025-03	penalty	21464312.59	2025-03-03	\N
665	287	2023-08	penalty	16484609.95	2023-08-09	\N
666	488	2025-04	penalty	7534509.67	2025-04-27	\N
667	347	2022-03	salary	45535704.21	2022-03-02	\N
668	14	2025-03	bonus	2935216.06	2025-03-30	\N
669	450	2023-10	bonus	30250191.44	2023-10-19	\N
670	286	2023-02	penalty	19734483.77	2023-02-18	\N
671	162	2021-04	penalty	2963137.26	2021-04-20	\N
672	336	2020-02	bonus	2831259.86	2020-02-09	\N
673	380	2022-10	penalty	15759042.28	2022-10-29	\N
674	383	2020-07	bonus	23242263.21	2020-07-18	\N
675	433	2020-09	salary	22645551.08	2020-09-18	\N
676	326	2021-03	penalty	16348994.08	2021-03-08	\N
677	200	2021-12	penalty	48211199.78	2021-12-31	\N
678	443	2023-03	penalty	49032395.21	2023-03-14	\N
679	288	2022-10	bonus	8813358.98	2022-10-23	\N
680	133	2020-10	bonus	23394057.55	2020-10-27	\N
681	317	2023-09	bonus	27062085.37	2023-09-01	\N
682	49	2020-03	bonus	27687629.58	2020-03-13	\N
683	414	2022-11	penalty	26794032.13	2022-11-15	\N
684	154	2021-06	salary	36169506.14	2021-06-14	\N
685	289	2024-12	bonus	15704790.41	2024-12-25	\N
686	312	2024-09	salary	48579859.62	2024-09-06	\N
687	57	2020-09	penalty	40984189.40	2020-09-15	\N
688	23	2022-10	penalty	8317314.98	2022-10-17	\N
689	114	2021-03	salary	32587075.86	2021-03-02	\N
690	338	2020-04	bonus	19567157.87	2020-04-27	\N
691	241	2023-06	salary	31550391.77	2023-06-26	\N
692	208	2023-02	penalty	33703194.70	2023-02-13	\N
693	209	2024-07	salary	31483790.74	2024-07-13	\N
694	496	2024-09	salary	20049637.58	2024-09-20	\N
695	47	2025-02	penalty	33891981.92	2025-02-26	\N
696	459	2022-09	penalty	22362429.83	2022-09-23	\N
697	264	2020-11	penalty	44090208.30	2020-11-10	\N
698	468	2022-02	penalty	6854799.83	2022-02-08	\N
699	333	2022-07	bonus	36746531.18	2022-07-31	\N
700	1	2020-07	salary	42625913.65	2020-07-31	\N
701	341	2020-04	penalty	20716589.43	2020-04-09	\N
702	415	2020-11	salary	49449837.51	2020-11-05	\N
703	399	2021-09	bonus	42414898.45	2021-09-22	\N
704	148	2023-10	penalty	7606767.62	2023-10-26	\N
705	79	2023-11	penalty	40364662.96	2023-11-09	\N
706	369	2020-02	penalty	32800411.12	2020-02-07	\N
707	276	2024-06	bonus	31828774.56	2024-06-24	\N
708	413	2023-04	salary	36553918.85	2023-04-20	\N
709	65	2022-12	salary	12109357.36	2022-12-02	\N
710	149	2020-07	bonus	42346401.81	2020-07-13	\N
711	490	2020-10	penalty	44091023.54	2020-10-28	\N
712	94	2025-01	salary	29493520.49	2025-01-21	\N
713	37	2024-06	salary	582754.07	2024-06-14	\N
714	9	2024-10	penalty	8677325.60	2024-10-20	\N
715	350	2020-08	bonus	46978559.27	2020-08-17	\N
716	478	2021-02	salary	3335651.30	2021-02-19	\N
717	195	2023-06	bonus	32909588.17	2023-06-30	\N
718	480	2024-11	salary	19912302.26	2024-11-19	\N
719	78	2023-04	salary	19742225.06	2023-04-14	\N
720	72	2021-12	salary	43349047.49	2021-12-03	\N
721	349	2024-05	bonus	9808810.50	2024-05-02	\N
722	148	2021-02	salary	27862597.21	2021-02-13	\N
723	123	2024-09	bonus	28189202.37	2024-09-21	\N
724	265	2025-01	bonus	43052708.57	2025-01-20	\N
725	190	2020-08	bonus	44285726.07	2020-08-21	\N
726	501	2020-04	penalty	3339209.52	2020-04-16	\N
727	328	2021-07	salary	36358704.86	2021-07-22	\N
728	23	2024-07	penalty	39421595.25	2024-07-14	\N
729	242	2023-12	penalty	1092238.33	2023-12-24	\N
730	208	2023-07	bonus	10577931.85	2023-07-22	\N
731	139	2020-07	bonus	16575510.79	2020-07-30	\N
732	100	2021-03	salary	26260604.73	2021-03-26	\N
733	15	2022-10	bonus	20631481.17	2022-10-09	\N
734	92	2025-03	penalty	20267310.04	2025-03-15	\N
735	462	2022-10	penalty	6852673.75	2022-10-20	\N
736	40	2022-08	penalty	44994103.72	2022-08-11	\N
737	365	2024-04	penalty	25907304.73	2024-04-28	\N
738	336	2023-07	penalty	29785758.97	2023-07-26	\N
739	479	2023-08	bonus	18341988.08	2023-08-14	\N
740	469	2023-08	bonus	9065798.24	2023-08-10	\N
741	469	2021-11	salary	49195979.87	2021-11-05	\N
742	204	2021-08	bonus	31373437.81	2021-08-13	\N
743	499	2024-03	bonus	23110587.39	2024-03-10	\N
744	222	2020-06	salary	18222265.64	2020-06-24	\N
745	267	2023-07	bonus	24072060.08	2023-07-28	\N
746	401	2022-09	penalty	18461001.65	2022-09-28	\N
747	160	2023-03	penalty	19115313.29	2023-03-19	\N
748	362	2024-07	penalty	48685484.96	2024-07-17	\N
749	259	2020-06	salary	33721203.58	2020-06-24	\N
750	127	2020-03	salary	10611463.52	2020-03-01	\N
751	243	2022-12	salary	48121586.57	2022-12-24	\N
752	23	2020-10	penalty	42221329.84	2020-10-25	\N
753	152	2024-09	salary	30103745.06	2024-09-12	\N
754	174	2023-01	salary	24331976.88	2023-01-08	\N
755	445	2022-07	salary	38051633.35	2022-07-21	\N
756	326	2024-01	salary	26496350.43	2024-01-16	\N
757	286	2024-03	bonus	30248276.70	2024-03-13	\N
758	74	2024-12	bonus	18255066.72	2024-12-27	\N
759	122	2020-09	penalty	21444076.17	2020-09-04	\N
760	173	2021-02	bonus	28275283.22	2021-02-06	\N
761	253	2024-01	penalty	45830846.43	2024-01-19	\N
762	207	2025-04	salary	13838271.23	2025-04-21	\N
763	300	2023-02	penalty	29325362.30	2023-02-03	\N
764	403	2022-08	bonus	45732000.59	2022-08-12	\N
765	308	2020-10	penalty	3064293.60	2020-10-25	\N
766	270	2020-06	salary	1269347.12	2020-06-12	\N
767	437	2023-04	salary	21492987.90	2023-04-27	\N
768	272	2021-07	bonus	23996087.93	2021-07-23	\N
769	499	2024-07	bonus	47144235.30	2024-07-20	\N
770	209	2021-01	bonus	18617626.52	2021-01-27	\N
771	15	2021-10	penalty	13887079.09	2021-10-11	\N
772	205	2020-12	bonus	27761944.69	2020-12-04	\N
773	145	2020-09	penalty	8822187.30	2020-09-01	\N
774	132	2022-04	bonus	39484079.29	2022-04-12	\N
775	181	2021-04	penalty	18810070.07	2021-04-13	\N
776	425	2023-07	penalty	35631880.02	2023-07-18	\N
777	164	2022-08	salary	10849944.87	2022-08-16	\N
778	472	2021-09	penalty	15546628.49	2021-09-24	\N
779	25	2024-04	bonus	2605748.16	2024-04-15	\N
780	205	2022-10	salary	18907264.31	2022-10-24	\N
781	329	2023-07	bonus	28498899.82	2023-07-18	\N
782	274	2025-04	bonus	35790885.20	2025-04-10	\N
783	23	2024-07	penalty	3650780.36	2024-07-01	\N
784	294	2022-01	bonus	12173941.27	2022-01-25	\N
785	469	2021-03	bonus	16874023.88	2021-03-25	\N
786	63	2022-01	salary	25966006.24	2022-01-22	\N
787	412	2024-09	penalty	10003431.42	2024-09-24	\N
788	57	2021-08	bonus	20355146.97	2021-08-06	\N
789	313	2023-02	penalty	12760072.68	2023-02-15	\N
790	447	2025-03	salary	30513271.27	2025-03-01	\N
791	353	2023-06	bonus	47896337.55	2023-06-30	\N
792	327	2021-11	penalty	21427693.29	2021-11-07	\N
793	201	2023-09	bonus	44341246.35	2023-09-10	\N
794	243	2025-04	bonus	48669832.23	2025-04-26	\N
795	274	2020-04	bonus	18583080.57	2020-04-21	\N
796	428	2024-07	bonus	43381185.35	2024-07-22	\N
797	199	2022-11	salary	12183069.06	2022-11-11	\N
798	85	2023-09	bonus	33136539.68	2023-09-17	\N
799	405	2020-01	penalty	41567787.20	2020-01-03	\N
800	64	2023-05	bonus	37599837.38	2023-05-19	\N
801	65	2020-02	bonus	15769146.58	2020-02-19	\N
802	211	2024-09	bonus	10118416.05	2024-09-21	\N
803	42	2021-10	penalty	13474279.81	2021-10-31	\N
804	220	2022-09	penalty	49059792.44	2022-09-05	\N
805	314	2024-08	salary	8205872.63	2024-08-06	\N
806	131	2021-10	salary	32103732.45	2021-10-26	\N
807	467	2025-05	bonus	29062715.70	2025-05-11	\N
808	400	2020-09	penalty	48060490.11	2020-09-16	\N
809	217	2020-07	penalty	49731764.69	2020-07-21	\N
810	246	2023-06	bonus	32780645.17	2023-06-03	\N
811	83	2023-12	penalty	15698371.40	2023-12-23	\N
812	473	2022-11	salary	22116272.53	2022-11-26	\N
813	436	2020-12	bonus	44006391.40	2020-12-25	\N
814	277	2021-07	penalty	32817531.09	2021-07-22	\N
815	178	2023-04	penalty	28296199.00	2023-04-22	\N
816	285	2022-09	bonus	2448128.39	2022-09-15	\N
817	455	2021-02	bonus	45927532.73	2021-02-06	\N
818	274	2023-07	salary	22448792.26	2023-07-19	\N
819	279	2020-09	salary	7794162.16	2020-09-25	\N
820	278	2021-12	bonus	19232037.04	2021-12-01	\N
821	358	2020-08	penalty	42728099.18	2020-08-09	\N
822	338	2022-04	penalty	7324926.31	2022-04-17	\N
823	30	2025-05	penalty	28813671.24	2025-05-21	\N
824	342	2021-10	bonus	45910080.82	2021-10-12	\N
825	376	2022-04	bonus	33439941.87	2022-04-28	\N
826	208	2024-02	bonus	3128905.26	2024-02-18	\N
827	475	2022-08	salary	761377.48	2022-08-20	\N
828	308	2020-04	penalty	10480768.65	2020-04-17	\N
829	129	2020-01	salary	4614878.40	2020-01-02	\N
830	252	2020-01	bonus	45812451.11	2020-01-19	\N
831	333	2022-02	bonus	37240350.56	2022-02-15	\N
832	52	2022-06	salary	24967018.09	2022-06-27	\N
833	293	2023-03	salary	5784214.11	2023-03-13	\N
834	163	2020-11	salary	36964464.80	2020-11-04	\N
835	255	2024-04	penalty	19168829.81	2024-04-05	\N
836	340	2025-04	bonus	5157916.84	2025-04-16	\N
837	159	2024-10	salary	34363079.06	2024-10-01	\N
838	165	2021-09	bonus	34205774.19	2021-09-14	\N
839	130	2021-04	salary	36651851.43	2021-04-14	\N
840	348	2025-01	penalty	27153562.48	2025-01-21	\N
841	23	2022-09	penalty	48249721.86	2022-09-24	\N
842	99	2023-07	bonus	35579064.44	2023-07-02	\N
843	221	2020-09	salary	22184235.76	2020-09-22	\N
844	240	2023-04	salary	44939380.44	2023-04-22	\N
845	273	2022-08	bonus	1575966.78	2022-08-31	\N
846	441	2020-02	bonus	34980378.72	2020-02-03	\N
847	448	2021-08	salary	34329396.99	2021-08-27	\N
848	471	2021-03	bonus	26720626.20	2021-03-17	\N
849	247	2021-09	salary	10575203.03	2021-09-26	\N
850	67	2021-09	salary	23235201.04	2021-09-21	\N
851	205	2025-01	penalty	46513643.84	2025-01-11	\N
852	170	2023-01	bonus	49720681.53	2023-01-03	\N
853	394	2025-03	salary	28127947.56	2025-03-12	\N
854	356	2024-11	bonus	893719.18	2024-11-20	\N
855	254	2022-11	penalty	30359961.17	2022-11-25	\N
856	19	2023-03	bonus	49814315.54	2023-03-05	\N
857	462	2022-05	bonus	14559977.94	2022-05-07	\N
858	24	2020-10	salary	17482058.04	2020-10-24	\N
859	162	2022-11	salary	47497227.46	2022-11-06	\N
860	111	2023-04	salary	32188473.67	2023-04-21	\N
861	135	2023-05	penalty	30851725.54	2023-05-24	\N
862	126	2022-10	bonus	47569812.83	2022-10-22	\N
863	498	2024-02	penalty	32548513.57	2024-02-11	\N
864	214	2025-02	penalty	25120106.07	2025-02-15	\N
865	422	2022-04	salary	35696729.40	2022-04-15	\N
866	373	2024-11	bonus	48005274.63	2024-11-24	\N
867	253	2023-09	penalty	2386189.29	2023-09-03	\N
868	163	2024-08	salary	23106403.47	2024-08-14	\N
869	103	2021-09	penalty	43395319.80	2021-09-29	\N
870	57	2020-11	bonus	3692646.29	2020-11-04	\N
871	453	2022-04	bonus	16981757.49	2022-04-03	\N
872	381	2022-12	penalty	17609436.95	2022-12-31	\N
873	456	2021-12	salary	47330451.65	2021-12-29	\N
874	470	2024-10	bonus	9610173.14	2024-10-05	\N
875	136	2022-01	salary	7054074.26	2022-01-29	\N
876	209	2020-06	penalty	31485181.63	2020-06-25	\N
877	28	2023-10	salary	15729331.36	2023-10-17	\N
878	253	2020-03	bonus	29073958.34	2020-03-08	\N
879	255	2021-02	bonus	25123195.80	2021-02-21	\N
880	119	2021-05	penalty	9976344.49	2021-05-29	\N
881	233	2023-09	bonus	35197650.49	2023-09-07	\N
882	37	2021-07	penalty	19230391.24	2021-07-02	\N
883	9	2022-04	penalty	9901646.79	2022-04-01	\N
884	243	2024-07	penalty	3363709.24	2024-07-08	\N
885	431	2023-08	salary	36014694.33	2023-08-15	\N
886	208	2022-04	salary	45607882.44	2022-04-03	\N
887	268	2023-06	salary	27530550.10	2023-06-18	\N
888	217	2023-02	penalty	12219082.43	2023-02-22	\N
889	155	2024-02	bonus	5832097.38	2024-02-16	\N
890	469	2022-09	bonus	18629002.09	2022-09-24	\N
891	451	2021-08	salary	14707348.59	2021-08-20	\N
892	414	2024-07	salary	46448788.86	2024-07-15	\N
893	459	2021-01	penalty	7926191.51	2021-01-22	\N
894	24	2021-02	penalty	9318428.32	2021-02-16	\N
895	314	2020-01	salary	37025696.07	2020-01-26	\N
896	395	2022-08	penalty	5685965.20	2022-08-16	\N
897	118	2020-07	salary	9232912.74	2020-07-12	\N
898	433	2021-07	penalty	36667995.59	2021-07-26	\N
899	129	2024-07	penalty	11462458.94	2024-07-30	\N
900	189	2024-06	bonus	23602069.81	2024-06-24	\N
901	223	2022-06	salary	34972701.46	2022-06-27	\N
902	253	2021-07	penalty	45856121.93	2021-07-12	\N
903	446	2021-01	bonus	31692709.98	2021-01-04	\N
904	380	2021-08	salary	2472820.32	2021-08-21	\N
905	445	2022-06	penalty	2726004.83	2022-06-18	\N
906	145	2020-05	salary	3355784.40	2020-05-22	\N
907	322	2022-06	penalty	3874917.53	2022-06-21	\N
908	420	2020-02	penalty	1891624.26	2020-02-14	\N
909	100	2022-01	bonus	43047438.85	2022-01-09	\N
910	83	2020-09	penalty	22174551.19	2020-09-26	\N
911	173	2023-04	penalty	5736238.16	2023-04-02	\N
912	404	2024-04	salary	45307351.54	2024-04-26	\N
913	144	2021-09	salary	8373279.34	2021-09-24	\N
914	109	2024-12	penalty	27174709.53	2024-12-14	\N
915	42	2021-09	salary	24097381.37	2021-09-16	\N
916	324	2020-01	salary	45464145.10	2020-01-25	\N
917	42	2024-12	bonus	35737713.74	2024-12-13	\N
918	437	2020-02	bonus	22470251.24	2020-02-16	\N
919	23	2020-03	salary	33002368.43	2020-03-26	\N
920	9	2021-03	penalty	29110573.95	2021-03-27	\N
921	1	2024-02	penalty	41663493.29	2024-02-09	\N
922	174	2021-02	bonus	36704823.41	2021-02-20	\N
923	500	2023-06	bonus	35935433.01	2023-06-10	\N
924	327	2020-06	salary	26669637.40	2020-06-09	\N
925	394	2025-05	salary	31186911.51	2025-05-10	\N
926	14	2020-03	bonus	22038335.94	2020-03-10	\N
927	194	2023-10	bonus	8825561.54	2023-10-18	\N
928	403	2024-07	bonus	27401552.33	2024-07-01	\N
929	23	2025-01	salary	15807738.73	2025-01-26	\N
930	23	2022-09	bonus	23466963.48	2022-09-19	\N
931	415	2023-04	bonus	35071169.90	2023-04-19	\N
932	156	2023-03	bonus	25175436.53	2023-03-03	\N
933	496	2023-10	bonus	18452990.07	2023-10-30	\N
934	264	2020-04	bonus	1604165.84	2020-04-29	\N
935	383	2024-08	salary	18248999.10	2024-08-14	\N
936	242	2021-06	penalty	28849829.78	2021-06-26	\N
937	377	2022-11	penalty	9288223.80	2022-11-17	\N
938	316	2020-01	penalty	19413953.14	2020-01-28	\N
939	260	2024-04	bonus	16701229.52	2024-04-27	\N
940	396	2021-07	salary	34891904.56	2021-07-05	\N
941	97	2023-09	salary	49668944.69	2023-09-30	\N
942	201	2024-10	penalty	42613510.37	2024-10-25	\N
943	287	2020-07	salary	1178563.22	2020-07-03	\N
944	198	2024-03	bonus	24972556.27	2024-03-29	\N
945	178	2020-02	penalty	33407281.24	2020-02-17	\N
946	376	2022-09	salary	24333703.99	2022-09-29	\N
947	222	2021-06	salary	43840876.77	2021-06-21	\N
948	67	2022-02	bonus	49390875.25	2022-02-24	\N
949	436	2021-08	penalty	6512431.07	2021-08-29	\N
950	231	2020-11	penalty	40499886.64	2020-11-06	\N
951	98	2023-01	penalty	16745166.34	2023-01-02	\N
952	232	2022-05	bonus	36224926.88	2022-05-15	\N
953	488	2020-07	penalty	18426538.55	2020-07-12	\N
954	86	2023-07	penalty	29276683.71	2023-07-01	\N
955	492	2025-05	bonus	46883048.76	2025-05-27	\N
956	97	2024-08	salary	28664940.49	2024-08-14	\N
957	337	2024-03	bonus	22286474.72	2024-03-19	\N
958	45	2024-06	bonus	17752852.99	2024-06-02	\N
959	89	2024-09	bonus	28552773.27	2024-09-10	\N
960	302	2021-11	salary	33675097.57	2021-11-11	\N
961	71	2022-08	salary	27366847.65	2022-08-06	\N
962	416	2020-10	salary	23457777.52	2020-10-13	\N
963	235	2022-10	bonus	27111016.10	2022-10-06	\N
964	313	2024-07	penalty	31458064.35	2024-07-22	\N
965	299	2021-03	bonus	19255714.67	2021-03-28	\N
966	294	2022-07	penalty	2999389.80	2022-07-25	\N
967	323	2021-04	bonus	31322342.53	2021-04-24	\N
968	240	2022-08	penalty	16920329.83	2022-08-01	\N
969	21	2022-05	salary	13689242.34	2022-05-21	\N
970	479	2023-02	bonus	7599361.02	2023-02-03	\N
971	158	2023-09	penalty	40404794.35	2023-09-17	\N
972	297	2023-08	salary	36630929.59	2023-08-18	\N
973	71	2023-06	bonus	12887637.05	2023-06-06	\N
974	336	2020-08	salary	37230302.68	2020-08-08	\N
975	493	2022-07	salary	34427738.87	2022-07-14	\N
976	216	2022-01	penalty	17267392.83	2022-01-04	\N
977	230	2020-08	salary	43902345.19	2020-08-30	\N
978	375	2021-11	bonus	17379493.30	2021-11-22	\N
979	5	2023-03	penalty	23847536.49	2023-03-19	\N
980	10	2020-11	salary	10792478.68	2020-11-01	\N
981	187	2020-05	salary	4278509.54	2020-05-25	\N
982	142	2025-04	penalty	48683912.65	2025-04-27	\N
983	24	2023-10	salary	13757106.21	2023-10-07	\N
984	366	2022-07	penalty	11408204.38	2022-07-09	\N
985	418	2020-12	salary	33856672.04	2020-12-14	\N
986	129	2025-05	salary	45127326.69	2025-05-28	\N
987	204	2021-06	salary	1861689.87	2021-06-16	\N
988	361	2024-11	bonus	44887482.81	2024-11-11	\N
989	464	2023-09	penalty	16248652.74	2023-09-16	\N
990	108	2021-02	salary	7358627.61	2021-02-02	\N
991	470	2022-01	salary	18345519.23	2022-01-19	\N
992	377	2023-01	penalty	24756960.90	2023-01-24	\N
993	411	2022-07	penalty	5484251.74	2022-07-19	\N
994	499	2024-09	penalty	33025862.96	2024-09-15	\N
995	112	2021-06	penalty	41594340.30	2021-06-04	\N
996	41	2021-02	bonus	47915006.81	2021-02-28	\N
997	190	2024-08	salary	17850392.19	2024-08-27	\N
998	492	2020-02	penalty	15621886.05	2020-02-19	\N
999	247	2023-10	salary	7853650.90	2023-10-13	\N
1000	341	2021-02	penalty	36297647.29	2021-02-26	\N
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
4	11	pending	2025-06-13	Employee created
5	12	pending	2025-06-13	Employee created
6	13	pending	2025-06-13	Employee created
7	14	pending	2025-06-13	Employee created
8	15	pending	2025-06-13	Employee created
9	16	pending	2025-06-13	Employee created
10	17	pending	2025-06-13	Employee created
11	18	pending	2025-06-13	Employee created
12	19	pending	2025-06-13	Employee created
13	20	pending	2025-06-13	Employee created
14	21	pending	2025-06-13	Employee created
15	22	pending	2025-06-13	Employee created
16	23	pending	2025-06-13	Employee created
17	24	pending	2025-06-13	Employee created
18	25	pending	2025-06-13	Employee created
19	26	pending	2025-06-13	Employee created
20	27	pending	2025-06-13	Employee created
21	28	pending	2025-06-13	Employee created
22	29	pending	2025-06-13	Employee created
23	30	pending	2025-06-13	Employee created
24	31	pending	2025-06-13	Employee created
25	32	pending	2025-06-13	Employee created
26	33	pending	2025-06-13	Employee created
27	34	pending	2025-06-13	Employee created
28	35	pending	2025-06-13	Employee created
29	36	pending	2025-06-13	Employee created
30	37	pending	2025-06-13	Employee created
31	38	pending	2025-06-13	Employee created
32	39	pending	2025-06-13	Employee created
33	40	pending	2025-06-13	Employee created
34	41	pending	2025-06-13	Employee created
35	42	pending	2025-06-13	Employee created
36	43	pending	2025-06-13	Employee created
37	44	pending	2025-06-13	Employee created
38	45	pending	2025-06-13	Employee created
39	46	pending	2025-06-13	Employee created
40	47	pending	2025-06-13	Employee created
41	48	pending	2025-06-13	Employee created
42	49	pending	2025-06-13	Employee created
43	50	pending	2025-06-13	Employee created
44	51	pending	2025-06-13	Employee created
45	52	pending	2025-06-13	Employee created
46	53	pending	2025-06-13	Employee created
47	54	pending	2025-06-13	Employee created
48	55	pending	2025-06-13	Employee created
49	56	pending	2025-06-13	Employee created
50	57	pending	2025-06-13	Employee created
51	58	pending	2025-06-13	Employee created
52	59	pending	2025-06-13	Employee created
53	60	pending	2025-06-13	Employee created
54	61	pending	2025-06-13	Employee created
55	62	pending	2025-06-13	Employee created
56	63	pending	2025-06-13	Employee created
57	64	pending	2025-06-13	Employee created
58	65	pending	2025-06-13	Employee created
59	66	pending	2025-06-13	Employee created
60	67	pending	2025-06-13	Employee created
61	68	pending	2025-06-13	Employee created
62	69	pending	2025-06-13	Employee created
63	70	pending	2025-06-13	Employee created
64	71	pending	2025-06-13	Employee created
65	72	pending	2025-06-13	Employee created
66	73	pending	2025-06-13	Employee created
67	74	pending	2025-06-13	Employee created
68	75	pending	2025-06-13	Employee created
69	76	pending	2025-06-13	Employee created
70	77	pending	2025-06-13	Employee created
71	78	pending	2025-06-13	Employee created
72	79	pending	2025-06-13	Employee created
73	80	pending	2025-06-13	Employee created
74	81	pending	2025-06-13	Employee created
75	82	pending	2025-06-13	Employee created
76	83	pending	2025-06-13	Employee created
77	84	pending	2025-06-13	Employee created
78	85	pending	2025-06-13	Employee created
79	86	pending	2025-06-13	Employee created
80	87	pending	2025-06-13	Employee created
81	88	pending	2025-06-13	Employee created
82	89	pending	2025-06-13	Employee created
83	90	pending	2025-06-13	Employee created
84	91	pending	2025-06-13	Employee created
85	92	pending	2025-06-13	Employee created
86	93	pending	2025-06-13	Employee created
87	94	pending	2025-06-13	Employee created
88	95	pending	2025-06-13	Employee created
89	96	pending	2025-06-13	Employee created
90	97	pending	2025-06-13	Employee created
91	98	pending	2025-06-13	Employee created
92	99	pending	2025-06-13	Employee created
93	100	pending	2025-06-13	Employee created
94	101	pending	2025-06-13	Employee created
95	102	pending	2025-06-13	Employee created
96	103	pending	2025-06-13	Employee created
97	104	pending	2025-06-13	Employee created
98	105	pending	2025-06-13	Employee created
99	106	pending	2025-06-13	Employee created
100	107	pending	2025-06-13	Employee created
101	108	pending	2025-06-13	Employee created
102	109	pending	2025-06-13	Employee created
103	110	pending	2025-06-13	Employee created
104	111	pending	2025-06-13	Employee created
105	112	pending	2025-06-13	Employee created
106	113	pending	2025-06-13	Employee created
107	114	pending	2025-06-13	Employee created
108	115	pending	2025-06-13	Employee created
109	116	pending	2025-06-13	Employee created
110	117	pending	2025-06-13	Employee created
111	118	pending	2025-06-13	Employee created
112	119	pending	2025-06-13	Employee created
113	120	pending	2025-06-13	Employee created
114	121	pending	2025-06-13	Employee created
115	122	pending	2025-06-13	Employee created
116	123	pending	2025-06-13	Employee created
117	124	pending	2025-06-13	Employee created
118	125	pending	2025-06-13	Employee created
119	126	pending	2025-06-13	Employee created
120	127	pending	2025-06-13	Employee created
121	128	pending	2025-06-13	Employee created
122	129	pending	2025-06-13	Employee created
123	130	pending	2025-06-13	Employee created
124	131	pending	2025-06-13	Employee created
125	132	pending	2025-06-13	Employee created
126	133	pending	2025-06-13	Employee created
127	134	pending	2025-06-13	Employee created
128	135	pending	2025-06-13	Employee created
129	136	pending	2025-06-13	Employee created
130	137	pending	2025-06-13	Employee created
131	138	pending	2025-06-13	Employee created
132	139	pending	2025-06-13	Employee created
133	140	pending	2025-06-13	Employee created
134	141	pending	2025-06-13	Employee created
135	142	pending	2025-06-13	Employee created
136	143	pending	2025-06-13	Employee created
137	144	pending	2025-06-13	Employee created
138	145	pending	2025-06-13	Employee created
139	146	pending	2025-06-13	Employee created
140	147	pending	2025-06-13	Employee created
141	148	pending	2025-06-13	Employee created
142	149	pending	2025-06-13	Employee created
143	150	pending	2025-06-13	Employee created
144	151	pending	2025-06-13	Employee created
145	152	pending	2025-06-13	Employee created
146	153	pending	2025-06-13	Employee created
147	154	pending	2025-06-13	Employee created
148	155	pending	2025-06-13	Employee created
149	156	pending	2025-06-13	Employee created
150	157	pending	2025-06-13	Employee created
151	158	pending	2025-06-13	Employee created
152	159	pending	2025-06-13	Employee created
153	160	pending	2025-06-13	Employee created
154	161	pending	2025-06-13	Employee created
155	162	pending	2025-06-13	Employee created
156	163	pending	2025-06-13	Employee created
157	164	pending	2025-06-13	Employee created
158	165	pending	2025-06-13	Employee created
159	166	pending	2025-06-13	Employee created
160	167	pending	2025-06-13	Employee created
161	168	pending	2025-06-13	Employee created
162	169	pending	2025-06-13	Employee created
163	170	pending	2025-06-13	Employee created
164	171	pending	2025-06-13	Employee created
165	172	pending	2025-06-13	Employee created
166	173	pending	2025-06-13	Employee created
167	174	pending	2025-06-13	Employee created
168	175	pending	2025-06-13	Employee created
169	176	pending	2025-06-13	Employee created
170	177	pending	2025-06-13	Employee created
171	178	pending	2025-06-13	Employee created
172	179	pending	2025-06-13	Employee created
173	180	pending	2025-06-13	Employee created
174	181	pending	2025-06-13	Employee created
175	182	pending	2025-06-13	Employee created
176	183	pending	2025-06-13	Employee created
177	184	pending	2025-06-13	Employee created
178	185	pending	2025-06-13	Employee created
179	186	pending	2025-06-13	Employee created
180	187	pending	2025-06-13	Employee created
181	188	pending	2025-06-13	Employee created
182	189	pending	2025-06-13	Employee created
183	190	pending	2025-06-13	Employee created
184	191	pending	2025-06-13	Employee created
185	192	pending	2025-06-13	Employee created
186	193	pending	2025-06-13	Employee created
187	194	pending	2025-06-13	Employee created
188	195	pending	2025-06-13	Employee created
189	196	pending	2025-06-13	Employee created
190	197	pending	2025-06-13	Employee created
191	198	pending	2025-06-13	Employee created
192	199	pending	2025-06-13	Employee created
193	200	pending	2025-06-13	Employee created
194	201	pending	2025-06-13	Employee created
195	202	pending	2025-06-13	Employee created
196	203	pending	2025-06-13	Employee created
197	204	pending	2025-06-13	Employee created
198	205	pending	2025-06-13	Employee created
199	206	pending	2025-06-13	Employee created
200	207	pending	2025-06-13	Employee created
201	208	pending	2025-06-13	Employee created
202	209	pending	2025-06-13	Employee created
203	210	pending	2025-06-13	Employee created
204	211	pending	2025-06-13	Employee created
205	212	pending	2025-06-13	Employee created
206	213	pending	2025-06-13	Employee created
207	214	pending	2025-06-13	Employee created
208	215	pending	2025-06-13	Employee created
209	216	pending	2025-06-13	Employee created
210	217	pending	2025-06-13	Employee created
211	218	pending	2025-06-13	Employee created
212	219	pending	2025-06-13	Employee created
213	220	pending	2025-06-13	Employee created
214	221	pending	2025-06-13	Employee created
215	222	pending	2025-06-13	Employee created
216	223	pending	2025-06-13	Employee created
217	224	pending	2025-06-13	Employee created
218	225	pending	2025-06-13	Employee created
219	226	pending	2025-06-13	Employee created
220	227	pending	2025-06-13	Employee created
221	228	pending	2025-06-13	Employee created
222	229	pending	2025-06-13	Employee created
223	230	pending	2025-06-13	Employee created
224	231	pending	2025-06-13	Employee created
225	232	pending	2025-06-13	Employee created
226	233	pending	2025-06-13	Employee created
227	234	pending	2025-06-13	Employee created
228	235	pending	2025-06-13	Employee created
229	236	pending	2025-06-13	Employee created
230	237	pending	2025-06-13	Employee created
231	238	pending	2025-06-13	Employee created
232	239	pending	2025-06-13	Employee created
233	240	pending	2025-06-13	Employee created
234	241	pending	2025-06-13	Employee created
235	242	pending	2025-06-13	Employee created
236	243	pending	2025-06-13	Employee created
237	244	pending	2025-06-13	Employee created
238	245	pending	2025-06-13	Employee created
239	246	pending	2025-06-13	Employee created
240	247	pending	2025-06-13	Employee created
241	248	pending	2025-06-13	Employee created
242	249	pending	2025-06-13	Employee created
243	250	pending	2025-06-13	Employee created
244	251	pending	2025-06-13	Employee created
245	252	pending	2025-06-13	Employee created
246	253	pending	2025-06-13	Employee created
247	254	pending	2025-06-13	Employee created
248	255	pending	2025-06-13	Employee created
249	256	pending	2025-06-13	Employee created
250	257	pending	2025-06-13	Employee created
251	258	pending	2025-06-13	Employee created
252	259	pending	2025-06-13	Employee created
253	260	pending	2025-06-13	Employee created
254	261	pending	2025-06-13	Employee created
255	262	pending	2025-06-13	Employee created
256	263	pending	2025-06-13	Employee created
257	264	pending	2025-06-13	Employee created
258	265	pending	2025-06-13	Employee created
259	266	pending	2025-06-13	Employee created
260	267	pending	2025-06-13	Employee created
261	268	pending	2025-06-13	Employee created
262	269	pending	2025-06-13	Employee created
263	270	pending	2025-06-13	Employee created
264	271	pending	2025-06-13	Employee created
265	272	pending	2025-06-13	Employee created
266	273	pending	2025-06-13	Employee created
267	274	pending	2025-06-13	Employee created
268	275	pending	2025-06-13	Employee created
269	276	pending	2025-06-13	Employee created
270	277	pending	2025-06-13	Employee created
271	278	pending	2025-06-13	Employee created
272	279	pending	2025-06-13	Employee created
273	280	pending	2025-06-13	Employee created
274	281	pending	2025-06-13	Employee created
275	282	pending	2025-06-13	Employee created
276	283	pending	2025-06-13	Employee created
277	284	pending	2025-06-13	Employee created
278	285	pending	2025-06-13	Employee created
279	286	pending	2025-06-13	Employee created
280	287	pending	2025-06-13	Employee created
281	288	pending	2025-06-13	Employee created
282	289	pending	2025-06-13	Employee created
283	290	pending	2025-06-13	Employee created
284	291	pending	2025-06-13	Employee created
285	292	pending	2025-06-13	Employee created
286	293	pending	2025-06-13	Employee created
287	294	pending	2025-06-13	Employee created
288	295	pending	2025-06-13	Employee created
289	296	pending	2025-06-13	Employee created
290	297	pending	2025-06-13	Employee created
291	298	pending	2025-06-13	Employee created
292	299	pending	2025-06-13	Employee created
293	300	pending	2025-06-13	Employee created
294	301	pending	2025-06-13	Employee created
295	302	pending	2025-06-13	Employee created
296	303	pending	2025-06-13	Employee created
297	304	pending	2025-06-13	Employee created
298	305	pending	2025-06-13	Employee created
299	306	pending	2025-06-13	Employee created
300	307	pending	2025-06-13	Employee created
301	308	pending	2025-06-13	Employee created
302	309	pending	2025-06-13	Employee created
303	310	pending	2025-06-13	Employee created
304	311	pending	2025-06-13	Employee created
305	312	pending	2025-06-13	Employee created
306	313	pending	2025-06-13	Employee created
307	314	pending	2025-06-13	Employee created
308	315	pending	2025-06-13	Employee created
309	316	pending	2025-06-13	Employee created
310	317	pending	2025-06-13	Employee created
311	318	pending	2025-06-13	Employee created
312	319	pending	2025-06-13	Employee created
313	320	pending	2025-06-13	Employee created
314	321	pending	2025-06-13	Employee created
315	322	pending	2025-06-13	Employee created
316	323	pending	2025-06-13	Employee created
317	324	pending	2025-06-13	Employee created
318	325	pending	2025-06-13	Employee created
319	326	pending	2025-06-13	Employee created
320	327	pending	2025-06-13	Employee created
321	328	pending	2025-06-13	Employee created
322	329	pending	2025-06-13	Employee created
323	330	pending	2025-06-13	Employee created
324	331	pending	2025-06-13	Employee created
325	332	pending	2025-06-13	Employee created
326	333	pending	2025-06-13	Employee created
327	334	pending	2025-06-13	Employee created
328	335	pending	2025-06-13	Employee created
329	336	pending	2025-06-13	Employee created
330	337	pending	2025-06-13	Employee created
331	338	pending	2025-06-13	Employee created
332	339	pending	2025-06-13	Employee created
333	340	pending	2025-06-13	Employee created
334	341	pending	2025-06-13	Employee created
335	342	pending	2025-06-13	Employee created
336	343	pending	2025-06-13	Employee created
337	344	pending	2025-06-13	Employee created
338	345	pending	2025-06-13	Employee created
339	346	pending	2025-06-13	Employee created
340	347	pending	2025-06-13	Employee created
341	348	pending	2025-06-13	Employee created
342	349	pending	2025-06-13	Employee created
343	350	pending	2025-06-13	Employee created
344	351	pending	2025-06-13	Employee created
345	352	pending	2025-06-13	Employee created
346	353	pending	2025-06-13	Employee created
347	354	pending	2025-06-13	Employee created
348	355	pending	2025-06-13	Employee created
349	356	pending	2025-06-13	Employee created
350	357	pending	2025-06-13	Employee created
351	358	pending	2025-06-13	Employee created
352	359	pending	2025-06-13	Employee created
353	360	pending	2025-06-13	Employee created
354	361	pending	2025-06-13	Employee created
355	362	pending	2025-06-13	Employee created
356	363	pending	2025-06-13	Employee created
357	364	pending	2025-06-13	Employee created
358	365	pending	2025-06-13	Employee created
359	366	pending	2025-06-13	Employee created
360	367	pending	2025-06-13	Employee created
361	368	pending	2025-06-13	Employee created
362	369	pending	2025-06-13	Employee created
363	370	pending	2025-06-13	Employee created
364	371	pending	2025-06-13	Employee created
365	372	pending	2025-06-13	Employee created
366	373	pending	2025-06-13	Employee created
367	374	pending	2025-06-13	Employee created
368	375	pending	2025-06-13	Employee created
369	376	pending	2025-06-13	Employee created
370	377	pending	2025-06-13	Employee created
371	378	pending	2025-06-13	Employee created
372	379	pending	2025-06-13	Employee created
373	380	pending	2025-06-13	Employee created
374	381	pending	2025-06-13	Employee created
375	382	pending	2025-06-13	Employee created
376	383	pending	2025-06-13	Employee created
377	384	pending	2025-06-13	Employee created
378	385	pending	2025-06-13	Employee created
379	386	pending	2025-06-13	Employee created
380	387	pending	2025-06-13	Employee created
381	388	pending	2025-06-13	Employee created
382	389	pending	2025-06-13	Employee created
383	390	pending	2025-06-13	Employee created
384	391	pending	2025-06-13	Employee created
385	392	pending	2025-06-13	Employee created
386	393	pending	2025-06-13	Employee created
387	394	pending	2025-06-13	Employee created
388	395	pending	2025-06-13	Employee created
389	396	pending	2025-06-13	Employee created
390	397	pending	2025-06-13	Employee created
391	398	pending	2025-06-13	Employee created
392	399	pending	2025-06-13	Employee created
393	400	pending	2025-06-13	Employee created
394	401	pending	2025-06-13	Employee created
395	402	pending	2025-06-13	Employee created
396	403	pending	2025-06-13	Employee created
397	404	pending	2025-06-13	Employee created
398	405	pending	2025-06-13	Employee created
399	406	pending	2025-06-13	Employee created
400	407	pending	2025-06-13	Employee created
401	408	pending	2025-06-13	Employee created
402	409	pending	2025-06-13	Employee created
403	410	pending	2025-06-13	Employee created
404	411	pending	2025-06-13	Employee created
405	412	pending	2025-06-13	Employee created
406	413	pending	2025-06-13	Employee created
407	414	pending	2025-06-13	Employee created
408	415	pending	2025-06-13	Employee created
409	416	pending	2025-06-13	Employee created
410	417	pending	2025-06-13	Employee created
411	418	pending	2025-06-13	Employee created
412	419	pending	2025-06-13	Employee created
413	420	pending	2025-06-13	Employee created
414	421	pending	2025-06-13	Employee created
415	422	pending	2025-06-13	Employee created
416	423	pending	2025-06-13	Employee created
417	424	pending	2025-06-13	Employee created
418	425	pending	2025-06-13	Employee created
419	426	pending	2025-06-13	Employee created
420	427	pending	2025-06-13	Employee created
421	428	pending	2025-06-13	Employee created
422	429	pending	2025-06-13	Employee created
423	430	pending	2025-06-13	Employee created
424	431	pending	2025-06-13	Employee created
425	432	pending	2025-06-13	Employee created
426	433	pending	2025-06-13	Employee created
427	434	pending	2025-06-13	Employee created
428	435	pending	2025-06-13	Employee created
429	436	pending	2025-06-13	Employee created
430	437	pending	2025-06-13	Employee created
431	438	pending	2025-06-13	Employee created
432	439	pending	2025-06-13	Employee created
433	440	pending	2025-06-13	Employee created
434	441	pending	2025-06-13	Employee created
435	442	pending	2025-06-13	Employee created
436	443	pending	2025-06-13	Employee created
437	444	pending	2025-06-13	Employee created
438	445	pending	2025-06-13	Employee created
439	446	pending	2025-06-13	Employee created
440	447	pending	2025-06-13	Employee created
441	448	pending	2025-06-13	Employee created
442	449	pending	2025-06-13	Employee created
443	450	pending	2025-06-13	Employee created
444	451	pending	2025-06-13	Employee created
445	452	pending	2025-06-13	Employee created
446	453	pending	2025-06-13	Employee created
447	454	pending	2025-06-13	Employee created
448	455	pending	2025-06-13	Employee created
449	456	pending	2025-06-13	Employee created
450	457	pending	2025-06-13	Employee created
451	458	pending	2025-06-13	Employee created
452	459	pending	2025-06-13	Employee created
453	460	pending	2025-06-13	Employee created
454	461	pending	2025-06-13	Employee created
455	462	pending	2025-06-13	Employee created
456	463	pending	2025-06-13	Employee created
457	464	pending	2025-06-13	Employee created
458	465	pending	2025-06-13	Employee created
459	466	pending	2025-06-13	Employee created
460	467	pending	2025-06-13	Employee created
461	468	pending	2025-06-13	Employee created
462	469	pending	2025-06-13	Employee created
463	470	pending	2025-06-13	Employee created
464	471	pending	2025-06-13	Employee created
465	472	pending	2025-06-13	Employee created
466	473	pending	2025-06-13	Employee created
467	474	pending	2025-06-13	Employee created
468	475	pending	2025-06-13	Employee created
469	476	pending	2025-06-13	Employee created
470	477	pending	2025-06-13	Employee created
471	478	pending	2025-06-13	Employee created
472	479	pending	2025-06-13	Employee created
473	480	pending	2025-06-13	Employee created
474	481	pending	2025-06-13	Employee created
475	482	pending	2025-06-13	Employee created
476	483	pending	2025-06-13	Employee created
477	484	pending	2025-06-13	Employee created
478	485	pending	2025-06-13	Employee created
479	486	pending	2025-06-13	Employee created
480	487	pending	2025-06-13	Employee created
481	488	pending	2025-06-13	Employee created
482	489	pending	2025-06-13	Employee created
483	490	pending	2025-06-13	Employee created
484	491	pending	2025-06-13	Employee created
485	492	pending	2025-06-13	Employee created
486	493	pending	2025-06-13	Employee created
487	494	pending	2025-06-13	Employee created
488	495	pending	2025-06-13	Employee created
489	496	pending	2025-06-13	Employee created
490	497	pending	2025-06-13	Employee created
491	498	pending	2025-06-13	Employee created
492	499	pending	2025-06-13	Employee created
493	500	pending	2025-06-13	Employee created
494	501	pending	2025-06-13	Employee created
\.


--
-- Name: batch_batch_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.batch_batch_id_seq', 2557, true);


--
-- Name: customer_customer_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.customer_customer_id_seq', 1513, true);


--
-- Name: customer_order_order_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.customer_order_order_id_seq', 7, true);


--
-- Name: employee_employee_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.employee_employee_id_seq', 501, true);


--
-- Name: employment_contract_contract_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.employment_contract_contract_id_seq', 208, true);


--
-- Name: operating_expense_log_log_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.operating_expense_log_log_id_seq', 2000, true);


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

SELECT pg_catalog.setval('public.salary_bonus_log_log_id_seq', 1000, true);


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

SELECT pg_catalog.setval('public.work_status_log_log_id_seq', 494, true);


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
-- Name: employee employee_national_id_unique; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.employee
    ADD CONSTRAINT employee_national_id_unique UNIQUE (national_id);


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
-- Name: TABLE batch; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.batch TO admin_role;
GRANT SELECT ON TABLE public.batch TO manager_role;
GRANT SELECT ON TABLE public.batch TO sales_staff_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.batch TO warehouse_staff_role;


--
-- Name: TABLE customer; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.customer TO admin_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.customer TO manager_role;
GRANT SELECT,UPDATE ON TABLE public.customer TO customer_role;


--
-- Name: TABLE customer_order; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.customer_order TO admin_role;
GRANT SELECT ON TABLE public.customer_order TO manager_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.customer_order TO sales_staff_role;
GRANT SELECT,INSERT ON TABLE public.customer_order TO customer_role;


--
-- Name: TABLE employee; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.employee TO admin_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.employee TO manager_role;
GRANT SELECT ON TABLE public.employee TO sales_staff_role;


--
-- Name: TABLE employment_contract; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.employment_contract TO admin_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.employment_contract TO manager_role;


--
-- Name: TABLE operating_expense_log; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.operating_expense_log TO admin_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.operating_expense_log TO manager_role;


--
-- Name: TABLE order_detail; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.order_detail TO admin_role;
GRANT SELECT ON TABLE public.order_detail TO manager_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.order_detail TO sales_staff_role;
GRANT SELECT ON TABLE public.order_detail TO customer_role;


--
-- Name: TABLE product; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.product TO admin_role;
GRANT SELECT ON TABLE public.product TO manager_role;
GRANT SELECT ON TABLE public.product TO sales_staff_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.product TO warehouse_staff_role;
GRANT SELECT ON TABLE public.product TO customer_role;


--
-- Name: TABLE product_category; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.product_category TO admin_role;
GRANT SELECT ON TABLE public.product_category TO manager_role;
GRANT SELECT ON TABLE public.product_category TO sales_staff_role;
GRANT SELECT ON TABLE public.product_category TO warehouse_staff_role;


--
-- Name: TABLE salary_bonus_log; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.salary_bonus_log TO admin_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.salary_bonus_log TO manager_role;


--
-- Name: TABLE warehouse; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.warehouse TO admin_role;
GRANT SELECT ON TABLE public.warehouse TO manager_role;
GRANT SELECT ON TABLE public.warehouse TO sales_staff_role;
GRANT SELECT,INSERT,UPDATE ON TABLE public.warehouse TO warehouse_staff_role;


--
-- Name: TABLE warehouse_category; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.warehouse_category TO admin_role;
GRANT SELECT ON TABLE public.warehouse_category TO manager_role;
GRANT SELECT ON TABLE public.warehouse_category TO sales_staff_role;
GRANT SELECT ON TABLE public.warehouse_category TO warehouse_staff_role;


--
-- Name: TABLE work_status_log; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.work_status_log TO admin_role;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.work_status_log TO manager_role;


--
-- PostgreSQL database dump complete
--

