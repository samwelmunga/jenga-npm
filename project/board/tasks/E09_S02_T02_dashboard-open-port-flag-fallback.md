---
id: E09_S02_T02
story_id: E09_S02
epic_id: E09
title: Add fallback URL-to-stdout behavior and --port flag support to dashboard open
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Add fallback URL-to-stdout behavior and --port flag support to dashboard open

## Description
Extend `jenga dashboard open` with a `--port` flag so the target URL can be customised (matching the convention from `jenga dashboard start`). Ensure the fallback path — printing the URL to stdout when no browser can be launched — works correctly on all supported platforms. The default port must match the default used by `jenga dashboard start`.

## Prerequisites
- E09_S02_T01 — base `dashboard open` command must be implemented

## Acceptance Criteria
- [ ] `--port <number>` flag is accepted; URL is constructed using that port
- [ ] Default port matches the default used by `jenga dashboard start`
- [ ] When browser launch is not possible (no `DISPLAY`, headless CI, etc.), URL is printed to stdout with a clear message
- [ ] `--port` flag is documented in the command's `--help` output
