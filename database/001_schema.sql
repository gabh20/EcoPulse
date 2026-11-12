CREATE EXTENSION IF NOT EXISTS postgis;

CREATE TABLE users (
    id uuid PRIMARY KEY,
    name varchar(80) NOT NULL,
    email varchar(254) NOT NULL UNIQUE,
    password_hash text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Guarda o conteúdo original para detectar reutilização indevida do identificador.
CREATE TABLE submissions (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    payload jsonb NOT NULL,
    state text NOT NULL DEFAULT 'PENDING',
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE reports (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    type text NOT NULL CHECK (type IN ('FLOOD','BLOCKED_ROAD','SMOKE','AIR_QUALITY','HEAT')),
    description varchar(500) NOT NULL,
    latitude double precision NOT NULL CHECK (latitude BETWEEN -90 AND 90),
    longitude double precision NOT NULL CHECK (longitude BETWEEN -180 AND 180),
    accuracy_meters double precision NOT NULL CHECK (accuracy_meters >= 0),
    location geography(Point,4326) NOT NULL,
    region varchar(5) NOT NULL,
    observed_at timestamptz NOT NULL,
    expires_at timestamptz NOT NULL,
    status text NOT NULL CHECK (status IN ('ACTIVE','EXPIRED','RESOLVED'))
);
CREATE INDEX reports_location_idx ON reports USING gist(location);
CREATE INDEX reports_region_idx ON reports(region);
CREATE INDEX reports_expiry_idx ON reports(expires_at) WHERE status='ACTIVE';

-- A ocorrência e o evento saem da mesma transação (padrão outbox).
CREATE TABLE outbox (
    id uuid PRIMARY KEY,
    body jsonb NOT NULL,
    published_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX outbox_pending_idx ON outbox(created_at) WHERE published_at IS NULL;

CREATE TABLE devices (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users(id),
    fcm_token text,
    latitude double precision NOT NULL,
    longitude double precision NOT NULL,
    location geography(Point,4326) NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX devices_location_idx ON devices USING gist(location);

CREATE TABLE push_deliveries (
    event_id uuid NOT NULL,
    device_id uuid NOT NULL REFERENCES devices(id),
    delivered_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY(event_id, device_id)
);
