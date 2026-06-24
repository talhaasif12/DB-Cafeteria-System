/* =============================================================================
   Cafeteria Management System (Oracle 19c)
   File: 05_plsql.sql
   Purpose:
     - PL/SQL package (spec + body): CafeteriaManager
     - Cursors for pending orders and low-stock items
     - Triggers for IDs, inventory deduction, rating maintenance, delete protection
     - Object types for order summaries

   Notes:
     - "ORDER" is quoted and must be referenced as "ORDER".
     - PlaceOrder uses SYS.ODCIVARCHAR2LIST where each element is formatted as:
         '<ItemID>:<Quantity>'
       Example: SYS.ODCIVARCHAR2LIST('1:2','6:1','15:1')
   ============================================================================ */

/* -----------------------------------------------------------------------------
   OBJECT TYPE: OrderSummaryType
   --------------------------------------------------------------------------- */
CREATE OR REPLACE TYPE OrderSummaryType AS OBJECT (
  OrderID       NUMBER,
  CustomerName  VARCHAR2(100),
  TotalAmount   NUMBER,
  Status        VARCHAR2(20),
  MEMBER FUNCTION GetLabel RETURN VARCHAR2
);
/

CREATE OR REPLACE TYPE BODY OrderSummaryType AS
  MEMBER FUNCTION GetLabel RETURN VARCHAR2 IS
  BEGIN
    RETURN 'Order #' || OrderID || ' - ' || CustomerName || ' (' || Status || ')';
  END;
END;
/

/* -----------------------------------------------------------------------------
   DEMO QUERY USING OBJECT TYPE
   --------------------------------------------------------------------------- */
-- Returns a "table" (result set) of OrderSummaryType objects
SELECT
  OrderSummaryType(o.ORDER_ID, c.NAME, o.TOTAL_AMOUNT, o.STATUS) AS ORDER_SUMMARY
FROM "ORDER" o
JOIN CUSTOMER c ON c.CUSTOMER_ID = o.CUSTOMER_ID
ORDER BY o.ORDER_ID;

/* -----------------------------------------------------------------------------
   PACKAGE: CafeteriaManager (SPEC)
   --------------------------------------------------------------------------- */
CREATE OR REPLACE PACKAGE CafeteriaManager AS
  /* Inserts a new order and its items, calculates totals with applicable discount.
     p_Items element format: '<ItemID>:<Quantity>' */
  PROCEDURE PlaceOrder(
    p_CustomerID IN NUMBER,
    p_EmployeeID IN NUMBER,
    p_Items      IN SYS.ODCIVARCHAR2LIST
  );

  /* Records or updates payment and updates order status accordingly */
  PROCEDURE ProcessPayment(
    p_OrderID IN NUMBER,
    p_Amount  IN NUMBER,
    p_Method  IN VARCHAR2
  );

  /* Returns lifetime completed spending for a customer */
  FUNCTION GetCustomerTotal(p_CustomerID IN NUMBER) RETURN NUMBER;

  /* Returns the average feedback rating for an item */
  FUNCTION GetAverageRating(p_ItemID IN NUMBER) RETURN NUMBER;
END CafeteriaManager;
/

/* -----------------------------------------------------------------------------
   PACKAGE: CafeteriaManager (BODY)
   --------------------------------------------------------------------------- */
