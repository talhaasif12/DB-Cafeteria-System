from __future__ import annotations

import datetime as dt

from flask import Flask, flash, redirect, render_template, request, url_for
import oracledb

from db import POOL


app = Flask(__name__)
app.secret_key = "cafeteria-secret-key-change-me"


def _as_date(value: str) -> dt.date:
    return dt.datetime.strptime(value, "%Y-%m-%d").date()


@app.get("/")
def root():
    return redirect(url_for("dashboard"))


@app.get("/menu")
def menu():
    sql = """
    SELECT
      mc.CATEGORY_NAME,
      mi.ITEM_ID,
      mi.NAME AS ITEM_NAME,
      mi.PRICE,
      mi.CALORIE_COUNT,
      mi.AVERAGE_RATING
    FROM MENU_ITEM mi
    JOIN MENU_CATEGORY mc ON mc.CATEGORY_ID = mi.CATEGORY_ID
    WHERE mi.IS_AVAILABLE = 'Y'
    ORDER BY mc.CATEGORY_NAME, mi.NAME
    """
    with POOL.acquire() as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            rows = cur.fetchall()

    grouped: dict[str, list[dict]] = {}
    for cat, item_id, name, price, cal, avg_rating in rows:
        grouped.setdefault(cat, []).append(
            {
                "item_id": int(item_id),
                "name": name,
                "price": float(price),
                "calorie_count": int(cal),
                "avg_rating": float(avg_rating),
            }
        )
    return render_template("menu.html", grouped=grouped)


@app.route("/order", methods=["GET", "POST"])
def order():
    with POOL.acquire() as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT customer_id, name, customer_type FROM customer ORDER BY name"
            )
            customers = cur.fetchall()

            cur.execute(
                """
                SELECT mi.item_id, mc.category_name, mi.name, mi.price
                FROM menu_item mi
                JOIN menu_category mc ON mc.category_id = mi.category_id
                WHERE mi.is_available = 'Y'
                ORDER BY mc.category_name, mi.name
                """
            )
            items = cur.fetchall()

            cur.execute(
                "SELECT employee_id, name, role FROM employee WHERE role='Cashier' ORDER BY name"
            )
            cashiers = cur.fetchall()

    if request.method == "GET":
        return render_template(
            "order.html",
            customers=customers,
            cashiers=cashiers,
            items=items,
        )

    customer_id = int(request.form.get("customer_id") or "0")
    employee_id = int(request.form.get("employee_id") or "0")
    payment_method = request.form.get("payment_method") or "Cash"

    chosen: list[str] = []
    for item_id, _, _, _ in items:
        qty_raw = request.form.get(f"qty_{item_id}", "").strip()
        if not qty_raw:
            continue
        try:
            qty = int(qty_raw)
        except ValueError:
            flash("Invalid quantity entered (must be a number).", "danger")
            return redirect(url_for("order"))
        if qty <= 0:
            continue
        chosen.append(f"{int(item_id)}:{qty}")

    if customer_id <= 0 or employee_id <= 0:
        flash("Please select a customer and a cashier.", "danger")
        return redirect(url_for("order"))
    if not chosen:
        flash("Please select at least one item with quantity.", "danger")
        return redirect(url_for("order"))

    try:
        with POOL.acquire() as conn:
            with conn.cursor() as cur:
                arr = cur.arrayvar(oracledb.DB_TYPE_VARCHAR, chosen)
                cur.callproc("CafeteriaManager.PlaceOrder", [customer_id, employee_id, arr])

                # Get the newly created order id for this session/customer (same txn)
                cur.execute(
                    """
                    SELECT order_id, total_amount
                    FROM "ORDER"
                    WHERE customer_id = :cid
                      AND order_date = TRUNC(SYSDATE)
                    ORDER BY order_id DESC
                    FETCH FIRST 1 ROWS ONLY
                    """,
                    {"cid": customer_id},
                )
                row = cur.fetchone()
                if not row:
                    raise RuntimeError("Order was placed but could not be located.")
                order_id, total_amount = int(row[0]), float(row[1])

                # Auto-process full payment for demo usability
                cur.callproc(
                    "CafeteriaManager.ProcessPayment",
                    [order_id, total_amount, payment_method],
                )
            conn.commit()

        flash(f"Order #{order_id} placed and paid successfully.", "success")
        return redirect(url_for("orders"))
    except Exception as ex:
        flash(f"Failed to place order: {ex}", "danger")
        return redirect(url_for("order"))


