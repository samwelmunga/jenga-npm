import { useState } from 'react'
import BoardTab from './tabs/BoardTab'
import ActiveSprintTab from './tabs/ActiveSprintTab'
import HistoryTab from './tabs/HistoryTab'
import ArchitectureTab from './tabs/ArchitectureTab'
import './App.css'

const TABS = [
  { id: 'board', label: 'Backlog' },
  { id: 'active-sprint', label: 'Active Sprint' },
  { id: 'history', label: 'History' },
  { id: 'architecture', label: 'Architecture' },
]

export default function App() {
  const [activeTab, setActiveTab] = useState('board')

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
      </div>
    </div>
  )
}
