import base64
import json
import uuid
from concurrent.futures import ThreadPoolExecutor

import jwt
import pytest
from fastapi.testclient import TestClient

from housefull.api import app as api_app
from housefull.auth import COOKIE_NAME
from housefull.db import pool
from housefull.limits import EMAIL_LIMIT, IP_LIMIT
from housefull.messaging import get_publisher
from housefull.worker import app as worker_app
from scripts.expire_holds import expire_holds

PASSWORD = "correct-horse"
EVENT = {"name": "Show", "venue": "Town Hall", "starts_at": "2099-12-01T19:00:00Z", "price_inr": 500}


class FakePublisher:
    def __init__(self):
        self.ids = []
        self.fail = False

    def publish(self, booking_id):
        if self.fail:
            raise RuntimeError("pubsub down")
        self.ids.append(booking_id)


@pytest.fixture(scope="session", autouse=True)
def db_pool():
    pool.open(wait=True)
    yield
    pool.close()


@pytest.fixture(autouse=True)
def publisher():
    fake = FakePublisher()
    api_app.dependency_overrides[get_publisher] = lambda: fake
    yield fake
    api_app.dependency_overrides.clear()


def anonymous():
    # A unique address per client, so the suite doesn't hit the IP limit.
    return TestClient(
        api_app,
        raise_server_exceptions=False,
        headers={"x-client-ip": uuid.uuid4().hex},
    )


def new_user():
    client = anonymous()
    email = f"{uuid.uuid4().hex}@example.com"
    res = client.post("/auth/register", json={"email": email, "password": PASSWORD})
    assert res.status_code == 201
    client.email = email
    return client


@pytest.fixture
def user():
    return new_user()


@pytest.fixture
def admin():
    client = new_user()
    with pool.connection() as conn:
        conn.execute("UPDATE users SET is_admin = true WHERE email = %s", (client.email,))
    return client


def make_event(admin, seats=3):
    res = admin.post(
        "/events",
        json={**EVENT, "seats": seats},
    )
    assert res.status_code == 201
    return res.json()["id"]


def book(client, event_id, *seats):
    return client.post(f"/events/{event_id}/bookings", json={"seat_labels": list(seats or ["S1"])})


def start_event(event_id):
    with pool.connection() as conn:
        conn.execute("UPDATE events SET starts_at = now() - interval '1 hour' WHERE id = %s", (event_id,))


def push(client, booking_id):
    data = base64.b64encode(json.dumps({"booking_id": booking_id}).encode()).decode()
    return client.post("/pubsub/push", json={"message": {"data": data}})


def test_register_login_and_logout():
    client = new_user()
    assert client.get("/auth/me").json()["email"] == client.email
    assert "password_hash" not in client.get("/auth/me").json()
    client.post("/auth/logout")
    client.cookies.clear()
    assert client.get("/auth/me").status_code == 401
    res = client.post("/auth/login", json={"email": client.email.upper(), "password": PASSWORD})
    assert res.status_code == 200
    assert "password_hash" not in res.json()
    assert client.get("/auth/me").status_code == 200


def test_session_cookie_is_http_only():
    client = anonymous()
    res = client.post(
        "/auth/register",
        json={"email": f"{uuid.uuid4().hex}@example.com", "password": PASSWORD},
    )
    assert "httponly" in res.headers["set-cookie"].lower()
    assert "samesite=lax" in res.headers["set-cookie"].lower()


def test_wrong_password_and_unknown_email_look_the_same(user):
    wrong = anonymous().post(
        "/auth/login", json={"email": user.email, "password": "wrong-password"}
    )
    unknown = anonymous().post(
        "/auth/login", json={"email": "nobody@example.com", "password": PASSWORD}
    )
    assert wrong.status_code == unknown.status_code == 401
    assert wrong.json() == unknown.json()


def test_duplicate_email_and_short_password_are_rejected(user):
    res = anonymous().post("/auth/register", json={"email": user.email, "password": PASSWORD})
    assert res.status_code == 409
    res = anonymous().post("/auth/register", json={"email": "x@example.com", "password": "short"})
    assert res.status_code == 422


