import type { SVGProps } from 'react'

type IconProps = SVGProps<SVGSVGElement>

const base = {
  viewBox: '0 0 24 24',
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.75,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
}

export function MapPinIcon(props: IconProps) {
  return (
    <svg {...base} {...props}>
      <path d="M20 10c0 5.5-8 12-8 12s-8-6.5-8-12a8 8 0 1 1 16 0Z" />
      <circle cx="12" cy="10" r="2.75" />
    </svg>
  )
}

export function RouteIcon(props: IconProps) {
  return (
    <svg {...base} {...props}>
      <circle cx="5" cy="6" r="2.25" />
      <circle cx="19" cy="18" r="2.25" />
      <path d="M5 8.25V13a4 4 0 0 0 4 4h6" />
      <path d="m12.5 14.5 2.5 2.5-2.5 2.5" />
    </svg>
  )
}

export function UsersIcon(props: IconProps) {
  return (
    <svg {...base} {...props}>
      <circle cx="9" cy="8" r="3.25" />
      <path d="M2.75 19.25c0-3.45 2.8-6 6.25-6s6.25 2.55 6.25 6" />
      <path d="M16 5.5c1.65.4 2.85 1.85 2.85 3.6 0 1.75-1.2 3.2-2.85 3.6" />
      <path d="M18.25 13.4c1.9.55 3.25 2.15 3.25 4.35" />
    </svg>
  )
}

export function GaugeIcon(props: IconProps) {
  return (
    <svg {...base} {...props}>
      <path d="M3.5 15a8.5 8.5 0 1 1 17 0" />
      <path d="M12 15 15.5 9" />
      <path d="M12 15h.01" />
    </svg>
  )
}

export function BellIcon(props: IconProps) {
  return (
    <svg {...base} {...props}>
      <path d="M6 9a6 6 0 1 1 12 0c0 3.4 1 5 1.75 6.25H4.25C5 14 6 12.4 6 9Z" />
      <path d="M9.75 18.5a2.25 2.25 0 0 0 4.5 0" />
    </svg>
  )
}

export function ActivityIcon(props: IconProps) {
  return (
    <svg {...base} {...props}>
      <path d="M3 12h4l2-7 4 14 2-7h6" />
    </svg>
  )
}

export function WifiIcon(props: IconProps) {
  return (
    <svg {...base} {...props}>
      <path d="M4 8.5a12 12 0 0 1 16 0" />
      <path d="M7 12a8 8 0 0 1 10 0" />
      <path d="M10 15.5a4 4 0 0 1 4 0" />
      <circle cx="12" cy="19" r="1" fill="currentColor" stroke="none" />
    </svg>
  )
}

export function WifiOffIcon(props: IconProps) {
  return (
    <svg {...base} {...props}>
      <path d="M4 8.5c1.6-1.35 3.5-2.2 5.5-2.55" />
      <path d="M14.5 6a12 12 0 0 1 5.5 2.5" />
      <path d="M7 12a8 8 0 0 1 4.5-2.15" />
      <path d="M14 10.8A8 8 0 0 1 17 12" />
      <path d="M10 15.5a4 4 0 0 1 4 0" />
      <circle cx="12" cy="19" r="1" fill="currentColor" stroke="none" />
      <path d="M2.5 3.5 21 22" />
    </svg>
  )
}

export function BusIcon(props: IconProps) {
  return (
    <svg {...base} {...props}>
      <rect x="3.5" y="4.5" width="17" height="12" rx="2.5" />
      <path d="M3.5 11h17" />
      <path d="M7 16v2.25" />
      <path d="M17 16v2.25" />
      <circle cx="7.25" cy="19" r="1" fill="currentColor" stroke="none" />
      <circle cx="16.75" cy="19" r="1" fill="currentColor" stroke="none" />
      <path d="M7 7.5h2.5M14.5 7.5H17" />
    </svg>
  )
}

export function ChartBarIcon(props: IconProps) {
  return (
    <svg {...base} {...props}>
      <path d="M4 20V10" />
      <path d="M12 20V4" />
      <path d="M20 20v-7" />
      <path d="M2.5 20h19" />
    </svg>
  )
}

export function LayersIcon(props: IconProps) {
  return (
    <svg {...base} {...props}>
      <path d="m12 3 8.5 4.5L12 12 3.5 7.5 12 3Z" />
      <path d="m3.5 12 8.5 4.5 8.5-4.5" />
      <path d="m3.5 16.5 8.5 4.5 8.5-4.5" />
    </svg>
  )
}

export function ClockIcon(props: IconProps) {
  return (
    <svg {...base} {...props}>
      <circle cx="12" cy="12" r="8.5" />
      <path d="M12 7.5V12l3 2" />
    </svg>
  )
}

export function CheckCircleIcon(props: IconProps) {
  return (
    <svg {...base} {...props}>
      <circle cx="12" cy="12" r="8.5" />
      <path d="m8.25 12.25 2.5 2.5 5-5.5" />
    </svg>
  )
}

export function ConstructionIcon(props: IconProps) {
  return (
    <svg {...base} {...props}>
      <path d="M3.5 20 12 5l8.5 15Z" />
      <path d="M8.5 16h7" />
      <path d="M12 9.5v3" />
      <circle cx="12" cy="16.5" r="0.5" fill="currentColor" stroke="none" />
    </svg>
  )
}
