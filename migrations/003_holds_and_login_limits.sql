ALTER TABLE bookings DROP CONSTRAINT bookings_status_check;
ALTER TABLE bookings ADD CONSTRAINT bookings_status_check
    CHECK (status IN ('pending', 'confirmed', 'expired'));

-- An expired booking must not stop the seat being booked again.
DROP INDEX bookings_one_per_seat;
CREATE UNIQUE INDEX bookings_one_per_seat ON bookings (seat_id) WHERE status <> 'expired';
CREATE INDEX bookings_pending_created_at ON bookings (created_at) WHERE status = 'pending';

CREATE TABLE login_attempts (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    key          TEXT NOT NULL,
    attempted_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX login_attempts_key_time ON login_attempts (key, attempted_at);
