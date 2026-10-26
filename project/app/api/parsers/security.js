/**
 * @file project/app/api/parsers/security.js
 * Read-only reader for the dashboard Security view (E85_S03_T01). Assembles one payload from three
 * optional sources under the invoking project's root (resolveProjectRoot(), resolved per call so a
 * test can set JENGA_PROJECT_ROOT at any time before calling):
 *
 *   1. <data dir>/credential-findings.json   written by E85_S02_T01 (scripts/scan-credential-patterns.sh)
 *      The data dir is `paths.data` from project/configs/workflow.json when that is a safe relative
 *      path, else `project/data`.
 *   2. project/logs/events.json              JSONL; `audit_result` and `audit_consent` events written by
 *      scripts/audit-record.sh (E85_S01_T04, the pinned event contract).
 *   3. project/configs/audit-config.json     the audit settings (E85_S01).
 *
 * Returned shape (the `data` payload of the future /api/security route):
 *
 *   {
 *     credential_findings: {
 *       state: 'recorded' | 'never-scanned' | 'error',
 *       scan_date: 'YYYY-MM-DD' | null, command: string | null,
 *       summary: { total: int, by_skill: { [skill]: int } },
 *       findings: [{ skill: string|null, file, line, class, text,
 *                    scope: 'flagged'|'other', verdict: 'true read'|'benign mention',
 *                    reason, action: 'reword'|'allow-list'|'none' }],
 *       error: null | string
 *     },
 *     audits: {
 *       state: 'recorded' | 'never-audited' | 'error',
 *       config: null | { mode, severity_threshold, offline_behavior, production_only },
 *       targets: [{ scanned_dir, status, threshold, counts: { low, moderate, high, critical, total },
 *                   consent_basis, date, rapport, last_consent_date }],
 *       history: [ same shape as a target, one per audit_result event, newest first, capped at 200 ],
 *       error: null | string
 *     }
 *   }
 *
 * Rules:
 *   - Missing is not an error: no findings file -> 'never-scanned'; no audit_result event ->
 *     'never-audited'; no config file -> `config: null`.
 *   - Malformed is reported, not fatal, and never affects the other half: an unparseable findings file
 *     (or one whose schema_version is not 1) -> credential_findings.state 'error'; an unparseable config
 *     -> audits.state 'error' (targets and history are still populated from the events).
 *   - A line of events.json that does not parse (e.g. a torn last line) is skipped.
 *   - Audit `status` values (clean, findings, unavailable, disabled) are preserved unchanged.
 *   - "Newest" is decided by the event `date` string (ISO 8601 UTC, so it sorts lexically), ties broken
 *     by file order (a later line is newer). `history` is every audit_result newest first (cap 200).
 *     `targets` holds the newest audit_result per `scanned_dir` (a null scanned_dir is its own key),
 *     ordered newest first, each carrying `last_consent_date`: the newest audit_consent date for that
 *     same scanned_dir, else null.
 *   - Never writes. Only resolveProjectRoot() may throw (an unresolvable root fails loudly, as for every
 *     sibling parser); every source read is guarded.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { resolveProjectRoot } = require('../lib/resolve-project-root');

const HISTORY_CAP = 200;
const DEFAULT_DATA_DIR = path.join('project', 'data');
const COUNT_KEYS = ['low', 'moderate', 'high', 'critical', 'total'];

/** @returns {{ok: true, value: any}|{ok: false, missing: boolean, message: string}} */
function readJsonFile(file) {
  let raw;
  try {
    raw = fs.readFileSync(file, 'utf8');
  } catch (err) {
    if (err.code === 'ENOENT') return { ok: false, missing: true, message: 'missing' };
    return { ok: false, missing: false, message: `cannot read ${path.basename(file)}: ${err.message}` };
  }
  try {
    return { ok: true, value: JSON.parse(raw) };
  } catch (err) {
    return { ok: false, missing: false, message: `cannot parse ${path.basename(file)}: ${err.message}` };
  }
}

function isPlainObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

/** Honour `paths.data` from workflow.json when it is a safe relative path; else project/data. */
function resolveDataDir(root) {
  const wf = readJsonFile(path.join(root, 'project', 'configs', 'workflow.json'));
  if (wf.ok && isPlainObject(wf.value) && isPlainObject(wf.value.paths)) {
    const p = wf.value.paths.data;
    if (
      typeof p === 'string' &&
      p.trim() !== '' &&
      !path.isAbsolute(p) &&
      !p.split(/[\\/]/).includes('..')
    ) {
      return path.join(root, p);
    }
  }
  return path.join(root, DEFAULT_DATA_DIR);
}

function emptyFindings(state, error) {
  return {
    state,
    scan_date: null,
    command: null,
    summary: { total: 0, by_skill: {} },
    findings: [],
    error: error || null,
  };
}

