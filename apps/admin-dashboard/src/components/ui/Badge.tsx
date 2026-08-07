import type { HTMLAttributes } from 'react'

interface BadgeProps extends HTMLAttributes<HTMLSpanElement> {
  tone?: 'neutral' | 'primary' | 'crowded' | 'estimated' | 'live'
  dot?: boolean
}

const TONE: Record<NonNullable<BadgeProps['tone']>, string> = {
  neutral: 'bg-stale/12 text-stale',
  primary: 'bg-primary-wash text-primary',
  crowded: 'bg-crowded/12 text-crowded',
  estimated: 'bg-estimated/12 text-estimated',
  live: 'bg-live/12 text-live',
}

const DOT: Record<NonNullable<BadgeProps['tone']>, string> = {
  neutral: 'bg-stale',
  primary: 'bg-primary',
  crowded: 'bg-crowded',
  estimated: 'bg-estimated',
  live: 'bg-live',
}

export function Badge({ tone = 'neutral', dot = false, className = '', children, ...props }: BadgeProps) {
  return (
    <span
      className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-[11px] font-semibold ${TONE[tone]} ${className}`}
      {...props}
    >
      {dot && <span className={`h-1.5 w-1.5 shrink-0 rounded-full ${DOT[tone]}`} />}
      {children}
    </span>
  )
}
