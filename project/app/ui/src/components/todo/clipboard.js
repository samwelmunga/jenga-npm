// E47_S10_T05 - copy text with navigator.clipboard, falling back to a hidden textarea and execCommand("copy").
// `env` is injectable for tests. Never throws; resolves { ok, method } with method 'clipboard' | 'fallback' | 'none'.
export async function copyText(text, env = {}) {
  const nav = 'navigator' in env ? env.navigator : (typeof navigator === 'undefined' ? undefined : navigator)
  const doc = 'document' in env ? env.document : (typeof document === 'undefined' ? undefined : document)
  if (nav && nav.clipboard && typeof nav.clipboard.writeText === 'function') {
    try { await nav.clipboard.writeText(text); return { ok: true, method: 'clipboard' } } catch { /* fall through */ }
  }
  if (doc && doc.body && typeof doc.createElement === 'function') {
    const area = doc.createElement('textarea')
    try {
      area.value = text
      area.setAttribute('readonly', '')
      area.style.position = 'fixed'
      area.style.opacity = '0'
      doc.body.appendChild(area)
      area.select()
      if (typeof doc.execCommand === 'function' && doc.execCommand('copy')) return { ok: true, method: 'fallback' }
    } catch { /* fall through */ } finally {
      try { doc.body.removeChild(area) } catch { /* already gone */ }
    }
  }
  return { ok: false, method: 'none' }
}
