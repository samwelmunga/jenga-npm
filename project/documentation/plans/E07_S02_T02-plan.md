# Plan: E07_S02_T02 — Markdown-to-HTML Rendering for Rapport Content

## Approach
Use `marked` library for markdown parsing + `DOMPurify` for XSS sanitisation.

## Steps
1. `npm install --prefix dashboard marked dompurify`
2. In `EntryDetailPanel.jsx`, import `{ marked }` from `marked` and `DOMPurify` from `dompurify`
3. For rapport entries: `const html = DOMPurify.sanitize(marked.parse(content_summary || ''))`
4. Render via `<div className="markdown-body" dangerouslySetInnerHTML={{ __html: html }} />`
5. Add CSS for `.markdown-body`: headings, paragraphs, code blocks, pre, blockquote