def test_forged_and_expired_tokens_are_rejected(user):
    user_id = user.get("/auth/me").json()["id"]
    forged = jwt.encode({"sub": str(user_id), "exp": 9999999999}, "x" * 40, algorithm="HS256")
    expired = jwt.encode(
        {"sub": str(user_id), "exp": 1}, "test-only-secret-at-least-32-bytes-long", algorithm="HS256"
    )
    for token in (forged, expired, "garbage"):
        client = anonymous()
        client.cookies.set(COOKIE_NAME, token)
        assert client.get("/auth/me").status_code == 401


def test_only_admins_create_events(user, admin):
    body = {**EVENT, "seats": 1}
    assert anonymous().post("/events", json=body).status_code == 401
    assert user.post("/events", json=body).status_code == 403
    assert admin.post("/events", json=body).status_code == 201


def test_browsing_is_public_but_booking_needs_login(admin):
    event_id = make_event(admin)
    client = anonymous()
    assert client.get("/events").status_code == 200
    assert client.get(f"/events/{event_id}/seats").status_code == 200
    assert book(client, event_id).status_code == 401


def test_booking_removes_seat_from_available(user, admin):
    event_id = make_event(admin)
    assert book(user, event_id).status_code == 202
    assert user.get(f"/events/{event_id}/seats").json()["available"] == ["S2", "S3"]


def test_seat_cannot_be_booked_twice(user, admin):
    event_id = make_event(admin)
    assert book(user, event_id).status_code == 202
    assert book(new_user(), event_id).status_code == 409


def test_concurrent_requests_give_seat_to_one_person(admin, publisher):
    event_id = make_event(admin, seats=1)
    users = [new_user() for _ in range(25)]
    with ThreadPoolExecutor(max_workers=25) as executor:
        results = list(executor.map(lambda u: book(u, event_id).status_code, users))
    assert results.count(202) == 1
    assert results.count(409) == 24
    assert len(publisher.ids) == 1


def test_seat_is_released_when_publish_fails(user, admin, publisher):
    event_id = make_event(admin)
    publisher.fail = True
    assert book(user, event_id).status_code == 500
    assert "S1" in user.get(f"/events/{event_id}/seats").json()["available"]


def test_bookings_are_private(user, admin):
    event_id = make_event(admin)
    booking_id = book(user, event_id).json()["id"]
    assert [b["id"] for b in user.get("/me/bookings").json()] == [booking_id]
    other = new_user()
    assert other.get("/me/bookings").json() == []
    assert other.get(f"/bookings/{booking_id}").status_code == 404
    assert anonymous().get(f"/bookings/{booking_id}").status_code == 401
    assert admin.get(f"/bookings/{booking_id}").status_code == 200


def test_worker_confirms_booking_and_ignores_repeats(user, admin):
    event_id = make_event(admin)
    booking_id = book(user, event_id).json()["id"]
    worker = TestClient(worker_app)
    assert push(worker, booking_id).status_code == 204
    first = user.get(f"/bookings/{booking_id}").json()
    assert first["status"] == "confirmed"
    assert push(worker, booking_id).status_code == 204
    assert user.get(f"/bookings/{booking_id}").json() == first


def test_worker_retries_unknown_booking_and_rejects_bad_message():
    worker = TestClient(worker_app)
    assert push(worker, 999999999).status_code == 404
    assert worker.post("/pubsub/push", json={"message": {}}).status_code == 400


def test_ui_is_served():
    res = anonymous().get("/")
    assert res.status_code == 200
    assert "HOUSEFULL" in res.text


def age_booking(booking_id, minutes=60):
    with pool.connection() as conn:
        conn.execute(
            "UPDATE bookings SET created_at = now() - make_interval(mins => %s::int) WHERE id = %s",
            (minutes, booking_id),
        )


def run_expiry():
    with pool.connection() as conn:
        return expire_holds(conn, 15)


def test_old_pending_booking_releases_seat_for_someone_else(user, admin):
    event_id = make_event(admin)
    booking_id = book(user, event_id).json()["id"]
    age_booking(booking_id)
    assert run_expiry() == 1
    assert user.get(f"/bookings/{booking_id}").json()["status"] == "expired"
    assert book(new_user(), event_id).status_code == 202


def test_recent_and_confirmed_bookings_are_not_expired(user, admin):
    event_id = make_event(admin)
    recent = book(user, event_id, "S1").json()["id"]
    confirmed = book(user, event_id, "S2").json()["id"]
    assert push(TestClient(worker_app), confirmed).status_code == 204
    age_booking(confirmed)
    assert run_expiry() == 0
    assert user.get(f"/bookings/{recent}").json()["status"] == "pending"
    assert user.get(f"/bookings/{confirmed}").json()["status"] == "confirmed"


