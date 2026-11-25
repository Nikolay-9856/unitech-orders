-- ============================================================
-- Роли СУБД и пользователи (PostgreSQL 16)
-- Принцип минимальных привилегий
-- ============================================================

-- журнал статусов пишет только триггер с правами владельца
ALTER FUNCTION fn_orders_status_audit() SECURITY DEFINER SET search_path = public;

-- ---------- групповые роли (без права входа) ----------
CREATE ROLE ute_reader   NOLOGIN;
CREATE ROLE ute_operator NOLOGIN;
CREATE ROLE ute_admin    NOLOGIN;

REVOKE ALL ON DATABASE unitech_orders FROM PUBLIC;
REVOKE ALL ON SCHEMA public FROM PUBLIC;
REVOKE EXECUTE ON ALL PROCEDURES IN SCHEMA public FROM PUBLIC;

-- ute_reader: только чтение таблиц и представлений
GRANT CONNECT ON DATABASE unitech_orders TO ute_reader;
GRANT USAGE   ON SCHEMA public           TO ute_reader;
GRANT SELECT  ON ALL TABLES IN SCHEMA public TO ute_reader;

-- ute_operator: менеджеры и бухгалтерия (наследует reader)
GRANT ute_reader TO ute_operator;
GRANT INSERT, UPDATE, DELETE ON orders, order_items TO ute_operator;
GRANT INSERT                 ON payments            TO ute_operator;
GRANT INSERT, UPDATE         ON customers           TO ute_operator;
GRANT UPDATE (stock_qty)     ON products            TO ute_operator;   -- резерв остатков
GRANT USAGE ON SEQUENCE orders_order_id_seq, order_items_item_id_seq,
                         payments_payment_id_seq, customers_customer_id_seq TO ute_operator;
GRANT EXECUTE ON PROCEDURE sp_create_order(INT, INT, DATE, VARCHAR, VARCHAR, INT, VARCHAR),
                           sp_add_order_item(INT, INT, INT),
                           sp_change_order_status(INT, VARCHAR, INT),
                           sp_register_payment(INT, NUMERIC, VARCHAR, VARCHAR, INT, INT) TO ute_operator;

-- ute_admin: полный доступ
GRANT ute_operator TO ute_admin;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public TO ute_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ute_admin;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA public TO ute_admin;
GRANT ALL PRIVILEGES ON DATABASE unitech_orders TO ute_admin;

-- ---------- пользователи СУБД ----------
CREATE ROLE ute_app_reader   LOGIN PASSWORD 'ЗАДАЙТЕ_ПАРОЛЬ_READER' CONNECTION LIMIT 10;
CREATE ROLE ute_app_operator LOGIN PASSWORD 'ЗАДАЙТЕ_ПАРОЛЬ_OPERATOR' CONNECTION LIMIT 20;
CREATE ROLE ute_app_admin    LOGIN PASSWORD 'ЗАДАЙТЕ_ПАРОЛЬ_ADMIN' CONNECTION LIMIT 5;

GRANT ute_reader   TO ute_app_reader;
GRANT ute_operator TO ute_app_operator;
GRANT ute_admin    TO ute_app_admin;
