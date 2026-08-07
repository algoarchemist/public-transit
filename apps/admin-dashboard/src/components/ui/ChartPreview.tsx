const BAR_HEIGHTS = [40, 65, 50, 80, 55, 70, 45, 60, 90, 50, 35, 75]

export function BarsPreview() {
  return (
    <div className="flex h-32 items-end gap-2">
      {BAR_HEIGHTS.map((h, i) => (
        <div key={i} className="flex-1 rounded-t-md bg-card-nested" style={{ height: `${h}%` }} />
      ))}
    </div>
  )
}

const LINE_POINTS = '0,55 10,40 20,48 30,25 40,35 50,20 60,30 70,15 80,28 90,18 100,22'

export function LinePreview() {
  return (
    <svg viewBox="0 0 100 60" preserveAspectRatio="none" className="h-32 w-full text-border">
      <polyline points={LINE_POINTS} fill="none" stroke="currentColor" strokeWidth="2.5" vectorEffect="non-scaling-stroke" />
    </svg>
  )
}
