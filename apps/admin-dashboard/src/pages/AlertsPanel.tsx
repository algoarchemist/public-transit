import { useAlerts, type AlertItem } from '../hooks/useAlerts'

const TYPE_STYLE: Record<string, string> = {
  sos: 'bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300',
  accident: 'bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300',
  breakdown: 'bg-orange-100 text-orange-800 dark:bg-orange-950 dark:text-orange-300',
  road_diversion: 'bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300',
  route_deviation: 'bg-blue-100 text-blue-800 dark:bg-blue-950 dark:text-blue-300',
  traffic: 'bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300',
  signal_lost: 'bg-neutral-200 text-neutral-700 dark:bg-neutral-800 dark:text-neutral-300',
}

const TYPE_LABEL: Record<string, string> = {
  sos: 'SOS',
  accident: 'Accident',
  breakdown: 'Breakdown',
  road_diversion: 'Road diversion',
  route_deviation: 'Route deviation',
  traffic: 'Traffic',
  signal_lost: 'Signal lost',
}

function TypeBadge({ type }: { type: string }) {
  const cls = TYPE_STYLE[type] ?? 'bg-neutral-200 text-neutral-700 dark:bg-neutral-800 dark:text-neutral-300'
  return (
    <span className={`inline-block rounded px-2 py-0.5 text-xs font-medium ${cls}`}>
      {TYPE_LABEL[type] ?? type}
    </span>
  )
}

function AlertRow({ alert, onResolve }: { alert: AlertItem; onResolve: (id: number) => void }) {
  const raised = new Date(alert.raisedAt)
  return (
    <li className="flex items-center gap-4 border-b border-neutral-200 py-3 last:border-0 dark:border-neutral-800">
      <TypeBadge type={alert.type} />
      <div className="min-w-0 flex-1">
        <div className="truncate text-sm">
          {alert.busId ? <span className="font-medium">Bus {alert.busId}</span> : <span className="text-neutral-500">Bus unknown</span>}
          {alert.tripId != null && <span className="text-neutral-500"> · trip #{alert.tripId}</span>}
        </div>
        {alert.notes && <div className="truncate text-xs text-neutral-500">{alert.notes}</div>}
      </div>
      <div className="shrink-0 text-xs text-neutral-500" title={raised.toISOString()}>
        {raised.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })}
      </div>
      <button
        onClick={() => onResolve(alert.alertId)}
        className="shrink-0 rounded border border-neutral-300 px-2 py-1 text-xs hover:bg-neutral-100 dark:border-neutral-700 dark:hover:bg-neutral-800"
      >
        Resolve
      </button>
    </li>
  )
}

export default function AlertsPanel() {
  const { alerts, loading, error, resolve } = useAlerts()

  return (
    <div className="p-6">
      <h1 className="mb-2 text-xl font-semibold">Alerts &amp; SOS</h1>
      <p className="mb-4 text-sm text-neutral-500">
        Open driver-raised incidents (SOS, breakdown, traffic, diversions, accidents) from{' '}
        <code>alerts</code> — refreshes every 10s.
      </p>

      {error && <p className="mb-3 text-sm text-red-600">{error}</p>}

      {loading ? (
        <p className="text-sm text-neutral-500">Loading…</p>
      ) : alerts.length === 0 ? (
        <p className="text-sm text-neutral-500">No open alerts.</p>
      ) : (
        <ul>
          {alerts.map((a) => (
            <AlertRow key={a.alertId} alert={a} onResolve={resolve} />
          ))}
        </ul>
      )}
    </div>
  )
}
