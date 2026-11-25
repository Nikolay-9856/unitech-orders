"""Подключение к PostgreSQL (Юнитех.Заказы) — одна учётная запись.
Разделение на роли СУБД появится в версии v4.0."""
import os
from contextlib import contextmanager

import psycopg2
import psycopg2.extras
from psycopg2 import pool


def _load_env(path=".env"):
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, value = line.split("=", 1)
                os.environ.setdefault(key, value)


class DBConnection:
    _pool = None

    @classmethod
    def init(cls, env_path=".env"):
        _load_env(env_path)
        cls._pool = pool.SimpleConnectionPool(
            1, 5,
            host=os.environ["DB_HOST"], port=os.environ.get("DB_PORT", "5432"),
            dbname=os.environ["DB_NAME"], user=os.environ["DB_USER"],
            password=os.environ.get("DB_PASS", ""), application_name="unitech-orders")

    @classmethod
    @contextmanager
    def cursor(cls, app_role=None):
        conn = cls._pool.getconn()
        try:
            with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
                yield cur
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            cls._pool.putconn(conn)

    @classmethod
    def query(cls, sql, params=None, app_role=None):
        with cls.cursor() as cur:
            cur.execute(sql, params)
            return cur.fetchall()

    @classmethod
    def query_one(cls, sql, params=None, app_role=None):
        rows = cls.query(sql, params)
        return rows[0] if rows else None

    @classmethod
    def execute(cls, sql, params=None, app_role=None):
        with cls.cursor() as cur:
            cur.execute(sql, params)
            return cur.rowcount

    @classmethod
    def call(cls, proc, params, app_role=None, casts=None):
        """CALL хранимой процедуры; возвращает значения INOUT-параметров."""
        casts = casts or {}
        placeholders = ", ".join(
            f"%s::{casts[i]}" if i in casts else "%s" for i in range(len(params)))
        with cls.cursor() as cur:
            cur.execute(f"CALL {proc}({placeholders})", params)
            return cur.fetchone() if cur.description else None