CREATE OR REPLACE PACKAGE BODY CafeteriaManager AS

  FUNCTION parse_item_id(p_token VARCHAR2) RETURN NUMBER IS
  BEGIN
    RETURN TO_NUMBER(REGEXP_SUBSTR(p_token, '^\s*([0-9]+)\s*:', 1, 1, NULL, 1));
  EXCEPTION
    WHEN OTHERS THEN
      RAISE_APPLICATION_ERROR(-20001, 'Invalid item token "'||p_token||'". Expected "<ItemID>:<Qty>".');
  END;

  FUNCTION parse_qty(p_token VARCHAR2) RETURN NUMBER IS
  BEGIN
    RETURN TO_NUMBER(REGEXP_SUBSTR(p_token, ':\s*([0-9]+)\s*$', 1, 1, NULL, 1));
  EXCEPTION
    WHEN OTHERS THEN
      RAISE_APPLICATION_ERROR(-20002, 'Invalid quantity token "'||p_token||'". Expected "<ItemID>:<Qty>".');
  END;

  FUNCTION get_discount_percent(p_customer_id NUMBER, p_order_date DATE) RETURN NUMBER IS
    v_type CUSTOMER.CUSTOMER_TYPE%TYPE;
    v_pct  DISCOUNT.DISCOUNT_PERCENT%TYPE;
  BEGIN
    SELECT CUSTOMER_TYPE INTO v_type FROM CUSTOMER WHERE CUSTOMER_ID = p_customer_id;

    SELECT NVL(MAX(DISCOUNT_PERCENT),0)
      INTO v_pct
      FROM DISCOUNT
     WHERE CUSTOMER_TYPE = v_type
       AND TRUNC(p_order_date) BETWEEN VALID_FROM AND VALID_TO;

    RETURN NVL(v_pct,0);
  EXCEPTION
    WHEN NO_DATA_FOUND THEN
      RETURN 0;
  END;

  PROCEDURE PlaceOrder(
    p_CustomerID IN NUMBER,
    p_EmployeeID IN NUMBER,
    p_Items      IN SYS.ODCIVARCHAR2LIST
  ) IS
    v_order_id     NUMBER;
    v_total        NUMBER := 0;
    v_pct          NUMBER := 0;
    v_order_date   DATE := TRUNC(SYSDATE);
    v_order_time   VARCHAR2(5) := TO_CHAR(SYSDATE,'HH24:MI');
    v_item_id      NUMBER;
    v_qty          NUMBER;
    v_unit_price   NUMBER;
    v_item_avail   CHAR(1);
  BEGIN
    IF p_Items IS NULL OR p_Items.COUNT = 0 THEN
      RAISE_APPLICATION_ERROR(-20003, 'Order must contain at least one item.');
    END IF;

    v_order_id := SEQ_ORDER.NEXTVAL;

    INSERT INTO "ORDER"(ORDER_ID, CUSTOMER_ID, EMPLOYEE_ID, ORDER_DATE, ORDER_TIME, TOTAL_AMOUNT, STATUS, PAYMENT_METHOD)
    VALUES (v_order_id, p_CustomerID, p_EmployeeID, v_order_date, v_order_time, 0, 'Pending', NULL);

    FOR i IN 1 .. p_Items.COUNT LOOP
      v_item_id := parse_item_id(p_Items(i));
      v_qty     := parse_qty(p_Items(i));

      IF v_qty <= 0 THEN
        RAISE_APPLICATION_ERROR(-20004, 'Quantity must be > 0 for token "'||p_Items(i)||'".');
      END IF;

      SELECT PRICE, IS_AVAILABLE
        INTO v_unit_price, v_item_avail
        FROM MENU_ITEM
       WHERE ITEM_ID = v_item_id;

      IF v_item_avail <> 'Y' THEN
        RAISE_APPLICATION_ERROR(-20005, 'Menu item '||v_item_id||' is not available.');
      END IF;

      INSERT INTO ORDER_ITEM(ORDER_ITEM_ID, ORDER_ID, ITEM_ID, QUANTITY, UNIT_PRICE, SUBTOTAL)
      VALUES (SEQ_ORDER_ITEM.NEXTVAL, v_order_id, v_item_id, v_qty, v_unit_price, ROUND(v_qty * v_unit_price, 2));

      v_total := v_total + ROUND(v_qty * v_unit_price, 2);
    END LOOP;

    v_pct := get_discount_percent(p_CustomerID, v_order_date);
    v_total := ROUND(v_total * (1 - v_pct/100), 2);

    UPDATE "ORDER"
       SET TOTAL_AMOUNT = v_total
     WHERE ORDER_ID = v_order_id;

    -- Ensure a payment row exists in Pending state (cashier can later complete it)
    INSERT INTO PAYMENT(PAYMENT_ID, ORDER_ID, AMOUNT_PAID, PAYMENT_DATE, PAYMENT_STATUS)
    VALUES (SEQ_PAYMENT.NEXTVAL, v_order_id, 0, SYSDATE, 'Pending');

  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      RAISE;
  END PlaceOrder;

  PROCEDURE ProcessPayment(
    p_OrderID IN NUMBER,
    p_Amount  IN NUMBER,
    p_Method  IN VARCHAR2
  ) IS
    v_total   NUMBER;
    v_status  VARCHAR2(20);
    v_exists  NUMBER;
  BEGIN
    IF p_Amount < 0 THEN
      RAISE_APPLICATION_ERROR(-20006, 'Payment amount cannot be negative.');
    END IF;

    IF p_Method NOT IN ('Cash','Card','Wallet') THEN
      RAISE_APPLICATION_ERROR(-20007, 'Invalid payment method. Use Cash/Card/Wallet.');
    END IF;

    SELECT TOTAL_AMOUNT, STATUS
      INTO v_total, v_status
      FROM "ORDER"
     WHERE ORDER_ID = p_OrderID
       FOR UPDATE;

    IF v_status = 'Cancelled' THEN
      RAISE_APPLICATION_ERROR(-20008, 'Cannot process payment for a cancelled order.');
    END IF;

    SELECT COUNT(*) INTO v_exists FROM PAYMENT WHERE ORDER_ID = p_OrderID;

    IF v_exists = 0 THEN
      INSERT INTO PAYMENT(PAYMENT_ID, ORDER_ID, AMOUNT_PAID, PAYMENT_DATE, PAYMENT_STATUS)
      VALUES (SEQ_PAYMENT.NEXTVAL, p_OrderID, p_Amount, SYSDATE,
              CASE WHEN p_Amount >= v_total THEN 'Paid' ELSE 'Pending' END);
    ELSE
      UPDATE PAYMENT
         SET AMOUNT_PAID = p_Amount,
             PAYMENT_DATE = SYSDATE,
             PAYMENT_STATUS = CASE WHEN p_Amount >= v_total THEN 'Paid' ELSE 'Pending' END
       WHERE ORDER_ID = p_OrderID;
    END IF;

    UPDATE "ORDER"
       SET PAYMENT_METHOD = p_Method,
           STATUS = CASE WHEN p_Amount >= v_total THEN 'Completed' ELSE 'Pending' END
     WHERE ORDER_ID = p_OrderID;

    COMMIT;
  EXCEPTION
    WHEN OTHERS THEN
      ROLLBACK;
      RAISE;
  END ProcessPayment;

  FUNCTION GetCustomerTotal(p_CustomerID IN NUMBER) RETURN NUMBER IS
    v_total NUMBER;
  BEGIN
    SELECT NVL(SUM(TOTAL_AMOUNT),0)
      INTO v_total
      FROM "ORDER"
     WHERE CUSTOMER_ID = p_CustomerID
       AND STATUS = 'Completed';
    RETURN v_total;
  END GetCustomerTotal;

  FUNCTION GetAverageRating(p_ItemID IN NUMBER) RETURN NUMBER IS
    v_avg NUMBER;
  BEGIN
    SELECT ROUND(NVL(AVG(f.RATING),0),2)
      INTO v_avg
      FROM ORDER_ITEM oi
      JOIN FEEDBACK f
        ON f.ORDER_ID = oi.ORDER_ID
     WHERE oi.ITEM_ID = p_ItemID;
    RETURN v_avg;
  END GetAverageRating;

