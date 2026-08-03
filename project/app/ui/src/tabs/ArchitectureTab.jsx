import { useEffect, useState } from 'react'
import { get } from '../api/client'
import LoadingSpinner from '../components/LoadingSpinner'
import ErrorMessage from '../components/ErrorMessage'
import TechStackGrid from '../components/architecture/TechStackGrid'
import DependencyTable from '../components/architecture/DependencyTable'
import SADMap from '../components/architecture/SADMap'

export default function ArchitectureTab() {
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [data, setData] = useState(null)

  useEffect(() => {
    setLoading(true)
    setError(null)
    get('/v1/architecture')
      .then(setData)
      .catch(setError)
      .finally(() => setLoading(false))
  }, [])

  return (
    <div className="architecture-tab">
      <h2>Architecture</h2>
      {loading && <LoadingSpinner />}
      {error && <ErrorMessage error={error} />}
      {!loading && !error && !data && (
        <p className="arch-empty">No architecture data available.</p>
      )}
      {!loading && !error && data && (
        <>
          <section className="arch-section">
            <h3>Tech Stack</h3>
            <TechStackGrid items={data.tech_stack} />
          </section>
          <section className="arch-section">
            <h3>Dependencies</h3>
            <DependencyTable dependencies={data.dependencies} />
          </section>
          <section className="arch-section">
            <h3>Architecture Map</h3>
            <SADMap nodes={data.sad_map?.nodes} edges={data.sad_map?.edges} />
          </section>
        </>
      )}
    </div>
  )
}
