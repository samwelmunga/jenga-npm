# Execution Plan: Update validate_config.sh for npm target structure

**Task ID:** E26_S06_T04
**Story ID:** E26_S06
**Epic ID:** E26
**Date:** 2026-08-01 (UTC)
**Agent:** developer
**Session ID:** dev-E26_S06_T04-20260801T000000Z

---

## Task Summary
Extend `skills/publish/scripts/validate_config.sh` so that targets with `type: "npm"` are validated against their required fields (`npm.package_name` non-empty, `npm.access` in `{"public","restricted"}`). The absence of an `ios` block on an npm target must not cause a validation error. iOS validation must remain byte-for-byte equivalent for existing iOS targets, and the script must continue to pass `shellcheck`.

---

## Implementation Approach

The current script uses a single `jq` program to walk `$cfg.targets[]` and runs `target_valid` (which itself asserts `type == "mobile-ios"` and requires `ios` block). This is too narrow — an npm target would be reported as `"invalid target: <name>"` with no diagnostic detail.

Refactor the jq program so that:

1. Define a new `npm_valid` predicate matching the `npmSettings` definition in `publish.schema.json`:
   - `.package_name` present, non-empty string, matches npm name pattern (`^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$`, length ≤ 214)
   - `.access` string equal to `"public"` or `"restricted"`
   - Optional `.registry` (string, non-empty) — validated only if present
   - Optional `.dist_tag` (string matching `^[a-z0-9][a-z0-9._-]*$`) — validated only if present
2. Define an `npm_secrets_valid` predicate matching `npmSecretMap`: object where at least one of `NPM_TOKEN` or `NODE_AUTH_TOKEN` is present and is an env var ref.
3. Split `target_valid` into two branches keyed on `.type`:
   - `type == "mobile-ios"` → existing rules (unchanged): `platform == "ios-app-store"`, `secrets` matches iOS `secrets_valid`, `.ios` matches `ios_valid`.
   - `type == "npm"` → `platform` in `{"npm-registry","github-packages"}`, `.secrets` matches `npm_secrets_valid`, `.npm` matches `npm_valid`, `.ios` MUST NOT be present.
   - Any other `type` → invalid.
4. Change the per-target error emission so that when a target fails, we emit a more descriptive line if possible. Approach: keep the existing single-error-per-target shape (`"invalid target: <name>"`) but add a second pass that walks each target and emits granular field-level messages when the coarse `target_valid` check fails. This gives testers actionable output like `"target 'npm-registry': npm.package_name is required and must be non-empty"`.
5. Keep everything else (root schema draft check, `defaults.*` checks, non-empty targets array, etc.) unchanged.
6. Preserve exit code contract: any validation failure → exit `4`.
7. Run `shellcheck skills/publish/scripts/validate_config.sh` and fix any warnings introduced (there should be none — changes are entirely inside a jq heredoc-like string).

### jq design detail

The npm predicate mirrors the schema draft-07 conditional (`if type == "npm" then required: ["npm"], not: {required: ["ios"]}` etc.). Written in jq:

```jq
def npm_valid:
  type == "object"
  and (.package_name? | non_empty_string)
  and (.package_name? | test("^(?:@[a-z0-9][a-z0-9._-]*\\/)?[a-z0-9][a-z0-9._-]*$"))
  and ((.package_name? | length) <= 214)
  and (((.access? // "") == "public") or ((.access? // "") == "restricted"))
  and ((.registry? == null) or (.registry | non_empty_string))
  and ((.dist_tag? == null) or (.dist_tag | type == "string" and test("^[a-z0-9][a-z0-9._-]*$")));

def npm_secrets_valid:
  type == "object"
  and (
    ((.NPM_TOKEN? // null) != null and (.NPM_TOKEN | env_ref))
    or ((.NODE_AUTH_TOKEN? // null) != null and (.NODE_AUTH_TOKEN | env_ref))
  );

def target_valid:
  type == "object"
  and (.name? | type == "string" and test("^[a-z0-9][a-z0-9-]*$"))
  and (.checks? | checks_valid)
  and (
    (
      .type? == "mobile-ios"
      and .platform? == "ios-app-store"
      and (.secrets? | secrets_valid)
      and (.ios? | ios_valid)
    )
    or (
      .type? == "npm"
      and (((.platform? // "") == "npm-registry") or ((.platform? // "") == "github-packages"))
      and (.secrets? | npm_secrets_valid)
      and (.npm? | npm_valid)
      and ((.ios? // null) == null)
    )
  );
```

For granular error emission, add a follow-up per-target diagnostic block:

```jq
def target_diagnostics:
  . as $t
  | (if ($t.type? != "mobile-ios" and $t.type? != "npm") then ("target '" + ($t.name? // "<unnamed>") + "': type must be 'mobile-ios' or 'npm'") else empty end),
    (if $t.type? == "npm" then
       (if ($t.npm? | type) != "object" then ("target '" + ($t.name? // "<unnamed>") + "': npm block is required for npm targets") else empty end),
       (if (($t.npm?.package_name? // "") | non_empty_string | not) then ("target '" + ($t.name? // "<unnamed>") + "': npm.package_name is required and must be non-empty") else empty end),
       (if ((($t.npm?.access? // "") == "public") or (($t.npm?.access? // "") == "restricted") | not) then ("target '" + ($t.name? // "<unnamed>") + "': npm.access must be 'public' or 'restricted'") else empty end),
       (if (($t.ios? // null) != null) then ("target '" + ($t.name? // "<unnamed>") + "': ios block is not allowed on npm targets") else empty end)
     else empty end)
```

Only emit granular messages for targets that fail `target_valid`; otherwise fall back to the existing `"invalid target: <name>"` for iOS mismatches (kept for zero-regression on the iOS path).

---

## Files to Change

| File | Planned Change |
|------|----------------|
| `skills/publish/scripts/validate_config.sh` | Add `npm_valid` + `npm_secrets_valid` jq predicates; expand `target_valid` to branch on `.type`; add granular npm diagnostics. iOS branch untouched. |

---

## Dependencies & Risks

- Depends on `publish.schema.json` shape from E26_S03 (already merged) — verified above.
- Risk: subtle change to `target_valid` could re-break an existing iOS target. Mitigation: keep the iOS clause structurally identical, verify against `skills/publish/assets/publish.example.json` (two iOS targets) manually via `bash validate_config.sh <example>`.
- Risk: `shellcheck` warnings from the multi-line jq string are unlikely (existing script already contains a large jq heredoc-style block and passes). Will run shellcheck as final gate.
- No secrets or credentials involved.

---

## Notes

- Not modifying any other publish script per task instruction.
- Exit code contract preserved: `EXIT_CONFIG_INVALID=4` for any config/schema failure.
- iOS `secrets_valid` and `ios_valid` predicates are kept verbatim.
- `additionalProperties: false` behavior from the JSON schema is NOT enforced by this shell validator (it never was for iOS); tightening this is out of scope for T04.