END CafeteriaManager;
/

/* -----------------------------------------------------------------------------
   CURSORS (Explicit) — demo blocks
   --------------------------------------------------------------------------- */

/* Cursor 1: Loop through all pending orders and print OrderID, CustomerName, TotalAmount */
DECLARE
  CURSOR cur_pending IS
    SELECT o.ORDER_ID, c.NAME AS CUSTOMER_NAME, o.TOTAL_AMOUNT
      FROM "ORDER" o
      JOIN CUSTOMER c ON c.CUSTOMER_ID = o.CUSTOMER_ID
     WHERE o.STATUS = 'Pending'
     ORDER BY o.ORDER_ID;
BEGIN
  DBMS_OUTPUT.PUT_LINE('--- Pending Orders ---');
  FOR r IN cur_pending LOOP
    DBMS_OUTPUT.PUT_LINE('OrderID='||r.ORDER_ID||', Customer='||r.CUSTOMER_NAME||', Total='||r.TOTAL_AMOUNT);
  END LOOP;
END;
/

/* Cursor 2: List all low-stock inventory items with current quantity */
DECLARE
  CURSOR cur_low IS
    SELECT INVENTORY_ID, ITEM_NAME, UNIT, QUANTITY_IN_STOCK, REORDER_LEVEL
      FROM INVENTORY
     WHERE QUANTITY_IN_STOCK < REORDER_LEVEL
     ORDER BY ITEM_NAME;
