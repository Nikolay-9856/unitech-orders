# Юнитех.Заказы — автоматизация учёта заказов (ПМ.07)

Учебный проект производственной практики, ООО «Юнитех Экспорт», IT-отдел. PostgreSQL 16 + Python 3 / Flask 3.

## Версия v4.0 — триггеры и роли СУБД

### Что вошло в версию
- триггеры: `trg_order_items_line_sum`, `trg_order_items_total` (суммы), `trg_orders_status_audit` (журнал статусов), `trg_orders_updated_at`, `trg_products_updated_at`, `trg_users_updated_at`
- пересчёт суммы заказа перенесён из процедуры в триггеры
- `sql/05_roles.sql`: роли `ute_reader`, `ute_operator`, `ute_admin` и пользователи `ute_app_reader`, `ute_app_operator`, `ute_app_admin`
- приложение подключается под учётной записью СУБД, соответствующей роли пользователя (`APP_ROLE_TO_DB` в `app/db.py`)

### Развёртывание
1. Выполнить по порядку: `sql/01_schema.sql`, `sql/02_data.sql`, `sql/03_objects.sql`, `sql/05_roles.sql` (пароли пользователей СУБД задать свои)
2. В `pg_hba.conf` для 127.0.0.1 указать `scram-sha-256`
3. `pip install flask psycopg2-binary`
4. `app/.env` по образцу `app/.env.example`
5. `cd app && python app.py` → http://127.0.0.1:5080
