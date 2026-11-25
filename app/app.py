"""Юнитех.Заказы — веб-приложение для учёта заказов ООО «Юнитех Экспорт»."""
import os
from datetime import timedelta
from decimal import Decimal, InvalidOperation

import psycopg2
from flask import Flask, flash, redirect, render_template, request, url_for

from db import DBConnection
from security import PasswordHelper
from session import AppSession, login_required, permission_required

DBConnection.init(os.path.join(os.path.dirname(__file__), ".env"))
app = Flask(__name__)
app.secret_key = os.environ["SECRET_KEY"]
app.permanent_session_lifetime = timedelta(hours=8)

STATUSES = ["Новый", "Подтверждён", "Комплектуется", "Отгружен", "Закрыт", "Отменён"]
# какие кнопки смены статуса показывать (сами правила проверяет sp_change_order_status)
NEXT_STATUS = {
    "Новый": ["Подтверждён", "Отменён"],
    "Подтверждён": ["Комплектуется", "Отменён"],
    "Комплектуется": ["Отгружен"],
    "Отгружен": ["Закрыт"],
}
PAY_METHODS = ["Банковский перевод", "Аккредитив", "Оплата картой"]

PG_MESSAGES = {
    "23505": "Запись с таким значением уже существует",
    "23503": "Запись связана с другими данными и не может быть удалена",
    "23514": "Значение не прошло проверку (CHECK)",
    "42501": "Недостаточно прав для операции",
}


def db_error_text(exc: psycopg2.Error) -> str:
    """Текст из RAISE EXCEPTION процедуры либо сообщение по коду SQLSTATE."""
    app.logger.warning("DB error %s: %s", exc.pgcode, exc.diag.message_primary)
    if exc.pgcode in ("P0001", "P0002", "22023") or (exc.pgcode == "23505" and "Логин" in (exc.diag.message_primary or "")):
        return exc.diag.message_primary
    return PG_MESSAGES.get(exc.pgcode, "Ошибка базы данных")


def load_lookup(table, key, label, where=""):
    """Универсальная загрузка справочника для выпадающих списков."""
    return DBConnection.query(f"SELECT {key} AS id, {label} AS name FROM {table} {where} ORDER BY 2")


def money(value):
    return f"{value:,.2f}".replace(",", " ").replace(".", ",") if value is not None else "—"


app.jinja_env.filters["money"] = money


@app.context_processor
def inject_user():
    return {"me": AppSession.current(), "can": AppSession.can}


# ---------------- аутентификация ----------------
@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        login_name = request.form.get("login", "").strip().lower()
        password = request.form.get("password", "")
        user = DBConnection.query_one(
            """SELECT u.user_id, u.login, u.full_name, u.is_active,
                      u.password_hash, u.password_salt, r.role_code, r.role_name
               FROM users u JOIN roles r ON r.role_id = u.role_id
               WHERE u.login = %s""", (login_name,))
        if user and user["is_active"] and PasswordHelper.verify_password(
                password, user["password_salt"], user["password_hash"]):
            AppSession.start(user)
            return redirect(url_for("dashboard"))
        flash("Неверный логин или пароль", "error")
    return render_template("login.html")


@app.route("/logout")
def logout():
    AppSession.end()
    return redirect(url_for("login"))


# ---------------- главная ----------------
@app.route("/")
@login_required
def dashboard():
    totals = DBConnection.query_one(
        """SELECT COUNT(*) FILTER (WHERE status NOT IN ('Закрыт','Отменён')) AS active,
                  COALESCE(SUM(total_amount) FILTER (WHERE status NOT IN ('Закрыт','Отменён')), 0) AS in_work,
                  COALESCE(SUM(debt) FILTER (WHERE status <> 'Отменён'), 0) AS debt,
                  COUNT(*) FILTER (WHERE is_overdue) AS overdue
           FROM v_orders_full""")
    customers = DBConnection.query(
        "SELECT * FROM v_customer_stats WHERE orders_cnt > 0 ORDER BY ordered DESC LIMIT 5")
    mine = DBConnection.query(
        """SELECT * FROM v_orders_full
           WHERE manager = %s AND status NOT IN ('Закрыт','Отменён') ORDER BY due_date""",
        (AppSession.current()["full_name"],))
    recent = DBConnection.query(
        """SELECT l.changed_at, o.order_number, l.new_status
           FROM order_status_log l JOIN orders o ON o.order_id = l.order_id
           ORDER BY l.changed_at DESC, l.log_id DESC LIMIT 7""")
    return render_template("dashboard.html", totals=totals, customers=customers, mine=mine, recent=recent)