BEGIN
  DBMS_OUTPUT.PUT_LINE('--- Low Stock Items ---');
  FOR r IN cur_low LOOP
    DBMS_OUTPUT.PUT_LINE(r.ITEM_NAME||' ('||r.UNIT||') qty='||r.QUANTITY_IN_STOCK||' reorder='||r.REORDER_LEVEL);
  END LOOP;
END;
/

/* -----------------------------------------------------------------------------
   TRIGGERS
   --------------------------------------------------------------------------- */

/* Trigger 1: BEFORE INSERT on "ORDER" — auto-generate OrderID using sequence if null */
CREATE OR REPLACE TRIGGER TRG_ORDER_BI
BEFORE INSERT ON "ORDER"
FOR EACH ROW
BEGIN
  IF :NEW.ORDER_ID IS NULL THEN
    :NEW.ORDER_ID := SEQ_ORDER.NEXTVAL;
  END IF;
END;
/

/* Trigger 2: AFTER INSERT on ORDER_ITEM — deduct ingredient quantities from INVENTORY */
CREATE OR REPLACE TRIGGER TRG_ORDERITEM_AI_INV
AFTER INSERT ON ORDER_ITEM
FOR EACH ROW
DECLARE
  v_needed NUMBER(12,3);
  v_new_qty NUMBER(12,3);
BEGIN
  -- For each ingredient required by the ordered menu item, reduce stock
  FOR r IN (
    SELECT INVENTORY_ID, QUANTITY_REQUIRED
      FROM INGREDIENT_USAGE
     WHERE ITEM_ID = :NEW.ITEM_ID
  ) LOOP
    v_needed := r.QUANTITY_REQUIRED * :NEW.QUANTITY;

    UPDATE INVENTORY
       SET QUANTITY_IN_STOCK = QUANTITY_IN_STOCK - v_needed
     WHERE INVENTORY_ID = r.INVENTORY_ID
     RETURNING QUANTITY_IN_STOCK INTO v_new_qty;

    IF v_new_qty < 0 THEN
      RAISE_APPLICATION_ERROR(-20020,
        'Insufficient inventory for INVENTORY_ID='||r.INVENTORY_ID||' after deducting '||v_needed);
    END IF;
  END LOOP;
END;
/

/* Trigger 3: AFTER INSERT on FEEDBACK — update denormalized AVERAGE_RATING on MENU_ITEM
   Only items included in the feedback's order are recalculated.
*/
CREATE OR REPLACE TRIGGER TRG_FEEDBACK_AI_AVGR
AFTER INSERT ON FEEDBACK
FOR EACH ROW
BEGIN
  FOR r IN (
    SELECT DISTINCT oi.ITEM_ID
      FROM ORDER_ITEM oi
     WHERE oi.ORDER_ID = :NEW.ORDER_ID
  ) LOOP
    UPDATE MENU_ITEM mi
       SET mi.AVERAGE_RATING = (
         SELECT ROUND(NVL(AVG(f.RATING),0),2)
           FROM ORDER_ITEM oi2
           JOIN FEEDBACK f ON f.ORDER_ID = oi2.ORDER_ID
          WHERE oi2.ITEM_ID = r.ITEM_ID
       )
     WHERE mi.ITEM_ID = r.ITEM_ID;
  END LOOP;
END;
/

/* Trigger 4: BEFORE DELETE on "ORDER" — prevent deleting completed orders */
CREATE OR REPLACE TRIGGER TRG_ORDER_BD_PROTECT
BEFORE DELETE ON "ORDER"
FOR EACH ROW
BEGIN
  IF :OLD.STATUS = 'Completed' THEN
    RAISE_APPLICATION_ERROR(-20030, 'Completed orders cannot be deleted for audit purposes.');
  END IF;
END;
/

