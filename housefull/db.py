import os

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from housefull.config import DATABASE_URL

pool = ConnectionPool(
    DATABASE_URL,
    min_size=1,
    max_size=int(os.environ.get("DB_POOL_SIZE", "10")),
    open=False,
    kwargs={"row_factory": dict_row},
)
