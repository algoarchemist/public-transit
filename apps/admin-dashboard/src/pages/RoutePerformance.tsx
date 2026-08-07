import { useEffect, useState } from 'react'
import { api } from '../lib/api'
import { PageHeader } from '../components/ui/PageHeader'
import { Card, CardBody, CardHeader, CardTitle } from '../components/ui/Card'
import { EmptyState } from '../components/ui/EmptyState'
import { Skeleton } from '../components/ui/Skeleton'
import { ClockIcon, GaugeIcon, RouteIcon, ConstructionIcon } from '../components/ui/icons'

interface RouteSummary {
  directionId: string
  routeId: string | null
  ref: string | null
  name: string | null
  operator: string | null
  stopCount: number
}

interface RoutePerformanceData {
  routeId: string
  onTimePercent: number | null
  avgDelaySec: number | null
  problemSegments: unknown[]
}

function routeLabel(r: RouteSummary): string {
  return r.name ?? r.ref ?? r.directionId
}

function KpiTile({
  icon: Icon,
  label,
  value,
  suffix,
}: {
  icon: typeof ClockIcon
  label: string
  value: number | null
  suffix?: string
}) {
  return (
    <Card className="p-4">
      <div className="flex items-center gap-2 text-xs font-semibold text-muted-foreground">
        <Icon className="h-4 w-4" />
        {label}
      </div>
      {value === null ? (
        <div className="mt-2 text-sm font-medium text-muted-foreground/70">Not yet available</div>
      ) : (
        <div className="mt-1 text-2xl font-bold tracking-tight text-foreground">
          {value}
          {suffix}
        </div>
      )}
    </Card>
  )
}

export default function RoutePerformance() {
  const [routes, setRoutes] = useState<RouteSummary[] | null>(null)
  const [selected, setSelected] = useState<string>('')
  const [perf, setPerf] = useState<RoutePerformanceData | null>(null)
  const [loadingRoutes, setLoadingRoutes] = useState(true)
  const [loadingPerf, setLoadingPerf] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    api
      .get<RouteSummary[]>('/routes')
      .then((res) => {
        if (cancelled) return
        setRoutes(res.data)
        if (res.data.length > 0) setSelected(res.data[0].directionId)
      })
      .catch(() => !cancelled && setError('Could not reach the routes service'))
      .finally(() => !cancelled && setLoadingRoutes(false))
    return () => {
      cancelled = true
    }
  }, [])

  useEffect(() => {
    if (!selected) return
    let cancelled = false
    setLoadingPerf(true)
    api
      .get<RoutePerformanceData>(`/routes/${selected}/performance`)
      .then((res) => !cancelled && setPerf(res.data))
      .catch(() => !cancelled && setError('Could not load performance for this route'))
      .finally(() => !cancelled && setLoadingPerf(false))
    return () => {
      cancelled = true
    }
  }, [selected])

  return (
    <div className="p-6">
      <PageHeader
        title="Route Performance"
        description="Per-route on-time %, average delay, and flagged problem segments."
        actions={
          routes && routes.length > 0 ? (
            <select
              value={selected}
              onChange={(e) => setSelected(e.target.value)}
              className="rounded-full bg-card-nested px-4 py-2 text-sm font-semibold text-foreground outline-none"
            >
              {routes.map((r) => (
                <option key={r.directionId} value={r.directionId}>
                  {routeLabel(r)}
                </option>
              ))}
            </select>
          ) : undefined
        }
      />

      {error && <div className="mb-4 rounded-nested bg-crowded/10 px-4 py-3 text-sm font-medium text-crowded">{error}</div>}

      {loadingRoutes ? (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <Skeleton className="h-24" />
          <Skeleton className="h-24" />
          <Skeleton className="h-24" />
        </div>
      ) : routes && routes.length === 0 ? (
        <EmptyState icon={RouteIcon} title="No routes ingested yet" description="Once route geometry is loaded, it'll show up here." />
      ) : (
        <>
          <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-3">
            {loadingPerf ? (
              <>
                <Skeleton className="h-24" />
                <Skeleton className="h-24" />
                <Skeleton className="h-24" />
              </>
            ) : (
              <>
                <KpiTile icon={ClockIcon} label="On-time %" value={perf?.onTimePercent ?? null} suffix="%" />
                <KpiTile icon={GaugeIcon} label="Avg delay" value={perf?.avgDelaySec ?? null} suffix="s" />
                <KpiTile
                  icon={ConstructionIcon}
                  label="Problem segments"
                  value={perf ? perf.problemSegments.length : null}
                />
              </>
            )}
          </div>

          <Card>
            <CardHeader>
              <CardTitle>Flagged problem segments</CardTitle>
            </CardHeader>
            <CardBody>
              {!loadingPerf && perf?.problemSegments.length === 0 && (
                <EmptyState
                  bare
                  icon={ConstructionIcon}
                  title="On-time and delay aggregates are still being built"
                  description="This route's segment-level stats will appear here once the on-time/delay pipeline (segment_travel_stats + stop_events) is wired up on the backend."
                />
              )}
            </CardBody>
          </Card>
        </>
      )}
    </div>
  )
}