# ---------------- заказы: READ ----------------
@app.route("/orders")
@login_required
def orders():
    status = request.args.get("status", "")
    customer = request.args.get("customer", "")
    text = request.args.get("q", "").strip()
    sql = "SELECT * FROM v_orders_full WHERE TRUE"
    params = []
    if status:
        sql += " AND status = %s"
        params.append(status)
    if customer:
        sql += " AND customer = %s"
        params.append(customer)
    if text:
        sql += " AND (order_number ILIKE %s OR customer ILIKE %s)"
        params += [f"%{text}%", f"%{text}%"]
    sql += " ORDER BY order_date DESC, order_number DESC"
    rows = DBConnection.query(sql, params)
    customers = load_lookup("customers", "customer_id", "name")
    return render_template("orders.html", rows=rows, statuses=STATUSES, customers=customers,
                           f_status=status, f_customer=customer, f_q=text)


@app.route("/orders/<int:order_id>")
@login_required
def order_card(order_id):
    order = DBConnection.query_one("SELECT * FROM v_orders_full WHERE order_id = %s", (order_id,))
    if not order:
        flash("Заказ не найден", "error")
        return redirect(url_for("orders"))
    extra = DBConnection.query_one(
        "SELECT delivery_address, comment FROM orders WHERE order_id = %s", (order_id,))
    items = DBConnection.query(
        """SELECT oi.*, p.sku, p.name, p.unit FROM order_items oi
           JOIN products p ON p.product_id = oi.product_id
           WHERE oi.order_id = %s ORDER BY oi.item_id""", (order_id,))
    payments = DBConnection.query(
        """SELECT pm.*, u.full_name FROM payments pm JOIN users u ON u.user_id = pm.created_by
           WHERE pm.order_id = %s ORDER BY pm.paid_at""", (order_id,))
    history = DBConnection.query(
        """SELECT l.*, u.full_name FROM order_status_log l LEFT JOIN users u ON u.user_id = l.changed_by
           WHERE l.order_id = %s ORDER BY l.changed_at, l.log_id""", (order_id,))
    products = DBConnection.query(
        "SELECT product_id AS id, sku || ' — ' || name || ' (ост. ' || stock_qty || ')' AS name "
        "FROM products WHERE is_active ORDER BY sku")
    return render_template("card.html", o=order, extra=extra, items=items, payments=payments,
                           history=history, products=products,
                           next_status=NEXT_STATUS.get(order["status"], []), methods=PAY_METHODS)


# ---------------- заказы: CREATE ----------------
@app.route("/orders/new", methods=["GET", "POST"])
@permission_required("order_create")
def order_new():
    form = request.form
    if request.method == "POST":
        try:
            res = DBConnection.call("sp_create_order", (
                int(form["customer_id"]), AppSession.current()["user_id"],
                form.get("due_date") or None, form.get("delivery_address") or None,
                form.get("comment") or None, None, None),
                app_role=AppSession.role(), casts={2: "date"})
            flash(f"Заказ создан: {res['p_order_number']}. Добавьте позиции.", "ok")
            return redirect(url_for("order_card", order_id=res["p_order_id"]))
        except psycopg2.Error as exc:
            flash(db_error_text(exc), "error")
    return render_template("order_form.html", o=None, form=form,
                           customers=load_lookup("customers", "customer_id", "name"))


