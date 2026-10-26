import { useState, useEffect } from 'react'
import BoardTab from './tabs/BoardTab'
import ActiveSprintTab from './tabs/ActiveSprintTab'
import HistoryTab from './tabs/HistoryTab'
import ArchitectureTab from './tabs/ArchitectureTab'
import RapportsTab from './tabs/RapportsTab'
import DocumentationTab from './tabs/DocumentationTab'
import SecurityTab from './tabs/SecurityTab'
import AppHeader from './components/AppHeader'
import { dashboardTitle } from './projectTitle'
import ThemeToggle from './components/ThemeToggle'
import TodoWarningsBanner from './components/TodoWarningsBanner'
import LeaveGuardModal from './components/LeaveGuardModal'
import useLeaveGuard from './hooks/useLeaveGuard'
import { get } from './api/client'
import './App.css'

const TABS = [
  { id: 'board', label: 'Backlog' },
  { id: 'active-sprint', label: 'Active Sprint' },
  { id: 'history', label: 'History' },
  { id: 'architecture', label: 'Architecture' },
  { id: 'rapports', label: 'Rapports' },
  { id: 'documentation', label: 'Documentation' },
  { id: 'security', label: 'Security' },
]

export default function App() {
  const [activeTab, setActiveTab] = useState('board')
  // E47_S09 - resolved project name (null until /v1/health answers); `homeKey` remounts the tab content so
  // the logo always lands on a fresh Backlog landing view (no lingering in-tab selection).
  const [projectName, setProjectName] = useState(null)
  const [homeKey, setHomeKey] = useState(0)
  const title = dashboardTitle(projectName)
  // E47_S08_T02 — confirm before browser Back leaves the dashboard (and native prompt on close/reload).
  const { confirming, stay, leave } = useLeaveGuard()

  // E47_S06_T01 / E47_S09 - fetch the serving project's name from `/v1/health` (resolved server-side:
  // strategy doc, README H1, git repo name, package.json - see api/lib/resolve-project-title.js). On failure
  // or a missing name, `dashboardTitle` yields index.html's static fallback, never "undefined".
  useEffect(() => {
    get('/v1/health')
      .then(data => {
        if (data && typeof data.projectName === 'string' && data.projectName.trim().length > 0) {
          setProjectName(data.projectName)
        }
      })
      .catch(() => {
        // Network/parse failure - keep the static fallback title.
      })
  }, [])

  useEffect(() => {
    document.title = title
  }, [title])

  // Logo -> Backlog. State only: no history.pushState, so the E47_S08 leave guard's sentinel is untouched.
  function goHome() {
    setActiveTab('board')
    setHomeKey(k => k + 1)
  }

  return (
    <div className="app">
      <AppHeader title={title} onHome={goHome} />
      <header className="app-header">
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
        <ThemeToggle />
      </header>
      <TodoWarningsBanner />
      <div className="tab-content" key={homeKey}>
        {activeTab === 'board' && <BoardTab />}
        {activeTab === 'active-sprint' && <ActiveSprintTab />}
        {activeTab === 'history' && <HistoryTab />}
        {activeTab === 'architecture' && <ArchitectureTab />}
        {activeTab === 'rapports' && <RapportsTab />}
        {activeTab === 'documentation' && <DocumentationTab />}
        {activeTab === 'security' && <SecurityTab />}
      </div>
      {confirming && <LeaveGuardModal onStay={stay} onLeave={leave} />}
    </div>
  )
}
