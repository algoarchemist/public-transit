import type { HTMLAttributes } from 'react'

export function Card({ className = '', ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={`rounded-card bg-card shadow-card ${className}`} {...props} />
}

export function CardHeader({ className = '', ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={`flex items-center justify-between gap-3 px-5 pt-5 pb-3 ${className}`} {...props} />
}

export function CardTitle({ className = '', ...props }: HTMLAttributes<HTMLHeadingElement>) {
  return <h2 className={`text-[13px] font-semibold tracking-wide text-muted-foreground uppercase ${className}`} {...props} />
}

export function CardBody({ className = '', ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={`px-5 pb-5 ${className}`} {...props} />
}
