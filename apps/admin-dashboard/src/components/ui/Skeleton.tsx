export function Skeleton({ className = '' }: { className?: string }) {
  return <div className={`animate-pulse rounded-nested bg-foreground/6 ${className}`} />
}
