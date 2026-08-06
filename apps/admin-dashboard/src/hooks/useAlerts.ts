import { useCallback, useEffect, useRef, useState } from 'react'
import { api } from '../lib/api'

export interface AlertItem {
  alertId: number
  type: string
  busId: string | null
  tripId: number | null
  notes: string | null
  raisedAt: string
}

const POLL_MS = 10_000

// No "alerts" websocket room exists yet (gateway.ts only broadcasts bus:update) — the
// SOS/breakdown feed needs to feel current, so this polls GET /api/alerts on an
// interval rather than pretending to be push-based.
export function useAlerts() {
  const [alerts, setAlerts] = useState<AlertItem[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const timerRef = useRef<ReturnType<typeof setInterval> | undefined>(undefined)

  const fetchAlerts = useCallback(async () => {
    try {
      const res = await api.get<{ alerts: AlertItem[] }>('/alerts', { params: { limit: 50 } })
      setAlerts(res.data.alerts)
      setError(null)
    } catch {
      setError('Could not reach the alerts service')
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    fetchAlerts()
    timerRef.current = setInterval(fetchAlerts, POLL_MS)
    return () => clearInterval(timerRef.current)
  }, [fetchAlerts])

  const resolve = useCallback(async (alertId: number) => {
    // Optimistic: a driver's incident disappearing off the board should feel instant.
    // If the PATCH fails, the next poll tick brings it back.
    setAlerts((prev) => prev.filter((a) => a.alertId !== alertId))
    try {
      await api.patch(`/alerts/${alertId}/resolve`)
    } catch {
      fetchAlerts()
    }
  }, [fetchAlerts])

  return { alerts, loading, error, resolve }
}
