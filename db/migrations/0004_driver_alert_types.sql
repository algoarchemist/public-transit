-- Widens `alerts.type` for driver-raised incidents.
--
-- 0001's constraint covered only what the *system* detects — 'route_deviation' and
-- 'signal_lost' are inferred by the stream-processor, 'sos'/'breakdown' were the
-- driver-raised pair originally scoped. The driver app now reports road conditions
-- too (docs §10 phase 5): traffic jams, diversions and accidents, which are the
-- three the operator actually needs to hear about to re-plan a headway.
--
-- These stay one table rather than becoming a separate `incidents` table: they have
-- identical shape (type, trip, bus, where, when, note) and the admin view wants them
-- interleaved on one timeline. A second table would be two queries to render one list.

ALTER TABLE alerts DROP CONSTRAINT alerts_type_check;

ALTER TABLE alerts ADD CONSTRAINT alerts_type_check CHECK (
    type IN (
        -- driver-raised
        'sos',
        'breakdown',
        'traffic',
        'road_diversion',
        'accident',
        -- system-inferred
        'route_deviation',
        'signal_lost'
    )
);

-- Who reported it. Driver-raised and system-inferred alerts need different handling
-- downstream (one is a human account of the road, the other is a guess from missing
-- data) and the type alone no longer distinguishes them.
ALTER TABLE alerts ADD COLUMN source text NOT NULL DEFAULT 'system'
    CHECK (source IN ('driver', 'system'));

-- The admin alert feed is "what is happening right now", i.e. unresolved, newest
-- first — this is the index that query wants.
CREATE INDEX alerts_open_idx ON alerts (raised_at DESC) WHERE resolved_at IS NULL;
