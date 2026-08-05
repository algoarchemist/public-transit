export default function PassengerLoadAnalytics() {
  return (
    <div className="p-6">
      <h1 className="text-xl font-semibold mb-2">Passenger Load Analytics</h1>
      <p className="text-sm text-neutral-500">
        Ridership by route/stop/hour, weekday vs weekend curves, ticket-revenue vs ridership correlation.
        TODO: fetch from api-gateway /analytics/ridership.
      </p>
    </div>
  )
}
