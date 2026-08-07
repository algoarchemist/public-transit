import { useEffect, useState } from 'react'
import { Bar, BarChart, CartesianGrid, ResponsiveContainer, Tooltip, XAxis, YAxis } from 'recharts'
import { api } from '../lib/api'
import { PageHeader } from '../components/ui/PageHeader'
import { Card, CardBody, CardHeader, CardTitle } from '../components/ui/Card'
import { EmptyState } from '../components/ui/EmptyState'
import { Skeleton } from '../components/ui/Skeleton'
import { StatCard } from '../components/ui/StatCard'
import { UsersIcon, RouteIcon, ClockIcon } from '../components/ui/icons'

interface HourRow {
  hour: number
  boardings: number
  alightings: number
  events: number
}

interface DayTypeRow {
  dayType: string
  boardings: number
  alightings: number
}

interface RidershipResponse {
  byHour: HourRow[]
  byDayType: DayTypeRow[]
  sampleStopEvents: number
  source: string
}

export default function PassengerLoadAnalytics() {
  const [data, setData] = useState<RidershipResponse | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    api
      .get<RidershipResponse>('/admin/analytics/ridership')
      .then((res) => !cancelled && setData(res.data))
      .catch(() => !cancelled && setError('Could not reach the analytics service'))
      .finally(() => !cancelled && setLoading(false))
    return () => {
      cancelled = true
    }
  }, [])

  const totalBoardings = data?.byHour.reduce((sum, r) => sum + r.boardings, 0) ?? 0
  const totalAlightings = data?.byHour.reduce((sum, r) => sum + r.alightings, 0) ?? 0
  const busiestHour = data?.byHour.reduce<HourRow | null>(
    (max, r) => (!max || r.boardings > max.boardings ? r : max),
    null,
  )

  const hourChartData = (data?.byHour ?? []).map((r) => ({ ...r, label: `${r.hour}:00` }))

  return (
    <div className="p-6">
      <PageHeader
        title="Passenger Load Analytics"
        description="Ridership by hour and weekday vs. weekend, from real stop-event boarding/alighting counts."
      />

      {error && <div className="mb-4 rounded-nested bg-crowded/10 px-4 py-3 text-sm font-medium text-crowded">{error}</div>}

      {loading ? (
        <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <Skeleton className="h-24" />
          <Skeleton className="h-24" />
          <Skeleton className="h-24" />
        </div>
      ) : !data || data.sampleStopEvents === 0 ? (
        <EmptyState
          icon={UsersIcon}
          title="No stop events recorded yet"
          description="This fills in as buses complete real stop arrivals — see services/stream-processor's real-time persistence (docs §7.3)."
        />
      ) : (
        <>
          <div className="mb-6 grid grid-cols-1 gap-4 sm:grid-cols-3">
            <StatCard label="Total boardings" value={totalBoardings.toLocaleString()} icon={UsersIcon} tone="neutral" />
            <StatCard label="Total alightings" value={totalAlightings.toLocaleString()} icon={RouteIcon} tone="neutral" />
            <StatCard
              label="Busiest hour"
              value={busiestHour ? `${busiestHour.hour}:00` : '—'}
              hint={busiestHour ? `${busiestHour.boardings} boardings` : undefined}
              icon={ClockIcon}
              tone="neutral"
            />
          </div>

          <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
            <Card>
              <CardHeader>
                <CardTitle>Ridership by hour</CardTitle>
              </CardHeader>
              <CardBody>
                <div className="h-64">
                  <ResponsiveContainer width="100%" height="100%">
                    <BarChart data={hourChartData} margin={{ top: 8, right: 8, left: -16, bottom: 0 }}>
                      <CartesianGrid strokeDasharray="3 3" stroke="var(--color-border)" vertical={false} />
                      <XAxis dataKey="label" tick={{ fontSize: 11, fill: 'var(--color-muted-foreground)' }} axisLine={false} tickLine={false} interval={1} />
                      <YAxis tick={{ fontSize: 12, fill: 'var(--color-muted-foreground)' }} axisLine={false} tickLine={false} />
                      <Tooltip
                        contentStyle={{ background: 'var(--color-card)', border: '1px solid var(--color-border)', borderRadius: 12, fontSize: 12 }}
                        labelStyle={{ color: 'var(--color-foreground)', fontWeight: 600 }}
                      />
                      <Bar dataKey="boardings" name="Boardings" fill="var(--color-primary)" radius={[6, 6, 0, 0]} />
                    </BarChart>
                  </ResponsiveContainer>
                </div>
              </CardBody>
            </Card>

            <Card>
              <CardHeader>
                <CardTitle>Weekday vs. weekend</CardTitle>
              </CardHeader>
              <CardBody>
                {data.byDayType.length > 0 ? (
                  <div className="h-64">
                    <ResponsiveContainer width="100%" height="100%">
                      <BarChart data={data.byDayType} margin={{ top: 8, right: 8, left: -16, bottom: 0 }}>
                        <CartesianGrid strokeDasharray="3 3" stroke="var(--color-border)" vertical={false} />
                        <XAxis dataKey="dayType" tick={{ fontSize: 12, fill: 'var(--color-muted-foreground)' }} axisLine={false} tickLine={false} />
                        <YAxis tick={{ fontSize: 12, fill: 'var(--color-muted-foreground)' }} axisLine={false} tickLine={false} />
                        <Tooltip
                          contentStyle={{ background: 'var(--color-card)', border: '1px solid var(--color-border)', borderRadius: 12, fontSize: 12 }}
                          labelStyle={{ color: 'var(--color-foreground)', fontWeight: 600 }}
                        />
                        <Bar dataKey="boardings" name="Boardings" fill="var(--color-primary)" radius={[6, 6, 0, 0]} />
                      </BarChart>
                    </ResponsiveContainer>
                  </div>
                ) : (
                  <EmptyState bare icon={ClockIcon} title="Not enough spread yet" description="Needs stop events across more than one day type." />
                )}
              </CardBody>
            </Card>
          </div>

          <p className="mt-4 text-xs text-muted-foreground">{data.source} — {data.sampleStopEvents.toLocaleString()} stop events sampled.</p>
        </>
      )}
    </div>
  )
}
