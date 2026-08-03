# Plan: E16_S02_T01 & E16_S02_T02 — Copilot Config Scaffold

## Tasks Covered
- **T01**: Create `templates/copilot-instructions.md.tpl`
- **T02**: Extend `lib/commands/init.js` to generate `.github/copilot-instructions.md`

## Approach

### T01 — Template
Create a Markdown template with `<!-- JENGA:START -->` / `<!-- JENGA:END -->` markers wrapping a professional Copilot system prompt block. Include:
- Jenga framework description
- Skill invocation instructions (`/skill-name` syntax)
- `{{SKILL_LIST}}` placeholder
- Prompt routing guidance
- `JENGA_PROJECT_DIR` env var note

### T02 — init.js edits
After the `injectSettings` try/catch block, add logic to:
1. Read the template from `templates/copilot-instructions.md.tpl`
2. Discover skills dynamically from `config.skillsPath` — read `SKILL.md` frontmatter `description:` field for each skill dir
3. Replace `{{SKILL_LIST}}` with a generated Markdown list
4. Write `.github/copilot-instructions.md`:
   - Fresh project: create `.github/` if needed, write the full rendered template
   - Existing file: replace only the `<!-- JENGA:START -->...<!-- JENGA:END -->` block
5. Add `mkdirSync` and `readdirSync` to fs imports

## Files Changed
- `templates/copilot-instructions.md.tpl` (new)
- `lib/commands/init.js` (surgical edit)
