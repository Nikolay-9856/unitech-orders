-- ============================================================
-- База данных: unitech_orders
-- Система: «Юнитех.Заказы» — автоматизация учёта заказов
-- Организация: ООО «Юнитех Экспорт», IT-отдел
-- СУБД: PostgreSQL 16
-- ============================================================

DROP TABLE IF EXISTS order_status_log, payments, order_items, orders, products,
                     product_categories, customers, users, roles CASCADE;

-- 1. Роли пользователей приложения
CREATE TABLE roles (
    role_id     SMALLSERIAL  PRIMARY KEY,
    role_code   VARCHAR(20)  NOT NULL UNIQUE,
    role_name   VARCHAR(60)  NOT NULL
);

-- 2. Пользователи системы (сотрудники компании)
CREATE TABLE users (
    user_id        SERIAL       PRIMARY KEY,
    login          VARCHAR(40)  NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL,
    email          VARCHAR(120) NOT NULL UNIQUE,
    position       VARCHAR(100),
    role_id        SMALLINT     NOT NULL REFERENCES roles(role_id),
    password_hash  CHAR(64)     NOT NULL,
    password_salt  CHAR(32)     NOT NULL,
    is_active      BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMP    NOT NULL DEFAULT now(),
    updated_at     TIMESTAMP    NOT NULL DEFAULT now()
);

-- 3. Клиенты (зарубежные и российские покупатели)
CREATE TABLE customers (
    customer_id  SERIAL       PRIMARY KEY,
    name         VARCHAR(150) NOT NULL,
    tax_id       VARCHAR(14)  NOT NULL UNIQUE CHECK (tax_id ~ '^[0-9]{9,14}$'),
    country      VARCHAR(60)  NOT NULL,
    email        VARCHAR(120),
    phone        VARCHAR(30),
    manager_id   INT          REFERENCES users(user_id) ON DELETE SET NULL,
    created_at   TIMESTAMP    NOT NULL DEFAULT now()
);

-- 4. Категории товаров
CREATE TABLE product_categories (
    category_id  SMALLSERIAL  PRIMARY KEY,
    name         VARCHAR(80)  NOT NULL UNIQUE
);

-- 5. Номенклатура
CREATE TABLE products (
    product_id   SERIAL        PRIMARY KEY,
    sku          VARCHAR(20)   NOT NULL UNIQUE,
    name         VARCHAR(150)  NOT NULL,
    category_id  SMALLINT      NOT NULL REFERENCES product_categories(category_id),
    unit         VARCHAR(10)   NOT NULL DEFAULT 'шт',
    price        NUMERIC(12,2) NOT NULL CHECK (price > 0),
    stock_qty    INT           NOT NULL DEFAULT 0 CHECK (stock_qty >= 0),
    is_active    BOOLEAN       NOT NULL DEFAULT TRUE,
    updated_at   TIMESTAMP     NOT NULL DEFAULT now()
);

-- 6. Заказы (основная сущность)
CREATE TABLE orders (
    order_id      SERIAL        PRIMARY KEY,
    order_number  VARCHAR(20)   NOT NULL UNIQUE,
    manager_id    INT           NOT NULL REFERENCES users(user_id),
    customer_id   INT           NOT NULL REFERENCES customers(customer_id),
    status        VARCHAR(20)   NOT NULL DEFAULT 'Новый'
                  CHECK (status IN ('Новый','Подтверждён','Комплектуется',
                                    'Отгружен','Закрыт','Отменён')),
    order_date    DATE          NOT NULL DEFAULT current_date,
    due_date      DATE,
    delivery_address VARCHAR(200),
    total_amount  NUMERIC(14,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
    comment       VARCHAR(300),
    created_at    TIMESTAMP     NOT NULL DEFAULT now(),
    updated_at    TIMESTAMP     NOT NULL DEFAULT now(),
    CONSTRAINT chk_order_due CHECK (due_date IS NULL OR due_date >= order_date)
);

-- 7. Позиции заказа
CREATE TABLE order_items (
    item_id     SERIAL        PRIMARY KEY,
    order_id    INT           NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    product_id  INT           NOT NULL REFERENCES products(product_id),
    qty         INT           NOT NULL CHECK (qty > 0),
    price       NUMERIC(12,2) NOT NULL CHECK (price > 0),
    line_sum    NUMERIC(14,2) NOT NULL DEFAULT 0,
    UNIQUE (order_id, product_id)
);

-- 8. Оплаты по заказам
CREATE TABLE payments (
    payment_id  SERIAL        PRIMARY KEY,
    order_id    INT           NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    amount      NUMERIC(14,2) NOT NULL CHECK (amount > 0),
    method      VARCHAR(25)   NOT NULL
                CHECK (method IN ('Банковский перевод','Аккредитив','Оплата картой')),
    doc_ref     VARCHAR(40),
    paid_at     TIMESTAMP     NOT NULL DEFAULT now(),
    created_by  INT           NOT NULL REFERENCES users(user_id)
);

-- 9. Журнал смены статусов заказа (заполняется триггером)
CREATE TABLE order_status_log (
    log_id      BIGSERIAL    PRIMARY KEY,
    order_id    INT          NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    old_status  VARCHAR(20),
    new_status  VARCHAR(20)  NOT NULL,
    changed_by  INT          REFERENCES users(user_id),
    changed_at  TIMESTAMP    NOT NULL DEFAULT now()
);

CREATE INDEX ix_orders_status    ON orders(status);
CREATE INDEX ix_orders_customer  ON orders(customer_id);
CREATE INDEX ix_items_product    ON order_items(product_id);
CREATE INDEX ix_payments_order   ON payments(order_id);
CREATE INDEX ix_status_log_order ON order_status_log(order_id, changed_at);

COMMENT ON TABLE roles              IS 'Роли пользователей приложения';
COMMENT ON TABLE users              IS 'Пользователи системы';
COMMENT ON TABLE customers          IS 'Клиенты-покупатели';
COMMENT ON TABLE product_categories IS 'Категории товаров';
COMMENT ON TABLE products           IS 'Номенклатура и складской остаток';
COMMENT ON TABLE orders             IS 'Заказы клиентов';
COMMENT ON TABLE order_items        IS 'Позиции заказа';
COMMENT ON TABLE payments           IS 'Оплаты по заказам';
COMMENT ON TABLE order_status_log   IS 'Журнал смены статусов заказа';
