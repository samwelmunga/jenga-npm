# Summary: E16_S02_T01 & E16_S02_T02 — Copilot Config Scaffold

## T01 — Create Copilot instructions template

**File created:** `templates/copilot-instructions.md.tpl`

The template is a professional Copilot system prompt that includes:
- `<!-- JENGA:START -->` / `<!-- JENGA:END -->` markers for idempotent updates
- A concise description of the Jenga agent framework
- Skill invocation instructions (`/skill-name` syntax)
- `{{SKILL_LIST}}` placeholder replaced at init time with actual skill names and descriptions
- A routing decision table (skill match → invoke skill; free-form → answer directly)
- A note that `JENGA_PROJECT_DIR` is the canonical project directory env var

## T02 — Update jenga init to scaffold Copilot config

**File edited:** `lib/commands/init.js`

Changes:
- Added `mkdirSync` and `readdirSync` to the `fs` import
- After the `injectSettings` block, added a new try/catch that:
  1. Reads `templates/copilot-instructions.md.tpl`
  2. Dynamically discovers skills from `config.skillsPath` — reads `SKILL.md` frontmatter `description:` field per skill directory
  3. Replaces `{{SKILL_LIST}}` with the generated Markdown bullet list
  4. Writes `.github/copilot-instructions.md`:
     - **Fresh project**: creates `.github/` if needed, writes the full rendered template
     - **Re-run**: replaces only the `<!-- JENGA:START -->...<!-- JENGA:END -->` block; all content outside markers is preserved
  5. Falls back gracefully with a console warning if the template is missing or any error occurs
  6. Logs `✓ .github/copilot-instructions.md written` on success

## Verification
- `node --input-type=module` import test confirms no syntax errors in `init.js`
- Template is valid Markdown with all required elements
