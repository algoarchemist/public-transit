export default function RoutePerformance() {
  return (
    <div className="p-6">
      <h1 className="text-xl font-semibold mb-2">Route Performance</h1>
      <p className="text-sm text-neutral-500">
        Per-route on-time %, average delay, occupancy heatmap by hour, flagged problem segments.
        TODO: fetch from api-gateway /routes/:id/performance, render with Recharts.
      </p>
    </div>
  )
}
