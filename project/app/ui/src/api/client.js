const API_BASE_URL = import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:3001'

async function request(path, options = {}) {
  const url = `${API_BASE_URL}${path}`
  const res = await fetch(url, options)
  const json = await res.json()
  if (!res.ok || json.error) {
    throw new Error(json.error ?? `HTTP ${res.status}`)
  }
  return json.data
}

export function get(path) {
  return request(path)
}

export default { get, request }
