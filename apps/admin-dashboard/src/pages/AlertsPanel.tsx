export default function AlertsPanel() {
  return (
    <div className="p-6">
      <h1 className="text-xl font-semibold mb-2">Alerts &amp; SOS</h1>
      <p className="text-sm text-neutral-500">
        Breakdown reports, SOS button presses, geofence route-deviation alerts.
        TODO: subscribe to WebSocket "alerts" room for live push.
      </p>
    </div>
  )
}
