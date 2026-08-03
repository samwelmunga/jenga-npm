# Plan: E08_S03_T04 — Integrate SADMap into ArchitectureTab

## Approach
Edit `project/app/ui/src/tabs/ArchitectureTab.jsx`:
1. Import `SADMap` from `../components/architecture/SADMap`
2. Add a new `<section className="arch-section">` after the Dependencies section
3. Render `<SADMap nodes={data.sad_map?.nodes} edges={data.sad_map?.edges} />`
4. Use optional chaining to handle cases where `sad_map` may be undefined
