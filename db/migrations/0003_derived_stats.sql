-- Derived feature tables (architecture doc §3.3), deferred by 0001_init.sql's MVP
-- note until something downstream actually needed them — stream-processor's
-- etaScoringLoop.ts now does (docs §7.3 item 3).
--
-- Deliberately NOT FKs to route_segments.id / stops.id. The live in-memory
-- pipeline (routeStore.ts, data/snapshots/<label>/segments.geojson) only ever
-- knows direction_id + sequence and each stop's real osm_node_id — it never
-- queries Postgres for anything. Keying these tables the same way avoids a
-- fragile join between the file-snapshot-based live pipeline and Postgres's
-- separate serial-id schema; route_id is carried as plain text for readability/
-- filtering only, not a FK to routes.id.
--
-- dow stays in the schema (forward-compatible with docs §3.3) but is populated
-- as -1 ("any day") by services/ml-service/train/refresh_stats.py, not a real
-- per-weekday breakdown: at the simulator's current volume (4 trips/route/day),
-- a (segment, dow, hour) cell gets roughly 1-3 samples over a 30-day window —
-- too sparse to be a real signal rather than noise. Same finding already
-- documented in train/dataset.py for the offline training pipeline. Consumers
-- should look up the real dow first and fall back to -1 (see stream-processor's
-- statsStore.ts), so real per-dow data can slot in later with no code change.
--
-- These are populated by a batch script re-run against the simulator's backfill
-- corpus (data/backfill/<label>/), NOT a live TimescaleDB continuous aggregate —
-- consumer.ts doesn't persist raw gps_pings/stop_events to Postgres yet, so
-- there is no live traffic to continuously aggregate from. Re-run
-- refresh_stats.py after regenerating the backfill corpus to refresh these.

CREATE TABLE segment_travel_stats (
    direction_id     text NOT NULL,
    sequence         integer NOT NULL,
    route_id         text,
    dow              smallint NOT NULL CHECK (dow BETWEEN -1 AND 6),
    hour_bucket      smallint NOT NULL CHECK (hour_bucket BETWEEN 0 AND 23),
    agg_window       text NOT NULL CHECK (agg_window IN ('7d', '30d')), -- `window` is a reserved SQL keyword
    avg_speed_kmh    real NOT NULL,
    p50_duration_sec real NOT NULL,
    p85_duration_sec real NOT NULL,
    sample_count     integer NOT NULL,
    refreshed_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (direction_id, sequence, dow, hour_bucket, agg_window)
);
CREATE INDEX segment_travel_stats_lookup_idx
    ON segment_travel_stats (direction_id, sequence, hour_bucket, agg_window);

CREATE TABLE stop_dwell_stats (
    stop_osm_node_id bigint NOT NULL,
    dow              smallint NOT NULL CHECK (dow BETWEEN -1 AND 6),
    hour_bucket      smallint NOT NULL CHECK (hour_bucket BETWEEN 0 AND 23),
    p50_dwell_sec    real NOT NULL,
    avg_boarding     real NOT NULL,
    avg_alighting    real NOT NULL,
    sample_count     integer NOT NULL,
    refreshed_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (stop_osm_node_id, dow, hour_bucket)
);
CREATE INDEX stop_dwell_stats_lookup_idx ON stop_dwell_stats (stop_osm_node_id, hour_bucket);
