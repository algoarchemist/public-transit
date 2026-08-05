export default function ModelHealth() {
  return (
    <div className="p-6">
      <h1 className="text-xl font-semibold mb-2">Model Health</h1>
      <p className="text-sm text-neutral-500">
        ETA MAE trend and per-bus data-freshness (last-ping-age) indicators.
        TODO: fetch from ml-service /health/metrics.
      </p>
    </div>
  )
}