def test_late_message_does_not_revive_expired_booking(user, admin):
    event_id = make_event(admin)
    booking_id = book(user, event_id).json()["id"]
    age_booking(booking_id)
    run_expiry()
    assert push(TestClient(worker_app), booking_id).status_code == 204
    assert user.get(f"/bookings/{booking_id}").json()["status"] == "expired"
    assert "S1" in user.get(f"/events/{event_id}/seats").json()["available"]


def bad_login(client, email):
    return client.post("/auth/login", json={"email": email, "password": "wrong-password"})


def test_email_is_locked_after_too_many_failures(user):
    attacker = anonymous()
    for _ in range(EMAIL_LIMIT):
        assert bad_login(attacker, user.email).status_code == 401
    assert bad_login(attacker, user.email).status_code == 429
    res = attacker.post("/auth/login", json={"email": user.email, "password": PASSWORD})
    assert res.status_code == 429
    assert res.headers["retry-after"] == "900"


def test_successful_login_clears_failures(user):
    client = anonymous()
    for _ in range(3):
        for _ in range(EMAIL_LIMIT - 1):
            assert bad_login(client, user.email).status_code == 401
        res = client.post("/auth/login", json={"email": user.email, "password": PASSWORD})
        assert res.status_code == 200


def test_one_address_cannot_try_many_emails():
    attacker = anonymous()
    for _ in range(IP_LIMIT):
        assert bad_login(attacker, f"{uuid.uuid4().hex}@example.com").status_code == 401
    assert bad_login(attacker, f"{uuid.uuid4().hex}@example.com").status_code == 429


def test_unknown_email_is_limited_the_same_way():
    client = anonymous()
    email = f"{uuid.uuid4().hex}@example.com"
    for _ in range(EMAIL_LIMIT):
        assert bad_login(client, email).status_code == 401
    assert bad_login(client, email).status_code == 429


def test_forwarded_for_header_cannot_dodge_ip_limit():
    real = uuid.uuid4().hex
    for i in range(IP_LIMIT):
        client = TestClient(api_app, headers={"x-client-ip": real, "x-forwarded-for": f"fake{i}"})
        assert bad_login(client, f"{uuid.uuid4().hex}@example.com").status_code == 401
    client = TestClient(api_app, headers={"x-client-ip": real, "x-forwarded-for": "other"})
    assert bad_login(client, f"{uuid.uuid4().hex}@example.com").status_code == 429


def test_old_attempts_are_cleaned_up():
    with pool.connection() as conn:
        conn.execute(
            "INSERT INTO login_attempts (key, attempted_at) VALUES ('ip:old', now() - interval '2 hours')"
        )
    run_expiry()
    with pool.connection() as conn:
        row = conn.execute("SELECT count(*) AS total FROM login_attempts WHERE key = 'ip:old'").fetchone()
    assert row["total"] == 0


def test_multi_seat_booking_totals_price_and_confirms_every_seat(user, admin):
    event_id = make_event(admin, seats=4)
    booking = book(user, event_id, "S1", "S2", "S3").json()
    assert booking["total_inr"] == 1500
    assert booking["reference"].startswith("HF-")
    assert push(TestClient(worker_app), booking["id"]).status_code == 204
    seats = {s["label"]: s["status"] for s in user.get(f"/events/{event_id}/seats").json()["seats"]}
    assert seats == {"S1": "booked", "S2": "booked", "S3": "booked", "S4": "available"}
    assert user.get(f"/bookings/{booking['id']}").json()["seat_labels"] == ["S1", "S2", "S3"]


def test_booking_is_all_or_nothing(user, admin):
    event_id = make_event(admin)
    assert book(user, event_id, "S2").status_code == 202
    assert book(new_user(), event_id, "S1", "S2").status_code == 409
    assert user.get(f"/events/{event_id}/seats").json()["available"] == ["S1", "S3"]


def test_booking_limits_are_enforced(user, admin):
    event_id = make_event(admin, seats=8)
    too_many = [f"S{n}" for n in range(1, 8)]
    assert book(user, event_id, *too_many).status_code == 422
    assert book(user, event_id, "S1", "S1").status_code == 422
    assert book(user, event_id, "S99").status_code == 409


