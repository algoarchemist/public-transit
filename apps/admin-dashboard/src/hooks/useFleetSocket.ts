import { useEffect, useState } from 'react'
import type { BusState } from '@setutrack/shared-types'
import { socket } from '../lib/socket'

// The gateway auto-joins every socket to the admin:fleet room on connect (see
// gateway.ts) — no subscribe:* emit needed here, this hook only listens.
export function useFleetSocket() {
  const [buses, setBuses] = useState<Map<string, BusState>>(new Map())
  const [connected, setConnected] = useState(false)

  useEffect(() => {
    const onConnect = () => setConnected(true)
    const onDisconnect = () => setConnected(false)
    const onUpdate = (state: BusState) => {
      setBuses((prev) => {
        const next = new Map(prev)
        next.set(state.busId, state)
        return next
      })
    }

    socket.on('connect', onConnect)
    socket.on('disconnect', onDisconnect)
    socket.on('bus:update', onUpdate)
    socket.connect()

    return () => {
      socket.off('connect', onConnect)
      socket.off('disconnect', onDisconnect)
      socket.off('bus:update', onUpdate)
      socket.disconnect()
    }
  }, [])

  return { buses, connected }
}
