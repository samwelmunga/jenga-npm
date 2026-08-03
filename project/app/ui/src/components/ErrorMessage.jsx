import './components.css'

export default function ErrorMessage({ error }) {
  const message = error instanceof Error ? error.message : String(error ?? 'Unknown error')
  return <div className="error-message">⚠ {message}</div>
}
