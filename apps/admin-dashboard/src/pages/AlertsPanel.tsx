import { useMemo, useState } from 'react'
import { useAlerts, type AlertItem } from '../hooks/useAlerts'
import { PageHeader } from '../components/ui/PageHeader'
import { StatCard } from '../components/ui/StatCard'
import { Badge } from '../components/ui/Badge'
import { Card } from '../components/ui/Card'
import { EmptyState } from '../components/ui/EmptyState'
import { Skeleton } from '../components/ui/Skeleton'
import { BellIcon } from '../components/ui/icons'

type BadgeTone = 'crowded' | 'estimated' | 'primary' | 'neutral' | 'live'

const TYPE_META: Record<string, { label: string; tone: BadgeTone }> = {
  sos: { label: 'SOS', tone: 'crowded' },
  accident: { label: 'Accident', tone: 'crowded' },
  breakdown: { label: 'Breakdown', tone: 'estimated' },
  road_diversion: { label: 'Road diversion', tone: 'primary' },
  route_deviation: { label: 'Route deviation', tone: 'primary' },
  traffic: { label: 'Traffic', tone: 'estimated' },
  signal_lost: { label: 'Signal lost', tone: 'neutral' },
}

const URGENT_TYPES = new Set(['sos', 'accident'])

function meta(type: string) {
  return TYPE_META[type] ?? { label: type, tone: 'neutral' as BadgeTone }
}

function TypeBadge({ type }: { type: string }) {
  const m = meta(type)
  return (
    <Badge tone={m.tone} dot>
      {m.label}
    </Badge>
  )
}

function timeAgo(iso: string): string {
  const seconds = Math.max(0, Math.floor((Date.now() - new Date(iso).getTime()) / 1000))
  if (seconds < 60) return `${seconds}s ago`
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  return `${hours}h ago`
}

function AlertRow({ alert, onResolve }: { alert: AlertItem; onResolve: (id: number) => void }) {
  const raised = new Date(alert.raisedAt)
  return (
    <li className="flex items-center gap-4 px-5 py-3.5">
      <div className="w-36 shrink-0">
        <TypeBadge type={alert.type} />
      </div>
      <div className="min-w-0 flex-1">
        <div className="truncate text-sm font-medium text-foreground">
          {alert.busId ? <span className="font-semibold">Bus {alert.busId}</span> : <span className="text-muted-foreground">Bus unknown</span>}
          {alert.tripId != null && <span className="text-muted-foreground"> · trip #{alert.tripId}</span>}
        </div>
        {alert.notes && <div className="truncate text-xs text-muted-foreground">{alert.notes}</div>}
      </div>
      <div className="shrink-0 text-right text-xs font-medium text-muted-foreground" title={raised.toISOString()}>
        {timeAgo(alert.raisedAt)}
      </div>
      <button
        onClick={() => onResolve(alert.alertId)}
        className="shrink-0 rounded-full bg-card-nested px-3 py-1.5 text-xs font-semibold text-foreground transition-colors hover:bg-primary hover:text-primary-foreground"
      >
        Resolve
      </button>
    </li>
  )
}

export default function AlertsPanel() {
  const { alerts, loading, error, resolve } = useAlerts()
  const [filter, setFilter] = useState<string | null>(null)

  const { urgentCount, breakdownCount, otherCount } = useMemo(() => {
    let urgent = 0
    let breakdown = 0
    let other = 0
    for (const a of alerts) {
      if (URGENT_TYPES.has(a.type)) urgent++
      else if (a.type === 'breakdown') breakdown++
      else other++
    }
    return { urgentCount: urgent, breakdownCount: breakdown, otherCount: other }
  }, [alerts])

  const types = useMemo(() => Array.from(new Set(alerts.map((a) => a.type))), [alerts])
  const visible = filter ? alerts.filter((a) => a.type === filter) : alerts

  return (
    <div className="p-6">
      <PageHeader
        title="Alerts & SOS"
        description="Open driver-raised incidents (SOS, breakdown, traffic, diversions, accidents) — refreshes every 10s."
      />

      <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-3">
        <StatCard label="Open alerts" value={String(alerts.length)} icon={BellIcon} tone={alerts.length ? 'warn' : 'good'} />
        <StatCard label="SOS / accident" value={String(urgentCount)} icon={BellIcon} tone={urgentCount ? 'bad' : 'good'} />
        <StatCard label="Breakdowns" value={String(breakdownCount)} icon={BellIcon} tone={breakdownCount ? 'warn' : 'good'} />
      </div>

      {error && (
        <div className="mb-4 rounded-nested bg-crowded/10 px-4 py-3 text-sm font-medium text-crowded">{error}</div>
      )}

      <Card>
        <div className="flex items-center gap-2 overflow-x-auto px-5 pt-4 pb-2">
          <button
            onClick={() => setFilter(null)}
            className={`shrink-0 rounded-full px-3 py-1.5 text-xs font-semibold transition-colors ${
              filter === null ? 'bg-primary text-primary-foreground' : 'bg-card-nested text-muted-foreground hover:text-foreground'
            }`}
          >
            All ({alerts.length})
          </button>
          {types.map((t) => (
            <button
              key={t}
              onClick={() => setFilter(t)}
              className={`shrink-0 rounded-full px-3 py-1.5 text-xs font-semibold transition-colors ${
                filter === t ? 'bg-primary text-primary-foreground' : 'bg-card-nested text-muted-foreground hover:text-foreground'
              }`}
            >
              {meta(t).label} ({alerts.filter((a) => a.type === t).length})
            </button>
          ))}
          {otherCount > 0 && <span className="ml-auto shrink-0 text-xs font-medium text-muted-foreground">{otherCount} other</span>}
        </div>

        {loading ? (
          <div className="space-y-3 p-5">
            <Skeleton className="h-10 w-full" />
            <Skeleton className="h-10 w-full" />
            <Skeleton className="h-10 w-full" />
          </div>
        ) : visible.length === 0 ? (
          <EmptyState
            bare
            icon={BellIcon}
            title={alerts.length === 0 ? 'No open alerts' : 'No alerts match this filter'}
            description={
              alerts.length === 0
                ? 'The fleet is quiet — new SOS, breakdown, and diversion reports will show up here as drivers raise them.'
                : 'Try a different filter or clear it to see everything.'
            }
          />
        ) : (
          <ul className="divide-y divide-border">
            {visible.map((a) => (
              <AlertRow key={a.alertId} alert={a} onResolve={resolve} />
            ))}
          </ul>
        )}
      </Card>
    </div>
  )
}
