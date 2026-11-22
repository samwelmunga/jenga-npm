# Fixture for tests/task-usage-cost-worked-example.bats (E90_S01_T10)

Synthetic transcripts that reproduce the "Worked example" section of `project/documentation/task-usage.md`: three tasks
(`E9_S02_T01`, `E9_S02_T02`, `E10_S01_T01`) in two stories and one main-session overhead entry, all on the model
`fixture-priced`. `ratios.json` is the ratio config (the test points `JENGA_PRICE_RATIOS_FILE` at it, so the real,
re-datable config is never read). Run: `scripts/task-usage.sh --report --allocate --projects-dir
tests/fixtures/task-usage-cost/projects --project-dir /fixture/proj`.
