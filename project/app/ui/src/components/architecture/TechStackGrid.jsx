import './architecture.css'

export default function TechStackGrid({ items }) {
  if (!items || items.length === 0) {
    return <p className="arch-empty">No tech stack data available.</p>
  }

  return (
    <div className="tech-grid">
      {items.map((item, i) => (
        <div key={item.name || i} className="tech-card">
          <span className="tech-name">{item.name}</span>
          {item.description && (
            <span className="tech-description">{item.description}</span>
          )}
        </div>
      ))}
    </div>
  )
}
