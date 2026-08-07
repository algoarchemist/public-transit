import type { ComponentType, SVGProps } from 'react'
import { Card } from './Card'

interface StatCardProps {
  label: string
  value: string
  hint?: string
  icon: ComponentType<SVGProps<SVGSVGElement>>
  tone?: 'neutral' | 'good' | 'warn' | 'bad'
}

const TONE_ICON: Record<NonNullable<StatCardProps['tone']>, string> = {
  neutral: 'bg-primary-wash text-primary',
  good: 'bg-live/10 text-live',
  warn: 'bg-estimated/10 text-estimated',
  bad: 'bg-crowded/10 text-crowded',
}

export function StatCard({ label, value, hint, icon: Icon, tone = 'neutral' }: StatCardProps) {
  return (
    <Card className="flex items-start gap-4 p-4">
      <div className={`flex h-11 w-11 shrink-0 items-center justify-center rounded-nested ${TONE_ICON[tone]}`}>
        <Icon className="h-5 w-5" />
      </div>
      <div className="min-w-0">
        <div className="text-xs font-semibold text-muted-foreground">{label}</div>
        <div className="mt-0.5 text-2xl font-bold tracking-tight text-foreground">{value}</div>
        {hint && <div className="mt-0.5 truncate text-xs font-medium text-muted-foreground">{hint}</div>}
      </div>
    </Card>
  )
}
