"""Управление подключением к PostgreSQL (Юнитех.Заказы)."""
import os
from contextlib import contextmanager

import psycopg2
import psycopg2.extras
from psycopg2 import pool

# роль приложения -> учётная запись СУБД (принцип минимальных привилегий)
APP_ROLE_TO_DB = {
    "ADMIN": "ADMIN",
    "MANAGER": "OPERATOR",
    "ACCOUNTANT": "OPERATOR",
    "VIEWER": "READER",
}


def _load_env(path=".env"):
    """Простой загрузчик .env без внешних зависимостей."""
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                os.environ.setdefault(key, value)


class DBConnection:
    """Пулы соединений для трёх учётных записей СУБД."""

    _pools = {}

    @classmethod
    def init(cls, env_path=".env"):
        _load_env(env_path)
        for kind in ("READER", "OPERATOR", "ADMIN"):
            cls._pools[kind] = pool.SimpleConnectionPool(
                1, 5,
                host=os.environ["DB_HOST"],
                port=os.environ.get("DB_PORT", "5432"),
                dbname=os.environ["DB_NAME"],
                user=os.environ[f"DB_USER_{kind}"],
                password=os.environ[f"DB_PASS_{kind}"],
                application_name="unitech-orders",
            )

    @classmethod
    @contextmanager
    def cursor(cls, app_role="VIEWER"):
        """Курсор с автоматическим commit/rollback и возвратом соединения в пул."""
        kind = APP_ROLE_TO_DB.get(app_role, "READER")
        conn = cls._pools[kind].getconn()
        try:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                yield cur
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            cls._pools[kind].putconn(conn)

    @classmethod
    def query(cls, sql, params=None, app_role="VIEWER"):
        with cls.cursor(app_role) as cur:
            cur.execute(sql, params)
            return cur.fetchall()

    @classmethod
    def query_one(cls, sql, params=None, app_role="VIEWER"):
        rows = cls.query(sql, params, app_role)
        return rows[0] if rows else None

    @classmethod
    def execute(cls, sql, params=None, app_role="MANAGER"):
        with cls.cursor(app_role) as cur:
            cur.execute(sql, params)
            return cur.rowcount

    @classmethod
    def call(cls, proc, params, app_role="MANAGER", casts=None):
        """CALL хранимой процедуры; возвращает значения INOUT-параметров.
        casts — явные типы параметров (например, {1: "smallint"})."""
        casts = casts or {}
        placeholders = ", ".join(
            f"%s::{casts[i]}" if i in casts else "%s" for i in range(len(params)))
        with cls.cursor(app_role) as cur:
            cur.execute(f"CALL {proc}({placeholders})", params)
            return cur.fetchone() if cur.description else None
