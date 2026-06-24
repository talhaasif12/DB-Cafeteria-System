import oracledb

def create_pool() -> oracledb.ConnectionPool:
    return oracledb.create_pool(
        user="cafeteria_admin",
        password="cafe1234",
        dsn="localhost:1521/XEPDB1",
        min=1,
        max=4,
        increment=1,
        timeout=60,
        wait_timeout=30,
        ping_interval=60,
    )

POOL = create_pool()

def fetchall(sql: str, params: dict | None = None) -> list[dict]:
    with POOL.acquire() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params or {})
            cols = [d[0].lower() for d in cur.description]
            return [dict(zip(cols, row)) for row in cur.fetchall()]

def execute(sql: str, params: dict | None = None) -> None:
    with POOL.acquire() as conn:
        with conn.cursor() as cur:
            cur.execute(sql, params or {})
        conn.commit()