# ---------------- заказы: UPDATE ----------------
@app.route("/orders/<int:order_id>/edit", methods=["GET", "POST"])
@permission_required("order_edit")
def order_edit(order_id):
    o = DBConnection.query_one("SELECT * FROM orders WHERE order_id = %s", (order_id,))
    if request.method == "POST":
        f = request.form
        try:
            n = DBConnection.execute(
                """UPDATE orders
                      SET customer_id = %s, due_date = %s, delivery_address = %s, comment = %s
                    WHERE order_id = %s AND status IN ('Новый','Подтверждён')""",
                (int(f["customer_id"]), f.get("due_date") or None, f.get("delivery_address") or None,
                 f.get("comment") or None, order_id), app_role=AppSession.role())
            flash("Изменения сохранены" if n else "Реквизиты можно менять до начала комплектации",
                  "ok" if n else "warn")
            return redirect(url_for("order_card", order_id=order_id))
        except psycopg2.Error as exc:
            flash(db_error_text(exc), "error")
    return render_template("order_form.html", o=o, form=request.form,
                           customers=load_lookup("customers", "customer_id", "name"))


# ---------------- заказы: DELETE ----------------
@app.route("/orders/<int:order_id>/delete", methods=["POST"])
@permission_required("order_delete")
def order_delete(order_id):
    try:
        n = DBConnection.execute(
            "DELETE FROM orders WHERE order_id = %s AND status IN ('Новый','Отменён')",
            (order_id,), app_role=AppSession.role())
        if n:
            flash("Заказ удалён вместе с позициями, оплатами и историей", "ok")
        else:
            flash("Удалять можно только новые и отменённые заказы", "warn")
    except psycopg2.Error as exc:
        flash(db_error_text(exc), "error")
    return redirect(url_for("orders"))


# ---------------- позиции, статус, оплата ----------------
@app.route("/orders/<int:order_id>/items", methods=["POST"])
@permission_required("order_edit")
def item_add(order_id):
    try:
        DBConnection.call("sp_add_order_item",
                          (order_id, int(request.form["product_id"]), int(request.form["qty"])),
                          app_role=AppSession.role())
        flash("Позиция добавлена, сумма заказа пересчитана", "ok")
    except (psycopg2.Error, ValueError) as exc:
        flash(db_error_text(exc) if isinstance(exc, psycopg2.Error) else "Укажите количество числом", "error")
    return redirect(url_for("order_card", order_id=order_id))


@app.route("/orders/<int:order_id>/items/<int:item_id>/delete", methods=["POST"])
@permission_required("order_edit")
def item_delete(order_id, item_id):
    n = DBConnection.execute(
        """DELETE FROM order_items oi USING orders o
           WHERE oi.item_id = %s AND oi.order_id = o.order_id AND o.order_id = %s AND o.status = 'Новый'""",
        (item_id, order_id), app_role=AppSession.role())
    flash("Позиция удалена" if n else "Позиции можно удалять только у нового заказа", "ok" if n else "warn")
    return redirect(url_for("order_card", order_id=order_id))


@app.route("/orders/<int:order_id>/status", methods=["POST"])
@permission_required("order_status")
def order_status(order_id):
    try:
        DBConnection.call("sp_change_order_status",
                          (order_id, request.form["status"], AppSession.current()["user_id"]),
                          app_role=AppSession.role())
        flash(f"Статус изменён: {request.form['status']}", "ok")
    except psycopg2.Error as exc:
        flash(db_error_text(exc), "error")
    return redirect(url_for("order_card", order_id=order_id))


@app.route("/orders/<int:order_id>/payments", methods=["POST"])
@permission_required("payment")
def payment_add(order_id):
    try:
        amount = Decimal(request.form["amount"].replace(" ", "").replace(",", "."))
        res = DBConnection.call("sp_register_payment",
                                (order_id, amount, request.form["method"], request.form.get("doc_ref") or None,
                                 AppSession.current()["user_id"], None),
                                app_role=AppSession.role(), casts={1: "numeric"})
        flash(f"Оплата № {res['p_payment_id']} зарегистрирована", "ok")
    except InvalidOperation:
        flash("Сумма указана неверно", "error")
    except psycopg2.Error as exc:
        flash(db_error_text(exc), "error")
    return redirect(url_for("order_card", order_id=order_id))


