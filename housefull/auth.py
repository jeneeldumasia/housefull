import os
from datetime import datetime, timedelta, timezone

import jwt
from argon2 import PasswordHasher
from argon2.exceptions import VerifyMismatchError
from fastapi import Cookie, Depends, HTTPException, Response

from housefull.db import pool

COOKIE_NAME = "housefull_session"
JWT_ALGORITHM = "HS256"
SESSION_HOURS = 12

JWT_SECRET = os.environ["JWT_SECRET"]
COOKIE_SECURE = os.environ.get("COOKIE_SECURE", "true").lower() != "false"

hasher = PasswordHasher()
# Checked when the email is unknown, so login takes the same time either way.
DUMMY_HASH = hasher.hash("not-a-real-password")


def hash_password(password: str) -> str:
    return hasher.hash(password)


def verify_password(password_hash: str | None, password: str) -> bool:
    try:
        hasher.verify(password_hash or DUMMY_HASH, password)
    except VerifyMismatchError:
        return False
    return password_hash is not None


def set_session(response: Response, user_id: int) -> None:
    token = jwt.encode(
        {
            "sub": str(user_id),
            "exp": datetime.now(timezone.utc) + timedelta(hours=SESSION_HOURS),
        },
        JWT_SECRET,
        algorithm=JWT_ALGORITHM,
    )
    response.set_cookie(
        COOKIE_NAME,
        token,
        max_age=SESSION_HOURS * 3600,
        httponly=True,
        secure=COOKIE_SECURE,
        samesite="lax",
    )


def clear_session(response: Response) -> None:
    response.delete_cookie(COOKIE_NAME)


def current_user(housefull_session: str | None = Cookie(default=None)) -> dict:
    if housefull_session is None:
        raise HTTPException(401, "log in first")
    try:
        claims = jwt.decode(housefull_session, JWT_SECRET, algorithms=[JWT_ALGORITHM])
    except jwt.InvalidTokenError as exc:
        raise HTTPException(401, "log in first") from exc
    with pool.connection() as conn:
        user = conn.execute(
            "SELECT id, email, is_admin FROM users WHERE id = %s",
            (int(claims["sub"]),),
        ).fetchone()
    if user is None:
        raise HTTPException(401, "log in first")
    return user


def admin_user(user: dict = Depends(current_user)) -> dict:
    if not user["is_admin"]:
        raise HTTPException(403, "admin only")
    return user
