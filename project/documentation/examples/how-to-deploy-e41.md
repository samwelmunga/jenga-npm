# How to Deploy E41 (GitHub Pages Documentation Site)

## What it is
E41 is the **Launch & Discoverability** epic. "Deploying E41" specifically refers to
**E41_S13: GitHub Pages Documentation Site** — turning the existing wiki content
(`project/.wiki/documentation.md`, `intro-guide.md`, `concepts/`) into a real, navigable
static website instead of one long scrollable file.

## Why it exists
Before this story, all docs lived in a flat GitHub Wiki / single long markdown file. That's
fine for grep, bad for a new user who wants Getting Started → Concepts → Skills reference
navigation without endless scrolling.

## How it works
1. **Tooling**: GitHub's built-in Jekyll support, served from a `docs/` folder on `main`
   (theme: `minima`). No custom build pipeline — GitHub builds it natively.
2. **Where it actually lives**: Pages was originally meant to be enabled on this repo
   (`samwelmunga/JengaAgent`), but that repo is **private**, and GitHub Pages on private
   repos requires GitHub Pro (`gh api` returned HTTP 422). So the site is mirrored instead
   to the **public** counterpart repo, `samwelmunga/jenga-npm`, via the `/mirror-public`
   skill — `docs/` isn't blocked by `.publicignore`, so it rides along automatically.
3. **Enabling Pages** (non-interactive, once targeting the right repo):
   ```
   gh api -X POST repos/samwelmunga/jenga-npm/pages -f "source[branch]=main" -f "source[path]=/docs"
   ```
4. **Verification**: poll `gh api repos/samwelmunga/jenga-npm/pages/builds/latest` for
   `status: built`, then `WebFetch` the live URL to confirm nav and content render.
5. **Live URL**: `https://samwelmunga.github.io/jenga-npm/`

## When to use this pattern
If you need to deploy a Pages site from a **private** repo in this project, don't try to
enable Pages directly on it — mirror the relevant folder to the public `jenga-npm` repo
first (via `/mirror-public`), then enable Pages there. Enabling it on the private repo
directly hits the same 422.

## Example: redeploying after content changes
If wiki content changes and the site needs to catch up:
1. Update `project/.wiki/*` (source of truth — the site is *restructured from* it, not
   superseding it).
2. Port the changes into `docs/` following the existing nav structure
   (Getting Started / Concepts / Reference).
3. Run `/mirror-public` to push `docs/` to `samwelmunga/jenga-npm`.
4. Confirm the build: `gh api repos/samwelmunga/jenga-npm/pages/builds/latest`.

## Sources
- `project/board/stories/E41_S13_github-pages-documentation-site.md`
- `project/board/tasks/E41_S13_T01_scaffold-static-site-and-enable-pages.md`
- `project/board/tasks/E41_S13_T04_verify-site-and-set-homepage.md`
