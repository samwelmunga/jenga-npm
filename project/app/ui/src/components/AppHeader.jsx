import logo from '../assets/jenga-logo.png'
import './app-header.css'

// E47_S09_T02 - persistent dashboard header: Jenga logo (a button that opens the Backlog) and the
// project title. vite.config.js raises build.assetsInlineLimit so the PNG is embedded as a data: URI in the JS bundle, so the
// single-file `--snapshot` export renders it from file:// with no network request.
export default function AppHeader({ title, onHome }) {
  return (
    <div className="app-title-bar">
      <button type="button" className="app-logo-btn" onClick={onHome} aria-label="Jenga AI - open Backlog">
        <img className="app-logo" src={logo} alt="Jenga AI" width="104" height="32" />
      </button>
      <h1 className="app-title">{title}</h1>
    </div>
  )
}
