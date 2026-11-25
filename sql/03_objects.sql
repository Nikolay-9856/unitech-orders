-- ============================================================
-- Объекты БД unitech_orders: представления и хранимые процедуры
-- ============================================================

-- ---------- ПРЕДСТАВЛЕНИЯ ----------

-- Реестр заказов: клиент, менеджер, сумма, оплачено, долг, просрочка
CREATE OR REPLACE VIEW v_orders_full AS
SELECT o.order_id,
       o.order_number,
       o.order_date,
       o.due_date,
       o.status,
       c.name                              AS customer,
       c.country,
       u.full_name                         AS manager,
       o.total_amount,
       COALESCE(p.paid, 0)                 AS paid,
       o.total_amount - COALESCE(p.paid, 0) AS debt,
       (o.due_date < current_date
        AND o.status NOT IN ('Отгружен','Закрыт','Отменён')) AS is_overdue,
       o.updated_at
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
JOIN users     u ON u.user_id     = o.manager_id
LEFT JOIN (SELECT order_id, SUM(amount) AS paid
           FROM payments GROUP BY order_id) p ON p.order_id = o.order_id;

-- Сводка по клиентам: число заказов, выручка, оплаты, задолженность
CREATE OR REPLACE VIEW v_customer_stats AS
SELECT c.customer_id,
       c.name,
       c.country,
       COUNT(o.order_id) FILTER (WHERE o.status <> 'Отменён')         AS orders_cnt,
       COALESCE(SUM(o.total_amount) FILTER (WHERE o.status <> 'Отменён'), 0) AS ordered,
       COALESCE(SUM(pp.paid), 0)                                      AS paid,
       COALESCE(SUM(o.total_amount) FILTER (WHERE o.status <> 'Отменён'), 0)
         - COALESCE(SUM(pp.paid), 0)                                  AS debt,
       MAX(o.order_date)                                              AS last_order
FROM customers c
LEFT JOIN orders o ON o.customer_id = c.customer_id
LEFT JOIN (SELECT order_id, SUM(amount) AS paid
           FROM payments GROUP BY order_id) pp ON pp.order_id = o.order_id
GROUP BY c.customer_id, c.name, c.country;

-- Продажи по номенклатуре (без отменённых заказов) и текущий остаток
CREATE OR REPLACE VIEW v_product_sales AS
SELECT pr.product_id, pr.sku, pr.name, pc.name AS category, pr.unit,
       pr.stock_qty,
       COALESCE(SUM(oi.qty), 0)      AS sold_qty,
       COALESCE(SUM(oi.line_sum), 0) AS revenue
FROM products pr
JOIN product_categories pc ON pc.category_id = pr.category_id
LEFT JOIN order_items oi ON oi.product_id = pr.product_id
     AND oi.order_id IN (SELECT order_id FROM orders WHERE status <> 'Отменён')
GROUP BY pr.product_id, pr.sku, pr.name, pc.name, pr.unit, pr.stock_qty;

-- ---------- ХРАНИМЫЕ ПРОЦЕДУРЫ ----------

-- 1) Создание заказа с автоматическим номером ЗК-ГГГГ-NNNNN
CREATE OR REPLACE PROCEDURE sp_create_order(
    IN    p_customer_id  INT,
    IN    p_manager_id   INT,
    IN    p_due_date     DATE,
    IN    p_address      VARCHAR,
    IN    p_comment      VARCHAR,
    INOUT p_order_id     INT     DEFAULT NULL,
    INOUT p_order_number VARCHAR DEFAULT NULL)
LANGUAGE plpgsql AS $$
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

-- 2) Добавление позиции в заказ (цена берётся из каталога)
CREATE OR REPLACE PROCEDURE sp_add_order_item(
    IN p_order_id   INT,
    IN p_product_id INT,
    IN p_qty        INT)
LANGUAGE plpgsql AS $$
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
    INSERT INTO order_items (order_id, product_id, qty, price, line_sum)
    VALUES (p_order_id, p_product_id, p_qty, v_price, p_qty * v_price)
    ON CONFLICT (order_id, product_id)
    DO UPDATE SET qty = order_items.qty + EXCLUDED.qty, price = EXCLUDED.price,
                  line_sum = (order_items.qty + EXCLUDED.qty) * EXCLUDED.price;

    -- до появления триггеров (v4.0) итог заказа пересчитывает сама процедура
    UPDATE orders
       SET total_amount = (SELECT COALESCE(SUM(line_sum), 0) FROM order_items WHERE order_id = p_order_id)
     WHERE order_id = p_order_id;
END;
$$;

-- 3) Смена статуса заказа по допустимым переходам, резерв и возврат остатков
CREATE OR REPLACE PROCEDURE sp_change_order_status(
    IN p_order_id   INT,
    IN p_new_status VARCHAR,
    IN p_user_id    INT)
LANGUAGE plpgsql AS $$
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

-- 4) Регистрация оплаты; полностью оплаченный отгруженный заказ закрывается
CREATE OR REPLACE PROCEDURE sp_register_payment(
    IN    p_order_id   INT,
    IN    p_amount     NUMERIC,
    IN    p_method     VARCHAR,
    IN    p_doc_ref    VARCHAR,
    IN    p_user_id    INT,
    INOUT p_payment_id INT DEFAULT NULL)
LANGUAGE plpgsql AS $$
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

-- 5) Регистрация пользователя (соль и хэш вычисляет приложение)
CREATE OR REPLACE PROCEDURE sp_register_user(
    IN    p_login     VARCHAR,
    IN    p_full_name VARCHAR,
    IN    p_email     VARCHAR,
    IN    p_position  VARCHAR,
    IN    p_role_code VARCHAR,
    IN    p_hash      CHAR(64),
    IN    p_salt      CHAR(32),
    INOUT p_user_id   INT DEFAULT NULL)
LANGUAGE plpgsql AS $$
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
