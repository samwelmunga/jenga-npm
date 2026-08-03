# Execution Plan: Add npm settings block and example config to schema

**Task ID:** E26_S03_T02
**Story ID:** E26_S03
**Epic ID:** E26
**Date:** 2026-07-31 (UTC)
**Agent:** developer
**Session ID:** dev-E26_S03_T02

---

## Task Summary
Replace the placeholder `definitions.npmSettings` open-object in `skills/publish/schemas/publish.schema.json` (added by T01) with the concrete field definitions for an npm publish target: `package_name`, `access`, `registry`, `dist_tag`. Then create `skills/publish/assets/publish.example.npm.json` — a valid, annotated example npm target configuration.

---

## Implementation Approach

1. Update `definitions.npmSettings` in `publish.schema.json`:
   - `type: "object"`, `additionalProperties: false`
   - `required: ["package_name", "access"]`
   - `package_name`: string, minLength 1, pattern permitting scoped names (`@scope/name`) and plain names
   - `access`: string enum `["public", "restricted"]`
   - `registry`: string, `format: uri`, default `"https://registry.npmjs.org"` (JSON Schema `default` is informational only)
   - `dist_tag`: string, default `"latest"`, minLength 1
   - Keep top-level `description` explaining the block

2. Create `skills/publish/assets/publish.example.npm.json` demonstrating a public npm registry publish:
   - version 1, standard defaults block
   - single target `type: "npm"`, `platform: "npm-registry"`
   - `secrets` containing `NPM_TOKEN` (satisfies T01 conditional `npmSecretMap`)
   - `npm` block with `package_name`, `access: "public"`, `registry`, `dist_tag: "latest"`
   - inline `notes` field explaining the file, and use of `$comment`-style clarifications where JSON allows (JSON does not permit comments — inline explanations will go into a `notes` field on the target plus a companion comment in the file via a top-level `_comment` key? No — root has `additionalProperties: false`, so use only the `notes` field on the target).
   - Since JSON does not permit true comments and the schema is strict, the primary annotation channel will be the `notes` field on the target. A brief companion note appended to `skills/publish/assets/secrets-guide.md` is out of scope; instead, keep a short human-readable explanation inside `notes`.

3. Validate:
   - Use `ajv` (via `npx ajv-cli`) to compile the schema and validate the new npm example, the iOS example, and two negative fixtures (missing `package_name`, missing `access`).

---

## Files to Change

| File | Planned Change |
|------|----------------|
| skills/publish/schemas/publish.schema.json | Replace `definitions.npmSettings` body with concrete field defs |
| skills/publish/assets/publish.example.npm.json | New file — valid npm example config |

---

## Dependencies & Risks

- Depends on E26_S03_T01 (branch `E26_S03_T01-schema-conditionals`, commit cc94c88). Worktree branched from that branch, not main.
- No external code dependencies beyond `ajv-cli` for local validation (`npx --yes ajv-cli`).
- Risk: JSON files cannot contain comments; annotations must live in the `notes` field or an accompanying markdown note. Mitigated by using `notes` on the target and clear field naming.

---

## Notes

- `additionalProperties: false` on `npmSettings` matches the surrounding schema style (`iosSettings` uses the same).
- `package_name` regex is intentionally permissive: covers scoped (`@scope/name`) and unscoped npm names per npm's naming rules (lowercase, url-safe, may start with `@`).
