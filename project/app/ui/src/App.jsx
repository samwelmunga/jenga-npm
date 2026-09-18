import { useState, useEffect } from 'react'
import BoardTab from './tabs/BoardTab'
import ActiveSprintTab from './tabs/ActiveSprintTab'
import HistoryTab from './tabs/HistoryTab'
import ArchitectureTab from './tabs/ArchitectureTab'
import RapportsTab from './tabs/RapportsTab'
import DocumentationTab from './tabs/DocumentationTab'
import { get } from './api/client'
import './App.css'

const TABS = [
  { id: 'board', label: 'Backlog' },
  { id: 'active-sprint', label: 'Active Sprint' },
  { id: 'history', label: 'History' },
  { id: 'architecture', label: 'Architecture' },
  { id: 'rapports', label: 'Rapports' },
  { id: 'documentation', label: 'Documentation' },
]

export default function App() {
  const [activeTab, setActiveTab] = useState('board')

  // E47_S06_T01 — set the browser tab title to the serving project's name once `/v1/health`
  // resolves, so multiple dashboards (or multiple tabs of the same one) are distinguishable.
  // `index.html`'s static "Jenga AI Dashboard" title stays as the pre-JS/no-name-available
  // fallback: if the request fails, or `projectName` is missing/null (e.g. the consuming
  // project's package.json is missing, unreadable, or has no `name` field — see
  // `project/app/api/routes/health.js`'s `resolveProjectName()`), the title is left untouched
  // rather than rendering something like "undefined's Dashboard".
  useEffect(() => {
    get('/v1/health')
      .then(data => {
        if (data && typeof data.projectName === 'string' && data.projectName.trim().length > 0) {
          document.title = `${data.projectName}'s Dashboard`
        }
      })
      .catch(() => {
        // Network/parse failure — keep index.html's static fallback title.
      })
  }, [])

  return (
    <div className="app">
      <nav className="tabs">
        {TABS.map(tab => (
          <button
            key={tab.id}
            className={`tab-btn${activeTab === tab.id ? ' active' : ''}`}
            onClick={() => setActiveTab(tab.id)}
          >
            {tab.label}
          </button>
        ))}
      </nav>
      <div className="tab-content">
        {activeTab === 'board' && <BoardTab />}
        {activeTab === 'active-sprint' && <ActiveSprintTab />}
        {activeTab === 'history' && <HistoryTab />}
        {activeTab === 'architecture' && <ArchitectureTab />}
        {activeTab === 'rapports' && <RapportsTab />}
        {activeTab === 'documentation' && <DocumentationTab />}
      </div>
    </div>
  )
}
