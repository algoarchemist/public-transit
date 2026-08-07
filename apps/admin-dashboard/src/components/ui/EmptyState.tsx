import type { ComponentType, ReactNode, SVGProps } from 'react'

interface EmptyStateProps {
  icon: ComponentType<SVGProps<SVGSVGElement>>
  title: string
  description?: string
  children?: ReactNode
  bare?: boolean
}

export function EmptyState({ icon: Icon, title, description, children, bare = false }: EmptyStateProps) {
  return (
    <div
      className={`flex flex-col items-center justify-center px-6 py-14 text-center ${
        bare ? '' : 'rounded-card bg-card shadow-card'
      }`}
    >
      <div className="flex h-14 w-14 items-center justify-center rounded-full bg-primary-wash text-primary">
        <Icon className="h-6 w-6" />
      </div>
      <h3 className="mt-4 text-[15px] font-semibold text-foreground">{title}</h3>
      {description && <p className="mt-1.5 max-w-sm text-sm text-muted-foreground">{description}</p>}
      {children && <div className="mt-5">{children}</div>}
    </div>
  )
}