# ---------------- клиенты и товары ----------------
@app.route("/customers", methods=["GET", "POST"])
@login_required
def customers():
    if request.method == "POST" and AppSession.can("customers"):
        f = request.form
        try:
            DBConnection.execute(
                """INSERT INTO customers (name, tax_id, country, email, phone, manager_id)
                   VALUES (%s, %s, %s, %s, %s, %s)""",
                (f["name"].strip(), f["tax_id"].strip(), f["country"].strip(), f.get("email") or None,
                 f.get("phone") or None, AppSession.current()["user_id"]), app_role=AppSession.role())
            flash("Клиент добавлен", "ok")
        except psycopg2.Error as exc:
            flash("Налоговый номер — от 9 до 14 цифр" if exc.pgcode == "23514" else db_error_text(exc), "error")
    rows = DBConnection.query(
        """SELECT s.*, c.tax_id, u.full_name AS manager FROM v_customer_stats s
           JOIN customers c ON c.customer_id = s.customer_id
           LEFT JOIN users u ON u.user_id = c.manager_id ORDER BY s.name""")
    return render_template("customers.html", rows=rows)


@app.route("/products")
@login_required
def products():
    rows = DBConnection.query("SELECT * FROM v_product_sales ORDER BY category, sku")
    return render_template("products.html", rows=rows)


# ---------------- отчёты ----------------
@app.route("/reports")
@login_required
def reports():
    managers = DBConnection.query(
        """SELECT u.full_name, COUNT(o.order_id) AS orders_cnt,
                  COALESCE(SUM(o.total_amount), 0) AS amount
           FROM orders o RIGHT JOIN users u ON u.user_id = o.manager_id AND o.status <> 'Отменён'
           JOIN roles r ON r.role_id = u.role_id
           WHERE r.role_code IN ('MANAGER','ADMIN')
           GROUP BY u.full_name ORDER BY amount DESC""")
    by_category = DBConnection.query(
        """SELECT pc.name, COUNT(oi.item_id) AS lines, COALESCE(SUM(oi.line_sum), 0) AS revenue
           FROM order_items oi
           JOIN products pr ON pr.product_id = oi.product_id
           RIGHT JOIN product_categories pc ON pc.category_id = pr.category_id
           GROUP BY pc.name ORDER BY revenue DESC""")
    debtors = DBConnection.query(
        "SELECT * FROM v_customer_stats WHERE debt > 0 ORDER BY debt DESC")
    return render_template("reports.html", managers=managers, by_category=by_category, debtors=debtors)


# ---------------- администрирование пользователей ----------------
@app.route("/admin/users", methods=["GET", "POST"])
@permission_required("users")
def admin_users():
    if request.method == "POST":
        f = request.form
        weak = PasswordHelper.check_strength(f["password"])
        if weak:
            flash("Пароль: " + ", ".join(weak), "error")
        else:
            salt = PasswordHelper.generate_salt()
            pwd_hash = PasswordHelper.hash_password(f["password"], salt)
            try:
                res = DBConnection.call("sp_register_user", (
                    f["login"].strip(), f["full_name"].strip(), f["email"].strip(),
                    f.get("position") or None, f["role_code"], pwd_hash, salt, None), app_role="ADMIN")
                flash(f"Пользователь создан, ID = {res['p_user_id']}", "ok")
            except psycopg2.Error as exc:
                flash(db_error_text(exc), "error")
    rows = DBConnection.query(
        """SELECT u.user_id, u.login, u.full_name, u.position, r.role_name, u.is_active,
                  left(u.password_hash, 12) || '…' AS hash_head, u.created_at
           FROM users u JOIN roles r ON r.role_id = u.role_id ORDER BY u.user_id""", app_role="ADMIN")
    return render_template("users.html", rows=rows,
                           roles=DBConnection.query("SELECT role_code, role_name FROM roles ORDER BY role_id"))


@app.route("/admin/users/<int:user_id>/toggle", methods=["POST"])
@permission_required("users")
def admin_user_toggle(user_id):
    DBConnection.execute("UPDATE users SET is_active = NOT is_active WHERE user_id = %s",
                         (user_id,), app_role="ADMIN")
    return redirect(url_for("admin_users"))


@app.errorhandler(403)
def forbidden(_):
    return render_template("message.html", title="Доступ запрещён",
                           text="Для вашей роли эта страница недоступна."), 403


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5080, debug=False)
