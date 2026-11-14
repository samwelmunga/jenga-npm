/**
 * @file project/app/api/routes/todo.test.js
 * E47_S10_T01 - plain-`assert` tests for GET /v1/todo against a fixture project in a temp dir
 * (JENGA_PROJECT_ROOT); the live project/todo.md is never read.
 *   node project/app/api/routes/todo.test.js
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const http = require('http');
const express = require('express');

const todoRouter = require('./todo');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'jenga-todo-route-'));
process.env.JENGA_PROJECT_ROOT = root;

function request(port, method) {
  return new Promise((resolve, reject) => {
    const req = http.request({ port, method, path: '/v1/todo' }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => resolve({ status: res.statusCode, body }));
    });
    req.on('error', reject);
    req.end();
  });
}

(async () => {
  const app = express();
  app.use('/v1/todo', todoRouter);
  const server = app.listen(0);
  const port = server.address().port;
  try {
    const missing = await request(port, 'GET');
    assert.strictEqual(missing.status, 200);
    assert.deepEqual(JSON.parse(missing.body).data, [], 'missing todo.md -> empty list');

    fs.mkdirSync(path.join(root, 'project'), { recursive: true });
    fs.writeFileSync(path.join(root, 'project', 'todo.md'), '# Todo\nDo it: E01_S01_T01\nNo ref line\nEpic only: E05\n');
    const res = await request(port, 'GET');
    const json = JSON.parse(res.body);
    assert.strictEqual(res.status, 200);
    assert.strictEqual(json.error, null);
    assert.deepEqual(json.data, [{ ref: 'E01_S01_T01', title: 'Do it', line: 2 }]);

    for (const verb of ['POST', 'PUT', 'PATCH', 'DELETE']) {
      assert.strictEqual((await request(port, verb)).status, 404, verb + ' must not be exposed');
    }
    console.log('todo route tests: all checks passed');
  } catch (err) {
    console.error('todo route tests FAILED:', err.message);
    process.exitCode = 1;
  } finally {
    server.close();
    fs.rmSync(root, { recursive: true, force: true });
  }
})();
