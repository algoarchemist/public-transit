import { useEffect, useState } from 'react'
import {
  Bar,
  BarChart,
  CartesianGrid,
  Legend,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from 'recharts'
import { api } from '../lib/api'
import { PageHeader } from '../components/ui/PageHeader'
import { Card, CardBody, CardHeader, CardTitle } from '../components/ui/Card'
import { EmptyState } from '../components/ui/EmptyState'
import { Skeleton } from '../components/ui/Skeleton'
import { StatCard } from '../components/ui/StatCard'
import { Badge } from '../components/ui/Badge'
import { ActivityIcon, BusIcon, GaugeIcon, WifiIcon } from '../components/ui/icons'

type ConfidenceTier = 'live' | 'estimated' | 'stale' | 'unknown'

interface ModelMetrics {
  trained_at: string
  git_sha: string
  snapshot_label: string
  per_segment_mae_sec: { model: number; naive_baseline: number }
  per_segment_improvement_pct: number
  horizon_bucketed_mae_sec: {
    model: Record<string, { mae_sec: number; n: number }>
    naive_baseline: Record<string, { mae_sec: number; n: number }>
  }
}

interface FleetBus {
  busId: string
  directionId: string | null
  ageSec: number | null
  confidenceTier: ConfidenceTier
  lastPingAt: string | null
}

interface ModelHealthResponse {
  model: ModelMetrics | null
  modelError: string | null
  fleet: {
    busesTracked: number
    tierCounts: Record<ConfidenceTier, number>
    buses: FleetBus[]
  }
}

const HORIZON_ORDER = ['0-2min', '2-5min', '5-10min', '10min+']

const TIER_BADGE: Record<ConfidenceTier, 'live' | 'estimated' | 'neutral'> = {
  live: 'live',
  estimated: 'estimated',
  stale: 'neutral',
  unknown: 'neutral',
}

function formatAge(ageSec: number | null): string {
  if (ageSec === null) return '—'
  if (ageSec < 60) return `${ageSec}s ago`
  return `${Math.round(ageSec / 60)}m ago`
}

export default function ModelHealth() {
  const [data, setData] = useState<ModelHealthResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    api
      .get<ModelHealthResponse>('/admin/analytics/model-health')
      .then((res) => !cancelled && setData(res.data))
      .catch(() => !cancelled && setError('Could not reach the analytics service'))
      .finally(() => !cancelled && setLoading(false))
    return () => {
      cancelled = true
    }
  }, [])

  const horizonRows = data?.model
    ? HORIZON_ORDER.filter((h) => data.model!.horizon_bucketed_mae_sec.model[h]).map((h) => ({
        horizon: h,
        model: data.model!.horizon_bucketed_mae_sec.model[h].mae_sec,
        naive: data.model!.horizon_bucketed_mae_sec.naive_baseline[h].mae_sec,
      }))
    : []

  return (
    <div className="p-6">
      <PageHeader
        title="Model Health"
        description="ETA MAE from the last training run, and per-bus data-freshness (last-ping-age) read live from Redis."
      />

      {error && <div className="mb-4 rounded-nested bg-crowded/10 px-4 py-3 text-sm font-medium text-crowded">{error}</div>}

      {loading ? (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <Skeleton className="h-24" />
          <Skeleton className="h-24" />
          <Skeleton className="h-24" />
        </div>
      ) : (
        <>
          <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-3">
            <StatCard
              label="Per-segment MAE"
              value={data?.model ? `${data.model.per_segment_mae_sec.model.toFixed(1)}s` : '—'}
              hint={data?.model ? `vs. ${data.model.per_segment_mae_sec.naive_baseline.toFixed(1)}s naive baseline` : undefined}
              icon={GaugeIcon}
              tone={data?.model ? 'good' : 'neutral'}
            />
            <StatCard
              label="Improvement over baseline"
              value={data?.model ? `${data.model.per_segment_improvement_pct.toFixed(1)}%` : '—'}
              hint={data?.model ? `git ${data.model.git_sha.slice(0, 7)}` : undefined}
              icon={ActivityIcon}
              tone={data?.model ? 'good' : 'neutral'}
            />
            <StatCard
              label="Buses tracked"
              value={String(data?.fleet.busesTracked ?? 0)}
              hint={
                data
                  ? `${data.fleet.tierCounts.live} live · ${data.fleet.tierCounts.estimated} estimated · ${data.fleet.tierCounts.stale} stale`
                  : undefined
              }
              icon={BusIcon}
              tone="neutral"
            />
          </div>

          <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
            <Card>
              <CardHeader>
                <CardTitle>ETA MAE by horizon (model vs. naive baseline)</CardTitle>
              </CardHeader>
              <CardBody>
                {data?.model ? (
                  <div className="h-64">
                    <ResponsiveContainer width="100%" height="100%">
                      <BarChart data={horizonRows} margin={{ top: 8, right: 8, left: -16, bottom: 0 }}>
                        <CartesianGrid strokeDasharray="3 3" stroke="var(--color-border)" vertical={false} />
                        <XAxis dataKey="horizon" tick={{ fontSize: 12, fill: 'var(--color-muted-foreground)' }} axisLine={false} tickLine={false} />
                        <YAxis
                          tick={{ fontSize: 12, fill: 'var(--color-muted-foreground)' }}
                          axisLine={false}
                          tickLine={false}
                          label={{ value: 'MAE (sec)', angle: -90, position: 'insideLeft', fontSize: 11, fill: 'var(--color-muted-foreground)' }}
                        />
                        <Tooltip
                          contentStyle={{ background: 'var(--color-card)', border: '1px solid var(--color-border)', borderRadius: 12, fontSize: 12 }}
                          labelStyle={{ color: 'var(--color-foreground)', fontWeight: 600 }}
                        />
                        <Legend wrapperStyle={{ fontSize: 12 }} />
                        <Bar dataKey="naive" name="Naive baseline" fill="var(--color-stale)" radius={[6, 6, 0, 0]} />
                        <Bar dataKey="model" name="Model" fill="var(--color-primary)" radius={[6, 6, 0, 0]} />
                      </BarChart>
                    </ResponsiveContainer>
                  </div>
                ) : (
                  <EmptyState
                    bare
                    icon={GaugeIcon}
                    title="No trained model metrics yet"
                    description={data?.modelError ?? 'Run services/ml-service/train/train_eta.py to produce artifacts/metrics.json.'}
                  />
                )}
              </CardBody>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle>Data freshness by bus</CardTitle>
              </CardHeader>
              <CardBody className="max-h-64 overflow-y-auto">
                {data && data.fleet.buses.length > 0 ? (
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="text-left text-xs font-semibold text-muted-foreground">
                        <th className="pb-2">Bus</th>
                        <th className="pb-2">Route</th>
                        <th className="pb-2">Last ping</th>
                        <th className="pb-2 text-right">Status</th>
                      </tr>
                    </thead>
                    <tbody>
                      {data.fleet.buses.map((b) => (
                        <tr key={b.busId} className="border-t border-border">
                          <td className="py-2 font-semibold text-foreground">{b.busId}</td>
                          <td className="py-2 text-muted-foreground">{b.directionId ?? '—'}</td>
                          <td className="py-2 text-muted-foreground">{formatAge(b.ageSec)}</td>
                          <td className="py-2 text-right">
                            <Badge tone={TIER_BADGE[b.confidenceTier]} dot>
                              {b.confidenceTier}
                            </Badge>
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                ) : (
                  <EmptyState bare icon={WifiIcon} title="No buses reporting yet" description="Once a bus sends a real GPS ping, it'll show up here." />
                )}
              </CardBody>
            </Card>
          </div>
        </>
      )}
    </div>
  )
}
