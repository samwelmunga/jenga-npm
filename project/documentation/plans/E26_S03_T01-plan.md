# Execution Plan: Restructure publish.schema.json for conditional type validation

**Task ID:** E26_S03_T01
**Story ID:** E26_S03
**Epic ID:** E26
**Date:** 2026-07-31 (UTC)
**Agent:** developer
**Session ID:** dev-E26_S03_T01-20260731T132429Z

---

## Task Summary
Refactor `skills/publish/schemas/publish.schema.json` so that a single `target` entry can be one of several types (`mobile-ios` today, `npm` for the follow-up task). The schema must:

- Add `"npm"` to the `type` enum and `"npm-registry"` + `"github-packages"` to the `platform` enum.
- Use JSON Schema draft-07 conditional validation (`allOf` + `if`/`then`/`else`) keyed on `type` so that:
  - iOS targets still require the `ios` block and the current iOS `secrets` shape.
  - npm targets do NOT require an `ios` block; instead they require `secrets.NPM_TOKEN`.
- Remain draft-07 compliant and continue validating the existing `publish.example.json` (iOS) file without modification.

T02 will fill in the concrete `npm` settings block (`package_name`, `access`, `registry`, `dist_tag`). This task only needs to leave a clean seam for that.

---

## Implementation Approach

1. Split `secretMap` into two named definitions: `iosSecretMap` (the current shape, renamed for clarity) and `npmSecretMap` (`NPM_TOKEN` required; `NODE_AUTH_TOKEN` allowed as an optional alias per the story text).
2. Introduce a placeholder `npmSettings` definition that is an open object (`type: "object"`, `additionalProperties: true`). This is the seam for T02 — T02 will replace this body with the real field definitions without needing to touch the `target` conditionals. A comment-style `description` field on the definition will call this out.
3. Rework `target` so that:
   - `required` is reduced to the fields common to every target type: `name`, `type`, `platform`, `checks`, `secrets`.
   - `properties.ios` and `properties.npm` are declared but not required at the top level.
   - `properties.type` enum becomes `["mobile-ios", "npm"]`.
   - `properties.platform` enum becomes `["ios-app-store", "npm-registry", "github-packages"]`.
   - `additionalProperties: false` is preserved.
   - An `allOf` block adds two `if`/`then` branches:
     - If `type === "mobile-ios"`: require `ios`, forbid `npm` (via `not: { required: ["npm"] }`), and constrain `platform` to `"ios-app-store"`, and constrain `secrets` to `iosSecretMap`.
     - If `type === "npm"`: require `npm`, forbid `ios`, constrain `platform` to `["npm-registry", "github-packages"]`, and constrain `secrets` to `npmSecretMap`.
4. Validate the schema is itself a valid draft-07 schema using Python's `jsonschema` (`Draft7Validator.check_schema`).
5. Validate the existing `publish.example.json` (iOS) still passes.
6. Sanity-check with two synthetic inline documents inside a Python one-liner:
   - A minimal `npm` target (no `ios` block, `secrets.NPM_TOKEN` set, `npm: {}`) — should validate.
   - A `mobile-ios` target missing the `ios` block — should fail.

---

## Files to Change

| File | Planned Change |
|------|----------------|
| `skills/publish/schemas/publish.schema.json` | Refactor: add `npm`/`npm-registry`/`github-packages` enums, split secret definitions, add `npmSettings` placeholder, add `allOf` conditional block on `target`. |

No other files change in this task.

---

## Dependencies & Risks

- **No external dependencies** — pure schema refactor.
- **Downstream coupling:** `skills/publish/scripts/validate_config.sh` and `check_target_config.sh` may key off `type`/`platform` enums. Refactor here does not narrow anything, only widens — so no regression risk. Any changes to those scripts belong to E26_S06.
- **Risk: over-constraining `secrets` in the conditional branch.** Using `properties.secrets: { $ref: "#/definitions/iosSecretMap" }` inside the `then` branch cleanly re-validates the whole `secrets` object against the iOS shape. This preserves the current behavior for iOS while allowing `npm` targets to use a different shape.
- **Risk: `additionalProperties: false` on `target` combined with `if/then` fields.** Adding `npm` and `ios` as declared properties on `target` (both optional at the top level) keeps `additionalProperties: false` satisfied.
- **T02 seam:** `npmSettings` is intentionally open (`additionalProperties: true`) so T02 can drop in the real definition (`package_name`, `access`, `registry`, `dist_tag`) without any structural change to `target`.

---

## Notes

- Draft-07 supports `if`/`then`/`else` natively — no draft bump needed.
- The story's DoD allows `NODE_AUTH_TOKEN` as an alternative to `NPM_TOKEN`. I will model this in `npmSecretMap` as `anyOf: [{ required: ["NPM_TOKEN"] }, { required: ["NODE_AUTH_TOKEN"] }]` so either satisfies the schema.
