import { useEffect, useState } from 'react'
import { NavLink, Outlet, useLocation } from 'react-router'
import {
  MapPinIcon,
  RouteIcon,
  UsersIcon,
  GaugeIcon,
  BellIcon,
  ActivityIcon,
} from './ui/icons'

const links = [
  { to: '/', label: 'Live Fleet Map', icon: MapPinIcon },
  { to: '/route-performance', label: 'Route Performance', icon: RouteIcon },
  { to: '/passenger-load', label: 'Passenger Load', icon: UsersIcon },
  { to: '/demand-supply', label: 'Demand-Supply', icon: GaugeIcon },
  { to: '/alerts', label: 'Alerts & SOS', icon: BellIcon },
  { to: '/model-health', label: 'Model Health', icon: ActivityIcon },
]

function useClock() {
  const [now, setNow] = useState(() => new Date())
  useEffect(() => {
    const id = setInterval(() => setNow(new Date()), 1000)
    return () => clearInterval(id)
  }, [])
  return now
}

export default function Layout() {
  const location = useLocation()
  const now = useClock()
  const active = links.find((l) => (l.to === '/' ? location.pathname === '/' : location.pathname.startsWith(l.to)))

  return (
    <div className="flex min-h-screen bg-background">
      <nav className="flex w-60 shrink-0 flex-col border-r border-border bg-card">
        <div className="flex items-center gap-2.5 px-5 py-5">
          <div className="flex h-9 w-9 items-center justify-center rounded-nested bg-primary text-sm font-bold text-primary-foreground">
            S
          </div>
          <div>
            <div className="text-sm font-bold tracking-tight text-foreground">SetuTrack</div>
            <div className="text-[11px] font-medium text-muted-foreground">Operations Admin</div>
          </div>
        </div>

        <ul className="flex-1 space-y-1 px-3">
          {links.map((l) => (
            <li key={l.to}>
              <NavLink
                to={l.to}
                end={l.to === '/'}
                className={({ isActive }) =>
                  `flex items-center gap-2.5 rounded-full px-3.5 py-2.5 text-sm font-semibold transition-colors ${
                    isActive
                      ? 'bg-primary text-primary-foreground'
                      : 'text-muted-foreground hover:bg-card-nested hover:text-foreground'
                  }`
                }
              >
                <l.icon className="h-[18px] w-[18px] shrink-0" />
                {l.label}
              </NavLink>
            </li>
          ))}
        </ul>

        <div className="border-t border-border px-5 py-4 text-[11px] font-medium text-muted-foreground">
          Mohali Tricity Network
        </div>
      </nav>

      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-14 shrink-0 items-center justify-between border-b border-border bg-card px-6">
          <div className="text-[15px] font-semibold text-foreground">{active?.label ?? 'Dashboard'}</div>
          <div className="text-xs font-medium tabular-nums text-muted-foreground">
            {now.toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' })}
            {'  '}
            {now.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit', second: '2-digit' })}
          </div>
        </header>

        <main className="min-w-0 flex-1 overflow-y-auto">
          <Outlet />
        </main>
      </div>
    </div>
  )
}
