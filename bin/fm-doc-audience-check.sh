#!/usr/bin/env bash
# fm-doc-audience-check.sh - validate the tracked documentation audience inventory.
#
# Usage:
#   bin/fm-doc-audience-check.sh
#   bin/fm-doc-audience-check.sh --root <repo> [--inventory <path>]
#
# The inventory owns classification and setup routing.
# This check validates structure only and does not keyword-lint prose.
# Requires node (version 20 or later).
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
exec node - "$@" <<'JS'
'use strict';
const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const MARKDOWN_LINK_RE = /!?\[[^\]]*\]\(([^)]+)\)/g;
const HTML_LINK_RE = /\b(?:href|src)=["']([^"']+)["']/gi;
const REQUIRED_TRACKED_PATTERNS = ['*.md', '*.mdx', '*.rst', '*.txt', 'docs/examples/*'];

// Python str.splitlines line boundaries.
const LINE_BREAK_RE = new RegExp('\\r\\n|[\\n\\r\\v\\f\\x1c-\\x1e\\x85' + String.fromCharCode(0x2028, 0x2029) + ']');

class CheckError extends Error {}

function fail(message) {
  throw new CheckError(message);
}

// Python-style repr for the few values that appear in messages.
function pyRepr(v) {
  if (v === null || v === undefined) return 'None';
  if (v === true) return 'True';
  if (v === false) return 'False';
  if (typeof v === 'string') {
    const q = v.includes("'") && !v.includes('"') ? '"' : "'";
    let s = v.replace(/\\/g, '\\\\');
    if (q === "'") s = s.replace(/'/g, "\\'");
    s = s.replace(/\n/g, '\\n').replace(/\r/g, '\\r').replace(/\t/g, '\\t');
    return q + s + q;
  }
  if (Array.isArray(v)) return '[' + v.map(pyRepr).join(', ') + ']';
  if (typeof v === 'object') {
    return '{' + Object.entries(v).map(([k, x]) => pyRepr(k) + ': ' + pyRepr(x)).join(', ') + '}';
  }
  return String(v);
}

// Resolve symlinks component by component without requiring the path to exist.
function resolvePath(p) {
  let queue = (p.startsWith('/') ? p : process.cwd() + '/' + p).split('/');
  let resolved = '/';
  let links = 0;
  while (queue.length) {
    const part = queue.shift();
    if (part === '' || part === '.') continue;
    if (part === '..') {
      resolved = path.dirname(resolved);
      continue;
    }
    const cand = resolved === '/' ? '/' + part : resolved + '/' + part;
    let st;
    try {
      st = fs.lstatSync(cand);
    } catch (e) {
      resolved = cand;
      continue;
    }
    if (st.isSymbolicLink()) {
      if (++links > 40) fail('symlink loop from ' + cand);
      const target = fs.readlinkSync(cand);
      if (target.startsWith('/')) resolved = '/';
      queue = target.split('/').concat(queue);
    } else {
      resolved = cand;
    }
  }
  return resolved;
}

function unquote(text) {
  return text.replace(/(%[0-9a-fA-F]{2})+/g, (m) => Buffer.from(m.replace(/%/g, ''), 'hex').toString('utf8'));
}

function urlsplit(url) {
  let rest = url;
  let scheme = '';
  let netloc = '';
  const sm = /^([A-Za-z][A-Za-z0-9+.-]*):/.exec(rest);
  if (sm) {
    scheme = sm[1].toLowerCase();
    rest = rest.slice(sm[0].length);
  }
  if (rest.startsWith('//')) {
    const end = rest.slice(2).search(/[/?#]/);
    const stop = end === -1 ? rest.length : end + 2;
    netloc = rest.slice(2, stop);
    rest = rest.slice(stop);
  }
  let fragment = '';
  const hi = rest.indexOf('#');
  if (hi !== -1) {
    fragment = rest.slice(hi + 1);
    rest = rest.slice(0, hi);
  }
  const qi = rest.indexOf('?');
  if (qi !== -1) rest = rest.slice(0, qi);
  return { scheme, netloc, path: rest, fragment };
}

function readText(file) {
  return new TextDecoder('utf-8', { fatal: true }).decode(fs.readFileSync(file));
}

function gitTracked(root, patterns) {
  const proc = spawnSync('git', ['-C', root, 'ls-files', '-z', '--', ...patterns], { encoding: 'buffer' });
  if (proc.error) fail(`git ls-files failed: ${proc.error.message}`);
  if (proc.status !== 0) {
    const detail = proc.stderr.toString('utf8').trim();
    fail(`git ls-files failed: ${detail || 'unknown error'}`);
  }
  return proc.stdout.toString('utf8').split('\0').filter((p) => p).sort();
}

function isObject(v) {
  return v !== null && typeof v === 'object' && !Array.isArray(v);
}

function loadInventory(file) {
  let data;
  try {
    data = JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch (exc) {
    if (exc && exc.code === 'ENOENT') fail(`inventory is missing: ${file}`);
    fail(`inventory is unreadable: ${exc.message}`);
  }
  if (!isObject(data)) fail('inventory root must be an object');
  if (data.version !== 1) fail('inventory version must be 1');
  return data;
}

function listOfStrings(value, label) {
  if (!Array.isArray(value) || value.length === 0 || !value.every((v) => typeof v === 'string' && v)) {
    fail(`${label} must be a non-empty string array`);
  }
  return value;
}

function normalizedLinkValue(raw) {
  let value = raw.trim();
  if (value.startsWith('<') && value.endsWith('>')) value = value.slice(1, -1).trim();
  if (value.includes(' ')) value = value.split(/\s+/).filter((s) => s)[0];
  return value;
}

function isUnder(root, target) {
  return target === root || target.startsWith(root === '/' ? '/' : root + '/');
}

function resolveLocalTarget(root, source, raw) {
  const split = urlsplit(normalizedLinkValue(raw));
  if (split.scheme || split.netloc) return null;
  if (!split.path) return split.fragment ? resolvePath(source) : null;
  const decoded = unquote(split.path);
  const rel = path.relative(root, source);
  if (decoded.startsWith('/')) fail(`absolute local link in ${rel}: ${raw}`);
  const target = resolvePath(path.dirname(source) + '/' + decoded);
  if (!isUnder(resolvePath(root), target)) fail(`local link escapes repository in ${rel}: ${raw}`);
  return target;
}

function markdownLocalLinks(root, source) {
  let text;
  try {
    text = readText(source);
  } catch (exc) {
    fail(`cannot read prose surface ${path.relative(root, source)}: ${exc.message}`);
  }
  const rawLinks = [...text.matchAll(MARKDOWN_LINK_RE)].map((m) => m[1])
    .concat([...text.matchAll(HTML_LINK_RE)].map((m) => m[1]));
  const result = [];
  for (const raw of rawLinks) {
    const target = resolveLocalTarget(root, source, raw);
    if (target !== null) result.push([raw, target]);
  }
  return result;
}

function githubHeadingSlug(value) {
  value = value.replace(/<[^>]+>/g, '');
  value = value.replace(/`/g, '').trim().toLowerCase();
  value = value.replace(/[^\p{L}\p{N}_\- ]/gu, '');
  return value.replace(/\s/g, '-');
}

function markdownAnchors(file) {
  const anchors = new Set();
  const counts = new Map();
  let lines;
  try {
    lines = readText(file).split(LINE_BREAK_RE);
  } catch (exc) {
    fail(`cannot read link target ${file}: ${exc.message}`);
  }
  for (const line of lines) {
    const match = /^#{1,6}\s+(.+?)\s*#*\s*$/.exec(line);
    if (match) {
      const base = githubHeadingSlug(match[1]);
      if (base) {
        const count = counts.get(base) || 0;
        anchors.add(count === 0 ? base : `${base}-${count}`);
        counts.set(base, count + 1);
      }
    }
    for (const m of line.matchAll(/<(?:a|span)\s+(?:name|id)=["']([^"']+)["']/gi)) anchors.add(m[1]);
  }
  return anchors;
}

function isMarkdown(file) {
  const ext = path.extname(file).toLowerCase();
  return ext === '.md' || ext === '.mdx';
}

function relPosix(root, target) {
  return path.relative(root, target).split(path.sep).join('/');
}

function validate(root, inventoryPath) {
  const data = loadInventory(inventoryPath);
  const scope = data.scope;
  if (!isObject(scope)) fail('scope must be an object');
  const patterns = listOfStrings(scope.trackedPatterns, 'scope.trackedPatterns');
  if (JSON.stringify(patterns) !== JSON.stringify(REQUIRED_TRACKED_PATTERNS)) {
    fail('scope.trackedPatterns must match the fixed maintained-prose scope');
  }
  const audiences = new Set(listOfStrings(data.allowedAudiences, 'allowedAudiences'));
  const setupAudiences = new Set(listOfStrings(data.setupAudiences, 'setupAudiences'));
  for (const a of setupAudiences) {
    if (!audiences.has(a)) fail('setupAudiences contains an audience outside allowedAudiences');
  }

  const surfaces = data.surfaces;
  if (!Array.isArray(surfaces)) fail('surfaces must be an array');
  const paths = [];
  const classifications = new Map();
  surfaces.forEach((entry, index) => {
    if (!isObject(entry)) fail(`surfaces[${index}] must be an object`);
    const p = entry.path;
    const audience = entry.audience;
    if (typeof p !== 'string' || !p) fail(`surfaces[${index}].path must be a non-empty string`);
    if (!audiences.has(audience)) fail(`${p}: unsupported audience ${pyRepr(audience)}`);
    paths.push(p);
    classifications.set(p, audience);
  });

  const pathCounts = new Map();
  for (const p of paths) pathCounts.set(p, (pathCounts.get(p) || 0) + 1);
  const duplicates = [...pathCounts].filter(([, c]) => c !== 1).map(([p]) => p).sort();
  if (duplicates.length) fail('surfaces classified more than once: ' + duplicates.join(', '));

  const tracked = new Set(gitTracked(root, patterns));
  const classified = new Set(paths);
  const missing = [...tracked].filter((p) => !classified.has(p)).sort();
  const extra = [...classified].filter((p) => !tracked.has(p)).sort();
  if (missing.length || extra.length) {
    const details = [];
    if (missing.length) details.push('unclassified: ' + missing.join(', '));
    if (extra.length) details.push('not tracked/in scope: ' + extra.join(', '));
    fail(details.join('; '));
  }

  const readmePath = root + '/README.md';
  const readmeTargets = new Set(markdownLocalLinks(root, readmePath).map(([, target]) => relPosix(root, target)));
  const setupTargets = listOfStrings(data.readmeSetupTargets, 'readmeSetupTargets');
  for (const target of setupTargets) {
    if (!readmeTargets.has(target)) fail(`README setup target is not linked from README.md: ${target}`);
    if (!setupAudiences.has(classifications.get(target))) {
      fail(`README setup target ${target} has disallowed audience ${pyRepr(classifications.get(target))}`);
    }
  }

  const pointers = data.requiredOwnerPointers;
  if (!Array.isArray(pointers) || pointers.length === 0) fail('requiredOwnerPointers must be a non-empty array');
  pointers.forEach((pointer, index) => {
    if (!isObject(pointer)) fail(`requiredOwnerPointers[${index}] must be an object`);
    const source = pointer.source;
    const target = pointer.target;
    if (typeof source !== 'string' || typeof target !== 'string' || !source || !target) {
      fail(`requiredOwnerPointers[${index}] needs non-empty source and target`);
    }
    const sourcePath = root + '/' + source;
    const targetPath = root + '/' + target;
    if (!fs.existsSync(sourcePath)) fail(`owner-pointer source is missing: ${source}`);
    if (!fs.existsSync(targetPath)) fail(`owner-pointer target is missing: ${target}`);
    let sourceText;
    try {
      sourceText = readText(sourcePath);
    } catch (exc) {
      fail(`owner-pointer source is unreadable ${source}: ${exc.message}`);
    }
    let linkedTargets = new Set();
    if (isMarkdown(sourcePath)) {
      linkedTargets = new Set(markdownLocalLinks(root, sourcePath).map(([, linked]) => relPosix(root, linked)));
    }
    if (!sourceText.includes(target) && !linkedTargets.has(target)) {
      fail(`required owner pointer missing: ${source} -> ${target}`);
    }
  });

  let checkedLinks = 0;
  const anchorCache = new Map();
  for (const p of [...tracked].sort()) {
    if (!isMarkdown(p)) continue;
    const source = root + '/' + p;
    for (const [raw, target] of markdownLocalLinks(root, source)) {
      checkedLinks += 1;
      if (!fs.existsSync(target)) fail(`unresolved local link in ${p}: ${raw}`);
      const fragment = unquote(urlsplit(normalizedLinkValue(raw)).fragment);
      if (fragment && fs.statSync(target).isFile() && isMarkdown(target)) {
        if (!anchorCache.has(target)) anchorCache.set(target, markdownAnchors(target));
        if (!anchorCache.get(target).has(fragment)) fail(`unresolved local anchor in ${p}: ${raw}`);
      }
    }
  }
  return [tracked.size, checkedLinks];
}

const USAGE = 'usage: fm-doc-audience-check.sh [-h] [--root ROOT] [--inventory INVENTORY]';

function argError(message) {
  process.stderr.write(`${USAGE}\nfm-doc-audience-check.sh: error: ${message}\n`);
  process.exit(2);
}

function parseArgs(argv) {
  const opts = { root: null, inventory: null };
  const names = ['--root', '--inventory', '--help'];
  const unknown = [];
  for (let i = 0; i < argv.length; i++) {
    let arg = argv[i];
    let inline = null;
    if (arg.startsWith('--')) {
      const eq = arg.indexOf('=');
      if (eq !== -1) {
        inline = arg.slice(eq + 1);
        arg = arg.slice(0, eq);
      }
      const hits = names.filter((n) => n.startsWith(arg));
      if (names.includes(arg)) {
        hits.length = 0;
        hits.push(arg);
      }
      if (hits.length > 1) argError(`ambiguous option: ${arg} could match ${hits.join(', ')}`);
      if (hits.length === 1) arg = hits[0];
    }
    if (arg === '-h' || arg === '--help') {
      process.stdout.write(`${USAGE}\n\nValidate Firstmate documentation audiences and local links.\n\n` +
        'options:\n  -h, --help            show this help message and exit\n  --root ROOT\n  --inventory INVENTORY\n');
      process.exit(0);
    } else if (arg === '--root' || arg === '--inventory') {
      let value = inline;
      if (value === null) {
        if (i + 1 >= argv.length || argv[i + 1].startsWith('-')) argError(`argument ${arg}: expected one argument`);
        value = argv[++i];
      }
      opts[arg.slice(2)] = value;
    } else {
      unknown.push(argv[i]);
    }
  }
  if (unknown.length) argError(`unrecognized arguments: ${unknown.join(' ')}`);
  return opts;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const root = resolvePath(args.root === null ? process.cwd() : args.root);
  let inventoryPath = args.inventory !== null ? args.inventory : root + '/docs/documentation-audiences.json';
  if (!inventoryPath.startsWith('/')) inventoryPath = root + '/' + inventoryPath;
  let surfaces;
  let links;
  try {
    [surfaces, links] = validate(root, inventoryPath);
  } catch (exc) {
    if (exc instanceof CheckError) {
      process.stderr.write(`fm-doc-audience-check: ${exc.message}\n`);
      return 1;
    }
    throw exc;
  }
  process.stdout.write(`fm-doc-audience-check: ok surfaces=${surfaces} local_links=${links}\n`);
  return 0;
}

process.exitCode = main();
JS
