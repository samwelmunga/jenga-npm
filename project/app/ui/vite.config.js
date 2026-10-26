import { createRequire } from 'node:module'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// E47_S08_T03 - the dev server binds a verified-free port (5173 first) and proxies /v1 to whichever port the
// API actually bound: JENGA_API_PORT, else the port the running dashboard recorded, else 3001. Start the API
// first. `vite --port <n>` still wins and, being strictPort, fails loudly when <n> is busy.
const require = createRequire(import.meta.url)
const here = path.dirname(fileURLToPath(import.meta.url))
const { findFreePort } = require(path.resolve(here, '../../../scripts/find-free-port.cjs'))
const portState = require(path.resolve(here, '../../../scripts/dashboard-port-state.cjs'))

function apiPort() {
  const env = parseInt(process.env.JENGA_API_PORT || '', 10)
  if (Number.isInteger(env)) return env
  try {
    const root = require(path.resolve(here, '../api/lib/resolve-project-root.js')).resolveProjectRoot()
    const state = portState.readState(root)
    if (state) return state.port
  } catch { /* not inside a Jenga project */ }
  return portState.DEFAULT_PORT
}

// Snapshot mode used to live here: a `--mode snapshot` build registered an
// inline-data plugin plus vite-plugin-singlefile to produce the single-file
// export behind `j.dashboard --snapshot`.
//
// That approach could only ever work inside this monorepo. The published
// tarball ships project/app/ui/dist/** and scripts/** and nothing else — no
// package.json, no vite.config.js, no src/ — so a consumer install had no vite
// to run and no sources to build, and `--snapshot` failed on every one of them.
//
// The single-file export is now produced by
// project/app/ui/scripts/build-snapshot-html.cjs, which inlines an already-built
// dist/ with zero dependencies and therefore runs identically here and in a
// consumer's node_modules. The runtime half never needed a special build mode
// in the first place: src/api/client.js reads an embedded
// <script id="jenga-dashboard-data"> tag whenever one is present, so the
// ordinary build below is already snapshot-capable.
export default defineConfig(async ({ command }) => ({
  plugins: [react()],
  // E47_S09_T02 - the header logo (~15 kB PNG) must be inlined as a data: URI so the single-file snapshot export
  // (build-snapshot-html.cjs, which only inlines the JS/CSS bundles) never references a separate image file.
  build: { assetsInlineLimit: 32 * 1024 },
  ...(command === 'serve'
    ? {
        server: {
          port: await findFreePort({ start: 5173 }),
          strictPort: true,
          proxy: { '/v1': { target: `http://localhost:${apiPort()}`, changeOrigin: true } },
        },
      }
    : {}),
}))
