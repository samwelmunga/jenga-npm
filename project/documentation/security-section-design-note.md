# Security Section Design Note

**Epic:** E08 — Agent Dashboard Architecture Tab  
**Story:** E08_S02 — Security Section Spike  
**Status:** Spike Complete  
**Date:** 2025-01-01

---

## 1. Locally Available Data (No Network Required)

The following security signals can be collected **entirely on the developer's machine** without any external network calls:

### a) Dependency Vulnerability Audit (`npm audit`)
- **Source:** `package-lock.json` or `yarn.lock` parsed against the locally-cached npm advisory database
- **How:** Run `npm audit --json` as a child process — npm bundles its advisory DB locally and only consults the network when refreshing it
- **Caveat:** The bundled advisory DB may be stale; add a timestamp so developers know when it was last updated
- **Output shape:** List of `{name, severity, description, fix_version, url}` objects

### b) `.env` File Presence Check
- **Source:** Filesystem scan of the project root and subdirectories for `.env`, `.env.local`, `.env.production`, `.env.*` files
- **Check:** Verify whether each found `.env*` file is listed in `.gitignore`
- **Signal:** Warn if any `.env` file is not gitignored — this is a common secret-leakage risk
- **No network needed:** Pure filesystem + text comparison

### c) Dependency License Scan
- **Source:** `package-lock.json` / `node_modules/<pkg>/package.json` — each package declares a `license` field
- **How:** Walk `node_modules` (or read from lock file metadata) and collect license identifiers
- **Signal:** Flag packages with restrictive licenses (GPL, AGPL, SSPL) when the project is commercial
- **No network needed:** All metadata is already on disk after `npm install`

### d) Outdated Package Detection
- **Source:** Run `npm outdated --json` locally
- **Signal:** Packages with known vulnerabilities are often outdated; outdated count is a useful proxy metric
- **No network needed for local cache:** Results use the locally cached registry data

---

## 2. Data Requiring External Calls

### a) Live CVE / Advisory Database Lookup
- **Sources:** [GitHub Advisory API](https://docs.github.com/en/rest/security-advisories), [OSV.dev](https://osv.dev/), [Snyk](https://snyk.io/)
- **Why needed:** The locally-cached advisory DB can be weeks old; new CVEs are published daily
- **Tradeoff:** Adds network latency and a potential auth requirement (GitHub token for higher rate limits). In an offline/airgapped environment this will fail silently
- **Recommendation:** Mark as **optional / deferred for v1**. Show "last updated" timestamp so developers know the staleness of the local data. Provide a "Refresh from OSV.dev" button for v2

### b) License Compliance Check Against SPDX Registry
- **Source:** SPDX license list at `https://spdx.org/licenses/`
- **Why needed:** Package `license` fields are often informal strings ("MIT", "MIT License", "mit"); normalising them requires the canonical SPDX list
- **Recommendation:** Bundle a static snapshot of the SPDX identifiers list (small JSON ~60KB) so no live call is needed

---

## 3. Signal-to-Noise Ratio Strategy

To avoid alert fatigue:

1. **Show only HIGH and CRITICAL severity vulnerabilities** by default — suppress moderate/low unless the user opts in
2. **Group by severity** (Critical → High → Moderate → Low) with collapsible sections
3. **Deduplicate** — if the same advisory affects 5 packages, show it once with affected package names listed
4. **Suppress false positives** — dev-only dependencies with no runtime exposure should be visually de-emphasised
5. **Show a summary count** (e.g. "2 critical, 1 high") at the top so developers get the gist at a glance without scrolling

---

## 4. Subsection vs Dedicated Tab

**Recommendation: Subsection of the Architecture tab for v1.**

**Rationale:**
- Security metadata (vulnerabilities, `.env` warnings, license issues) is tightly coupled to the dependency and tech-stack data already shown in the Architecture tab
- Most projects will have a small number of findings; a dedicated tab would feel empty most of the time
- A collapsible "Security" accordion at the bottom of the Architecture tab keeps all project health metadata in one place
- **Dedicated tab only when:** security findings grow to the point where navigation between vulnerability groups, remediation history, and policy config warrants its own context (typically 20+ distinct advisories or an organisation-wide policy workflow)

---

## 5. Recommended API Endpoint Shape

**Endpoint:** `GET /v1/architecture/security`

### Response Schema

```json
{
  "data": {
    "audited_at": "2025-01-01T12:00:00Z",
    "summary": {
      "critical": 1,
      "high": 2,
      "moderate": 3,
      "low": 5,
      "info": 0
    },
    "vulnerabilities": [
      {
        "name": "lodash",
        "installed_version": "4.17.15",
        "severity": "high",
        "description": "Prototype Pollution in lodash",
        "fix_version": "4.17.21",
        "advisory_url": "https://github.com/advisories/GHSA-xxxxx"
      }
    ],
    "env_warnings": [
      ".env is present but not listed in .gitignore"
    ],
    "license_issues": [
      {
        "name": "some-package",
        "version": "1.2.3",
        "license": "GPL-3.0",
        "reason": "Restrictive license detected"
      }
    ]
  },
  "meta": {
    "timestamp": "2025-01-01T12:00:00Z",
    "version": "1.0.0"
  },
  "error": null
}
```

### Notes
- `audited_at` reflects when `npm audit` was last run locally (not the current request time) so stale data is surfaced clearly
- `severity` values: `"critical"`, `"high"`, `"moderate"`, `"low"`, `"info"`
- The endpoint runs `npm audit --json` synchronously on each request for v1; add caching in v2
- Returns an empty `vulnerabilities: []` (not an error) if `package-lock.json` is absent
