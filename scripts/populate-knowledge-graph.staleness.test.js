#!/usr/bin/env node
/**
 * @file scripts/populate-knowledge-graph.staleness.test.js
 * Plain Node `assert`-based unit tests for E20_S10_T05's staleness/revalidation logic in
 * scripts/populate-knowledge-graph.js (hashSource, checkStaleness, ensureProvenanceMetadata). Same
 * no-framework convention as knowledge-graph.test.js and
 * populate-knowledge-graph.entity-resolution.test.js.
 *
 * Run directly:
 *   node scripts/populate-knowledge-graph.staleness.test.js
 */

import assert from 'node:assert';
import {
  hashSource,
  checkStaleness,
  ensureProvenanceMetadata,
} from './populate-knowledge-graph.js';

async function main() {
  const tests = [];
  function test(name, fn) {
    tests.push({ name, fn });
  }

  // -----------------------------------------------------------------------------------------
  // hashSource()
  // -----------------------------------------------------------------------------------------

  test('hashSource: identical content produces identical hashes', () => {
    assert.strictEqual(hashSource('hello world'), hashSource('hello world'));
  });

  test('hashSource: different content produces different hashes', () => {
    assert.notStrictEqual(hashSource('hello world'), hashSource('hello mars'));
  });

  test('hashSource: is defined for empty/undefined content (never throws)', () => {
    assert.doesNotThrow(() => hashSource(''));
    assert.doesNotThrow(() => hashSource(undefined));
    assert.strictEqual(hashSource(''), hashSource(undefined));
  });

  // -----------------------------------------------------------------------------------------
  // checkStaleness()
  // -----------------------------------------------------------------------------------------

  test('checkStaleness: reports "unchanged, no badge" (stale: false) when the source hash still matches', () => {
    const content = 'function billingWorker() { reconcileLedger(); }';
    const node = { content_hash: hashSource(content) };
    assert.deepStrictEqual(checkStaleness(node, content), { stale: false });
  });

  test('checkStaleness: reports "needs re-verification" (stale: true) when the source has changed', () => {
    const originalContent = 'function billingWorker() { reconcileLedger(); }';
    const changedContent = 'function billingWorker() { retryCharge(); }'; // materially different
    const node = { content_hash: hashSource(originalContent) };
    assert.deepStrictEqual(checkStaleness(node, changedContent), { stale: true });
  });

  test('checkStaleness: a node with no stored content_hash is never reported stale (nothing to compare against)', () => {
    assert.deepStrictEqual(checkStaleness({}, 'anything'), { stale: false });
    assert.deepStrictEqual(checkStaleness(null, 'anything'), { stale: false });
  });

  // -----------------------------------------------------------------------------------------
  // ensureProvenanceMetadata()
  // -----------------------------------------------------------------------------------------

  test('ensureProvenanceMetadata: a board node is left untouched (no extracted_at/content_hash)', () => {
    const node = { id: 'E90', type: 'epic', label: 'Epic', description: 'd', source: 'board' };
    const result = ensureProvenanceMetadata(node, '2026-01-01T00:00:00Z');
    assert.strictEqual(result, node);
    assert.strictEqual(result.content_hash, undefined);
    assert.strictEqual(result.extracted_at, undefined);
  });

  test('ensureProvenanceMetadata: a new non-board node is stamped with content_hash + extracted_at', () => {
    const node = { id: 'svc-1', type: 'service', label: 'Billing Worker', description: 'd', source: 'ast' };
    const result = ensureProvenanceMetadata(node, '2026-01-01T00:00:00Z');
    assert.ok(result.content_hash);
    assert.strictEqual(result.extracted_at, '2026-01-01T00:00:00Z');
  });

  test('ensureProvenanceMetadata: re-stamping unchanged content does NOT bump extracted_at (no noisy re-timestamping)', () => {
    const node = { id: 'svc-1', type: 'service', label: 'Billing Worker', description: 'd', source: 'ast' };
    const first = ensureProvenanceMetadata(node, '2026-01-01T00:00:00Z');
    const second = ensureProvenanceMetadata(first, '2026-06-01T00:00:00Z'); // later "now", same content
    assert.strictEqual(second.extracted_at, '2026-01-01T00:00:00Z', 'extracted_at must not change when content is unchanged');
    assert.strictEqual(second.content_hash, first.content_hash);
  });

  test('ensureProvenanceMetadata: content that actually changes DOES bump both content_hash and extracted_at', () => {
    const node = { id: 'svc-1', type: 'service', label: 'Billing Worker', description: 'd', source: 'ast' };
    const first = ensureProvenanceMetadata(node, '2026-01-01T00:00:00Z');
    const changed = { ...first, description: 'materially different description' };
    const second = ensureProvenanceMetadata(changed, '2026-06-01T00:00:00Z');
    assert.notStrictEqual(second.content_hash, first.content_hash);
    assert.strictEqual(second.extracted_at, '2026-06-01T00:00:00Z');
  });

  test('a purely cosmetic/formatting-only change to normalized input does not flip staleness when the caller passes normalized content', () => {
    // Simulates a future caller that normalizes whitespace before hashing (e.g. a normalized AST
    // dump rather than raw file bytes) — per the task's "prefer hashing normalized/parsed
    // structure over raw bytes where feasible" guidance.
    const normalize = (raw) => raw.trim().replace(/\s+/g, ' ');
    const original = 'function billingWorker() {\n  reconcileLedger();\n}\n';
    const cosmeticallyReformatted = '  function   billingWorker()   {   reconcileLedger();   }  ';

    const node = { content_hash: hashSource(normalize(original)) };
    assert.deepStrictEqual(checkStaleness(node, normalize(cosmeticallyReformatted)), { stale: false });
  });

  let failures = 0;
  for (const { name, fn } of tests) {
    try {
      await fn();
      console.log(`PASS - ${name}`);
    } catch (err) {
      failures += 1;
      console.error(`FAIL - ${name}`);
      console.error(err && err.stack ? err.stack : err);
    }
  }

  console.log(`\n${tests.length - failures}/${tests.length} passed`);
  if (failures > 0) process.exitCode = 1;
}

main();
