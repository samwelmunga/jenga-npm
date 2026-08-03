---
id: E05_S01_T02
story_id: E05_S01
epic_id: E05
title: Define Response Envelope and Error Types
status: Done
date_created: 2026-05-05
date_started: 2026-05-05
date_completed: 2026-05-05
assigned_to: developer
---

# Task: Define Response Envelope and Error Types

## Description
Create shared TypeScript/JS type definitions (or JSDoc typedefs if the project is plain JS) for the standard response envelope and error shape defined in the API contract document. These types must be importable by all endpoint handlers to enforce consistency at the code level.

Types to define:
- `ApiEnvelope<T>` — `{ data: T | null, meta: Meta, error: ApiError | null }`
- `Meta` — `{ timestamp: string, version: string }`
- `ApiError` — `{ code: string, message: string, details?: string[] }`
- Helper factory functions: `successResponse(data, meta)` and `errorResponse(code, message, details?)`

Place types in `api/types.js` (or `.ts`) and helpers in `api/response.js`.

## Prerequisites
- E05_S01_T01 (API contract document) must be written first so types match the spec

## Acceptance Criteria
- [ ] `ApiEnvelope`, `Meta`, and `ApiError` types are defined and exported
- [ ] `successResponse` helper wraps data in the envelope correctly
- [ ] `errorResponse` helper wraps error in the envelope correctly
- [ ] Both helpers are importable from a single module path
- [ ] All fields match the shapes documented in `docs/api-contract.md`
