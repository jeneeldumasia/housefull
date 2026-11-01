import base64
import json
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Response

from houseful.db import pool

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("houseful.worker")


@asynccontextmanager
async def lifespan(_: FastAPI):
    pool.open(wait=True)
    yield
    pool.close()


app = FastAPI(title="Houseful worker", lifespan=lifespan)


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.post("/pubsub/push", status_code=204)
def handle_push(envelope: dict):
    # Pub/Sub retries any non-2xx, then moves the message to the dead-letter topic.
    try:
        data = base64.b64decode(envelope["message"]["data"])
        booking_id = json.loads(data)["booking_id"]
    except (KeyError, TypeError, ValueError) as exc:
        raise HTTPException(400, "invalid message") from exc

    with pool.connection() as conn:
        booking = conn.execute(
            "SELECT status, seat_id, email FROM bookings WHERE id = %s FOR UPDATE",
            (booking_id,),
        ).fetchone()
        if booking is None:
            raise HTTPException(404, "booking not found yet")
        # Pub/Sub delivers at least once, so a repeat must do nothing.
        if booking["status"] == "pending":
            conn.execute(
                "UPDATE bookings SET status = 'confirmed', confirmed_at = now() WHERE id = %s",
                (booking_id,),
            )
            conn.execute(
                "UPDATE seats SET status = 'booked' WHERE id = %s",
                (booking["seat_id"],),
            )
            log.info("confirmation sent booking_id=%s", booking_id)
    return Response(status_code=204)
