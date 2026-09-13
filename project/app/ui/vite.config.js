import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

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
export default defineConfig({
  plugins: [react()],
})
