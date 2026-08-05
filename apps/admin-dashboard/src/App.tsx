import { BrowserRouter, Routes, Route } from 'react-router-dom'
import Layout from './components/Layout'
import LiveFleetMap from './pages/LiveFleetMap'
import RoutePerformance from './pages/RoutePerformance'
import PassengerLoadAnalytics from './pages/PassengerLoadAnalytics'
import DemandSupplyPlanning from './pages/DemandSupplyPlanning'
import AlertsPanel from './pages/AlertsPanel'
import ModelHealth from './pages/ModelHealth'

export default function App() {
  return (
    <BrowserRouter>
      <Routes>
        <Route element={<Layout />}>
          <Route index element={<LiveFleetMap />} />
          <Route path="route-performance" element={<RoutePerformance />} />
          <Route path="passenger-load" element={<PassengerLoadAnalytics />} />
          <Route path="demand-supply" element={<DemandSupplyPlanning />} />
          <Route path="alerts" element={<AlertsPanel />} />
          <Route path="model-health" element={<ModelHealth />} />
        </Route>
      </Routes>
    </BrowserRouter>
  )
}
