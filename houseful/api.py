from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from houseful.auth import (
    admin_user,
    clear_session,
    current_user,
    hash_password,
    set_session,
    verify_password,
)
from houseful.db import pool
from houseful.limits import check_limits, clear_attempts, client_ip
from houseful.messaging import BookingPublisher, get_publisher


@asynccontextmanager
async def lifespan(_: FastAPI):
    pool.open(wait=True)
    yield
    pool.close()


app = FastAPI(title="Houseful", lifespan=lifespan)


class Credentials(BaseModel):
    email: str = Field(pattern=r"^[^@\s]+@[^@\s]+$", max_length=254)
    password: str = Field(min_length=8, max_length=128)


class EventIn(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    starts_at: datetime
    seats: int = Field(gt=0, le=10000)


class BookingIn(BaseModel):
    seat_label: str


@app.get("/healthz")
def healthz():
    with pool.connection() as conn:
        conn.execute("SELECT 1")
    return {"status": "ok"}


@app.post("/auth/register", status_code=201)
def register(body: Credentials, request: Request, response: Response):
    check_limits(client_ip(request))
    password_hash = hash_password(body.password)
    with pool.connection() as conn:
        user = conn.execute(
            """
            INSERT INTO users (email, password_hash) VALUES (%s, %s)
            ON CONFLICT (email) DO NOTHING
            RETURNING id, email, is_admin
            """,
            (body.email.lower(), password_hash),
        ).fetchone()
    if user is None:
        raise HTTPException(409, "email already registered")
    set_session(response, user["id"])
    return user


@app.post("/auth/login")
def login(body: Credentials, request: Request, response: Response):
    email = body.email.lower()
    attempt_id = check_limits(client_ip(request), email)
    with pool.connection() as conn:
        user = conn.execute(
            "SELECT id, email, is_admin, password_hash FROM users WHERE email = %s",
            (email,),
        ).fetchone()
    if not verify_password(user["password_hash"] if user else None, body.password):
        raise HTTPException(401, "wrong email or password")
    clear_attempts(attempt_id, email)
    set_session(response, user["id"])
    return {key: user[key] for key in ("id", "email", "is_admin")}


@app.post("/auth/logout", status_code=204)
def logout(response: Response):
    clear_session(response)


@app.get("/auth/me")
def me(user: dict = Depends(current_user)):
    return user


@app.get("/events")
def list_events():
    with pool.connection() as conn:
        return conn.execute(
            """
            SELECT e.id, e.name, e.starts_at,
                   count(s.id) AS total_seats,
                   count(s.id) FILTER (WHERE s.status = 'available') AS available_seats
            FROM events e LEFT JOIN seats s ON s.event_id = e.id
            GROUP BY e.id
            ORDER BY e.starts_at
            """
        ).fetchall()


@app.post("/events", status_code=201)
def create_event(body: EventIn, _: dict = Depends(admin_user)):
    with pool.connection() as conn:
        event = conn.execute(
            "INSERT INTO events (name, starts_at) VALUES (%s, %s) RETURNING id",
            (body.name, body.starts_at),
        ).fetchone()
        conn.execute(
            """
            INSERT INTO seats (event_id, label)
            SELECT %s, 'S' || n FROM generate_series(1, %s) AS n
            """,
            (event["id"], body.seats),
        )
    return {"id": event["id"], "seats": body.seats}


@app.get("/events/{event_id}/seats")
def list_seats(event_id: int):
    with pool.connection() as conn:
        event = conn.execute(
            "SELECT id, name, starts_at FROM events WHERE id = %s", (event_id,)
        ).fetchone()
        if event is None:
            raise HTTPException(404, "event not found")
        seats = conn.execute(
            "SELECT label, status FROM seats WHERE event_id = %s ORDER BY id",
            (event_id,),
        ).fetchall()
    return {
        **event,
        "seats": seats,
        "available": [s["label"] for s in seats if s["status"] == "available"],
    }


@app.post("/events/{event_id}/bookings", status_code=202)
def create_booking(
    event_id: int,
    body: BookingIn,
    user: dict = Depends(current_user),
    publisher: BookingPublisher = Depends(get_publisher),
):
    with pool.connection() as conn:
        # The WHERE clause makes this atomic: only one concurrent request can
        # move a seat out of 'available'.
        seat = conn.execute(
            """
            UPDATE seats SET status = 'held'
            WHERE event_id = %s AND label = %s AND status = 'available'
            RETURNING id
            """,
            (event_id, body.seat_label),
        ).fetchone()
        if seat is None:
            raise HTTPException(409, "seat is not available")
        booking = conn.execute(
            """
            INSERT INTO bookings (seat_id, user_id, email) VALUES (%s, %s, %s)
            RETURNING id, status
            """,
            (seat["id"], user["id"], user["email"]),
        ).fetchone()
        # Publish before commit: if this fails the seat hold rolls back. A
        # message can arrive early, so the worker retries until the row exists.
        publisher.publish(booking["id"])
    return booking


BOOKING_COLUMNS = """
    b.id, b.status, b.email, b.confirmed_at, b.user_id,
    s.label AS seat_label, e.id AS event_id, e.name AS event_name, e.starts_at
"""
BOOKING_JOINS = """
    FROM bookings b
    JOIN seats s ON s.id = b.seat_id
    JOIN events e ON e.id = s.event_id
"""


@app.get("/me/bookings")
def my_bookings(user: dict = Depends(current_user)):
    with pool.connection() as conn:
        return conn.execute(
            f"""
            SELECT {BOOKING_COLUMNS} {BOOKING_JOINS}
            WHERE b.user_id = %s ORDER BY b.id DESC
            """,
            (user["id"],),
        ).fetchall()


@app.get("/bookings/{booking_id}")
def get_booking(booking_id: int, user: dict = Depends(current_user)):
    with pool.connection() as conn:
        booking = conn.execute(
            f"SELECT {BOOKING_COLUMNS} {BOOKING_JOINS} WHERE b.id = %s",
            (booking_id,),
        ).fetchone()
    # 404 rather than 403, so ids can't be probed for other people's bookings.
    if booking is None or (booking["user_id"] != user["id"] and not user["is_admin"]):
        raise HTTPException(404, "booking not found")
    return booking


# Must stay last: it serves everything the routes above don't match.
app.mount(
    "/",
    StaticFiles(directory=Path(__file__).parent / "static", html=True),
    name="ui",
)
