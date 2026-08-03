---
id: E20_S06
epic_id: E20
title: DB Migration Job — Export Kuzu to External Database
status: Pending
date_created: 2026-07-10
date_started:
date_completed:
tasks: []
---

# Story: DB Migration Job — Export Kuzu to External Database

As a JengaAgent user, I want to be able to migrate my project's knowledge graph from the embedded Kuzu store to an external database so that I can leverage more powerful tooling, shared infrastructure, or persistent cross-session access.

## Acceptance Criteria
- [ ] `scripts/migrate-knowledge-graph-to-db.sh` exists and supports at minimum one external target: Neo4j (via Bolt) or PostgreSQL with Apache AGE or pgvector
- [ ] Migration script accepts `--target <neo4j|postgres>`, `--uri <connection-string>`, and `--dry-run` flags
- [ ] `--dry-run` prints a summary of nodes and edges that would be migrated without writing anything
- [ ] Migration is idempotent: re-running against the same external DB does not duplicate nodes/edges (upsert by stable ID)
- [ ] A `jobs/migrate-knowledge-graph/` job directory is scaffolded following the existing jobs pattern with `job.config.json` and `README.md`
- [ ] Migration job reads from Kuzu and writes to the external target using a documented, versioned export schema
- [ ] Post-migration validation confirms node/edge counts match between Kuzu and external DB
- [ ] Credentials are never hardcoded; the script reads from environment variables or a `.env` file that is gitignored

## Definition of Done
- [ ] `--dry-run` mode runs without error on a populated Kuzu instance and prints a meaningful summary
- [ ] Migration to Neo4j (or Postgres) completes and post-migration validation passes
- [ ] Re-running the migration produces no duplicates
- [ ] No credentials appear in any committed file
