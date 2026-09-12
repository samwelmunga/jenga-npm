/**
 * @file project/app/api/parsers/architecture.js
 * Reads package.json and project.config.json to return tech stack + dependency info.
 * The SAD map itself is sourced from project/knowledge-graph/graph.json via ./knowledge-graph.js
 * (E08_S05_T01) rather than parsed live from board epics/stories.
 */

const fs = require('fs');
const path = require('path');
const { readSADMap } = require('./knowledge-graph');
const { resolveProjectRoot } = require('../lib/resolve-project-root');

// Resolved relative to the invoking project's own root (E47_S02_T01/T02), not a fixed __dirname
// climb — see project/app/api/lib/resolve-project-root.js.
const ROOT = resolveProjectRoot();

/**
 * Safely read and parse a JSON file.
 * @param {string} filePath
 * @returns {Object|null}
 */
function readJson(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch {
    return null;
  }
}

/**
 * Parse project config files into architecture metadata.
 * @returns {Promise<Object>}
 */
async function parseArchitecture() {
  const pkg    = readJson(path.join(ROOT, 'package.json'));
  const config = readJson(path.join(ROOT, 'project.config.json'));

  // Build tech stack from project.config.json fields + package metadata
  const tech_stack = [];
  if (config) {
    if (config.workflow)         tech_stack.push({ name: config.workflow, description: `Workflow engine (v${(pkg && pkg.version) || 'unknown'})` }); // E26_S01_T03: version from package.json, not deprecated workflow_version
    if (config.description)      tech_stack.push({ name: 'Jenga AI', description: config.description });
  }
  if (pkg) {
    tech_stack.push({ name: 'Node.js', description: 'JavaScript runtime' });
    const express = pkg.dependencies && pkg.dependencies['express'];
    if (express) tech_stack.push({ name: 'Express', description: `HTTP server framework (${express})` });
  }

  // Build dependency list
  const dependencies = [];
  if (pkg) {
    for (const [name, version] of Object.entries(pkg.dependencies || {})) {
      dependencies.push({ name, version, type: 'runtime' });
    }
    for (const [name, version] of Object.entries(pkg.devDependencies || {})) {
      dependencies.push({ name, version, type: 'devDependency' });
    }
  }

  return {
    tech_stack,
    dependencies,
    sad_map: readSADMap(),
    _sources: {
      package_json: pkg ? { name: pkg.name, version: pkg.version } : null,
      project_config: config || null,
    },
  };
}

module.exports = { parseArchitecture };
