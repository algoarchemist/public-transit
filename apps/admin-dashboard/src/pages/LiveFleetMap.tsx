export default function LiveFleetMap() {
  return (
    <div className="p-6">
      <h1 className="text-xl font-semibold mb-2">Live Fleet Map</h1>
      <p className="text-sm text-neutral-500">
        MapLibre GL view of all active buses, color-coded on-time / delayed / crowded.
        TODO: wire to WebSocket gateway (bus-state-updates) and render markers on route polylines.
      </p>
    </div>
  )
}
