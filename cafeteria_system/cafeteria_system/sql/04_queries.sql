/* =============================================================================
   Cafeteria Management System (Oracle 19c)
   File: 04_queries.sql
   Purpose:
     - Advanced SQL queries requested in the project
     - Joins, Set operations, Subqueries, Views, Indexes

   Notes:
     - "ORDER" is quoted and must be referenced as "ORDER".
   ============================================================================ */

/* -----------------------------------------------------------------------------
   JOINS
   --------------------------------------------------------------------------- */

/* 1) INNER JOIN — all completed orders with customer name and total amount */
SELECT
  o.ORDER_ID,
  c.NAME AS CUSTOMER_NAME,
  o.ORDER_DATE,
  o.TOTAL_AMOUNT
FROM "ORDER" o
JOIN CUSTOMER c
  ON c.CUSTOMER_ID = o.CUSTOMER_ID
WHERE o.STATUS = 'Completed'
ORDER BY o.ORDER_DATE DESC, o.ORDER_ID DESC;

/* 2) LEFT OUTER JOIN — all menu items with their feedback (including no feedback)
      Feedback is per order; we derive per-item feedback by linking orders that
      contained the item.
*/
SELECT
  mi.ITEM_ID,
  mi.NAME AS ITEM_NAME,
  f.FEEDBACK_ID,
  f.RATING,
  f.COMMENTS,
  f.FEEDBACK_DATE
FROM MENU_ITEM mi
LEFT JOIN ORDER_ITEM oi
  ON oi.ITEM_ID = mi.ITEM_ID
LEFT JOIN FEEDBACK f
  ON f.ORDER_ID = oi.ORDER_ID
ORDER BY mi.ITEM_ID, f.FEEDBACK_DATE;

/* 3) FULL JOIN — all employees and their assigned orders (including unassigned)
      Unassigned orders are those with EMPLOYEE_ID IS NULL.
*/
SELECT
  e.EMPLOYEE_ID,
  e.NAME AS EMPLOYEE_NAME,
  o.ORDER_ID,
  o.STATUS,
  o.ORDER_DATE,
  o.TOTAL_AMOUNT
FROM EMPLOYEE e
FULL OUTER JOIN "ORDER" o
  ON o.EMPLOYEE_ID = e.EMPLOYEE_ID
ORDER BY NVL(e.EMPLOYEE_ID, 999999), NVL(o.ORDER_ID, 999999);

/* -----------------------------------------------------------------------------
   SET OPERATIONS
   --------------------------------------------------------------------------- */

/* 4) UNION — combine customer names from Student and Staff types */
SELECT NAME FROM CUSTOMER WHERE CUSTOMER_TYPE = 'Student'
UNION
SELECT NAME FROM CUSTOMER WHERE CUSTOMER_TYPE = 'Staff'
ORDER BY NAME;

/* 5) INTERSECT — find items that appear in both orders and inventory
      This is a business-specific demo: some menu items map directly to an
      inventory item by name (e.g., Mineral Water (500ml)).
*/
SELECT mi.NAME AS ITEM_NAME
FROM MENU_ITEM mi
INTERSECT
SELECT i.ITEM_NAME
FROM INVENTORY i;

/* 6) MINUS — find menu items never ordered */
SELECT mi.ITEM_ID, mi.NAME
FROM MENU_ITEM mi
MINUS
SELECT mi2.ITEM_ID, mi2.NAME
FROM MENU_ITEM mi2
JOIN ORDER_ITEM oi
  ON oi.ITEM_ID = mi2.ITEM_ID
ORDER BY ITEM_ID;

/* -----------------------------------------------------------------------------
   SUBQUERIES
   --------------------------------------------------------------------------- */

/* 7) CORRELATED SUBQUERY — customers who spent above the average order amount */
SELECT
  c.CUSTOMER_ID,
  c.NAME,
  ROUND(SUM(o.TOTAL_AMOUNT), 2) AS LIFETIME_SPEND
FROM CUSTOMER c
JOIN "ORDER" o
  ON o.CUSTOMER_ID = c.CUSTOMER_ID
WHERE o.STATUS = 'Completed'
GROUP BY c.CUSTOMER_ID, c.NAME
HAVING SUM(o.TOTAL_AMOUNT) >
  (SELECT AVG(o2.TOTAL_AMOUNT)
   FROM "ORDER" o2
   WHERE o2.STATUS = 'Completed');

/* 8) NON-CORRELATED SUBQUERY — top 3 most ordered menu items (by quantity) */
SELECT *
FROM (
  SELECT
    mi.ITEM_ID,
    mi.NAME,
    SUM(oi.QUANTITY) AS TOTAL_QTY
  FROM MENU_ITEM mi
  JOIN ORDER_ITEM oi
    ON oi.ITEM_ID = mi.ITEM_ID
  GROUP BY mi.ITEM_ID, mi.NAME
  ORDER BY TOTAL_QTY DESC
)
WHERE ROWNUM <= 3;

/* -----------------------------------------------------------------------------
   VIEWS
   --------------------------------------------------------------------------- */

/* 9) DailyRevenue — total revenue grouped by date
      Revenue uses Paid payments only.
*/
CREATE OR REPLACE VIEW DailyRevenue AS
SELECT
  TRUNC(p.PAYMENT_DATE) AS REVENUE_DATE,
  ROUND(SUM(p.AMOUNT_PAID), 2) AS TOTAL_REVENUE
FROM PAYMENT p
WHERE p.PAYMENT_STATUS = 'Paid'
GROUP BY TRUNC(p.PAYMENT_DATE);

/* 10) PopularItems — items ordered more than 5 times with avg rating
       Avg rating derived from feedback of orders that included the item.
*/
CREATE OR REPLACE VIEW PopularItems AS
SELECT
  mi.ITEM_ID,
  mi.NAME AS ITEM_NAME,
  SUM(oi.QUANTITY) AS TOTAL_ORDERED_QTY,
  ROUND(AVG(f.RATING), 2) AS AVG_RATING_FROM_FEEDBACK
FROM MENU_ITEM mi
JOIN ORDER_ITEM oi
  ON oi.ITEM_ID = mi.ITEM_ID
LEFT JOIN FEEDBACK f
  ON f.ORDER_ID = oi.ORDER_ID
GROUP BY mi.ITEM_ID, mi.NAME
HAVING SUM(oi.QUANTITY) > 5;

/* 11) LowInventory — all ingredients below reorder level */
CREATE OR REPLACE VIEW LowInventory AS
SELECT
  INVENTORY_ID,
  ITEM_NAME,
  UNIT,
  QUANTITY_IN_STOCK,
  REORDER_LEVEL,
  LAST_RESTOCKED
FROM INVENTORY
WHERE QUANTITY_IN_STOCK < REORDER_LEVEL;

/* -----------------------------------------------------------------------------
   INDEXING
   --------------------------------------------------------------------------- */

/* 12) Indexes */
CREATE INDEX IDX_ORDER_ORDERDATE ON "ORDER"(ORDER_DATE);
CREATE INDEX IDX_MENUITEM_CATEGORY ON MENU_ITEM(CATEGORY_ID);
CREATE INDEX IDX_FEEDBACK_CUSTOMER ON FEEDBACK(CUSTOMER_ID);

