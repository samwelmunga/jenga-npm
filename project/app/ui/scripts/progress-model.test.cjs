#!/usr/bin/env node
'use strict'
// E92_S03_T04: model test for the dashboard progress pies. Zero test framework, plain node, like
// budget-view.test.cjs. progressModel.js is pure ESM, so it is loaded with a dynamic import (the ui package
// is "type": "module"); no bundler is involved.
// Run: node project/app/ui/scripts/progress-model.test.cjs
const assert = require('assert')
const fs = require('fs')
const path = require('path')
const { pathToFileURL } = require('url')

const modelPath = path.join(__dirname, '..', 'src', 'components', 'progress', 'progressModel.js')
const tokensPath = path.join(__dirname, '..', 'src', 'tokens.css')

const BLOCK = {
  counts: { Passed: 4, Merged: 1, 'In Progress': 1, Failed: 1, Blocked: 1, Pending: 1, Backlog: 1, Rejected: 3 },
  totals: { done: 5, in_progress: 1, failed: 2, pending: 2, rejected: 3, unknown: 0, denominator: 10 },
}

async function main() {
  const { buildPieModel, progressHeadline } = await import(pathToFileURL(modelPath).href)
  const sum = (arr) => arr.reduce((a, b) => a + b, 0)

  // 1. Example block: five slices, fixed order, tokens, labels, percents total 100, rejected last.
  {
    const m = buildPieModel(BLOCK, 'Tasks')
    assert.strictEqual(m.title, 'Tasks')
    assert.strictEqual(m.empty, false)
    assert.strictEqual(m.total, 13)
    assert.deepStrictEqual(m.slices.map(s => s.key), ['done', 'in_progress', 'failed', 'pending', 'rejected'])
    assert.deepStrictEqual(m.slices.map(s => s.label), ['Done', 'In progress', 'Failed or blocked', 'Pending', 'Rejected (not counted)'])
    assert.deepStrictEqual(m.slices.map(s => s.count), [5, 1, 2, 2, 3])
    assert.deepStrictEqual(m.slices.map(s => s.colorVar), [
      '--color-progress-done', '--color-progress-in-progress', '--color-progress-failed',
      '--color-progress-pending', '--color-progress-rejected',
    ])
    assert.strictEqual(sum(m.slices.map(s => s.percent)), 100)
    assert.deepStrictEqual(m.slices.map(s => s.percent), [39, 8, 15, 15, 23]) // floors 38 7 15 15 23 = 98; the two largest remainders (.69, .46) get the extra points
    // detail: raw statuses behind each bucket, from counts
    assert.strictEqual(m.slices[0].detail, 'Passed: 4, Merged: 1')
    assert.strictEqual(m.slices[2].detail, 'Failed: 1, Blocked: 1')
    assert.strictEqual(m.slices[3].detail, 'Pending: 1, Backlog: 1')
    assert.strictEqual(m.slices[4].detail, 'Rejected: 3')
  }

  // 2. Zero buckets are omitted; unknown is last, uses the border token, and lists its own strings.
  {
    const m = buildPieModel({
      counts: { Passed: 2, 'Not Started': 1 },
      totals: { done: 2, in_progress: 0, failed: 0, pending: 0, rejected: 0, unknown: 1, denominator: 2 },
    }, 'Tasks')
    assert.deepStrictEqual(m.slices.map(s => s.key), ['done', 'unknown'])
    assert.strictEqual(m.slices[1].colorVar, '--color-border-strong')
    assert.strictEqual(m.slices[1].label, 'Unknown status')
    assert.strictEqual(m.slices[1].detail, 'Not Started: 1')
    assert.deepStrictEqual(m.slices.map(s => s.percent), [67, 33])
  }

  // 3. Empty states: all zeros, { empty: true }, undefined, null.
  {
    const zeros = { counts: {}, totals: { done: 0, in_progress: 0, failed: 0, pending: 0, rejected: 0, unknown: 0, denominator: 0 } }
    for (const b of [zeros, { empty: true }, undefined, null]) {
      const m = buildPieModel(b, 'Epics')
      assert.strictEqual(m.empty, true)
      assert.deepStrictEqual(m.slices, [])
      assert.strictEqual(m.total, 0)
      assert.strictEqual(m.title, 'Epics')
    }
  }

  // 4. Rejected never takes another bucket's token, and no other bucket takes the rejected one.
  {
    const only = buildPieModel({ totals: { rejected: 4, denominator: 0 } }, 'x')
    assert.strictEqual(only.slices.length, 1)
    assert.strictEqual(only.slices[0].key, 'rejected')
    assert.strictEqual(only.slices[0].colorVar, '--color-progress-rejected')
    assert.strictEqual(only.slices[0].percent, 100)
    for (const s of buildPieModel(BLOCK, 'x').slices) {
      assert.strictEqual(s.colorVar === '--color-progress-rejected', s.key === 'rejected')
    }
  }

  // 5. Slice sizes come from totals, not from counts; missing counts only blanks the detail.
  {
    const m = buildPieModel({ totals: { done: 3, pending: 1 } }, 'x')
    assert.deepStrictEqual(m.slices.map(s => s.count), [3, 1])
    assert.deepStrictEqual(m.slices.map(s => s.detail), ['', ''])
    const lying = buildPieModel({ counts: { Passed: 99 }, totals: { done: 1, pending: 1 } }, 'x')
    assert.deepStrictEqual(lying.slices.map(s => s.count), [1, 1])
  }

  // 6. Percents always total 100 (largest remainder), including awkward splits.
  {
    for (const t of [[1, 1, 1], [1, 1, 1, 1, 1, 1], [7, 3, 3], [1, 99], [5, 1, 2, 2, 3]]) {
      const keys = ['done', 'in_progress', 'failed', 'pending', 'rejected', 'unknown']
      const totals = {}
      t.forEach((n, i) => { totals[keys[i]] = n })
      const m = buildPieModel({ totals }, 'x')
      assert.strictEqual(sum(m.slices.map(s => s.percent)), 100, JSON.stringify(t))
    }
  }

  // 7. Headline uses totals.denominator (3 rejected are not in it); empty gives 0 of 0.
  {
    assert.strictEqual(progressHeadline(BLOCK), '5 of 10 done')
    assert.strictEqual(progressHeadline({ empty: true }), '0 of 0 done')
    assert.strictEqual(progressHeadline(undefined), '0 of 0 done')
    assert.strictEqual(progressHeadline({ totals: { done: 2, denominator: 7, rejected: 40 } }), '2 of 7 done')
  }

  // 8. The colour tokens the model names exist in tokens.css.
  {
    const css = fs.readFileSync(tokensPath, 'utf8')
    for (const s of buildPieModel(BLOCK, 'x').slices) {
      assert.ok(css.includes(`${s.colorVar}:`), `${s.colorVar} is defined in tokens.css`)
    }
    assert.ok(css.includes('--color-border-strong:'), '--color-border-strong is defined in tokens.css')
  }

  console.log('progress-model: all assertions passed')
}

main().catch((err) => { console.error(err); process.exit(1) })
