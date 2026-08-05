import { NavLink, Outlet } from 'react-router-dom'

const links = [
  { to: '/', label: 'Live Fleet Map' },
  { to: '/route-performance', label: 'Route Performance' },
  { to: '/passenger-load', label: 'Passenger Load' },
  { to: '/demand-supply', label: 'Demand-Supply' },
  { to: '/alerts', label: 'Alerts & SOS' },
  { to: '/model-health', label: 'Model Health' },
]

export default function Layout() {
  return (
    <div className="flex min-h-screen">
      <nav className="w-56 shrink-0 border-r border-neutral-200 dark:border-neutral-800 p-4">
        <div className="font-semibold mb-4">SetuTrack Admin</div>
        <ul className="space-y-1">
          {links.map((l) => (
            <li key={l.to}>
              <NavLink
                to={l.to}
                end={l.to === '/'}
                className={({ isActive }) =>
                  `block rounded px-2 py-1.5 text-sm ${
                    isActive
                      ? 'bg-neutral-900 text-white dark:bg-neutral-100 dark:text-black'
                      : 'hover:bg-neutral-100 dark:hover:bg-neutral-800'
                  }`
                }
              >
                {l.label}
              </NavLink>
            </li>
          ))}
        </ul>
      </nav>
      <main className="flex-1">
        <Outlet />
      </main>
    </div>
  )
}
