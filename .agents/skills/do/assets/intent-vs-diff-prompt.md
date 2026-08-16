# Intent-vs-Diff LLM Prompt Template

This file contains the structured prompt used by `/do` to compare a completed task's stated intent against its actual diff. It is invoked **only** for tasks where `needs_docs: false`.

## Purpose

After a `needs_docs: false` task completes, `/do` runs `git diff --name-only HEAD~1` to get the list of changed file names and passes them — along with the task description and acceptance criteria — to the LLM using the prompt below. The LLM identifies any files that fall outside the expected scope of the task, enabling early detection of unregistered scope expansion.

## False-Positive Tuning Rationale

The prompt is calibrated to minimize false positives:

1. **Test file exemption**: Test files that correspond to source files explicitly mentioned in the task description are NOT flagged. Adding tests is universally expected and implied by any implementation task.
2. **Documentation file exemption**: Files like `README.md`, `WARP.md`, `CHANGELOG.md`, and any `*.md` in a `docs/` directory are NOT flagged. Documentation updates are standard outputs of any change.
3. **Inferability threshold — both conditions required**: A file is only flagged when it is BOTH (a) not mentioned by name in the description, AND (b) not clearly inferable from what the description says. A task that says "update the login handler" implicitly covers the login handler's test file, its dependency injector, and related middleware — even if those are not named. Only files with zero connection to the stated task are flagged.
4. **JSON-only output**: The LLM is asked to return only a JSON array to eliminate ambiguity in parsing the response.
5. **Config/lock file exemption**: `package-lock.json`, `yarn.lock`, `*.lock`, and other machine-managed files are NOT flagged — they change as a side-effect of dependency changes and are never the primary intent of a task.

## Prompt

```
You are reviewing a completed task to check if the implementation stayed within scope.

Task description: {description}

Acceptance criteria:
{acceptance_criteria}

Changed files:
{changed_files}

Your job: identify any changed files that are NOT mentioned and NOT clearly inferable from the task description or acceptance criteria above.

Rules for what NOT to flag:
- Do not flag test files (*.test.*, *.spec.*, files in __tests__/ or test/ directories) for source files that are explicitly mentioned or clearly implied in the task.
- Do not flag documentation files (*.md, files in docs/ directories, README, WARP.md, CHANGELOG).
- Do not flag lock files (package-lock.json, yarn.lock, *.lock, *.sum) or generated files (*.generated.*, dist/, build/).
- Do not flag configuration files (*.config.*, .env.example, tsconfig.json) unless the task has zero connection to configuration.
- Only flag a file when it has zero plausible connection to the stated task description. If you can construct a reasonable sentence explaining why the file might be touched given the task description, do not flag it.

Return ONLY a JSON array of file paths that are unexpected scope expansions. If all files are expected or fall under the exemptions above, return an empty array.

Examples of correct output:
- All files expected: []
- Two unexpected files: ["src/billing/invoice.ts", "scripts/deploy.sh"]

Do not include any explanation, commentary, or text outside the JSON array.
```

## Usage in `/do`

When the check runs, replace the template placeholders as follows:

- `{description}` — the full text of the task's `## Description` section from the task board file
- `{acceptance_criteria}` — the full text of the task's `## Acceptance Criteria` section (each criterion on its own line, including the `- [ ]` or `- [x]` prefix)
- `{changed_files}` — the newline-separated output of `git diff --name-only HEAD~1`, one file path per line

After receiving the LLM response:

1. Attempt to parse the response as a JSON array.
2. If parsing fails (malformed JSON), treat it as `[]` — do not flag divergence. Emit a debug note: `[intent-vs-diff] LLM response was not valid JSON; treating as no divergence.`
3. If the array is empty (`[]`), proceed without modifying the task frontmatter.
4. If the array is non-empty, write `divergence_flag: true` to the task's frontmatter and emit the warning:
   ```
   [DIVERGENCE WARNING] Task <task_id>: the following files were changed but are not mentioned or inferable from the task description:
     - <file1>
     - <file2>
   This is a non-blocking warning. Task outcome is not affected.
   ```