def test_overlapping_multi_seat_bookings_never_deadlock_or_double_sell(admin):
    event_id = make_event(admin, seats=6)
    orders = [("S1", "S2", "S3"), ("S3", "S2", "S1"), ("S2", "S3", "S4"), ("S4", "S3", "S2")] * 5
    users = [new_user() for _ in orders]
    with ThreadPoolExecutor(max_workers=20) as executor:
        results = list(executor.map(lambda p: book(p[0], event_id, *p[1]).status_code, zip(users, orders)))
    assert set(results) <= {202, 409}
    assert 1 <= results.count(202) <= 2
    with pool.connection() as conn:
        total = conn.execute(
            "SELECT count(*) AS held FROM seats WHERE event_id = %s AND status = 'held'", (event_id,)
        ).fetchone()["held"]
    assert total == results.count(202) * 3


def test_past_events_cannot_be_booked_and_are_hidden(user, admin):
    event_id = make_event(admin)
    start_event(event_id)
    assert book(user, event_id).status_code == 409
    assert event_id not in [e["id"] for e in anonymous().get("/events").json()]


def test_search_matches_name_and_venue_and_treats_wildcards_literally(admin):
    tag = uuid.uuid4().hex
    res = admin.post("/events", json={**EVENT, "name": f"Rock {tag}", "seats": 1})
    event_id = res.json()["id"]
    client = anonymous()
    assert [e["id"] for e in client.get("/events", params={"q": tag.upper()}).json()] == [event_id]
    assert client.get("/events", params={"q": "nothing-matches-this"}).json() == []
    assert client.get("/events", params={"q": "%" + tag[::-1]}).json() == []


def test_cancel_frees_seats_for_someone_else(user, admin):
    event_id = make_event(admin)
    booking_id = book(user, event_id, "S1", "S2").json()["id"]
    assert push(TestClient(worker_app), booking_id).status_code == 204
    assert user.post(f"/bookings/{booking_id}/cancel").status_code == 200
    detail = user.get(f"/bookings/{booking_id}").json()
    assert detail["status"] == "cancelled"
    assert detail["seat_labels"] == ["S1", "S2"]
    assert book(new_user(), event_id, "S1", "S2").status_code == 202


def test_cancel_rules(user, admin):
    event_id = make_event(admin)
    booking_id = book(user, event_id).json()["id"]
    assert new_user().post(f"/bookings/{booking_id}/cancel").status_code == 404
    assert anonymous().post(f"/bookings/{booking_id}/cancel").status_code == 401
    assert user.post(f"/bookings/{booking_id}/cancel").status_code == 200
    assert user.post(f"/bookings/{booking_id}/cancel").status_code == 409
    second = book(user, event_id, "S2").json()["id"]
    start_event(event_id)
    assert user.post(f"/bookings/{second}/cancel").status_code == 409


def test_late_message_does_not_revive_cancelled_booking(user, admin):
    event_id = make_event(admin)
    booking_id = book(user, event_id).json()["id"]
    user.post(f"/bookings/{booking_id}/cancel")
    assert push(TestClient(worker_app), booking_id).status_code == 204
    assert user.get(f"/bookings/{booking_id}").json()["status"] == "cancelled"
    assert "S1" in user.get(f"/events/{event_id}/seats").json()["available"]


def test_cancel_and_confirm_race_leaves_consistent_state(user, admin):
    event_id = make_event(admin)
    worker = TestClient(worker_app)
    for label in ("S1", "S2", "S3"):
        booking_id = book(user, event_id, label).json()["id"]
        with ThreadPoolExecutor(max_workers=2) as executor:
            executor.submit(push, worker, booking_id)
            executor.submit(user.post, f"/bookings/{booking_id}/cancel")
        assert user.get(f"/bookings/{booking_id}").json()["status"] == "cancelled"
    assert len(user.get(f"/events/{event_id}/seats").json()["available"]) == 3


def test_sign_ups_close_at_the_user_limit(monkeypatch):
    monkeypatch.setattr("housefull.api.MAX_USERS", 0)
    res = anonymous().post(
        "/auth/register",
        json={"email": f"{uuid.uuid4().hex}@example.com", "password": PASSWORD},
    )
    assert res.status_code == 403
