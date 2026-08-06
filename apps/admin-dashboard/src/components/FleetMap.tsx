import { useEffect, useRef } from 'react'
import { MapLibreMap, Marker, Popup } from 'maplibre-gl'
import 'maplibre-gl/dist/maplibre-gl.css'
import type { BusState } from '@setutrack/shared-types'
import { api } from '../lib/api'

// Matches the mohali-tricity snapshot geo-ingest/simulator/stream-processor all load.
const TRICITY_CENTER: [number, number] = [76.7179, 30.7046]

// No map tile key exists anywhere in this repo — MapLibre's own free demo style is
// the standard zero-config choice here. Skeletal only: real basemap/styling TBD.
const DEMO_STYLE = 'https://demotiles.maplibre.org/style.json'

function popupText(bus: BusState): string {
  return `Bus ${bus.busId} — Route ${bus.routeId}\n${bus.badge}`
}

export function FleetMap({ buses }: { buses: Map<string, BusState> }) {
  const containerRef = useRef<HTMLDivElement>(null)
  const mapRef = useRef<MapLibreMap | null>(null)
  const markersRef = useRef<Map<string, Marker>>(new Map())

  useEffect(() => {
    if (!containerRef.current) return
    const map = new MapLibreMap({
      container: containerRef.current,
      style: DEMO_STYLE,
      center: TRICITY_CENTER,
      zoom: 12,
    })
    mapRef.current = map
    return () => map.remove()
  }, [])

  // Real route geometry (data/snapshots/mohali-tricity/routes.geojson via
  // GET /routes/geometry) drawn under the live bus markers — one LineString per
  // route direction, so the dots have real roads to move along.
  useEffect(() => {
    const map = mapRef.current
    if (!map) return
    let cancelled = false

    async function addRouteLayer() {
      let data: GeoJSON.FeatureCollection
      try {
        data = (await api.get<GeoJSON.FeatureCollection>('/routes/geometry')).data
      } catch (err) {
        console.error('Failed to load route geometry', err)
        return
      }
      if (cancelled || map!.getSource('routes')) return
      map!.addSource('routes', { type: 'geojson', data })
      map!.addLayer({
        id: 'routes-line',
        type: 'line',
        source: 'routes',
        paint: { 'line-color': '#2563eb', 'line-width': 1.5, 'line-opacity': 0.5 },
      })
    }

    if (map.isStyleLoaded()) addRouteLayer()
    else map.once('load', addRouteLayer)

    return () => {
      cancelled = true
    }
  }, [])

  useEffect(() => {
    const map = mapRef.current
    if (!map) return

    const seen = new Set<string>()
    for (const bus of buses.values()) {
      seen.add(bus.busId)
      let marker = markersRef.current.get(bus.busId)
      if (!marker) {
        marker = new Marker()
          .setLngLat([bus.lon, bus.lat])
          .setPopup(new Popup({ offset: 12 }))
          .addTo(map)
        markersRef.current.set(bus.busId, marker)
      } else {
        marker.setLngLat([bus.lon, bus.lat])
      }
      marker.getPopup()?.setText(popupText(bus))
    }

    for (const [busId, marker] of markersRef.current) {
      if (!seen.has(busId)) {
        marker.remove()
        markersRef.current.delete(busId)
      }
    }
  }, [buses])

  return <div ref={containerRef} className="h-[calc(100vh-2rem)] w-full" />
}
