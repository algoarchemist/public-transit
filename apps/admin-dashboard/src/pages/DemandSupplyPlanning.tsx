export default function DemandSupplyPlanning() {
  return (
    <div className="p-6">
      <h1 className="text-xl font-semibold mb-2">Demand-Supply Planning</h1>
      <p className="text-sm text-neutral-500">
        Overlays predicted demand (crowd model) against current fleet allocation per route and
        surfaces over/under-supply windows. TODO: consume ml-service crowd predictions + api-gateway
        fleet allocation data.
      </p>
    </div>
  )
}
