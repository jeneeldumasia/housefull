from fastapi import HTTPException, Request

from houseful.db import pool

EMAIL_LIMIT = 5
IP_LIMIT = 30
WINDOW_MINUTES = 15


def client_ip(request: Request) -> str:
    # Google's front end appends the real address last; anything before it is
    # supplied by the caller and can't be trusted.
    forwarded = request.headers.get("x-forwarded-for", "").split(",")[-1].strip()
    return forwarded or (request.client.host if request.client else "unknown")


def _record(conn, key: str) -> tuple[int, int]:
    attempt = conn.execute(
        "INSERT INTO login_attempts (key) VALUES (%s) RETURNING id", (key,)
    ).fetchone()
    recent = conn.execute(
        """
        SELECT count(*) AS total FROM login_attempts
        WHERE key = %s AND attempted_at > now() - make_interval(mins => %s::int)
        """,
        (key, WINDOW_MINUTES),
    ).fetchone()
    return attempt["id"], recent["total"]


def check_limits(ip: str, email: str | None = None) -> int:
    """Count this attempt, then refuse it if a limit is passed.

    Counting first means parallel guesses can't all slip past the check. This
    commits on its own so the count survives the request failing.
    """
    with pool.connection() as conn:
        attempt_id, ip_count = _record(conn, f"ip:{ip}")
        email_count = _record(conn, f"email:{email}")[1] if email else 0
    if ip_count > IP_LIMIT or email_count > EMAIL_LIMIT:
        raise HTTPException(
            429,
            "too many attempts, try again later",
            headers={"Retry-After": str(WINDOW_MINUTES * 60)},
        )
    return attempt_id


def clear_attempts(attempt_id: int, email: str) -> None:
    with pool.connection() as conn:
        conn.execute(
            "DELETE FROM login_attempts WHERE id = %s OR key = %s",
            (attempt_id, f"email:{email}"),
        )
