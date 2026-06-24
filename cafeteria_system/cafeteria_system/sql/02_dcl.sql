/* =============================================================================
   Cafeteria Management System (Oracle 19c)
   File: 02_dcl.sql
   Purpose:
     - Create roles required by the application
     - Grant/revoke privileges exactly as requested

   Notes:
     - The table "ORDER" is quoted and must be referenced as "ORDER".
   ============================================================================ */

/* -----------------------------------------------------------------------------
   ROLES
   --------------------------------------------------------------------------- */
BEGIN
  EXECUTE IMMEDIATE 'CREATE ROLE cafeteria_viewer';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1921 THEN RAISE; END IF; -- ORA-01921: role name already exists
END;
/

BEGIN
  EXECUTE IMMEDIATE 'CREATE ROLE cafeteria_cashier';
EXCEPTION
  WHEN OTHERS THEN
    IF SQLCODE != -1921 THEN RAISE; END IF;
END;
/

/* -----------------------------------------------------------------------------
   GRANTS
   --------------------------------------------------------------------------- */
-- Viewer role: read-only access to key operational tables
GRANT SELECT ON "ORDER"   TO cafeteria_viewer;
GRANT SELECT ON MENU_ITEM TO cafeteria_viewer;
GRANT SELECT ON FEEDBACK  TO cafeteria_viewer;

-- Cashier role: allowed to record orders, order items, and payments
GRANT INSERT, UPDATE ON "ORDER"     TO cafeteria_cashier;
GRANT INSERT, UPDATE ON ORDER_ITEM  TO cafeteria_cashier;
GRANT INSERT, UPDATE ON PAYMENT     TO cafeteria_cashier;

/* -----------------------------------------------------------------------------
   REVOKES
   --------------------------------------------------------------------------- */
-- Explicitly revoke DROP (requested). Note: roles do not receive DROP on objects
-- unless granted system privileges; this ensures it is not present.
BEGIN
  EXECUTE IMMEDIATE 'REVOKE DROP ANY TABLE FROM cafeteria_cashier';
EXCEPTION
  WHEN OTHERS THEN
    -- If the role never had the privilege, Oracle raises an error; ignore it.
    -- (Common message: "system privileges not granted to 'CAFETERIA_CASHIER'")
    IF SQLCODE IN (-1952, -1927, -1031) THEN
      NULL;
    ELSE
      RAISE;
    END IF;
END;
/

/* -----------------------------------------------------------------------------
   END
   --------------------------------------------------------------------------- */

