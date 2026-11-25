# Юнитех.Заказы — автоматизация учёта заказов (ПМ.07)

Учебный проект производственной практики, ООО «Юнитех Экспорт», IT-отдел. PostgreSQL 16 + Python 3 / Flask 3.

## Версия v3.0 — представления и хранимые процедуры

### Что вошло в версию
- `sql/03_objects.sql`: VIEW `v_orders_full`, `v_customer_stats`, `v_product_sales`; процедуры `sp_create_order`, `sp_add_order_item`, `sp_change_order_status`, `sp_register_payment`, `sp_register_user`
- в карточке заказа: смена статуса по допустимым переходам с резервированием остатка, регистрация оплат
- страница «Пользователи» для администратора
- обработка ошибок RAISE EXCEPTION по коду SQLSTATE

### Развёртывание
1. Выполнить `sql/01_schema.sql`, `sql/02_data.sql`, `sql/03_objects.sql`
2. `pip install flask psycopg2-binary`
3. `app/.env` по образцу `app/.env.example`
4. `cd app && python app.py` → http://127.0.0.1:5080
