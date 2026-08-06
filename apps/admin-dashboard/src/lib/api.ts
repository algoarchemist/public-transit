import axios from 'axios'

export const api = axios.create({
  baseURL: import.meta.env.VITE_API_BASE_URL ?? '/api',
})

// socket.io-client does its own transport negotiation (polling -> websocket) from an
// http(s):// base URL, not a ws:// one — see src/lib/socket.ts.
export const REALTIME_WS_URL =
  import.meta.env.VITE_REALTIME_WS_URL ?? 'http://localhost:4001'
