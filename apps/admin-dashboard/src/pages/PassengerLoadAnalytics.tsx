import { PageHeader } from '../components/ui/PageHeader'
import { Card, CardBody, CardHeader, CardTitle } from '../components/ui/Card'
import { EmptyState } from '../components/ui/EmptyState'
import { BarsPreview, LinePreview } from '../components/ui/ChartPreview'
import { UsersIcon } from '../components/ui/icons'

export default function PassengerLoadAnalytics() {
  return (
    <div className="p-6">
      <PageHeader
        title="Passenger Load Analytics"
        description="Ridership by route/stop/hour, weekday vs weekend curves, and ticket-revenue vs ridership correlation."
      />

      <EmptyState
        icon={UsersIcon}
        title="Not wired up yet"
        description="This page will read from api-gateway's ridership analytics endpoint once it exists. The layout below is a preview of what it'll look like."
      />

      <div className="mt-6 grid grid-cols-1 gap-4 opacity-60 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Ridership by hour</CardTitle>
          </CardHeader>
          <CardBody>
            <BarsPreview />
          </CardBody>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Weekday vs weekend</CardTitle>
          </CardHeader>
          <CardBody>
            <LinePreview />
          </CardBody>
        </Card>
      </div>
    </div>
  )
}
