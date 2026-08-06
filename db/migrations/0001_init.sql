-- Core SetuTrack schema. Plain PostGIS, no TimescaleDB — MVP scale doesn't need
-- hypertables/continuous aggregates; time-series tables (gps_pings,
-- map_matched_positions, occupancy_snapshots) just get a btree index on `time`
-- instead. Revisit if/when real ping volume justifies it. Derived aggregate tables
-- (segment_travel_stats, stop_dwell_stats from architecture doc §3.3) are deferred
-- past MVP for the same reason — nothing downstream depends on them yet.
-- See docs/IMPLEMENTATION_ARCHITECTURE.md §3 for the full design this implements.

CREATE EXTENSION IF NOT EXISTS postgis;

-- 3.1 Static / reference tables ----------------------------------------------

CREATE TABLE cities (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    name        text NOT NULL UNIQUE,
    state       text NOT NULL,
    osm_area_id bigint,
    bbox        geometry(Polygon, 4326)
);

CREATE TABLE stops (
    id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    city_id        integer NOT NULL REFERENCES cities (id),
    osm_node_id    bigint,
    name           text,
    name_pa        text,
    name_hi        text,
    geom           geometry(Point, 4326) NOT NULL,
    footfall_prior real NOT NULL DEFAULT 0,
    created_at     timestamptz NOT NULL DEFAULT now(),
    UNIQUE (city_id, osm_node_id)
);
CREATE INDEX stops_geom_idx ON stops USING GIST (geom);

CREATE TABLE routes (
    id              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    city_id         integer NOT NULL REFERENCES cities (id),
    ref             text,
    name            text,
    operator        text,
    direction       text,
    osm_relation_id bigint,
    source          text NOT NULL CHECK (source IN ('osm_relation', 'osrm_synthesized')),
    geom            geometry(LineString, 4326) NOT NULL,
    length_m        double precision NOT NULL
);
CREATE INDEX routes_geom_idx ON routes USING GIST (geom);
CREATE INDEX routes_city_id_idx ON routes (city_id);

CREATE TABLE route_stops (
    route_id           integer NOT NULL REFERENCES routes (id) ON DELETE CASCADE,
    stop_id            integer NOT NULL REFERENCES stops (id),
    sequence           integer NOT NULL,
    dist_along_route_m double precision NOT NULL,
    scheduled_offset_sec integer,
    PRIMARY KEY (route_id, sequence)
);
CREATE INDEX route_stops_stop_id_idx ON route_stops (stop_id);

CREATE TABLE route_segments (
    id                    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    route_id              integer NOT NULL REFERENCES routes (id) ON DELETE CASCADE,
    sequence              integer NOT NULL,
    from_stop_id          integer NOT NULL REFERENCES stops (id),
    to_stop_id            integer NOT NULL REFERENCES stops (id),
    geom                  geometry(LineString, 4326) NOT NULL,
    length_m              double precision NOT NULL,
    osrm_baseline_sec     double precision,
    dominant_highway_class text,
    UNIQUE (route_id, sequence)
);
CREATE INDEX route_segments_geom_idx ON route_segments USING GIST (geom);

CREATE TABLE buses (
    id              integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    registration_no text NOT NULL UNIQUE,
    depot_id        text,
    capacity        integer,
    has_vltd        boolean NOT NULL DEFAULT false,
    model           text
);

-- 3.2 Operational / time-series tables ----------------------------------------

CREATE TABLE trips (
    id             integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    route_id       integer NOT NULL REFERENCES routes (id),
    bus_id         integer NOT NULL REFERENCES buses (id),
    driver_id      text,
    scheduled_start timestamptz,
    started_at     timestamptz,
    ended_at       timestamptz,
    status         text NOT NULL DEFAULT 'scheduled'
                   CHECK (status IN ('scheduled', 'running', 'completed', 'abandoned'))
);
CREATE INDEX trips_route_id_idx ON trips (route_id);
CREATE INDEX trips_bus_id_idx ON trips (bus_id);

CREATE TABLE gps_pings (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    time       timestamptz NOT NULL,
    trip_id    integer NOT NULL REFERENCES trips (id) ON DELETE CASCADE,
    bus_id     integer NOT NULL REFERENCES buses (id),
    geom       geometry(Point, 4326) NOT NULL,
    speed_kmh  real,
    heading    real,
    accuracy_m real,
    source     text NOT NULL CHECK (source IN ('sim', 'vltd', 'driver_app'))
);
CREATE INDEX gps_pings_trip_id_time_idx ON gps_pings (trip_id, time);
CREATE INDEX gps_pings_time_idx ON gps_pings (time);
CREATE INDEX gps_pings_geom_idx ON gps_pings USING GIST (geom);

CREATE TABLE map_matched_positions (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    time               timestamptz NOT NULL,
    trip_id            integer NOT NULL REFERENCES trips (id) ON DELETE CASCADE,
    route_id           integer NOT NULL REFERENCES routes (id),
    dist_along_route_m double precision,
    fraction_complete  real,
    current_segment_id integer REFERENCES route_segments (id),
    next_stop_id       integer REFERENCES stops (id),
    delay_sec          integer
);
CREATE INDEX map_matched_positions_trip_id_time_idx ON map_matched_positions (trip_id, time);

CREATE TABLE stop_events (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    trip_id         integer NOT NULL REFERENCES trips (id) ON DELETE CASCADE,
    stop_id         integer NOT NULL REFERENCES stops (id),
    sequence        integer NOT NULL,
    arrived_at      timestamptz,
    departed_at     timestamptz,
    dwell_sec       integer,
    boarding_count  integer,
    alighting_count integer
);
CREATE INDEX stop_events_trip_id_idx ON stop_events (trip_id);

CREATE TABLE occupancy_snapshots (
    id         bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    time       timestamptz NOT NULL,
    trip_id    integer NOT NULL REFERENCES trips (id) ON DELETE CASCADE,
    occupancy  real,
    source     text NOT NULL CHECK (source IN ('conductor_tally', 'ticket_derived', 'sensor'))
);
CREATE INDEX occupancy_snapshots_trip_id_time_idx ON occupancy_snapshots (trip_id, time);

CREATE TABLE tickets (
    id                integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    passenger_id      text NOT NULL,
    trip_id           integer NOT NULL REFERENCES trips (id),
    from_stop_id      integer NOT NULL REFERENCES stops (id),
    to_stop_id        integer NOT NULL REFERENCES stops (id),
    fare_paise        integer NOT NULL,
    qr_payload        text,
    signature         text,
    status            text NOT NULL DEFAULT 'issued',
    purchased_at      timestamptz NOT NULL DEFAULT now(),
    validated_at      timestamptz,
    validated_offline boolean NOT NULL DEFAULT false
);
CREATE INDEX tickets_trip_id_idx ON tickets (trip_id);
CREATE INDEX tickets_passenger_id_idx ON tickets (passenger_id);

CREATE TABLE alerts (
    id          integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    type        text NOT NULL CHECK (type IN ('sos', 'breakdown', 'route_deviation', 'signal_lost')),
    trip_id     integer REFERENCES trips (id),
    bus_id      integer REFERENCES buses (id),
    geom        geometry(Point, 4326),
    raised_at   timestamptz NOT NULL DEFAULT now(),
    resolved_at timestamptz,
    notes       text
);
CREATE INDEX alerts_trip_id_idx ON alerts (trip_id);
