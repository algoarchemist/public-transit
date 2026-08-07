import { PageHeader } from '../components/ui/PageHeader'
import { Card, CardBody, CardHeader, CardTitle } from '../components/ui/Card'
import { EmptyState } from '../components/ui/EmptyState'
import { BarsPreview } from '../components/ui/ChartPreview'
import { GaugeIcon } from '../components/ui/icons'

export default function DemandSupplyPlanning() {
  return (
    <div className="p-6">
      <PageHeader
        title="Demand-Supply Planning"
        description="Overlays predicted demand (crowd model) against current fleet allocation per route and surfaces over/under-supply windows."
      />

      <EmptyState
        icon={GaugeIcon}
        title="Not wired up yet"
        description="This page will combine ml-service crowd predictions with api-gateway fleet allocation data once both are available. The layout below is a preview."
      />

      <div className="mt-6 grid grid-cols-1 gap-4 opacity-60 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>Predicted demand vs allocated fleet</CardTitle>
          </CardHeader>
          <CardBody>
            <BarsPreview />
          </CardBody>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Under/over-supply windows</CardTitle>
          </CardHeader>
          <CardBody>
            <BarsPreview />
          </CardBody>
        </Card>
      </div>
    </div>
  )
}
