// Kept identical in chuanchuan and chuanchuan-open so either checkout runs independently.
// This checks repository metadata only; the official OpenSpec CLI validates spec content.
import { readFileSync, readdirSync, realpathSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const metadataFields = ['spec-id', 'spec-version', 'product-baseline',
  'release-target', 'lifecycle', 'delivery'];

function isSemVer(value) {
  if (typeof value !== 'string') return false;
  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$/.exec(value);
  return Boolean(match) && (!match[4] || match[4].split('.')
    .every(identifier => !/^\d+$/.test(identifier) || !/^0\d/.test(identifier)));
}

function isWithin(root, target) {
  const relative = path.relative(root, target);
  return relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative);
}

function expectedLifecycle(specPath) {
  if (typeof specPath !== 'string' || /[\\:\0]/.test(specPath) ||
      specPath.split('/').some(part => !part || part === '.' || part === '..')) return null;
  if (/^specs\/[^/]+\/spec\.md$/.test(specPath)) return 'baseline';
  if (/^changes\/(?!archive\/)[^/]+\/specs\/[^/]+\/spec\.md$/.test(specPath)) return 'planned';
  return null;
}

/** Return all diagnostics without modifying the checkout or consulting a peer repository. */
export function checkSpecVersions(root = process.cwd()) {
  root = path.resolve(root);
  const result = { errors: [], checkedSpecs: 0 };
  const report = (code, location, message) => result.errors.push(`${code}: ${location}: ${message}`);
  const read = (relative, code = 'FILE_MISSING') => {
    try { return readFileSync(path.join(root, relative), 'utf8').replace(/^\uFEFF/, ''); }
    catch (error) { report(code, relative, error.message); return null; }
  };
  const readJson = relative => {
    const source = read(relative);
    if (source === null) return null;
    try { return JSON.parse(source); }
    catch (error) { report('JSON_INVALID', relative, error.message); return null; }
  };
  const version = (value, location) => {
    if (!isSemVer(value)) report('INVALID_VERSION', location, `Expected SemVer, received ${JSON.stringify(value)}`);
  };
  const same = (actual, expected, location, code = 'VERSION_MISMATCH') => {
    if (actual !== expected) report(code, location,
      `Expected ${JSON.stringify(expected)}, received ${JSON.stringify(actual)}`);
  };

  const productVersion = read('VERSION')?.trim();
  version(productVersion, 'VERSION');
  const packageJson = readJson('package.json');
  version(packageJson?.version, 'package.json version');
  same(packageJson?.version, productVersion, 'package.json version');
  const versionPlan = read('docs/version-plan.md') ?? '';
  const releases = new Set([...versionPlan.matchAll(/^##[ \t]+v(\d+\.\d+\.\d+)(?=[ \t\r]|$)/gm)]
    .map(match => match[1]).filter(isSemVer));
  const checkRelease = (value, location) => {
    if (value !== 'unassigned' && !releases.has(value)) report('RELEASE_UNREGISTERED', location,
      `Release ${JSON.stringify(value)} is not a ## vX.Y.Z heading in docs/version-plan.md`);
  };

  const catalog = readJson('openspec/catalog.json');
  if (!catalog || typeof catalog !== 'object' || Array.isArray(catalog)) {
    report('CATALOG_SCHEMA', 'openspec/catalog.json', 'Expected a catalog object');
    return result;
  }
  if (catalog.schemaVersion !== 1 || !['chuanchuan', 'chuanchuan-open'].includes(catalog.repository))
    report('CATALOG_SCHEMA', 'openspec/catalog.json', 'Expected schemaVersion 1 and a known repository');
  version(catalog.productVersion, 'catalog productVersion');
  same(catalog.productVersion, productVersion, 'catalog productVersion');
  if (!Array.isArray(catalog.specs)) {
    report('CATALOG_SCHEMA', 'catalog specs', 'Expected an array');
    return result;
  }
  if (!catalog.specs.length) report('CATALOG_EMPTY', 'catalog specs', 'At least one spec must be catalogued');

  const specRoot = path.join(root, 'openspec');
  const realSpecRoot = realpathSync(specRoot);
  const catalogPaths = new Set();
  const catalogIds = new Set();
  for (const [index, entry] of catalog.specs.entries()) {
    const location = `catalog specs[${index}]`;
    if (!entry || typeof entry !== 'object' || Array.isArray(entry)) {
      report('CATALOG_SCHEMA', location, 'Expected a spec entry object');
      continue;
    }
    if (typeof entry.id !== 'string' || !entry.id.trim())
      report('CATALOG_SCHEMA', location, 'Expected a nonempty spec id');
    const identity = JSON.stringify([entry.lifecycle, entry.id]);
    if (catalogIds.has(identity)) report('DUPLICATE_ID', location, `${entry.lifecycle}/${entry.id}`);
    catalogIds.add(identity);
    if (catalogPaths.has(entry.path)) report('DUPLICATE_PATH', location, `${entry.path}`);
    catalogPaths.add(entry.path);
    version(entry.version, `${location} version`);
    checkRelease(entry.releaseTarget, `${location} releaseTarget`);

    const lifecycle = expectedLifecycle(entry.path);
    if (!lifecycle || entry.lifecycle !== lifecycle) {
      report('SPEC_PATH_INVALID', location, 'Use specs/<capability>/spec.md for baseline or changes/<active-change>/specs/<capability>/spec.md for planned');
      continue;
    }
    const specFile = path.join(specRoot, entry.path);
    try {
      if (!isWithin(realSpecRoot, realpathSync(specFile))) {
        report('SPEC_PATH_INVALID', entry.path, 'Resolved path escapes openspec');
        continue;
      }
    } catch (error) {
      report('SPEC_MISSING', entry.path, error.message);
      continue;
    }
    const source = read(`openspec/${entry.path}`, 'SPEC_MISSING');
    if (source === null) continue;
    result.checkedSpecs++;
    const frontmatter = /^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n|$)/.exec(source);
    if (!frontmatter) {
      report('FRONTMATTER_INVALID', entry.path, 'Expected YAML frontmatter at the start of the spec');
      continue;
    }
    const metadata = Object.create(null);
    for (const line of frontmatter[1].split(/\r?\n/)) {
      if (!line.trim() || line.trimStart().startsWith('#')) continue;
      const field = /^([a-z][a-z-]*):[ \t]*([A-Za-z0-9][A-Za-z0-9._+-]*)[ \t]*$/.exec(line);
      if (!field || Object.hasOwn(metadata, field[1])) {
        report('FRONTMATTER_INVALID', entry.path, `Expected unique keys with unquoted scalar values: ${line}`);
        continue;
      }
      metadata[field[1]] = field[2];
    }
    for (const key of metadataFields) {
      if (!metadata[key]) report('FRONTMATTER_INVALID', entry.path, `Missing ${key}`);
    }
    for (const [key, value] of Object.entries({ 'spec-id': entry.id, 'spec-version': entry.version,
      'release-target': entry.releaseTarget, lifecycle: entry.lifecycle })) {
      same(metadata[key], value, `${entry.path} ${key}`, 'METADATA_MISMATCH');
    }
    version(metadata['spec-version'], `${entry.path} spec-version`);
    version(metadata['product-baseline'], `${entry.path} product-baseline`);
    same(metadata['product-baseline'], productVersion, `${entry.path} product-baseline`);
    checkRelease(metadata['release-target'], `${entry.path} release-target`);
    if (!['implemented', 'partial', 'experimental', 'planned'].includes(metadata.delivery))
      report('DELIVERY_INVALID', entry.path, `Unknown delivery ${JSON.stringify(metadata.delivery)}`);
    else if ((metadata.lifecycle === 'planned') !== (metadata.delivery === 'planned'))
      report('DELIVERY_LIFECYCLE', entry.path, 'Planned specs require planned delivery; baseline specs require implemented, partial, or experimental delivery');
  }

  const discover = relative => {
    let children;
    try { children = readdirSync(path.join(specRoot, relative), { withFileTypes: true }); }
    catch (error) {
      if (error.code !== 'ENOENT') report('SPEC_SCAN_FAILED', relative, error.message);
      return;
    }
    for (const child of children.sort((a, b) => a.name.localeCompare(b.name))) {
      const childPath = `${relative}/${child.name}`;
      if (child.isSymbolicLink()) {
        report('SPEC_PATH_INVALID', childPath, 'Spec discovery does not follow symbolic links');
      } else if (child.isDirectory()) discover(childPath);
      else if (child.name === 'spec.md' && !catalogPaths.has(childPath))
        report('CATALOG_MISSING_SPEC', childPath, 'Active spec is absent from openspec/catalog.json');
    }
  };
  discover('specs');
  let changes = [];
  try { changes = readdirSync(path.join(specRoot, 'changes'), { withFileTypes: true }); }
  catch (error) {
    if (error.code !== 'ENOENT') report('SPEC_SCAN_FAILED', 'changes', error.message);
  }
  for (const change of changes) {
    if (change.name === 'archive') continue;
    if (change.isSymbolicLink()) report('SPEC_PATH_INVALID', `changes/${change.name}`, 'Active change must be a local directory');
    else if (change.isDirectory()) discover(`changes/${change.name}/specs`);
  }
  return result;
}

function main(args) {
  const usage = 'Usage: node tool/check_spec_versions.mjs [--root <repository-path>]';
  if (args.length === 1 && (args[0] === '--help' || args[0] === '-h')) {
    console.log(usage);
    return;
  }
  if (args.length && (args.length !== 2 || args[0] !== '--root' || !args[1] || args[1].startsWith('--'))) {
    console.error(usage);
    process.exitCode = 2;
    return;
  }
  const result = checkSpecVersions(args.length ? args[1] : process.cwd());
  if (result.errors.length) {
    console.error(result.errors.join('\n'));
    process.exitCode = 1;
  } else console.log(`Spec metadata valid: ${result.checkedSpecs} spec(s).`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2));
}
