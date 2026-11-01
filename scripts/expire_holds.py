"""Release seats whose booking was never confirmed. Runs on a schedule."""
import os

import psycopg

from houseful.config import DATABASE_URL

# Longer than Pub/Sub's retries, so a slow confirmation isn't cancelled.
HOLD_MINUTES = int(os.environ.get("HOLD_MINUTES", "15"))
ATTEMPT_RETENTION_HOURS = 1


def expire_holds(conn, minutes: int = HOLD_MINUTES) -> int:
    # SKIP LOCKED leaves alone any booking the worker is confirming right now.
    released = conn.execute(
        """
        WITH expired AS (
            UPDATE bookings SET status = 'expired'
            WHERE id IN (
                SELECT id FROM bookings
                WHERE status = 'pending'
                  AND created_at < now() - make_interval(mins => %s::int)
                FOR UPDATE SKIP LOCKED
            )
            RETURNING seat_id
        )
        UPDATE seats SET status = 'available'
        WHERE id IN (SELECT seat_id FROM expired)
        """,
        (minutes,),
    ).rowcount
    conn.execute(
        "DELETE FROM login_attempts WHERE attempted_at < now() - make_interval(hours => %s::int)",
        (ATTEMPT_RETENTION_HOURS,),
    )
    return released


def main() -> None:
    with psycopg.connect(DATABASE_URL) as conn:
        print(f"released {expire_holds(conn)} seats")


if __name__ == "__main__":
    main()
