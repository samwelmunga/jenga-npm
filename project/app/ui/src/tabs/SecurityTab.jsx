import { useEffect, useState } from 'react'
import { get } from '../api/client'
import LoadingSpinner from '../components/LoadingSpinner'
import ErrorMessage from '../components/ErrorMessage'
import AuditsPanel from '../components/security/AuditsPanel'
import FindingsTable from '../components/security/FindingsTable'
import './security-tab.css'

/**
 * SecurityTab — E85_S03_T04 (shell).
 *
 * Fetches the security aggregate from `GET /v1/security` on mount (through `src/api/client.js`'s
 * `get()` only, so the embedded-snapshot branch works unchanged) and holds it in `data` state.
 * Follows `RapportsTab.jsx`'s loading/error/fetch-on-mount pattern.
 *
 * The tab lays out two labelled sections, each a placeholder container with a stable class, id and
 * `data-testid`, which later tasks fill from `data`:
 *   - "Dependency audits"            -> `#security-dependency-audits`  (E85_S03_T05)
 *   - "Credential access findings"   -> `#security-credential-findings` (E85_S03_T06)
 */
export default function SecurityTab() {
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)
  const [data, setData] = useState(null)

  useEffect(() => {
    setLoading(true)
    setError(null)
    get('/v1/security')
      .then(result => setData(result || null))
      .catch(err => setError(err))
      .finally(() => setLoading(false))
  }, [])

  return (
    <div className="security-tab">
      <h2>Security</h2>
      {loading && <LoadingSpinner />}
      {error && <ErrorMessage error={error} />}
      {!loading && !error && (
        <>
          <section
            id="security-dependency-audits"
            className="security-section security-dependency-audits"
            data-testid="security-dependency-audits"
            aria-labelledby="security-dependency-audits-heading"
          >
            <h3 id="security-dependency-audits-heading" className="security-section-heading">
              Dependency audits
            </h3>
            <div className="security-section-body" data-has-data={data ? 'true' : 'false'}>
              <AuditsPanel audits={data?.audits} />
            </div>
          </section>
          <section
            id="security-credential-findings"
            className="security-section security-credential-findings"
            data-testid="security-credential-findings"
            aria-labelledby="security-credential-findings-heading"
          >
            <h3 id="security-credential-findings-heading" className="security-section-heading">
              Credential access findings
            </h3>
            <div className="security-section-body" data-has-data={data ? 'true' : 'false'}>
              <FindingsTable data={data?.credential_findings} />
            </div>
          </section>
        </>
      )}
    </div>
  )
}
