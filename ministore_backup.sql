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
-- Name: check_zero_stock_quantity(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.check_zero_stock_quantity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.stock_quantity IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 
        'Stock quantity must be 0 when adding a new product. If you want to increase stock, please create a new batch.';
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.check_zero_stock_quantity() OWNER TO postgres;

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
-- Name: prevent_manual_stock_quantity_update(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prevent_manual_stock_quantity_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.stock_quantity IS DISTINCT FROM OLD.stock_quantity THEN
        RAISE EXCEPTION 'You cannot manually update stock_quantity. Stock quantity is only updated automatically when adding a new batch.';
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.prevent_manual_stock_quantity_update() OWNER TO postgres;

--
-- Name: prevent_update_if_canceled(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.prevent_update_if_canceled() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF OLD.order_status = 'canceled' THEN
        RAISE EXCEPTION 'Order canceled, cannot update this order!';
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.prevent_update_if_canceled() OWNER TO postgres;

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
    cart text,
    registration_date date DEFAULT CURRENT_DATE,
    status character varying(32) DEFAULT 'active'::character varying,
    password character varying(128),
    CONSTRAINT customer_gender_check CHECK ((gender = ANY (ARRAY['M'::bpchar, 'F'::bpchar]))),
    CONSTRAINT customer_rank_check CHECK (((rank)::text = ANY ((ARRAY['silver'::character varying, 'gold'::character varying, 'diamond'::character varying])::text[]))),
    CONSTRAINT customer_status_check CHECK (((status)::text = ANY ((ARRAY['active'::character varying, 'blocked'::character varying, 'inactive'::character varying])::text[])))
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
    total_amount numeric(15,2),
    payment_method character varying(32),
    order_status character varying(32),
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
    CONSTRAINT employee_role_check CHECK (((role)::text = ANY ((ARRAY['sales_staff'::character varying, 'warehouse_staff'::character varying, 'warehouse_manager'::character varying, 'store_manager'::character varying, 'accountant'::character varying])::text[])))
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
    effective_date date
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
-- Name: warehouse warehouse_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouse ALTER COLUMN warehouse_id SET DEFAULT nextval('public.warehouse_warehouse_id_seq'::regclass);


--
-- Name: warehouse_category warehouse_category_id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouse_category ALTER COLUMN warehouse_category_id SET DEFAULT nextval('public.warehouse_category_warehouse_category_id_seq'::regclass);


--
-- Data for Name: batch; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.batch (batch_id, product_id, import_date, expiry_date, purchase_price, quantity, note, warehouse_id, remaining_quantity) FROM stdin;
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
35	1	2024-06-01	2024-12-01	75000.00	20	\N	1	20
46	1	2024-06-10	2026-01-10	76000.00	25	\N	1	25
38	4	2024-06-01	2024-11-30	190000.00	5	\N	1	5
49	4	2024-07-01	2026-04-30	192000.00	7	\N	1	7
39	5	2024-06-01	2024-07-10	14000.00	50	\N	2	50
50	5	2024-07-05	2026-05-10	14200.00	30	\N	2	30
\.


--
-- Data for Name: customer; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.customer (customer_id, full_name, gender, date_of_birth, phone, email, member_points, rank, cart, registration_date, status, password) FROM stdin;
1	Nguyen Van A	M	1990-01-01	0901000001	a.nguyen@email.com	50	silver	\N	2024-06-01	active	password1
2	Tran Thi B	F	1992-02-02	0901000002	b.tran@email.com	60	silver	\N	2024-06-02	active	password2
3	Le Van C	M	1988-03-03	0901000003	c.le@email.com	90	gold	\N	2024-06-03	active	password3
4	Pham Thi D	F	1995-04-04	0901000004	d.pham@email.com	20	silver	\N	2024-06-04	active	password4
5	Vo Minh E	M	1993-05-05	0901000005	e.vo@email.com	120	diamond	\N	2024-06-05	active	password5
6	Bui Thi F	F	1991-06-06	0901000006	f.bui@email.com	35	silver	\N	2024-06-06	blocked	password6
7	Doan Van G	M	1989-07-07	0901000007	g.doan@email.com	70	gold	\N	2024-06-07	active	password7
8	Dang Thi H	F	1996-08-08	0901000008	h.dang@email.com	10	silver	\N	2024-06-08	inactive	password8
9	Pham Van I	M	1994-09-09	0901000009	i.pham@email.com	100	diamond	\N	2024-06-09	active	password9
10	Tran Thi J	F	1997-10-10	0901000010	j.tran@email.com	80	gold	\N	2024-06-10	active	password10
\.


--
-- Data for Name: customer_order; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.customer_order (order_id, customer_id, employee_id, delivered_at, total_amount, payment_method, order_status, note, payment_status) FROM stdin;
1	1	2	2025-06-01 21:29:40.507785	6400000.00	cash	canceled	\N	refunded
2	1	2	2025-06-01 21:55:09.986117	6400000.00	cash	canceled	\N	unpaid
\.


--
-- Data for Name: employee; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.employee (employee_id, full_name, role, age, national_id, gender, address, phone, email, salary, password, employment_status) FROM stdin;
1	Alice Johnson	sales_staff	25	ID001	F	123 Main St	0123456789	alice@example.com	800.00	alicepass	pending
4	David Kim	store_manager	40	ID004	M	321 South St	0123456792	david@example.com	1500.00	davidpass	pending
8	Henry Ford	warehouse_manager	38	ID008	M	258 Garden Dr	0123456796	henry@example.com	1100.00	henrypass	pending
9	Ivy Nguyen	store_manager	27	ID009	F	369 Lake St	0123456797	ivy@example.com	1450.00	ivypass	active
3	Carol Lee	warehouse_manager	35	ID003	F	789 North Rd	0123456791	carol@example.com	1200.00	carolpass	active
5	Eva Green	accountant	28	ID005	F	654 West St	0123456793	eva@example.com	950.00	evapass	active
10	Jack White	accountant	31	ID010	M	753 Hill Rd	0123456798	jack@example.com	970.00	jackpass	active
6	Frank Brown	sales_staff	32	ID006	M	987 East Ave	0123456794	frank@example.com	820.00	frankpass	active
2	Bob Smith	warehouse_staff	30	ID002	M	456 First Ave	0123456790	bob@example.com	900.00	bobpass	active
7	Grace Lee	warehouse_staff	29	ID007	F	147 Park Blvd	0123456795	grace@example.com	880.00	gracepass	resigned
\.


--
-- Data for Name: employment_contract; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.employment_contract (contract_id, employee_id, contract_date, termination_reason, termination_date, content, contract_end_date, effective_date) FROM stdin;
1	2	2024-06-01	\N	\N	Labor contract for Bob Smith	2026-06-01	2024-06-10
2	3	2024-06-01	\N	\N	Labor contract for Carol Lee	2026-06-01	2024-06-10
3	5	2024-06-01	\N	\N	Labor contract for Eva Green	2026-06-01	2024-06-10
4	6	2024-06-01	\N	\N	Labor contract for Frank Brown	2026-06-01	2024-06-10
5	9	2024-06-01	\N	\N	Labor contract for Ivy Nguyen	2026-06-01	2024-06-10
6	10	2024-06-01	\N	\N	Labor contract for Jack White	2026-06-01	2024-06-10
8	7	2022-06-01	Contract ended normally	2023-06-10	Expired labor contract for Grace Lee	2023-06-10	2022-06-10
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
-- Name: batch_batch_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.batch_batch_id_seq', 55, true);


--
-- Name: customer_customer_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.customer_customer_id_seq', 10, true);


--
-- Name: customer_order_order_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.customer_order_order_id_seq', 2, true);


--
-- Name: employee_employee_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.employee_employee_id_seq', 10, true);


--
-- Name: employment_contract_contract_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.employment_contract_contract_id_seq', 8, true);


--
-- Name: order_detail_order_detail_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.order_detail_order_detail_id_seq', 12, true);


--
-- Name: product_category_product_category_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.product_category_product_category_id_seq', 7, true);


--
-- Name: product_product_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.product_product_id_seq', 20, true);


--
-- Name: warehouse_category_warehouse_category_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.warehouse_category_warehouse_category_id_seq', 7, true);


--
-- Name: warehouse_warehouse_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.warehouse_warehouse_id_seq', 10, true);


--
-- Name: batch batch_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.batch
    ADD CONSTRAINT batch_pkey PRIMARY KEY (batch_id);


--
-- Name: customer_order customer_order_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer_order
    ADD CONSTRAINT customer_order_pkey PRIMARY KEY (order_id);


--
-- Name: customer customer_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.customer
    ADD CONSTRAINT customer_pkey PRIMARY KEY (customer_id);


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
-- Name: batch trg_check_batch_warehouse_category; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_check_batch_warehouse_category BEFORE INSERT ON public.batch FOR EACH ROW EXECUTE FUNCTION public.check_batch_warehouse_category();


--
-- Name: batch trg_check_expiry_date_not_null; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_check_expiry_date_not_null BEFORE INSERT OR UPDATE ON public.batch FOR EACH ROW EXECUTE FUNCTION public.check_expiry_date_not_null();


--
-- Name: product trg_check_zero_stock_quantity; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_check_zero_stock_quantity BEFORE INSERT ON public.product FOR EACH ROW EXECUTE FUNCTION public.check_zero_stock_quantity();


--
-- Name: employee trg_enforce_contract_on_status_change; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_enforce_contract_on_status_change BEFORE UPDATE OF employment_status ON public.employee FOR EACH ROW EXECUTE FUNCTION public.enforce_contract_on_status_change();


--
-- Name: employee trg_enforce_pending_on_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_enforce_pending_on_insert BEFORE INSERT ON public.employee FOR EACH ROW EXECUTE FUNCTION public.enforce_pending_on_insert();


--
-- Name: customer_order trg_prevent_update_if_canceled; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_prevent_update_if_canceled BEFORE UPDATE ON public.customer_order FOR EACH ROW EXECUTE FUNCTION public.prevent_update_if_canceled();


--
-- Name: customer_order trg_set_delivered_at; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_set_delivered_at BEFORE UPDATE ON public.customer_order FOR EACH ROW EXECUTE FUNCTION public.set_delivered_at_when_completed();


--
-- Name: batch trg_set_remaining_quantity_on_batch_insert; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER trg_set_remaining_quantity_on_batch_insert BEFORE INSERT ON public.batch FOR EACH ROW EXECUTE FUNCTION public.set_remaining_quantity_on_batch_insert();


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
-- Name: warehouse warehouse_warehouse_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.warehouse
    ADD CONSTRAINT warehouse_warehouse_category_id_fkey FOREIGN KEY (warehouse_category_id) REFERENCES public.warehouse_category(warehouse_category_id) ON DELETE SET NULL;


--
-- PostgreSQL database dump complete
--

