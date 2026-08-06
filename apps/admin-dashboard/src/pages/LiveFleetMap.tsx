import { FleetMap } from '../components/FleetMap'
import { useFleetSocket } from '../hooks/useFleetSocket'

export default function LiveFleetMap() {
  const { buses, connected } = useFleetSocket()

  return (
    <div className="p-6">
      <h1 className="text-xl font-semibold mb-2">Live Fleet Map</h1>
      {!connected && (
        <p className="text-sm text-amber-600 mb-2">reconnecting to gateway…</p>
      )}
      <FleetMap buses={buses} />
    </div>
  )
}
