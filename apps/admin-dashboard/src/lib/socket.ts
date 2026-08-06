import { io } from 'socket.io-client'
import { REALTIME_WS_URL } from './api'

// One shared instance — LiveFleetMap is the only consumer today, and a singleton
// avoids reconnect thrash if the page remounts (e.g. React StrictMode double-mount).
export const socket = io(REALTIME_WS_URL, { autoConnect: false })
