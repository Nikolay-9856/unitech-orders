# Юнитех.Заказы — автоматизация учёта заказов (ПМ.07)

Учебный проект производственной практики, ООО «Юнитех Экспорт», IT-отдел. PostgreSQL 16 + Python 3 / Flask 3.

## Версия v5.0 — финальная версия

### Что вошло в версию
- все SQL-скрипты: `01_schema`, `02_data`, `03_objects`, `05_roles` и полный дамп `sql/dump_final.sql`
- финальное веб-приложение (CRUD, VIEW, процедуры, триггеры, роли СУБД, хэширование паролей)
- `docs/`: ER-диаграмма, схема навигации и все рисунки отчёта в формате draw.io

**Тестовые учётные записи:** admin (администратор), lebedeva, tarasov, shevchenko (менеджеры), kuzmina, egorova (бухгалтеры), vlasov (наблюдатель).

### Развёртывание
**Вариант А — из дампа:**
1. `createdb unitech_orders`
2. `psql -d unitech_orders -f sql/dump_final.sql`
3. `psql -d unitech_orders -f sql/05_roles.sql`

**Вариант Б — по скриптам:** `01_schema.sql` → `02_data.sql` → `03_objects.sql` → `05_roles.sql`

Далее: `pip install flask psycopg2-binary`, создать `app/.env` по образцу `app/.env.example`, запустить `cd app && python app.py` и открыть http://127.0.0.1:5080
