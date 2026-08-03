# WARP

> ⚠️ **CRITICAL — Source of Truth for All Features**
>
> All features — **skills, agents, hooks, scripts, and any other implementation** — **MUST be created and edited in the root directories** (`skills/`, `agents/`, `hooks/`, `scripts/`, etc.).
>
> The **`.agents/`** and **`.claude/`** directories are **generated build outputs** populated by the `/distribute` skill. They must **never** be used as the primary location for new or updated features. Any change made only inside `.agents/` or `.claude/` will be overwritten on the next distribution run.
>
> **Rule:** Canonical source → root directories. `.agents/` and `.claude/` → read-only build artifacts.

---

## `/reconcile-origin`

**Purpose:** Sync the current or specified local branch with `origin/<branch>` by rebasing local commits on top of the latest upstream state.

**Usage:**
- `/reconcile-origin` — reconcile the current branch
- `/reconcile-origin <branch>` — reconcile a named branch

**Conflict handling:** When upstream and local commits overlap, the skill presents a structured conflict rapport with the file path, local section, origin section, recommended resolution options, and a final **Handle it later** path that annotates preserved conflict markers.

**When to use:**
- Long-running worktrees that may have drifted behind origin
- Cross-session development where upstream has moved on
- Right before opening or refreshing a pull request
