/**
 * @file project/app/api/parsers/architecture.js
 * Reads package.json and project.config.json to return tech stack + dependency info.
 * Also builds a SAD map from board epics/stories.
 */

const fs = require('fs');
const path = require('path');
const matter = require('gray-matter');

const ROOT = path.resolve(__dirname, '../../../..');

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
 * Build a Software Architecture Diagram map from board epics/stories and package.json.
 * @returns {{ nodes: Array, edges: Array }}
 */
function parseSADMap() {
  try {
    const pkg = readJson(path.join(ROOT, 'package.json'));
    const epicsDir   = path.join(ROOT, 'project/board/epics');
    const storiesDir = path.join(ROOT, 'project/board/stories');

    const nodes = [];
    const edges = [];

    // Epic nodes
    const epicMap = {}; // id -> stories array
    if (fs.existsSync(epicsDir)) {
      const epicFiles = fs.readdirSync(epicsDir).filter(f => f.endsWith('.md'));
      for (const file of epicFiles) {
        try {
          const raw = fs.readFileSync(path.join(epicsDir, file), 'utf8');
          const { data } = matter(raw);
          if (data.id) {
            nodes.push({ id: data.id, label: data.title || data.id, type: 'epic' });
            epicMap[data.id] = data.stories || [];
          }
        } catch { /* skip unreadable file */ }
      }
    }

    // Story nodes + epic→story edges
    if (fs.existsSync(storiesDir)) {
      const storyFiles = fs.readdirSync(storiesDir).filter(f => f.endsWith('.md'));
      for (const file of storyFiles) {
        try {
          const raw = fs.readFileSync(path.join(storiesDir, file), 'utf8');
          const { data } = matter(raw);
          if (data.id) {
            nodes.push({ id: data.id, label: data.title || data.id, type: 'story' });
            if (data.epic_id) {
              edges.push({ from: data.epic_id, to: data.id });
            }
          }
        } catch { /* skip unreadable file */ }
      }
    }

    // Root project node + key dependency nodes
    const KEY_DEPS = ['express', 'react', 'react-dom', 'vite', 'cors', 'gray-matter'];
    const rootId = (pkg && pkg.name) ? pkg.name : 'project';
    nodes.push({ id: rootId, label: rootId, type: 'service' });

    const allDeps = Object.assign({}, pkg && pkg.dependencies, pkg && pkg.devDependencies);
    for (const dep of KEY_DEPS) {
      if (dep in allDeps) {
        nodes.push({ id: dep, label: dep, type: 'dependency' });
        edges.push({ from: rootId, to: dep });
      }
    }

    return { nodes, edges };
  } catch {
    return { nodes: [], edges: [] };
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
    if (config.description)      tech_stack.push({ name: 'JengaAgent', description: config.description });
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
    sad_map: parseSADMap(),
    _sources: {
      package_json: pkg ? { name: pkg.name, version: pkg.version } : null,
      project_config: config || null,
    },
  };
}

module.exports = { parseArchitecture };