function readCredentialFindings(root) {
  const res = readJsonFile(path.join(resolveDataDir(root), 'credential-findings.json'));
  if (!res.ok) return res.missing ? emptyFindings('never-scanned') : emptyFindings('error', res.message);

  const doc = res.value;
  if (!isPlainObject(doc) || doc.schema_version !== 1) {
    return emptyFindings('error', 'credential-findings.json is not schema_version 1');
  }
  if (!Array.isArray(doc.findings)) {
    return emptyFindings('error', 'credential-findings.json has no findings array');
  }

  const findings = doc.findings.filter(isPlainObject).map((f) => ({
    skill: f.skill === undefined ? null : f.skill,
    file: f.file,
    line: f.line,
    class: f.class,
    text: f.text,
    scope: f.scope,
    verdict: f.verdict,
    reason: f.reason,
    action: f.action,
  }));

  let summary;
  if (isPlainObject(doc.summary) && Number.isInteger(doc.summary.total) && isPlainObject(doc.summary.by_skill)) {
    summary = { total: doc.summary.total, by_skill: doc.summary.by_skill };
  } else {
    const by_skill = {};
    for (const f of findings) {
      if (typeof f.skill === 'string') by_skill[f.skill] = (by_skill[f.skill] || 0) + 1;
    }
    summary = { total: findings.length, by_skill };
  }

  return {
    state: 'recorded',
    scan_date: typeof doc.scan_date === 'string' ? doc.scan_date : null,
    command: typeof doc.command === 'string' ? doc.command : null,
    summary,
    findings,
    error: null,
  };
}

function readConfig(root) {
  const res = readJsonFile(path.join(root, 'project', 'configs', 'audit-config.json'));
  if (!res.ok) return res.missing ? { config: null, error: null } : { config: null, error: res.message };
  if (!isPlainObject(res.value)) {
    return { config: null, error: 'audit-config.json is not a JSON object' };
  }
  const c = res.value;
  const pick = (k) => (c[k] === undefined ? null : c[k]);
  return {
    config: {
      mode: pick('mode'),
      severity_threshold: pick('severity_threshold'),
      offline_behavior: pick('offline_behavior'),
      production_only: typeof c.production_only === 'boolean' ? c.production_only : null,
    },
    error: null,
  };
}

function normalizeCounts(counts) {
  const out = {};
  for (const k of COUNT_KEYS) {
    out[k] = isPlainObject(counts) && Number.isFinite(counts[k]) ? counts[k] : 0;
  }
  return out;
}

const strOrNull = (v) => (typeof v === 'string' ? v : null);

/** Newest first: date string descending, then file order (later line) descending. */
function newestFirst(a, b) {
  if (a.date !== b.date) return a.date < b.date ? 1 : -1;
  return b.idx - a.idx;
}

function readAuditEvents(root) {
  let raw;
  try {
    raw = fs.readFileSync(path.join(root, 'project', 'logs', 'events.json'), 'utf8');
  } catch {
    return { results: [], consents: new Map() };
  }

  const results = [];
  const consents = new Map(); // scanned_dir -> newest consent date string
  const lines = raw.split('\n');
  for (let idx = 0; idx < lines.length; idx++) {
    const line = lines[idx];
    if (!line.includes('audit_result') && !line.includes('audit_consent')) continue;
    let ev;
    try {
      ev = JSON.parse(line);
    } catch {
      continue; // torn or otherwise unparseable line
    }
    if (!isPlainObject(ev)) continue;

    if (ev.event === 'audit_result') {
      results.push({
        idx,
        date: typeof ev.date === 'string' ? ev.date : '',
        scanned_dir: strOrNull(ev.scanned_dir),
        status: ev.status,
        threshold: strOrNull(ev.threshold),
        counts: normalizeCounts(ev.counts),
        consent_basis: strOrNull(ev.consent_basis),
        rapport: strOrNull(ev.rapport),
      });
    } else if (ev.event === 'audit_consent' && typeof ev.scanned_dir === 'string' && typeof ev.date === 'string') {
      const prev = consents.get(ev.scanned_dir);
      if (prev === undefined || ev.date >= prev) consents.set(ev.scanned_dir, ev.date);
    }
  }
  return { results, consents };
}

function readAudits(root) {
  const { config, error } = readConfig(root);
  const { results, consents } = readAuditEvents(root);

  results.sort(newestFirst);
  const view = (r) => ({
    scanned_dir: r.scanned_dir,
    status: r.status,
    threshold: r.threshold,
    counts: r.counts,
    consent_basis: r.consent_basis,
    date: r.date === '' ? null : r.date,
    rapport: r.rapport,
    last_consent_date: r.scanned_dir !== null && consents.has(r.scanned_dir) ? consents.get(r.scanned_dir) : null,
  });

  const seen = new Set();
  const targets = [];
  for (const r of results) {
    if (seen.has(r.scanned_dir)) continue;
    seen.add(r.scanned_dir);
    targets.push(view(r));
  }
  const history = results.slice(0, HISTORY_CAP).map(view);

  let state;
  if (error) state = 'error';
  else state = results.length > 0 ? 'recorded' : 'never-audited';

  return { state, config, targets, history, error };
}

/**
 * Build the Security payload. Never throws for a missing or malformed source (only an unresolvable
 * project root propagates) and never writes.
 * @returns {Promise<{credential_findings: Object, audits: Object}>}
 */
async function readSecurity() {
  const root = resolveProjectRoot();
  return {
    credential_findings: readCredentialFindings(root),
    audits: readAudits(root),
  };
}

module.exports = { readSecurity };
