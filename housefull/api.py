import secrets
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request, Response
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from housefull.auth import (
    admin_user,
    clear_session,
    current_user,
    hash_password,
    set_session,
    verify_password,
)
from housefull.db import pool
from housefull.limits import check_limits, clear_attempts, client_ip
from housefull.messaging import BookingPublisher, get_publisher


@asynccontextmanager
async def lifespan(_: FastAPI):
    pool.open(wait=True)
    yield
    pool.close()


app = FastAPI(title="Housefull", lifespan=lifespan)


class Credentials(BaseModel):
    email: str = Field(pattern=r"^[^@\s]+@[^@\s]+$", max_length=254)
    password: str = Field(min_length=8, max_length=128)


MAX_SEATS_PER_BOOKING = 6
REFERENCE_ALPHABET = "23456789ABCDEFGHJKLMNPQRSTUVWXYZ"


class EventIn(BaseModel):
    name: str = Field(min_length=1, max_length=200)
    venue: str = Field(min_length=1, max_length=200)
    description: str = Field(default="", max_length=2000)
    starts_at: datetime
    seats: int = Field(gt=0, le=10000)
    price_inr: int = Field(ge=0, le=1000000)


class BookingIn(BaseModel):
    seat_labels: list[str] = Field(min_length=1, max_length=MAX_SEATS_PER_BOOKING)


def new_reference() -> str:
    return "HF-" + "".join(secrets.choice(REFERENCE_ALPHABET) for _ in range(8))


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
def list_events(q: str = ""):
    escaped = q.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    with pool.connection() as conn:
        return conn.execute(
            """
            SELECT e.id, e.name, e.venue, e.description, e.starts_at, e.price_inr,
                   count(s.id) AS total_seats,
                   count(s.id) FILTER (WHERE s.status = 'available') AS available_seats
            FROM events e LEFT JOIN seats s ON s.event_id = e.id
            WHERE e.starts_at > now() AND (e.name ILIKE %(q)s OR e.venue ILIKE %(q)s)
            GROUP BY e.id
            ORDER BY e.starts_at
            """,
            {"q": f"%{escaped}%"},
        ).fetchall()


@app.post("/events", status_code=201)
def create_event(body: EventIn, _: dict = Depends(admin_user)):
    with pool.connection() as conn:
        event = conn.execute(
            """
            INSERT INTO events (name, venue, description, starts_at, price_inr)
            VALUES (%s, %s, %s, %s, %s) RETURNING id
            """,
            (body.name, body.venue, body.description, body.starts_at, body.price_inr),
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
            """
            SELECT id, name, venue, description, starts_at, price_inr,
                   starts_at > now() AS bookable
            FROM events WHERE id = %s
            """,
            (event_id,),
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
    labels = sorted(set(body.seat_labels))
    if len(labels) != len(body.seat_labels):
        raise HTTPException(422, "seats must be different")
    with pool.connection() as conn:
        event = conn.execute(
            "SELECT price_inr, starts_at > now() AS bookable FROM events WHERE id = %s",
            (event_id,),
        ).fetchone()
        if event is None:
            raise HTTPException(404, "event not found")
        if not event["bookable"]:
            raise HTTPException(409, "this event has already started")
        # Locking in a fixed order stops two multi-seat bookings deadlocking.
        # Anything raised here rolls the whole booking back, so it's all or nothing.
        seats = conn.execute(
            """
            SELECT id FROM seats
            WHERE event_id = %s AND label = ANY(%s) AND status = 'available'
            ORDER BY id FOR UPDATE
            """,
            (event_id, labels),
        ).fetchall()
        if len(seats) != len(labels):
            raise HTTPException(409, "seat is not available")
        seat_ids = [seat["id"] for seat in seats]
        conn.execute("UPDATE seats SET status = 'held' WHERE id = ANY(%s)", (seat_ids,))
        booking = conn.execute(
            """
            INSERT INTO bookings (event_id, user_id, email, reference, total_inr)
            VALUES (%s, %s, %s, %s, %s)
            RETURNING id, reference, status, total_inr
            """,
            (event_id, user["id"], user["email"], new_reference(), event["price_inr"] * len(seats)),
        ).fetchone()
        conn.execute(
            """
            INSERT INTO booking_seats (booking_id, seat_id)
            SELECT %s, unnest(%s::bigint[])
            """,
            (booking["id"], seat_ids),
        )
        # Publish before commit: if this fails the seat hold rolls back. A
        # message can arrive early, so the worker retries until the row exists.
        publisher.publish(booking["id"])
    return booking


BOOKING_QUERY = """
    SELECT b.id, b.reference, b.status, b.email, b.total_inr, b.confirmed_at,
           b.cancelled_at, b.user_id, e.id AS event_id, e.name AS event_name,
           e.venue, e.starts_at, e.starts_at > now() AS cancellable,
           ARRAY(
               SELECT s.label
               FROM booking_seats bs JOIN seats s ON s.id = bs.seat_id
               WHERE bs.booking_id = b.id ORDER BY s.id
           ) AS seat_labels
    FROM bookings b JOIN events e ON e.id = b.event_id
"""


@app.get("/me/bookings")
def my_bookings(user: dict = Depends(current_user)):
    with pool.connection() as conn:
        return conn.execute(
            BOOKING_QUERY + "WHERE b.user_id = %s ORDER BY b.id DESC",
            (user["id"],),
        ).fetchall()


@app.get("/bookings/{booking_id}")
def get_booking(booking_id: int, user: dict = Depends(current_user)):
    with pool.connection() as conn:
        booking = conn.execute(BOOKING_QUERY + "WHERE b.id = %s", (booking_id,)).fetchone()
    # 404 rather than 403, so ids can't be probed for other people's bookings.
    if booking is None or (booking["user_id"] != user["id"] and not user["is_admin"]):
        raise HTTPException(404, "booking not found")
    return booking


@app.post("/bookings/{booking_id}/cancel")
def cancel_booking(booking_id: int, user: dict = Depends(current_user)):
    with pool.connection() as conn:
        booking = conn.execute(
            """
            SELECT b.status, b.user_id, e.starts_at > now() AS cancellable
            FROM bookings b JOIN events e ON e.id = b.event_id
            WHERE b.id = %s FOR UPDATE OF b
            """,
            (booking_id,),
        ).fetchone()
        if booking is None or booking["user_id"] != user["id"]:
            raise HTTPException(404, "booking not found")
        if booking["status"] not in ("pending", "confirmed"):
            raise HTTPException(409, "this booking is no longer active")
        if not booking["cancellable"]:
            raise HTTPException(409, "this event has already started")
        conn.execute(
            "UPDATE bookings SET status = 'cancelled', cancelled_at = now() WHERE id = %s",
            (booking_id,),
        )
        conn.execute(
            """
            WITH released AS (
                UPDATE booking_seats SET active = false
                WHERE booking_id = %s AND active
                RETURNING seat_id
            )
            UPDATE seats SET status = 'available'
            WHERE id IN (SELECT seat_id FROM released)
            """,
            (booking_id,),
        )
    return {"id": booking_id, "status": "cancelled"}


# Must stay last: it serves everything the routes above don't match.
app.mount(
    "/",
    StaticFiles(directory=Path(__file__).parent / "static", html=True),
    name="ui",
)
