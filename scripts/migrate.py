"""Apply migrations/*.sql in order, once each. Safe to run from several places."""
from pathlib import Path

import psycopg

from houseful.config import DATABASE_URL

MIGRATIONS = Path(__file__).resolve().parent.parent / "migrations"
LOCK_ID = 727274


def main() -> None:
    with psycopg.connect(DATABASE_URL) as conn:
        conn.execute("SELECT pg_advisory_xact_lock(%s)", (LOCK_ID,))
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                name       TEXT PRIMARY KEY,
                applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
            )
            """
        )
        applied = {r[0] for r in conn.execute("SELECT name FROM schema_migrations")}
        for path in sorted(MIGRATIONS.glob("*.sql")):
            if path.name in applied:
                continue
            print(f"applying {path.name}")
            conn.execute(path.read_text())
            conn.execute("INSERT INTO schema_migrations (name) VALUES (%s)", (path.name,))


if __name__ == "__main__":
    main()
