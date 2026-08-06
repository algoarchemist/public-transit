-- 0001's routes.source CHECK was written straight from architecture doc §3.1's two
-- values before Path A-hybrid was known to exist. In practice reconcile.py's
-- RouteSource enum has a real third value, 'osm_relation_inferred_stops' — real
-- relation geometry, but stop order inferred by projecting real stop nodes onto it —
-- and it's not rare: 100/110 real tricity routes reconcile this way (see
-- services/geo-ingest/README.md "Reconciliation paths"). The old constraint would
-- reject the majority of real inserts.
ALTER TABLE routes DROP CONSTRAINT routes_source_check;
ALTER TABLE routes ADD CONSTRAINT routes_source_check
    CHECK (source IN ('osm_relation', 'osm_relation_inferred_stops', 'osrm_synthesized'));

-- Upsert key so re-running geo-ingest against the same relation updates rather than
-- duplicates (docs/IMPLEMENTATION_ARCHITECTURE.md §4.2 "idempotent by osm_relation_id").
-- Partial because osrm_synthesized routes can have no relation at all — those have no
-- natural key here and just insert as new rows on re-run; accepted MVP gap, not silent
-- data loss (nothing is overwritten incorrectly, just not deduplicated).
CREATE UNIQUE INDEX routes_city_relation_uniq ON routes (city_id, osm_relation_id)
    WHERE osm_relation_id IS NOT NULL;