@app.get("/orders")
def orders():
    sql = """
    SELECT
      o.order_id,
      o.order_date,
      o.order_time,
      o.total_amount,
      o.status,
      o.payment_method,
      c.name AS customer_name
    FROM "ORDER" o
    JOIN customer c ON c.customer_id = o.customer_id
    ORDER BY o.order_date DESC, o.order_id DESC
    """
    with POOL.acquire() as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            rows = cur.fetchall()

    data = []
    for order_id, order_date, order_time, total_amount, status, method, customer_name in rows:
        data.append(
            {
                "order_id": int(order_id),
                "order_date": order_date,
                "order_time": order_time,
                "total_amount": float(total_amount),
                "status": status,
                "payment_method": method,
                "customer_name": customer_name,
            }
        )
    return render_template("orders.html", orders=data)


@app.get("/inventory")
def inventory():
    sql = """
    SELECT inventory_id, item_name, unit, quantity_in_stock, reorder_level, last_restocked
    FROM inventory
    ORDER BY item_name
    """
    with POOL.acquire() as conn:
        with conn.cursor() as cur:
            cur.execute(sql)
            rows = cur.fetchall()

    inv = []
    for inv_id, name, unit, qty, reorder, restocked in rows:
        inv.append(
            {
                "inventory_id": int(inv_id),
                "item_name": name,
                "unit": unit,
                "quantity_in_stock": float(qty),
                "reorder_level": float(reorder),
                "last_restocked": restocked,
                "is_low": float(qty) < float(reorder),
            }
        )
    return render_template("inventory.html", inventory=inv)


@app.route("/feedback", methods=["GET", "POST"])
def feedback():
    with POOL.acquire() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT o.order_id, c.name, o.total_amount
                FROM "ORDER" o
                JOIN customer c ON c.customer_id = o.customer_id
                LEFT JOIN feedback f ON f.order_id = o.order_id
                WHERE o.status = 'Completed'
                  AND f.feedback_id IS NULL
                ORDER BY o.order_date DESC, o.order_id DESC
                """
            )
            eligible = cur.fetchall()

    if request.method == "GET":
        return render_template("feedback.html", eligible_orders=eligible)

    order_id = int(request.form.get("order_id") or "0")
    rating = int(request.form.get("rating") or "0")
    comments = (request.form.get("comments") or "").strip()

    if order_id <= 0 or rating < 1 or rating > 5:
        flash("Please select an order and a valid rating (1-5).", "danger")
        return redirect(url_for("feedback"))

    try:
        with POOL.acquire() as conn:
            with conn.cursor() as cur:
                cur.execute(
                    'SELECT customer_id FROM "ORDER" WHERE order_id = :oid',
                    {"oid": order_id},
                )
                row = cur.fetchone()
                if not row:
                    raise RuntimeError("Order not found.")
                customer_id = int(row[0])

                cur.execute(
                    """
                    INSERT INTO feedback(feedback_id, customer_id, order_id, rating, comments, feedback_date)
                    VALUES (seq_feedback.NEXTVAL, :cid, :oid, :rating, :comments, SYSDATE)
                    """,
                    {
                        "cid": customer_id,
                        "oid": order_id,
                        "rating": rating,
                        "comments": comments or None,
                    },
                )
            conn.commit()

        flash("Feedback submitted successfully.", "success")
        return redirect(url_for("menu"))
    except Exception as ex:
        flash(f"Failed to submit feedback: {ex}", "danger")
        return redirect(url_for("feedback"))


@app.get("/dashboard")
def dashboard():
    today = dt.date.today()
    with POOL.acquire() as conn:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT NVL(SUM(amount_paid),0)
                FROM payment
                WHERE payment_status='Paid'
                  AND TRUNC(payment_date) = TRUNC(SYSDATE)
                """
            )
            revenue = float(cur.fetchone()[0])

            cur.execute(
                """
                SELECT COUNT(*)
                FROM "ORDER"
                WHERE order_date = TRUNC(SYSDATE)
                """
            )
            orders_today = int(cur.fetchone()[0])

            cur.execute("SELECT COUNT(*) FROM LowInventory")
            low_stock = int(cur.fetchone()[0])

            cur.execute(
                """
                SELECT item_name, total_qty
                FROM (
                  SELECT mi.name AS item_name, SUM(oi.quantity) AS total_qty
                  FROM order_item oi
                  JOIN "ORDER" o ON o.order_id = oi.order_id
                  JOIN menu_item mi ON mi.item_id = oi.item_id
                  WHERE o.order_date = TRUNC(SYSDATE)
                  GROUP BY mi.name
                  ORDER BY total_qty DESC
                )
                WHERE ROWNUM = 1
                """
            )
            top_row = cur.fetchone()
            top_item = top_row[0] if top_row else None
            top_qty = int(top_row[1]) if top_row else 0

    return render_template(
        "dashboard.html",
        today=today,
        revenue=revenue,
        orders_today=orders_today,
        low_stock=low_stock,
        top_item=top_item,
        top_qty=top_qty,
    )


if __name__ == "__main__":
    app.run(debug=True)

