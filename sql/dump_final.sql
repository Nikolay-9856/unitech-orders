--
-- PostgreSQL database dump
--

\restrict 8Koib4vwrWNxagyhuqMxshci2oW07xrV4SF48F09U0QKzcyC6vaE3L7hgo2o9u2

-- Dumped from database version 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)
-- Dumped by pg_dump version 16.15 (Ubuntu 16.15-0ubuntu0.24.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: fn_order_items_line_sum(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_order_items_line_sum() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.line_sum := NEW.qty * NEW.price;
    RETURN NEW;
END;
$$;


--
-- Name: fn_orders_recalc_total(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_orders_recalc_total() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_order INT := COALESCE(NEW.order_id, OLD.order_id);
BEGIN
    UPDATE orders
       SET total_amount = (SELECT COALESCE(SUM(line_sum), 0)
                             FROM order_items WHERE order_id = v_order)
     WHERE order_id = v_order;
    RETURN NULL;
END;
$$;


--
-- Name: fn_orders_status_audit(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_orders_status_audit() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public'
    AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO order_status_log (order_id, old_status, new_status, changed_by)
        VALUES (NEW.order_id, NULL, NEW.status, NEW.manager_id);
    ELSIF OLD.status IS DISTINCT FROM NEW.status THEN
        INSERT INTO order_status_log (order_id, old_status, new_status, changed_by)
        VALUES (NEW.order_id, OLD.status, NEW.status,
                NULLIF(current_setting('app.user_id', TRUE), '')::INT);
    END IF;
    RETURN NULL;
END;
$$;


--
-- Name: fn_set_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.fn_set_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;


--
-- Name: sp_add_order_item(integer, integer, integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_add_order_item(IN p_order_id integer, IN p_product_id integer, IN p_qty integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_status VARCHAR(20);
    v_price  NUMERIC(12,2);
    v_stock  INT;
    v_have   INT;
BEGIN
    SELECT status INTO v_status FROM orders WHERE order_id = p_order_id FOR UPDATE;
    IF v_status IS NULL THEN
        RAISE EXCEPTION 'Заказ % не найден', p_order_id USING ERRCODE = 'P0002';
    ELSIF v_status <> 'Новый' THEN
        RAISE EXCEPTION 'Состав можно менять только у нового заказа (сейчас «%»)', v_status
              USING ERRCODE = 'P0001';
    ELSIF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'Количество должно быть больше нуля' USING ERRCODE = '22023';
    END IF;

    SELECT price, stock_qty INTO v_price, v_stock
      FROM products WHERE product_id = p_product_id AND is_active;
    IF v_price IS NULL THEN
        RAISE EXCEPTION 'Товар % не найден или снят с продажи', p_product_id USING ERRCODE = 'P0002';
    END IF;

    SELECT COALESCE(qty, 0) INTO v_have
      FROM order_items WHERE order_id = p_order_id AND product_id = p_product_id;
    IF COALESCE(v_have, 0) + p_qty > v_stock THEN
        RAISE EXCEPTION 'Недостаточно товара на складе: доступно %, запрошено %',
              v_stock, COALESCE(v_have, 0) + p_qty USING ERRCODE = 'P0001';
    END IF;

    -- повторное добавление того же товара увеличивает количество
    INSERT INTO order_items (order_id, product_id, qty, price)
    VALUES (p_order_id, p_product_id, p_qty, v_price)
    ON CONFLICT (order_id, product_id)
    DO UPDATE SET qty = order_items.qty + EXCLUDED.qty, price = EXCLUDED.price;
END;
$$;


--
-- Name: sp_change_order_status(integer, character varying, integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_change_order_status(IN p_order_id integer, IN p_new_status character varying, IN p_user_id integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_old   VARCHAR(20);
    v_total NUMERIC(14,2);
    v_paid  NUMERIC(14,2);
    v_short TEXT;
BEGIN
    SELECT status, total_amount INTO v_old, v_total
      FROM orders WHERE order_id = p_order_id FOR UPDATE;
    IF v_old IS NULL THEN
        RAISE EXCEPTION 'Заказ % не найден', p_order_id USING ERRCODE = 'P0002';
    END IF;

    IF (v_old, p_new_status) NOT IN (
        ('Новый','Подтверждён'), ('Новый','Отменён'),
        ('Подтверждён','Комплектуется'), ('Подтверждён','Отменён'),
        ('Комплектуется','Отгружен'), ('Отгружен','Закрыт')) THEN
        RAISE EXCEPTION 'Переход «%» → «%» не допускается', v_old, p_new_status
              USING ERRCODE = 'P0001';
    END IF;

    IF p_new_status = 'Подтверждён' THEN
        IF NOT EXISTS (SELECT 1 FROM order_items WHERE order_id = p_order_id) THEN
            RAISE EXCEPTION 'Нельзя подтвердить пустой заказ' USING ERRCODE = 'P0001';
        END IF;
        SELECT string_agg(pr.sku, ', ') INTO v_short
          FROM order_items oi JOIN products pr ON pr.product_id = oi.product_id
         WHERE oi.order_id = p_order_id AND oi.qty > pr.stock_qty;
        IF v_short IS NOT NULL THEN
            RAISE EXCEPTION 'Не хватает остатка по позициям: %', v_short USING ERRCODE = 'P0001';
        END IF;
        -- резервирование: списываем остаток со склада
        UPDATE products pr SET stock_qty = pr.stock_qty - oi.qty
          FROM order_items oi
         WHERE oi.order_id = p_order_id AND pr.product_id = oi.product_id;
    ELSIF p_new_status = 'Отменён' AND v_old = 'Подтверждён' THEN
        -- снятие резерва
        UPDATE products pr SET stock_qty = pr.stock_qty + oi.qty
          FROM order_items oi
         WHERE oi.order_id = p_order_id AND pr.product_id = oi.product_id;
    ELSIF p_new_status = 'Закрыт' THEN
        SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE order_id = p_order_id;
        IF v_paid < v_total THEN
            RAISE EXCEPTION 'Заказ оплачен не полностью: % из %', v_paid, v_total USING ERRCODE = 'P0001';
        END IF;
    END IF;

    PERFORM set_config('app.user_id', p_user_id::TEXT, TRUE);
    UPDATE orders SET status = p_new_status WHERE order_id = p_order_id;
END;
$$;


--
-- Name: sp_create_order(integer, integer, date, character varying, character varying, integer, character varying); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_create_order(IN p_customer_id integer, IN p_manager_id integer, IN p_due_date date, IN p_address character varying, IN p_comment character varying, INOUT p_order_id integer DEFAULT NULL::integer, INOUT p_order_number character varying DEFAULT NULL::character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_seq INT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM customers WHERE customer_id = p_customer_id) THEN
        RAISE EXCEPTION 'Клиент % не найден', p_customer_id USING ERRCODE = 'P0002';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM users WHERE user_id = p_manager_id AND is_active) THEN
        RAISE EXCEPTION 'Менеджер % не найден или заблокирован', p_manager_id USING ERRCODE = 'P0002';
    END IF;

    -- сквозная нумерация в пределах года; блокировка от одновременной выдачи номера
    PERFORM pg_advisory_xact_lock(hashtext('orders_number'));
    SELECT COALESCE(MAX(split_part(order_number, '-', 3)::INT), 0) + 1
      INTO v_seq
      FROM orders
     WHERE split_part(order_number, '-', 2) = to_char(current_date, 'YYYY');

    p_order_number := 'ЗК-' || to_char(current_date, 'YYYY') || '-' || lpad(v_seq::TEXT, 5, '0');

    INSERT INTO orders (order_number, customer_id, manager_id, due_date, delivery_address, comment)
    VALUES (p_order_number, p_customer_id, p_manager_id, p_due_date, p_address, p_comment)
    RETURNING order_id INTO p_order_id;
END;
$$;


--
-- Name: sp_register_payment(integer, numeric, character varying, character varying, integer, integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_register_payment(IN p_order_id integer, IN p_amount numeric, IN p_method character varying, IN p_doc_ref character varying, IN p_user_id integer, INOUT p_payment_id integer DEFAULT NULL::integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_status VARCHAR(20);
    v_total  NUMERIC(14,2);
    v_paid   NUMERIC(14,2);
BEGIN
    SELECT status, total_amount INTO v_status, v_total
      FROM orders WHERE order_id = p_order_id FOR UPDATE;
    IF v_status IS NULL THEN
        RAISE EXCEPTION 'Заказ % не найден', p_order_id USING ERRCODE = 'P0002';
    ELSIF v_status IN ('Новый', 'Отменён') THEN
        RAISE EXCEPTION 'Оплата по заказу в статусе «%» не принимается', v_status USING ERRCODE = 'P0001';
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE order_id = p_order_id;
    IF p_amount <= 0 OR v_paid + p_amount > v_total THEN
        RAISE EXCEPTION 'Сумма % недопустима: остаток к оплате %', p_amount, v_total - v_paid
              USING ERRCODE = '22023';
    END IF;

    INSERT INTO payments (order_id, amount, method, doc_ref, created_by)
    VALUES (p_order_id, p_amount, p_method, p_doc_ref, p_user_id)
    RETURNING payment_id INTO p_payment_id;

    IF v_paid + p_amount = v_total AND v_status = 'Отгружен' THEN
        PERFORM set_config('app.user_id', p_user_id::TEXT, TRUE);
        UPDATE orders SET status = 'Закрыт' WHERE order_id = p_order_id;
    END IF;
END;
$$;


--
-- Name: sp_register_user(character varying, character varying, character varying, character varying, character varying, character, character, integer); Type: PROCEDURE; Schema: public; Owner: -
--

CREATE PROCEDURE public.sp_register_user(IN p_login character varying, IN p_full_name character varying, IN p_email character varying, IN p_position character varying, IN p_role_code character varying, IN p_hash character, IN p_salt character, INOUT p_user_id integer DEFAULT NULL::integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_role SMALLINT;
BEGIN
    IF EXISTS (SELECT 1 FROM users WHERE lower(login) = lower(p_login)) THEN
        RAISE EXCEPTION 'Логин «%» уже занят', p_login USING ERRCODE = '23505';
    END IF;
    SELECT role_id INTO v_role FROM roles WHERE role_code = p_role_code;
    IF v_role IS NULL THEN
        RAISE EXCEPTION 'Роль % не существует', p_role_code USING ERRCODE = 'P0002';
    END IF;
    INSERT INTO users (login, full_name, email, position, role_id, password_hash, password_salt)
    VALUES (lower(p_login), p_full_name, lower(p_email), p_position, v_role, p_hash, p_salt)
    RETURNING user_id INTO p_user_id;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customers (
    customer_id integer NOT NULL,
    name character varying(150) NOT NULL,
    tax_id character varying(14) NOT NULL,
    country character varying(60) NOT NULL,
    email character varying(120),
    phone character varying(30),
    manager_id integer,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT customers_tax_id_check CHECK (((tax_id)::text ~ '^[0-9]{9,14}$'::text))
);


--
-- Name: TABLE customers; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.customers IS 'Клиенты-покупатели';


--
-- Name: customers_customer_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.customers_customer_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: customers_customer_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.customers_customer_id_seq OWNED BY public.customers.customer_id;


--
-- Name: order_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_items (
    item_id integer NOT NULL,
    order_id integer NOT NULL,
    product_id integer NOT NULL,
    qty integer NOT NULL,
    price numeric(12,2) NOT NULL,
    line_sum numeric(14,2) DEFAULT 0 NOT NULL,
    CONSTRAINT order_items_price_check CHECK ((price > (0)::numeric)),
    CONSTRAINT order_items_qty_check CHECK ((qty > 0))
);


--
-- Name: TABLE order_items; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.order_items IS 'Позиции заказа';


--
-- Name: order_items_item_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.order_items_item_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: order_items_item_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.order_items_item_id_seq OWNED BY public.order_items.item_id;


--
-- Name: order_status_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.order_status_log (
    log_id bigint NOT NULL,
    order_id integer NOT NULL,
    old_status character varying(20),
    new_status character varying(20) NOT NULL,
    changed_by integer,
    changed_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE order_status_log; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.order_status_log IS 'Журнал смены статусов заказа';


--
-- Name: order_status_log_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.order_status_log_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: order_status_log_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.order_status_log_log_id_seq OWNED BY public.order_status_log.log_id;


--
-- Name: orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.orders (
    order_id integer NOT NULL,
    order_number character varying(20) NOT NULL,
    manager_id integer NOT NULL,
    customer_id integer NOT NULL,
    status character varying(20) DEFAULT 'Новый'::character varying NOT NULL,
    order_date date DEFAULT CURRENT_DATE NOT NULL,
    due_date date,
    delivery_address character varying(200),
    total_amount numeric(14,2) DEFAULT 0 NOT NULL,
    comment character varying(300),
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT chk_order_due CHECK (((due_date IS NULL) OR (due_date >= order_date))),
    CONSTRAINT orders_status_check CHECK (((status)::text = ANY ((ARRAY['Новый'::character varying, 'Подтверждён'::character varying, 'Комплектуется'::character varying, 'Отгружен'::character varying, 'Закрыт'::character varying, 'Отменён'::character varying])::text[]))),
    CONSTRAINT orders_total_amount_check CHECK ((total_amount >= (0)::numeric))
);


--
-- Name: TABLE orders; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.orders IS 'Заказы клиентов';


--
-- Name: orders_order_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.orders_order_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: orders_order_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.orders_order_id_seq OWNED BY public.orders.order_id;


--
-- Name: payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payments (
    payment_id integer NOT NULL,
    order_id integer NOT NULL,
    amount numeric(14,2) NOT NULL,
    method character varying(25) NOT NULL,
    doc_ref character varying(40),
    paid_at timestamp without time zone DEFAULT now() NOT NULL,
    created_by integer NOT NULL,
    CONSTRAINT payments_amount_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT payments_method_check CHECK (((method)::text = ANY ((ARRAY['Банковский перевод'::character varying, 'Аккредитив'::character varying, 'Оплата картой'::character varying])::text[])))
);


--
-- Name: TABLE payments; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.payments IS 'Оплаты по заказам';


--
-- Name: payments_payment_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.payments_payment_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: payments_payment_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.payments_payment_id_seq OWNED BY public.payments.payment_id;


--
-- Name: product_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_categories (
    category_id smallint NOT NULL,
    name character varying(80) NOT NULL
);


--
-- Name: TABLE product_categories; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.product_categories IS 'Категории товаров';


--
-- Name: product_categories_category_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.product_categories_category_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: product_categories_category_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.product_categories_category_id_seq OWNED BY public.product_categories.category_id;


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.products (
    product_id integer NOT NULL,
    sku character varying(20) NOT NULL,
    name character varying(150) NOT NULL,
    category_id smallint NOT NULL,
    unit character varying(10) DEFAULT 'шт'::character varying NOT NULL,
    price numeric(12,2) NOT NULL,
    stock_qty integer DEFAULT 0 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT products_price_check CHECK ((price > (0)::numeric)),
    CONSTRAINT products_stock_qty_check CHECK ((stock_qty >= 0))
);


--
-- Name: TABLE products; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.products IS 'Номенклатура и складской остаток';


--
-- Name: products_product_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.products_product_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: products_product_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.products_product_id_seq OWNED BY public.products.product_id;


--
-- Name: roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roles (
    role_id smallint NOT NULL,
    role_code character varying(20) NOT NULL,
    role_name character varying(60) NOT NULL
);


--
-- Name: TABLE roles; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.roles IS 'Роли пользователей приложения';


--
-- Name: roles_role_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.roles_role_id_seq
    AS smallint
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: roles_role_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.roles_role_id_seq OWNED BY public.roles.role_id;


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    user_id integer NOT NULL,
    login character varying(40) NOT NULL,
    full_name character varying(120) NOT NULL,
    email character varying(120) NOT NULL,
    "position" character varying(100),
    role_id smallint NOT NULL,
    password_hash character(64) NOT NULL,
    password_salt character(32) NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE users; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.users IS 'Пользователи системы';


--
-- Name: users_user_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.users_user_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_user_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.users_user_id_seq OWNED BY public.users.user_id;


--
-- Name: v_customer_stats; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_customer_stats AS
 SELECT c.customer_id,
    c.name,
    c.country,
    count(o.order_id) FILTER (WHERE ((o.status)::text <> 'Отменён'::text)) AS orders_cnt,
    COALESCE(sum(o.total_amount) FILTER (WHERE ((o.status)::text <> 'Отменён'::text)), (0)::numeric) AS ordered,
    COALESCE(sum(pp.paid), (0)::numeric) AS paid,
    (COALESCE(sum(o.total_amount) FILTER (WHERE ((o.status)::text <> 'Отменён'::text)), (0)::numeric) - COALESCE(sum(pp.paid), (0)::numeric)) AS debt,
    max(o.order_date) AS last_order
   FROM ((public.customers c
     LEFT JOIN public.orders o ON ((o.customer_id = c.customer_id)))
     LEFT JOIN ( SELECT payments.order_id,
            sum(payments.amount) AS paid
           FROM public.payments
          GROUP BY payments.order_id) pp ON ((pp.order_id = o.order_id)))
  GROUP BY c.customer_id, c.name, c.country;


--
-- Name: v_orders_full; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_orders_full AS
 SELECT o.order_id,
    o.order_number,
    o.order_date,
    o.due_date,
    o.status,
    c.name AS customer,
    c.country,
    u.full_name AS manager,
    o.total_amount,
    COALESCE(p.paid, (0)::numeric) AS paid,
    (o.total_amount - COALESCE(p.paid, (0)::numeric)) AS debt,
    ((o.due_date < CURRENT_DATE) AND ((o.status)::text <> ALL ((ARRAY['Отгружен'::character varying, 'Закрыт'::character varying, 'Отменён'::character varying])::text[]))) AS is_overdue,
    o.updated_at
   FROM (((public.orders o
     JOIN public.customers c ON ((c.customer_id = o.customer_id)))
     JOIN public.users u ON ((u.user_id = o.manager_id)))
     LEFT JOIN ( SELECT payments.order_id,
            sum(payments.amount) AS paid
           FROM public.payments
          GROUP BY payments.order_id) p ON ((p.order_id = o.order_id)));


--
-- Name: v_product_sales; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_product_sales AS
 SELECT pr.product_id,
    pr.sku,
    pr.name,
    pc.name AS category,
    pr.unit,
    pr.stock_qty,
    COALESCE(sum(oi.qty), (0)::bigint) AS sold_qty,
    COALESCE(sum(oi.line_sum), (0)::numeric) AS revenue
   FROM ((public.products pr
     JOIN public.product_categories pc ON ((pc.category_id = pr.category_id)))
     LEFT JOIN public.order_items oi ON (((oi.product_id = pr.product_id) AND (oi.order_id IN ( SELECT orders.order_id
           FROM public.orders
          WHERE ((orders.status)::text <> 'Отменён'::text))))))
  GROUP BY pr.product_id, pr.sku, pr.name, pc.name, pr.unit, pr.stock_qty;


--
-- Name: customers customer_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers ALTER COLUMN customer_id SET DEFAULT nextval('public.customers_customer_id_seq'::regclass);


--
-- Name: order_items item_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items ALTER COLUMN item_id SET DEFAULT nextval('public.order_items_item_id_seq'::regclass);


--
-- Name: order_status_log log_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_status_log ALTER COLUMN log_id SET DEFAULT nextval('public.order_status_log_log_id_seq'::regclass);


--
-- Name: orders order_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders ALTER COLUMN order_id SET DEFAULT nextval('public.orders_order_id_seq'::regclass);


--
-- Name: payments payment_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments ALTER COLUMN payment_id SET DEFAULT nextval('public.payments_payment_id_seq'::regclass);


--
-- Name: product_categories category_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_categories ALTER COLUMN category_id SET DEFAULT nextval('public.product_categories_category_id_seq'::regclass);


--
-- Name: products product_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products ALTER COLUMN product_id SET DEFAULT nextval('public.products_product_id_seq'::regclass);


--
-- Name: roles role_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles ALTER COLUMN role_id SET DEFAULT nextval('public.roles_role_id_seq'::regclass);


--
-- Name: users user_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users ALTER COLUMN user_id SET DEFAULT nextval('public.users_user_id_seq'::regclass);


--
-- Data for Name: customers; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.customers (customer_id, name, tax_id, country, email, phone, manager_id, created_at) FROM stdin;
1	ТОО «Алтын-Сервис»	180340021457	Казахстан	zakup@altyn-service.kz	+7 727 300-15-20	2	2026-10-28 11:00:00
2	ООО «БелТехСнаб»	191245873	Беларусь	order@beltechsnab.by	+375 17 388-40-12	3	2026-10-28 11:05:00
3	ОсОО «Ала-Тоо Энерджи»	02104201910057	Кыргызстан	info@alatoo-energy.kg	+996 312 90-44-10	2	2026-10-29 10:10:00
4	МЧЖ «Ташкент Индастри Групп»	305884120	Узбекистан	supply@tig.uz	+998 71 205-33-80	3	2026-10-29 10:20:00
5	ООО «ВолгаКомплект»	6316248870	Россия	snab@volgakomplekt.ru	+7 846 270-11-05	5	2026-10-30 09:15:00
6	ООО «СеверЛайн»	2901334712	Россия	office@severline.ru	+7 8182 63-20-40	\N	2026-11-12 14:00:00
\.


--
-- Data for Name: order_items; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.order_items (item_id, order_id, product_id, qty, price, line_sum) FROM stdin;
1	1	1	4	48500.00	194000.00
2	1	2	12	12300.00	147600.00
3	1	3	2	31900.00	63800.00
4	2	4	20	8700.00	174000.00
5	2	5	40	3400.00	136000.00
6	3	8	2	156000.00	312000.00
7	3	9	2	74200.00	148400.00
8	4	6	1200	96.00	115200.00
9	4	7	2000	54.00	108000.00
10	5	10	3	65000.00	195000.00
11	5	3	3	31900.00	95700.00
12	6	1	10	48500.00	485000.00
13	7	2	30	12300.00	369000.00
14	7	5	100	3400.00	340000.00
15	9	1	2	48500.00	97000.00
16	9	4	15	8700.00	130500.00
18	5	5	20	3400.00	68000.00
\.


--
-- Data for Name: order_status_log; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.order_status_log (log_id, order_id, old_status, new_status, changed_by, changed_at) FROM stdin;
1	1	\N	Новый	2	2026-10-29 10:00:00
2	1	Новый	Подтверждён	2	2026-10-29 16:00:00
3	1	Подтверждён	Комплектуется	2	2026-11-03 10:15:00
4	1	Комплектуется	Отгружен	2	2026-11-10 09:30:00
5	1	Отгружен	Закрыт	4	2026-11-18 11:40:00
6	2	\N	Новый	3	2026-10-30 10:00:00
7	2	Новый	Подтверждён	3	2026-10-30 17:20:00
8	2	Подтверждён	Комплектуется	3	2026-11-05 09:00:00
9	2	Комплектуется	Отгружен	3	2026-11-14 14:30:00
10	3	\N	Новый	2	2026-11-02 10:00:00
11	3	Новый	Подтверждён	2	2026-11-03 11:00:00
12	3	Подтверждён	Комплектуется	5	2026-11-12 16:40:00
13	4	\N	Новый	5	2026-11-05 10:00:00
14	4	Новый	Подтверждён	5	2026-11-06 10:30:00
15	5	\N	Новый	3	2026-11-09 10:00:00
16	6	\N	Новый	2	2026-11-11 10:00:00
17	6	Новый	Отменён	2	2026-11-13 12:05:00
18	7	\N	Новый	3	2026-11-16 10:00:00
19	7	Новый	Подтверждён	3	2026-11-17 09:45:00
20	8	\N	Новый	5	2026-11-20 10:00:00
21	9	\N	Новый	3	2026-11-25 18:43:56.189592
22	9	Новый	Подтверждён	3	2026-11-25 18:43:56.623393
\.


--
-- Data for Name: orders; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.orders (order_id, order_number, manager_id, customer_id, status, order_date, due_date, delivery_address, total_amount, comment, created_at, updated_at) FROM stdin;
1	ЗК-2026-00001	2	1	Закрыт	2026-10-29	2026-11-20	Казахстан, г. Алматы, ул. Сейфуллина, 410	405400.00	Модернизация насосной станции	2026-10-29 10:00:00	2026-11-18 11:40:00
2	ЗК-2026-00002	3	2	Отгружен	2026-10-30	2026-11-25	Беларусь, г. Минск, ул. Тимирязева, 65Б	310000.00	\N	2026-10-30 10:00:00	2026-11-14 14:30:00
3	ЗК-2026-00003	2	3	Комплектуется	2026-11-02	2026-12-01	Кыргызстан, г. Бишкек, пр. Чуй, 106	460400.00	Срочная сборка шкафов	2026-11-02 10:00:00	2026-11-12 16:40:00
4	ЗК-2026-00004	5	5	Подтверждён	2026-11-05	2026-11-15	Россия, г. Самара, Заводское ш., 12	223200.00	\N	2026-11-05 10:00:00	2026-11-06 10:30:00
6	ЗК-2026-00006	2	1	Отменён	2026-11-11	2026-11-30	\N	485000.00	Клиент перенёс закупку на 2027 г.	2026-11-11 10:00:00	2026-11-13 12:05:00
7	ЗК-2026-00007	3	2	Подтверждён	2026-11-16	2026-12-14	Беларусь, г. Минск, ул. Тимирязева, 65Б	709000.00	\N	2026-11-16 10:00:00	2026-11-17 09:45:00
8	ЗК-2026-00008	5	3	Новый	2026-11-20	2026-12-20	Кыргызстан, г. Бишкек, пр. Чуй, 106	0.00	Позиции уточняются у клиента	2026-11-20 10:00:00	2026-11-20 10:00:00
9	ЗК-2026-00009	3	5	Подтверждён	2026-11-25	2026-12-18	Россия, г. Самара, Заводское ш., 12	227500.00	Поставка для модернизации котельной	2026-11-25 18:43:56.189592	2026-11-25 18:43:56.623393
5	ЗК-2026-00005	3	4	Новый	2026-11-09	2026-12-10	Узбекистан, г. Ташкент, ул. Амира Темура, 107	358700.00	\N	2026-11-09 10:00:00	2026-11-25 18:43:56.876098
\.


--
-- Data for Name: payments; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.payments (payment_id, order_id, amount, method, doc_ref, paid_at, created_by) FROM stdin;
1	1	202700.00	Банковский перевод	ПП-1021	2026-10-30 15:10:00	4
2	1	202700.00	Банковский перевод	ПП-1088	2026-11-18 11:40:00	4
3	2	155000.00	Банковский перевод	ПП-2210	2026-11-02 12:00:00	6
4	3	138120.00	Аккредитив	LC-0457	2026-11-04 10:00:00	4
5	7	283600.00	Банковский перевод	ПП-2391	2026-11-19 13:25:00	6
6	9	120000.00	Банковский перевод	ПП-2475	2026-11-25 18:43:56.626674	4
\.


--
-- Data for Name: product_categories; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.product_categories (category_id, name) FROM stdin;
1	Контроллеры и модули
2	Датчики и КИП
3	Кабельная продукция
4	Электрощитовое оборудование
5	Программное обеспечение
6	Запасные части
\.


--
-- Data for Name: products; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.products (product_id, sku, name, category_id, unit, price, stock_qty, is_active, updated_at) FROM stdin;
2	UT-IO-16	Модуль ввода-вывода UT-IO16	1	шт	12300.00	120	t	2026-10-28 12:00:00
3	UT-HMI-07	Панель оператора 7"	1	шт	31900.00	25	t	2026-10-28 12:00:00
5	SD-TT-100	Датчик температуры Pt100	2	шт	3400.00	350	t	2026-10-28 12:00:00
6	CB-KVVG-4	Кабель КВВГ 4х1,5	3	м	96.00	5000	t	2026-10-28 12:00:00
7	CB-UTP-6	Кабель UTP cat.6	3	м	54.00	8000	t	2026-10-28 12:00:00
8	SH-SHU-60	Шкаф управления ШУ-60	4	шт	156000.00	6	t	2026-10-28 12:00:00
9	SH-UPS-3K	ИБП 3 кВА для шкафов управления	4	шт	74200.00	10	t	2026-10-28 12:00:00
10	SW-SCADA-L	Лицензия SCADA Unitech (1 АРМ)	5	шт	65000.00	100	t	2026-10-28 12:00:00
1	UT-PLC-100	Программируемый контроллер UT-PLC 100	1	шт	48500.00	38	t	2026-11-25 18:43:56.623393
4	SD-PT-25	Датчик давления SD-PT 25 бар	2	шт	8700.00	185	t	2026-11-25 18:43:56.623393
\.


--
-- Data for Name: roles; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.roles (role_id, role_code, role_name) FROM stdin;
1	ADMIN	Администратор системы
2	MANAGER	Менеджер по продажам
3	ACCOUNTANT	Бухгалтер
4	VIEWER	Наблюдатель
\.


--
-- Data for Name: users; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.users (user_id, login, full_name, email, "position", role_id, password_hash, password_salt, is_active, created_at, updated_at) FROM stdin;
1	admin	Захаров Кирилл Андреевич	k.zakharov@unitech-export.local	Ведущий специалист IT-отдела	1	050fa9ed0adff373001eac3e8320521f9d7879be70d5dec08c1095a8ebf54610	07f994862b236599e21463c1b831c650	t	2026-10-28 09:30:00	2026-11-25 18:43:24.569246
2	lebedeva	Лебедева Светлана Игоревна	s.lebedeva@unitech-export.local	Менеджер по экспорту	2	21a4494cd7308fee526f8739e573ee2f648557bab80b9cbe9f0d22357c454591	8df9febd28d5109b37e38d5369a5484e	t	2026-10-28 09:30:00	2026-11-25 18:43:24.569246
3	tarasov	Тарасов Максим Олегович	m.tarasov@unitech-export.local	Менеджер по экспорту	2	a514e262168b4038bcb6550555c8398fcced1d5b5e66760f6e3aed71d0c52819	3c8089970119b96f018422ca6b4adc4c	t	2026-10-28 09:30:00	2026-11-25 18:43:24.569246
4	kuzmina	Кузьмина Елена Викторовна	e.kuzmina@unitech-export.local	Главный бухгалтер	3	5d3c4d13d9d2b45bc6dc54fa871fa21689414e3ba021e348282c13d21bd5ff96	3063728ffe18edf9e8253e68d28475b0	t	2026-10-28 09:30:00	2026-11-25 18:43:24.569246
5	shevchenko	Шевченко Роман Дмитриевич	r.shevchenko@unitech-export.local	Руководитель отдела продаж	2	8815a3175f8e0e10df2a332c10daaa083d7296f218018938b432d4373275ddd5	a38e0e87f747a8442cbaa0e8b91787b5	t	2026-10-28 09:30:00	2026-11-25 18:43:24.569246
6	egorova	Егорова Дарья Сергеевна	d.egorova@unitech-export.local	Бухгалтер	3	23f0be3128f209711bf6f9f3c83382da86a5c728e54c317338f9af953bd52e96	57f7c41d704ecb59d3264d1dab3c2576	t	2026-10-28 09:30:00	2026-11-25 18:43:24.569246
7	vlasov	Власов Николай Петрович	n.vlasov@unitech-export.local	Аналитик	4	9dae3438c59014736c919ef5702822f0278802b3b51d5e8a61499054bf2c2aa2	2553436d22c7a9ec694f049ddc91c8e3	t	2026-10-28 09:30:00	2026-11-25 18:43:24.569246
\.


--
-- Name: customers_customer_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.customers_customer_id_seq', 6, true);


--
-- Name: order_items_item_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.order_items_item_id_seq', 19, true);


--
-- Name: order_status_log_log_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.order_status_log_log_id_seq', 23, true);


--
-- Name: orders_order_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.orders_order_id_seq', 10, true);


--
-- Name: payments_payment_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.payments_payment_id_seq', 6, true);


--
-- Name: product_categories_category_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.product_categories_category_id_seq', 6, true);


--
-- Name: products_product_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.products_product_id_seq', 10, true);


--
-- Name: roles_role_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.roles_role_id_seq', 4, true);


--
-- Name: users_user_id_seq; Type: SEQUENCE SET; Schema: public; Owner: -
--

SELECT pg_catalog.setval('public.users_user_id_seq', 7, true);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (customer_id);


--
-- Name: customers customers_tax_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_tax_id_key UNIQUE (tax_id);


--
-- Name: order_items order_items_order_id_product_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_order_id_product_id_key UNIQUE (order_id, product_id);


--
-- Name: order_items order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_pkey PRIMARY KEY (item_id);


--
-- Name: order_status_log order_status_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_status_log
    ADD CONSTRAINT order_status_log_pkey PRIMARY KEY (log_id);


--
-- Name: orders orders_order_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_order_number_key UNIQUE (order_number);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (order_id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (payment_id);


--
-- Name: product_categories product_categories_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_categories
    ADD CONSTRAINT product_categories_name_key UNIQUE (name);


--
-- Name: product_categories product_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_categories
    ADD CONSTRAINT product_categories_pkey PRIMARY KEY (category_id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (product_id);


--
-- Name: products products_sku_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_sku_key UNIQUE (sku);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (role_id);


--
-- Name: roles roles_role_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_role_code_key UNIQUE (role_code);


--
-- Name: users users_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users users_login_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_login_key UNIQUE (login);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (user_id);


--
-- Name: ix_items_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_items_product ON public.order_items USING btree (product_id);


--
-- Name: ix_orders_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_orders_customer ON public.orders USING btree (customer_id);


--
-- Name: ix_orders_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_orders_status ON public.orders USING btree (status);


--
-- Name: ix_payments_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_payments_order ON public.payments USING btree (order_id);


--
-- Name: ix_status_log_order; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_status_log_order ON public.order_status_log USING btree (order_id, changed_at);


--
-- Name: order_items trg_order_items_line_sum; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_order_items_line_sum BEFORE INSERT OR UPDATE OF qty, price ON public.order_items FOR EACH ROW EXECUTE FUNCTION public.fn_order_items_line_sum();


--
-- Name: order_items trg_order_items_total; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_order_items_total AFTER INSERT OR DELETE OR UPDATE ON public.order_items FOR EACH ROW EXECUTE FUNCTION public.fn_orders_recalc_total();


--
-- Name: orders trg_orders_status_audit; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_orders_status_audit AFTER INSERT OR UPDATE OF status ON public.orders FOR EACH ROW EXECUTE FUNCTION public.fn_orders_status_audit();


--
-- Name: orders trg_orders_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_orders_updated_at BEFORE UPDATE ON public.orders FOR EACH ROW EXECUTE FUNCTION public.fn_set_updated_at();


--
-- Name: products trg_products_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_products_updated_at BEFORE UPDATE ON public.products FOR EACH ROW EXECUTE FUNCTION public.fn_set_updated_at();


--
-- Name: users trg_users_updated_at; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_users_updated_at BEFORE UPDATE ON public.users FOR EACH ROW EXECUTE FUNCTION public.fn_set_updated_at();


--
-- Name: customers customers_manager_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_manager_id_fkey FOREIGN KEY (manager_id) REFERENCES public.users(user_id) ON DELETE SET NULL;


--
-- Name: order_items order_items_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(order_id) ON DELETE CASCADE;


--
-- Name: order_items order_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_items
    ADD CONSTRAINT order_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- Name: order_status_log order_status_log_changed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_status_log
    ADD CONSTRAINT order_status_log_changed_by_fkey FOREIGN KEY (changed_by) REFERENCES public.users(user_id);


--
-- Name: order_status_log order_status_log_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.order_status_log
    ADD CONSTRAINT order_status_log_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(order_id) ON DELETE CASCADE;


--
-- Name: orders orders_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- Name: orders orders_manager_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.orders
    ADD CONSTRAINT orders_manager_id_fkey FOREIGN KEY (manager_id) REFERENCES public.users(user_id);


--
-- Name: payments payments_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id);


--
-- Name: payments payments_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.orders(order_id) ON DELETE CASCADE;


--
-- Name: products products_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.product_categories(category_id);


--
-- Name: users users_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(role_id);


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: -
--

REVOKE USAGE ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO ute_reader;


--
-- Name: PROCEDURE sp_add_order_item(IN p_order_id integer, IN p_product_id integer, IN p_qty integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON PROCEDURE public.sp_add_order_item(IN p_order_id integer, IN p_product_id integer, IN p_qty integer) FROM PUBLIC;
GRANT ALL ON PROCEDURE public.sp_add_order_item(IN p_order_id integer, IN p_product_id integer, IN p_qty integer) TO ute_operator;
GRANT ALL ON PROCEDURE public.sp_add_order_item(IN p_order_id integer, IN p_product_id integer, IN p_qty integer) TO ute_admin;


--
-- Name: PROCEDURE sp_change_order_status(IN p_order_id integer, IN p_new_status character varying, IN p_user_id integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON PROCEDURE public.sp_change_order_status(IN p_order_id integer, IN p_new_status character varying, IN p_user_id integer) FROM PUBLIC;
GRANT ALL ON PROCEDURE public.sp_change_order_status(IN p_order_id integer, IN p_new_status character varying, IN p_user_id integer) TO ute_operator;
GRANT ALL ON PROCEDURE public.sp_change_order_status(IN p_order_id integer, IN p_new_status character varying, IN p_user_id integer) TO ute_admin;


--
-- Name: PROCEDURE sp_create_order(IN p_customer_id integer, IN p_manager_id integer, IN p_due_date date, IN p_address character varying, IN p_comment character varying, INOUT p_order_id integer, INOUT p_order_number character varying); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON PROCEDURE public.sp_create_order(IN p_customer_id integer, IN p_manager_id integer, IN p_due_date date, IN p_address character varying, IN p_comment character varying, INOUT p_order_id integer, INOUT p_order_number character varying) FROM PUBLIC;
GRANT ALL ON PROCEDURE public.sp_create_order(IN p_customer_id integer, IN p_manager_id integer, IN p_due_date date, IN p_address character varying, IN p_comment character varying, INOUT p_order_id integer, INOUT p_order_number character varying) TO ute_operator;
GRANT ALL ON PROCEDURE public.sp_create_order(IN p_customer_id integer, IN p_manager_id integer, IN p_due_date date, IN p_address character varying, IN p_comment character varying, INOUT p_order_id integer, INOUT p_order_number character varying) TO ute_admin;


--
-- Name: PROCEDURE sp_register_payment(IN p_order_id integer, IN p_amount numeric, IN p_method character varying, IN p_doc_ref character varying, IN p_user_id integer, INOUT p_payment_id integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON PROCEDURE public.sp_register_payment(IN p_order_id integer, IN p_amount numeric, IN p_method character varying, IN p_doc_ref character varying, IN p_user_id integer, INOUT p_payment_id integer) FROM PUBLIC;
GRANT ALL ON PROCEDURE public.sp_register_payment(IN p_order_id integer, IN p_amount numeric, IN p_method character varying, IN p_doc_ref character varying, IN p_user_id integer, INOUT p_payment_id integer) TO ute_operator;
GRANT ALL ON PROCEDURE public.sp_register_payment(IN p_order_id integer, IN p_amount numeric, IN p_method character varying, IN p_doc_ref character varying, IN p_user_id integer, INOUT p_payment_id integer) TO ute_admin;


--
-- Name: PROCEDURE sp_register_user(IN p_login character varying, IN p_full_name character varying, IN p_email character varying, IN p_position character varying, IN p_role_code character varying, IN p_hash character, IN p_salt character, INOUT p_user_id integer); Type: ACL; Schema: public; Owner: -
--

REVOKE ALL ON PROCEDURE public.sp_register_user(IN p_login character varying, IN p_full_name character varying, IN p_email character varying, IN p_position character varying, IN p_role_code character varying, IN p_hash character, IN p_salt character, INOUT p_user_id integer) FROM PUBLIC;
GRANT ALL ON PROCEDURE public.sp_register_user(IN p_login character varying, IN p_full_name character varying, IN p_email character varying, IN p_position character varying, IN p_role_code character varying, IN p_hash character, IN p_salt character, INOUT p_user_id integer) TO ute_admin;


--
-- Name: TABLE customers; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.customers TO ute_reader;
GRANT INSERT,UPDATE ON TABLE public.customers TO ute_operator;
GRANT ALL ON TABLE public.customers TO ute_admin;


--
-- Name: SEQUENCE customers_customer_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.customers_customer_id_seq TO ute_operator;
GRANT ALL ON SEQUENCE public.customers_customer_id_seq TO ute_admin;


--
-- Name: TABLE order_items; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.order_items TO ute_reader;
GRANT INSERT,DELETE,UPDATE ON TABLE public.order_items TO ute_operator;
GRANT ALL ON TABLE public.order_items TO ute_admin;


--
-- Name: SEQUENCE order_items_item_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.order_items_item_id_seq TO ute_operator;
GRANT ALL ON SEQUENCE public.order_items_item_id_seq TO ute_admin;


--
-- Name: TABLE order_status_log; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.order_status_log TO ute_reader;
GRANT ALL ON TABLE public.order_status_log TO ute_admin;


--
-- Name: SEQUENCE order_status_log_log_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.order_status_log_log_id_seq TO ute_admin;


--
-- Name: TABLE orders; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.orders TO ute_reader;
GRANT INSERT,DELETE,UPDATE ON TABLE public.orders TO ute_operator;
GRANT ALL ON TABLE public.orders TO ute_admin;


--
-- Name: SEQUENCE orders_order_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.orders_order_id_seq TO ute_operator;
GRANT ALL ON SEQUENCE public.orders_order_id_seq TO ute_admin;


--
-- Name: TABLE payments; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.payments TO ute_reader;
GRANT INSERT ON TABLE public.payments TO ute_operator;
GRANT ALL ON TABLE public.payments TO ute_admin;


--
-- Name: SEQUENCE payments_payment_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT USAGE ON SEQUENCE public.payments_payment_id_seq TO ute_operator;
GRANT ALL ON SEQUENCE public.payments_payment_id_seq TO ute_admin;


--
-- Name: TABLE product_categories; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.product_categories TO ute_reader;
GRANT ALL ON TABLE public.product_categories TO ute_admin;


--
-- Name: SEQUENCE product_categories_category_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.product_categories_category_id_seq TO ute_admin;


--
-- Name: TABLE products; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.products TO ute_reader;
GRANT ALL ON TABLE public.products TO ute_admin;


--
-- Name: COLUMN products.stock_qty; Type: ACL; Schema: public; Owner: -
--

GRANT UPDATE(stock_qty) ON TABLE public.products TO ute_operator;


--
-- Name: SEQUENCE products_product_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.products_product_id_seq TO ute_admin;


--
-- Name: TABLE roles; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.roles TO ute_reader;
GRANT ALL ON TABLE public.roles TO ute_admin;


--
-- Name: SEQUENCE roles_role_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.roles_role_id_seq TO ute_admin;


--
-- Name: TABLE users; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.users TO ute_reader;
GRANT ALL ON TABLE public.users TO ute_admin;


--
-- Name: SEQUENCE users_user_id_seq; Type: ACL; Schema: public; Owner: -
--

GRANT ALL ON SEQUENCE public.users_user_id_seq TO ute_admin;


--
-- Name: TABLE v_customer_stats; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.v_customer_stats TO ute_reader;
GRANT ALL ON TABLE public.v_customer_stats TO ute_admin;


--
-- Name: TABLE v_orders_full; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.v_orders_full TO ute_reader;
GRANT ALL ON TABLE public.v_orders_full TO ute_admin;


--
-- Name: TABLE v_product_sales; Type: ACL; Schema: public; Owner: -
--

GRANT SELECT ON TABLE public.v_product_sales TO ute_reader;
GRANT ALL ON TABLE public.v_product_sales TO ute_admin;


--
-- PostgreSQL database dump complete
--

\unrestrict 8Koib4vwrWNxagyhuqMxshci2oW07xrV4SF48F09U0QKzcyC6vaE3L7hgo2o9u2

