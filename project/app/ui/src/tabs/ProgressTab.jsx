import { useState, useEffect } from 'react'
import { get, isEmbeddedSnapshot } from '../api/client'
import LoadingSpinner from '../components/LoadingSpinner'
import ErrorMessage from '../components/ErrorMessage'
import ProgressView from '../components/progress/ProgressView'
import PipelineDiagram from '../components/progress/PipelineDiagram'

/**
 * Settles a GET into `{ data, error }` through `client.js`'s `get()` (so the embedded snapshot branch answers from
 * `routes.<key>` over file:// with no network call); it never rejects, so a failed fetch becomes an error state
 * instead of an unhandled rejection. `fetcher` is injectable for tests.
 */
function settle(path, fetcher) {
  return Promise.resolve()
    .then(() => fetcher(path))
    .then(
      data => ({ data, error: null }),
      error => ({ data: null, error }),
    )
}

/** `GET /v1/progress` (the four pies). */
export function loadProgress(fetcher = get) {
  return settle('/v1/progress', fetcher)
}

/** `GET /v1/pipeline` (the pipeline diagram, E92_S04). */
export function loadPipeline(fetcher = get) {
  return settle('/v1/pipeline', fetcher)
}

/** The three states of one section: shared spinner, shared error, or the section itself. */
function Section({ loading, error, children }) {
  if (loading) return <LoadingSpinner />
  if (error) return <ErrorMessage error={error} />
  return children
}

/**
 * The tab as a pure function of its state: the pies (`loading`, `error`, `data`) and, below them, the pipeline diagram
 * (`pipeline`: `{ loading, error, data }`). The two sections fail independently: a failed pipeline fetch shows an
 * ErrorMessage in the pipeline section only and leaves the pies; omitting `pipeline` omits the section.
 * `pointInTime` (true in a snapshot export) is handed to the diagram, which then says it is a point-in-time picture.
 */
export function ProgressTabBody({ loading, error, data, pipeline, pointInTime = false }) {
  return (
    <div className="progress-tab" data-testid="progress-tab">
      <Section loading={loading} error={error}>
        <ProgressView data={data} />
      </Section>
      {pipeline ? (
        <Section loading={pipeline.loading} error={pipeline.error}>
          <PipelineDiagram data={pipeline.data} pointInTime={pointInTime} />
        </Section>
      ) : null}
    </div>
  )
}

/**
 * ProgressTab — E92_S03_T06, extended by E92_S04_T05 with the pipeline diagram under the pies.
 */
export default function ProgressTab() {
  const [state, setState] = useState({ loading: true, error: null, data: null })
  const [pipeline, setPipeline] = useState({ loading: true, error: null, data: null })

  useEffect(() => {
    let live = true
    loadProgress().then(result => {
      if (live) setState({ loading: false, ...result })
    })
    loadPipeline().then(result => {
      if (live) setPipeline({ loading: false, ...result })
    })
    return () => { live = false }
  }, [])

  return <ProgressTabBody {...state} pipeline={pipeline} pointInTime={isEmbeddedSnapshot()} />
}
