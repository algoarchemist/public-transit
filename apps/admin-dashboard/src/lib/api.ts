import axios from 'axios'

export const api = axios.create({
  baseURL: import.meta.env.VITE_API_BASE_URL ?? '/api',
})

export const REALTIME_WS_URL =
  import.meta.env.VITE_REALTIME_WS_URL ?? 'ws://localhost:4001'
