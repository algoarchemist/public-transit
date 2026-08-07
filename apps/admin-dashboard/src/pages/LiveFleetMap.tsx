import { useMemo } from 'react'
import { FleetMap } from '../components/FleetMap'
import { useFleetSocket } from '../hooks/useFleetSocket'
import { PageHeader } from '../components/ui/PageHeader'
import { StatCard } from '../components/ui/StatCard'
import { Badge } from '../components/ui/Badge'
import { BusIcon, RouteIcon, WifiIcon, WifiOffIcon } from '../components/ui/icons'

export default function LiveFleetMap() {
  const { buses, connected } = useFleetSocket()

  const { routeCount, liveCount } = useMemo(() => {
    const routes = new Set<string>()
    let live = 0
    for (const bus of buses.values()) {
      routes.add(bus.routeId)
      if (bus.confidenceTier === 'live') live++
    }
    return { routeCount: routes.size, liveCount: live }
  }, [buses])

  return (
    <div className="flex h-full flex-col p-6">
      <PageHeader
        title="Live Fleet Map"
        description="Real-time bus positions streamed from the gateway's admin:fleet room."
        actions={
          <Badge tone={connected ? 'live' : 'estimated'} className="py-1.5">
            {connected ? <WifiIcon className="h-3.5 w-3.5" /> : <WifiOffIcon className="h-3.5 w-3.5" />}
            {connected ? 'Gateway connected' : 'Reconnecting…'}
          </Badge>
        }
      />

      <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-3">
        <StatCard label="Buses tracked" value={String(buses.size)} icon={BusIcon} tone="neutral" />
        <StatCard
          label="Live GPS fix"
          value={String(liveCount)}
          hint={buses.size ? `of ${buses.size} total` : undefined}
          icon={WifiIcon}
          tone={liveCount === buses.size && buses.size > 0 ? 'good' : 'warn'}
        />
        <StatCard label="Routes in service" value={String(routeCount)} icon={RouteIcon} tone="neutral" />
      </div>

      <div className="min-h-[420px] flex-1 overflow-hidden rounded-card shadow-card">
        <FleetMap buses={buses} />
      </div>
    </div>
  )
}
