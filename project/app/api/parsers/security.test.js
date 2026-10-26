/**
 * @file project/app/api/parsers/security.test.js
 * Plain Node `assert` test for `readSecurity()` in `parsers/security.js` (E85_S03_T01).
 * Each scenario builds a scratch project root under the OS temp dir and points JENGA_PROJECT_ROOT at it
 * before calling the reader. Never touches this repository's real files.
 *
 * Run: node project/app/api/parsers/security.test.js
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');

const base = fs.mkdtempSync(path.join(os.tmpdir(), 'security-test-'));
let counter = 0;

function makeRoot() {
  const root = path.join(base, `root${counter++}`);
  fs.mkdirSync(path.join(root, 'project', 'board'), { recursive: true });
  process.env.JENGA_PROJECT_ROOT = root;
  return root;
}
function put(root, rel, content) {
  const file = path.join(root, rel);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, content);
  return file;
}

const { readSecurity } = require('./security');

const counts = (low, moderate, high, critical) => ({ low, moderate, high, critical, total: low + moderate + high + critical });
const result = (dir, status, date, c, extra) =>
  JSON.stringify(Object.assign({
    event: 'audit_result', agent: 'audit-record', status, threshold: 'high', counts: c,
    scanned_dir: dir, consent_basis: 'user', rapport: null, session_id: 's', date,
  }, extra));
const consent = (dir, date) =>
  JSON.stringify({ event: 'audit_consent', agent: 'audit-record', tool_type: 'vulnerability', approved_by: 'user', scanned_dir: dir, session_id: 's', date });

const FINDING = {
  skill: 'j-connect', file: 'skills/j-connect/SKILL.md', line: 12, class: 'gh-auth', text: 'gh auth login',
  scope: 'flagged', verdict: 'true read', reason: 'reads the token', action: 'reword',
};

(async () => {
  // Empty project: never-scanned / never-audited, config null, no throw.
  {
    makeRoot();
    const empty = await readSecurity();
    assert.deepStrictEqual(empty, {
      credential_findings: { state: 'never-scanned', scan_date: null, command: null, summary: { total: 0, by_skill: {} }, findings: [], error: null },
      audits: { state: 'never-audited', config: null, targets: [], history: [], error: null },
    });
  }

  // Full fixture.
  {
    const root = makeRoot();
    put(root, 'project/data/credential-findings.json', JSON.stringify({
      schema_version: 1, scan_date: '2026-10-25', command: 'scripts/scan-credential-patterns.sh',
      summary: { total: 1, by_skill: { 'j-connect': 1 } }, findings: [FINDING, { ...FINDING, skill: null, line: 3, scope: 'other', verdict: 'benign mention', action: 'allow-list' }],
    }));
    put(root, 'project/configs/audit-config.json', JSON.stringify({ config_version: 1, mode: 'ask', severity_threshold: 'high', offline_behavior: 'warn', production_only: false }));
    const lines = [
      JSON.stringify({ event: 'session_start', agent: 'x', date: '2026-10-20T00:00:00Z' }),
      consent('/a', '2026-10-20T10:00:00Z'),
      result('/a', 'findings', '2026-10-20T10:05:00Z', counts(1, 2, 3, 0), { rapport: '/r/audit-a.md' }),
      result('/b', 'unavailable', '2026-10-21T09:00:00Z', counts(0, 0, 0, 0), { threshold: null, consent_basis: null }),
      consent('/a', '2026-10-22T10:00:00Z'),
      result('/a', 'clean', '2026-10-22T10:05:00Z', counts(0, 0, 0, 0)),
      result('/b', 'disabled', '2026-10-23T09:00:00Z', counts(0, 0, 0, 0), { threshold: null, consent_basis: null }),
    ];
    // Torn last line.
    put(root, 'project/logs/events.json', lines.join('\n') + '\n{"event":"audit_result","status":"cle');
    const events = fs.readFileSync(path.join(root, 'project/logs/events.json'), 'utf8');

    const out = await readSecurity();
    assert.deepStrictEqual(Object.keys(out), ['credential_findings', 'audits']);

    const cf = out.credential_findings;
    assert.strictEqual(cf.state, 'recorded');
    assert.strictEqual(cf.scan_date, '2026-10-25');
    assert.strictEqual(cf.command, 'scripts/scan-credential-patterns.sh');
    assert.deepStrictEqual(cf.summary, { total: 1, by_skill: { 'j-connect': 1 } });
    assert.strictEqual(cf.findings.length, 2);
    assert.deepStrictEqual(cf.findings[0], FINDING);
    assert.strictEqual(cf.findings[1].skill, null);
    assert.strictEqual(cf.error, null);

    const au = out.audits;
    assert.strictEqual(au.state, 'recorded');
    assert.deepStrictEqual(au.config, { mode: 'ask', severity_threshold: 'high', offline_behavior: 'warn', production_only: false });
    assert.strictEqual(au.error, null);

    // History: all 4 results, newest first.
    assert.deepStrictEqual(au.history.map((h) => [h.scanned_dir, h.status, h.date]), [
      ['/b', 'disabled', '2026-10-23T09:00:00Z'],
      ['/a', 'clean', '2026-10-22T10:05:00Z'],
      ['/b', 'unavailable', '2026-10-21T09:00:00Z'],
      ['/a', 'findings', '2026-10-20T10:05:00Z'],
    ]);
    // Targets: one per scanned_dir, newest result, newest first; unavailable/disabled preserved.
    assert.strictEqual(au.targets.length, 2);
    assert.deepStrictEqual(au.targets[0], {
      scanned_dir: '/b', status: 'disabled', threshold: null, counts: counts(0, 0, 0, 0),
      consent_basis: null, date: '2026-10-23T09:00:00Z', rapport: null, last_consent_date: null,
    });
    assert.deepStrictEqual(au.targets[1], {
      scanned_dir: '/a', status: 'clean', threshold: 'high', counts: counts(0, 0, 0, 0),
      consent_basis: 'user', date: '2026-10-22T10:05:00Z', rapport: null, last_consent_date: '2026-10-22T10:00:00Z',
    });
    assert.deepStrictEqual(au.history[3].counts, counts(1, 2, 3, 0));
    assert.strictEqual(au.history[3].rapport, '/r/audit-a.md');
    assert.strictEqual(au.history[3].last_consent_date, '2026-10-22T10:00:00Z');
    assert.strictEqual(au.history[2].status, 'unavailable');

    // Read-only.
    assert.strictEqual(fs.readFileSync(path.join(root, 'project/logs/events.json'), 'utf8'), events);
  }

  // Same-date ties resolve by file order; null scanned_dir is its own key; history cap of 200.
  {
    const root = makeRoot();
    const lines = [
      result(null, 'findings', '2026-10-20T00:00:00Z', counts(0, 0, 1, 0)),
      result(null, 'clean', '2026-10-20T00:00:00Z', counts(0, 0, 0, 0)),
      result('/a', 'clean', '2026-10-20T00:00:00Z', counts(0, 0, 0, 0)),
    ];
    for (let i = 0; i < 205; i++) lines.push(result('/many', 'clean', `2026-11-01T00:${String(Math.floor(i / 60)).padStart(2, '0')}:${String(i % 60).padStart(2, '0')}Z`, counts(0, 0, 0, 0)));
    put(root, 'project/logs/events.json', lines.join('\n') + '\n');
    const { audits } = await readSecurity();
    assert.strictEqual(audits.history.length, 200);
    assert.strictEqual(audits.targets.length, 3);
    const nullTarget = audits.targets.find((t) => t.scanned_dir === null);
    assert.strictEqual(nullTarget.status, 'clean');
    assert.strictEqual(nullTarget.last_consent_date, null);
    assert.strictEqual(audits.targets[0].scanned_dir, '/many');
  }

  // Malformed findings file: error there, audits half unaffected.
  {
    const root = makeRoot();
    put(root, 'project/data/credential-findings.json', '{ not json');
    put(root, 'project/logs/events.json', result('/a', 'clean', '2026-10-20T00:00:00Z', counts(0, 0, 0, 0)) + '\n');
    const out = await readSecurity();
    assert.strictEqual(out.credential_findings.state, 'error');
    assert.ok(out.credential_findings.error.length > 0);
    assert.deepStrictEqual(out.credential_findings.findings, []);
    assert.strictEqual(out.audits.state, 'recorded');
    assert.strictEqual(out.audits.targets.length, 1);
  }

  // Wrong schema_version: error.
  {
    const root = makeRoot();
    put(root, 'project/data/credential-findings.json', JSON.stringify({ schema_version: 2, findings: [] }));
    const out = await readSecurity();
    assert.strictEqual(out.credential_findings.state, 'error');
    assert.match(out.credential_findings.error, /schema_version 1/);
    assert.strictEqual(out.audits.state, 'never-audited');
  }

  // Malformed config: audits error, events still populate, findings half unaffected.
  {
    const root = makeRoot();
    put(root, 'project/configs/audit-config.json', '{"mode": ');
    put(root, 'project/logs/events.json', result('/a', 'findings', '2026-10-20T00:00:00Z', counts(0, 1, 0, 0)) + '\n');
    put(root, 'project/data/credential-findings.json', JSON.stringify({ schema_version: 1, scan_date: '2026-10-25', command: 'c', summary: { total: 0, by_skill: {} }, findings: [] }));
    const out = await readSecurity();
    assert.strictEqual(out.audits.state, 'error');
    assert.ok(out.audits.error.length > 0);
    assert.strictEqual(out.audits.config, null);
    assert.strictEqual(out.audits.targets.length, 1);
    assert.strictEqual(out.audits.history.length, 1);
    assert.strictEqual(out.credential_findings.state, 'recorded');
  }

  // workflow.json paths.data is honoured; unsafe values fall back to project/data.
  {
    const root = makeRoot();
    put(root, 'project/configs/workflow.json', JSON.stringify({ paths: { data: 'custom/data' } }));
    put(root, 'custom/data/credential-findings.json', JSON.stringify({ schema_version: 1, scan_date: '2026-10-25', command: 'c', summary: { total: 0, by_skill: {} }, findings: [] }));
    assert.strictEqual((await readSecurity()).credential_findings.state, 'recorded');
    put(root, 'project/configs/workflow.json', JSON.stringify({ paths: { data: '../escape' } }));
    assert.strictEqual((await readSecurity()).credential_findings.state, 'never-scanned');
  }

  fs.rmSync(base, { recursive: true, force: true });
  console.log('security.test.js: all assertions passed');
})().catch((err) => {
  fs.rmSync(base, { recursive: true, force: true });
  console.error(err);
  process.exit(1);
});
