/**
 * Small geometry helpers for map-matching and dead reckoning. Python's
 * app/geometry.py (geo-ingest, UTM-projected) can't be shared across runtimes, so
 * this is a from-scratch TS equivalent — deliberately simpler, using a local
 * equirectangular projection rather than a real UTM transform. That's accurate to
 * a few meters at the Punjab/tricity scale (a handful of km, mid-latitude ~30.7°N),
 * which is well within the map-matching precision this needs.
 */

export interface LonLat {
  lon: number;
  lat: number;
}

const EARTH_RADIUS_M = 6371000;

function toRad(deg: number): number {
  return (deg * Math.PI) / 180;
}

/** Great-circle distance between two points, in meters. */
export function haversineDistanceM(a: LonLat, b: LonLat): number {
  const dLat = toRad(b.lat - a.lat);
  const dLon = toRad(b.lon - a.lon);
  const lat1 = toRad(a.lat);
  const lat2 = toRad(b.lat);
  const sinDLat = Math.sin(dLat / 2);
  const sinDLon = Math.sin(dLon / 2);
  const h = sinDLat * sinDLat + Math.cos(lat1) * Math.cos(lat2) * sinDLon * sinDLon;
  return 2 * EARTH_RADIUS_M * Math.asin(Math.sqrt(h));
}

/** Local flat-plane (x, y) in meters, relative to `origin`. Valid for short distances only. */
function toLocalMeters(point: LonLat, origin: LonLat): { x: number; y: number } {
  const latRad = toRad(origin.lat);
  const x = toRad(point.lon - origin.lon) * EARTH_RADIUS_M * Math.cos(latRad);
  const y = toRad(point.lat - origin.lat) * EARTH_RADIUS_M;
  return { x, y };
}

function fromLocalMeters(p: { x: number; y: number }, origin: LonLat): LonLat {
  const latRad = toRad(origin.lat);
  const lat = origin.lat + (p.y / EARTH_RADIUS_M) * (180 / Math.PI);
  const lon = origin.lon + (p.x / (EARTH_RADIUS_M * Math.cos(latRad))) * (180 / Math.PI);
  return { lon, lat };
}

export function polylineLengthM(line: LonLat[]): number {
  let total = 0;
  for (let i = 1; i < line.length; i++) {
    total += haversineDistanceM(line[i - 1], line[i]);
  }
  return total;
}

export interface Projection {
  distAlongLineM: number;
  offsetM: number; // perpendicular distance from the point to the matched line
  segmentIndex: number; // index i such that the match lies on line[i] -> line[i+1]
  point: LonLat; // the matched point ON the line
}

/**
 * Projects `point` onto the polyline, returning the nearest point on the line, the
 * cumulative distance along the line to reach it, and which segment it fell on.
 * Used for map-matching a raw GPS fix onto a route's real geometry.
 */
export function projectOntoPolyline(point: LonLat, line: LonLat[]): Projection {
  if (line.length < 2) {
    throw new Error('polyline needs at least 2 points to project onto');
  }

  const origin = line[0];
  const p = toLocalMeters(point, origin);

  let best: Projection | null = null;
  let cumulative = 0;

  for (let i = 0; i < line.length - 1; i++) {
    const a = toLocalMeters(line[i], origin);
    const b = toLocalMeters(line[i + 1], origin);
    const segDx = b.x - a.x;
    const segDy = b.y - a.y;
    const segLenSq = segDx * segDx + segDy * segDy;

    let t = segLenSq === 0 ? 0 : ((p.x - a.x) * segDx + (p.y - a.y) * segDy) / segLenSq;
    t = Math.max(0, Math.min(1, t));

    const projX = a.x + t * segDx;
    const projY = a.y + t * segDy;
    const offsetM = Math.hypot(p.x - projX, p.y - projY);
    const segLenM = Math.hypot(segDx, segDy);
    const distAlongLineM = cumulative + t * segLenM;

    if (best === null || offsetM < best.offsetM) {
      best = {
        distAlongLineM,
        offsetM,
        segmentIndex: i,
        point: fromLocalMeters({ x: projX, y: projY }, origin),
      };
    }

    cumulative += segLenM;
  }

  return best as Projection;
}

/** The real point on `line` at `distM` along it (clamped to the line's ends). */
export function pointAtDistanceAlongPolyline(line: LonLat[], distM: number): LonLat {
  if (line.length < 2) {
    throw new Error('polyline needs at least 2 points');
  }
  if (distM <= 0) return line[0];

  const origin = line[0];
  let cumulative = 0;

  for (let i = 0; i < line.length - 1; i++) {
    const a = toLocalMeters(line[i], origin);
    const b = toLocalMeters(line[i + 1], origin);
    const segLenM = Math.hypot(b.x - a.x, b.y - a.y);

    if (cumulative + segLenM >= distM) {
      const t = segLenM === 0 ? 0 : (distM - cumulative) / segLenM;
      return fromLocalMeters({ x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y) }, origin);
    }
    cumulative += segLenM;
  }
  return line[line.length - 1];
}
