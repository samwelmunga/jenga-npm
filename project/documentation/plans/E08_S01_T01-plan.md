# Plan: E08_S01_T01 — Architecture Tab Data Fetching and State Management

## Approach
Create `dashboard/src/tabs/ArchitectureTab.jsx` mirroring the HistoryTab pattern.

## Steps
1. Fetch `GET /architecture` on mount using shared API client
2. Manage `loading`, `error`, `data` state
3. Render `<LoadingSpinner>` while loading, `<ErrorMessage>` on error
4. Pass `data.tech_stack` to `<TechStackGrid>` and `data.dependencies` to `<DependencyTable>`
5. Handle null/empty data gracefully with "No architecture data available" message
