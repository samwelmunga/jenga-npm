import fs from 'fs'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { viteSingleFile } from 'vite-plugin-singlefile'

// E47_S04_T03 — snapshot-mode-only plugin. Injects the JSON artifact captured by
// E47_S04_T02's capture-snapshot.js into the built HTML as an inline
// <script id="jenga-dashboard-data" type="application/json"> tag, which
// src/api/client.js's get() reads from instead of calling fetch() when present.
//
// Only registered when building with `--mode snapshot` (see the `build:snapshot` npm
// script and skills/j-dashboard/scripts/snapshot.sh) — never touches the normal
// `npm run dev` / `npm run build` (dashboard:start/open) path.
function injectSnapshotData() {
  return {
    name: 'jenga-inject-snapshot-data',
    transformIndexHtml(html) {
      const dataFile = process.env.SNAPSHOT_DATA_FILE
      if (!dataFile) {
        throw new Error(
          'jenga-inject-snapshot-data: SNAPSHOT_DATA_FILE env var is required when building with --mode snapshot'
        )
      }
      const raw = fs.readFileSync(dataFile, 'utf8')
      // Parse (not just read) so a malformed capture artifact fails the build loudly here,
      // rather than shipping a broken snapshot silently.
      const parsed = JSON.parse(raw)
      // Re-serialize from the parsed value (not the raw file bytes) and escape '<' so the
      // embedded JSON can never prematurely close the surrounding <script> tag.
      const serialized = JSON.stringify(parsed).replace(/</g, '\\u003c')
      const snippet = `<script id="jenga-dashboard-data" type="application/json">${serialized}</script>\n  </head>`
      // Use a replacer FUNCTION, not a plain string, for the second argument. String.replace
      // treats a string replacement's `$&`, `` $` ``, `$'`, `$$` sequences specially — and real
      // board/history content legitimately contains markdown code spans like `` `^[1-5]$` `` whose
      // closing "$`" is exactly the "insert everything before the match" pattern. With a string
      // replacement that reinserts the entire preceding document into itself. A function
      // replacer's return value is used verbatim, with no special-pattern interpretation, so this
      // is safe regardless of what characters the embedded snapshot data contains.
      return html.replace('</head>', () => snippet)
    },
  }
}

export default defineConfig(({ mode }) => ({
  plugins: [
    react(),
    ...(mode === 'snapshot' ? [injectSnapshotData(), viteSingleFile()] : []),
  ],
}))
