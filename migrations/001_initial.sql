CREATE TABLE events (
    id         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name       TEXT NOT NULL,
    starts_at  TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE seats (
    id       BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    event_id BIGINT NOT NULL REFERENCES events (id) ON DELETE CASCADE,
    label    TEXT NOT NULL,
    status   TEXT NOT NULL DEFAULT 'available'
             CHECK (status IN ('available', 'held', 'booked')),
    UNIQUE (event_id, label)
);

CREATE TABLE bookings (
    id           BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    seat_id      BIGINT NOT NULL REFERENCES seats (id),
    email        TEXT NOT NULL,
    status       TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending', 'confirmed')),
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    confirmed_at TIMESTAMPTZ
);

-- Backstop for the conditional UPDATE in the API: one live booking per seat.
CREATE UNIQUE INDEX bookings_one_per_seat ON bookings (seat_id);
