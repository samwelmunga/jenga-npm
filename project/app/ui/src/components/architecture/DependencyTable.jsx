import './architecture.css'

const TYPE_CONFIG = {
  runtime:       { label: 'runtime',  badgeClass: 'dep-runtime' },
  devDependency: { label: 'dev',      badgeClass: 'dep-dev' },
  peer:          { label: 'peer',     badgeClass: 'dep-peer' },
}

export default function DependencyTable({ dependencies }) {
  if (!dependencies || dependencies.length === 0) {
    return <p className="arch-empty">No dependency data available.</p>
  }

  return (
    <table className="dep-table">
      <thead>
        <tr>
          <th>Name</th>
          <th>Version</th>
          <th>Type</th>
        </tr>
      </thead>
      <tbody>
        {dependencies.map((dep, i) => {
          const cfg = TYPE_CONFIG[dep.type] || { label: dep.type || '—', badgeClass: '' }
          return (
            <tr key={dep.name || i}>
              <td className="dep-name">{dep.name}</td>
              <td className="dep-version">{dep.version || '—'}</td>
              <td>
                <span className={`dep-badge ${cfg.badgeClass}`}>{cfg.label}</span>
              </td>
            </tr>
          )
        })}
      </tbody>
    </table>
  )
}
