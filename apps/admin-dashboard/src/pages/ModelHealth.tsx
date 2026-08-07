import { PageHeader } from '../components/ui/PageHeader'
import { Card, CardBody, CardHeader, CardTitle } from '../components/ui/Card'
import { EmptyState } from '../components/ui/EmptyState'
import { LinePreview } from '../components/ui/ChartPreview'
import { ActivityIcon } from '../components/ui/icons'

export default function ModelHealth() {
  return (
    <div className="p-6">
      <PageHeader
        title="Model Health"
        description="ETA MAE trend and per-bus data-freshness (last-ping-age) indicators."
      />

      <EmptyState
        icon={ActivityIcon}
        title="Not wired up yet"
        description="This page will read from ml-service's /health/metrics endpoint once it exists. The layout below is a preview."
      />

      <div className="mt-6 grid grid-cols-1 gap-4 opacity-60 lg:grid-cols-2">
        <Card>
          <CardHeader>
            <CardTitle>ETA MAE trend</CardTitle>
          </CardHeader>
          <CardBody>
            <LinePreview />
          </CardBody>
        </Card>
        <Card>
          <CardHeader>
            <CardTitle>Data freshness by bus</CardTitle>
          </CardHeader>
          <CardBody>
            <LinePreview />
          </CardBody>
        </Card>
      </div>
    </div>
  )
}
