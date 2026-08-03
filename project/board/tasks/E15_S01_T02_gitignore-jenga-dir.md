---
id: E15_S01_T02
story: E15_S01
title: Add .jenga/ to gitignore template in jenga init
status: Done
date_created: 2026-05-10
---

# Task: Add .jenga/ to gitignore template in jenga init

## What to do
In `lib/commands/init.js`, when writing or updating `.gitignore` in the project root, ensure `.jenga/` is included. The write should be idempotent — do not add a duplicate line if `.jenga/` is already present.
