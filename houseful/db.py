from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

from houseful.config import DATABASE_URL

pool = ConnectionPool(
    DATABASE_URL,
    min_size=1,
    max_size=10,
    open=False,
    kwargs={"row_factory": dict_row},
)
