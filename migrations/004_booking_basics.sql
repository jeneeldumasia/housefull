ALTER TABLE events
    ADD COLUMN venue       TEXT NOT NULL DEFAULT '',
    ADD COLUMN description TEXT NOT NULL DEFAULT '',
    ADD COLUMN price_inr   INTEGER NOT NULL DEFAULT 0 CHECK (price_inr >= 0);

-- 'active' keeps old seats on a booking's history while freeing them for sale.
CREATE TABLE booking_seats (
    booking_id BIGINT NOT NULL REFERENCES bookings (id) ON DELETE CASCADE,
    seat_id    BIGINT NOT NULL REFERENCES seats (id),
    active     BOOLEAN NOT NULL DEFAULT true,
    PRIMARY KEY (booking_id, seat_id)
);
CREATE UNIQUE INDEX booking_seats_one_active ON booking_seats (seat_id) WHERE active;

INSERT INTO booking_seats (booking_id, seat_id, active)
SELECT id, seat_id, status <> 'expired' FROM bookings;

ALTER TABLE bookings
    ADD COLUMN event_id     BIGINT REFERENCES events (id),
    ADD COLUMN reference    TEXT,
    ADD COLUMN total_inr    INTEGER NOT NULL DEFAULT 0,
    ADD COLUMN cancelled_at TIMESTAMPTZ;

UPDATE bookings b
SET event_id = s.event_id,
    reference = 'HF-' || upper(substr(md5(b.id::text || random()::text), 1, 8))
FROM seats s
WHERE s.id = b.seat_id;

ALTER TABLE bookings
    ALTER COLUMN event_id SET NOT NULL,
    ALTER COLUMN reference SET NOT NULL,
    ADD CONSTRAINT bookings_reference_key UNIQUE (reference),
    DROP COLUMN seat_id;

ALTER TABLE bookings DROP CONSTRAINT bookings_status_check;
ALTER TABLE bookings ADD CONSTRAINT bookings_status_check
    CHECK (status IN ('pending', 'confirmed', 'expired', 'cancelled'));

CREATE INDEX events_starts_at ON events (starts_at);
