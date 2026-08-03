# Plan: E08_S01_T02 — Tech Stack Cards and Dependency Version Table

## Approach
Create two display components for the architecture data.

## Steps
1. `TechStackGrid.jsx`: renders a CSS grid of cards, one per `tech_stack` item (name + optional description)
2. `DependencyTable.jsx`: renders a `<table>` with columns Name | Version | Type; Type uses a colour-coded badge
   - `runtime` → blue badge
   - `dev` → grey badge  
   - `peer` → green badge
3. Graceful empty states for each component
