import { useEffect, useState } from 'react'
import { Bar, BarChart, CartesianGrid, Legend, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts'
import { api } from '../lib/api'
import { PageHeader } from '../components/ui/PageHeader'
import { Card, CardBody, CardHeader, CardTitle } from '../components/ui/Card'
import { EmptyState } from '../components/ui/EmptyState'
import { Skeleton } from '../components/ui/Skeleton'
import { Badge } from '../components/ui/Badge'
import { GaugeIcon, ConstructionIcon } from '../components/ui/icons'

interface RouteDemand {
  directionId: string | null
  name: string
  avgBoardingsPerTrip: number
  tripCount: number
  runningTrips: number
  status: 'under-supplied' | 'over-supplied' | 'balanced' | 'no-active-service'
}

interface DemandSupplyResponse {
  routes: RouteDemand[]
  flagged: RouteDemand[]
  source: string
}

const STATUS_BADGE: Record<RouteDemand['status'], { tone: 'crowded' | 'estimated' | 'live' | 'neutral'; label: string }> = {
  'under-supplied': { tone: 'crowded', label: 'Under-supplied' },
  'over-supplied': { tone: 'estimated', label: 'Over-supplied' },
  balanced: { tone: 'live', label: 'Balanced' },
  'no-active-service': { tone: 'neutral', label: 'No active service' },
}

export default function DemandSupplyPlanning() {
  const [data, setData] = useState<DemandSupplyResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    api
      .get<DemandSupplyResponse>('/admin/analytics/demand-supply')
      .then((res) => !cancelled && setData(res.data))
      .catch(() => !cancelled && setError('Could not reach the analytics service'))
      .finally(() => !cancelled && setLoading(false))
    return () => {
      cancelled = true
    }
  }, [])

  const topRoutes = (data?.routes ?? []).slice(0, 10).map((r) => ({
    name: r.name.length > 18 ? `${r.name.slice(0, 17)}…` : r.name,
    demand: r.avgBoardingsPerTrip,
    allocated: r.runningTrips,
  }))

  return (
    <div className="p-6">
      <PageHeader
        title="Demand-Supply Planning"
        description="Historical-average demand (real boardings/trip) against currently-allocated fleet per route, with over/under-supply flags."
      />

      {error && <div className="mb-4 rounded-nested bg-crowded/10 px-4 py-3 text-sm font-medium text-crowded">{error}</div>}

      {loading ? (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <Skeleton className="h-64" />
          <Skeleton className="h-64" />
        </div>
      ) : !data || data.routes.length === 0 ? (
        <EmptyState
          icon={GaugeIcon}
          title="No route ridership recorded yet"
          description="This fills in once trips have run with recorded stop events."
        />
      ) : (
        <>
          <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
            <Card>
              <CardHeader>
                <CardTitle>Predicted demand vs. allocated fleet</CardTitle>
              </CardHeader>
              <CardBody>
                <div className="h-72">
                  <ResponsiveContainer width="100%" height="100%">
                    <BarChart data={topRoutes} margin={{ top: 8, right: 8, left: -16, bottom: 32 }}>
                      <CartesianGrid strokeDasharray="3 3" stroke="var(--color-border)" vertical={false} />
                      <XAxis
                        dataKey="name"
                        tick={{ fontSize: 10, fill: 'var(--color-muted-foreground)' }}
                        axisLine={false}
                        tickLine={false}
                        angle={-35}
                        textAnchor="end"
                        interval={0}
                      />
                      <YAxis tick={{ fontSize: 12, fill: 'var(--color-muted-foreground)' }} axisLine={false} tickLine={false} />
                      <Tooltip
                        contentStyle={{ background: 'var(--color-card)', border: '1px solid var(--color-border)', borderRadius: 12, fontSize: 12 }}
                        labelStyle={{ color: 'var(--color-foreground)', fontWeight: 600 }}
                      />
                      <Legend wrapperStyle={{ fontSize: 12 }} />
                      <Bar dataKey="demand" name="Avg boardings/trip" fill="var(--color-primary)" radius={[6, 6, 0, 0]} />
                      <Bar dataKey="allocated" name="Buses running now" fill="var(--color-live)" radius={[6, 6, 0, 0]} />
                    </BarChart>
                  </ResponsiveContainer>
                </div>
              </CardBody>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle>Flagged routes</CardTitle>
              </CardHeader>
              <CardBody className="max-h-72 overflow-y-auto">
                {data.flagged.length > 0 ? (
                  <ul className="space-y-2">
                    {data.flagged.map((r) => (
                      <li key={r.directionId ?? r.name} className="flex items-center justify-between rounded-nested bg-card-nested px-3 py-2.5">
                        <div className="min-w-0">
                          <div className="truncate text-sm font-semibold text-foreground">{r.name}</div>
                          <div className="text-xs text-muted-foreground">
                            {r.avgBoardingsPerTrip} avg boardings/trip · {r.runningTrips} running now
                          </div>
                        </div>
                        <Badge tone={STATUS_BADGE[r.status].tone} dot>
                          {STATUS_BADGE[r.status].label}
                        </Badge>
                      </li>
                    ))}
                  </ul>
                ) : (
                  <EmptyState bare icon={ConstructionIcon} title="Nothing flagged" description="No route currently looks meaningfully over- or under-supplied." />
                )}
              </CardBody>
            </Card>
          </div>

          <p className="mt-4 text-xs text-muted-foreground">{data.source}</p>
        </>
      )}
    </div>
  )
}
