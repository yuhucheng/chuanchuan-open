// Kept identical in chuanchuan and chuanchuan-open; fixtures never need the peer checkout.
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import test from 'node:test';
import { checkSpecVersions } from './check_spec_versions.mjs';

const cli = fileURLToPath(new URL('./check_spec_versions.mjs', import.meta.url));

function fixture(t, repository = 'chuanchuan') {
  const root = mkdtempSync(path.join(tmpdir(), 'spec-versions-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const write = (relative, value) => {
    const target = path.join(root, relative);
    mkdirSync(path.dirname(target), { recursive: true });
    writeFileSync(target, value, 'utf8');
  };
  const catalog = {
    schemaVersion: 1, repository, productVersion: '0.1.0',
    specs: [{ id: 'media-contract', path: 'specs/media-contract/spec.md',
      version: '0.1.0', lifecycle: 'baseline', releaseTarget: '0.1.0' }],
  };
  const saveCatalog = () => write('openspec/catalog.json', JSON.stringify(catalog));
  const writeSpec = (entry = catalog.specs[0], override = {}) => {
    const metadata = {
      'spec-id': entry.id,
      'spec-version': entry.version,
      'product-baseline': '0.1.0',
      'release-target': entry.releaseTarget,
      lifecycle: entry.lifecycle,
      delivery: entry.lifecycle === 'planned' ? 'planned' : 'partial',
      ...override,
    };
    write(`openspec/${entry.path}`, `---\n${Object.entries(metadata)
      .filter(([, value]) => value !== undefined)
      .map(([key, value]) => `${key}: ${value}`).join('\n')}\n---\n# Fixture\n`);
  };
  write('VERSION', '0.1.0\n');
  write('package.json', JSON.stringify({ version: '0.1.0' }));
  write('docs/version-plan.md', '# Version plan\n\n## v0.1.0 — In development\n');
  saveCatalog();
  writeSpec();
  return { root, write, catalog, saveCatalog, writeSpec };
}

function rejects(f, code) {
  const result = checkSpecVersions(f.root);
  assert.ok(result.errors.some(error => error.includes(code)),
    `Expected ${code}; received ${JSON.stringify(result.errors)}`);
}

for (const repository of ['chuanchuan', 'chuanchuan-open']) {
  test(`accepts an independently readable ${repository} catalog`, t => {
    assert.deepEqual(checkSpecVersions(fixture(t, repository).root),
      { errors: [], checkedSpecs: 1 });
  });
}

test('accepts a planned revision of a baseline capability with an independent spec version', t => {
  const f = fixture(t);
  const entry = { id: 'media-contract', path: 'changes/improve-media/specs/media-contract/spec.md',
    version: '1.2.3-beta.1+build.7', lifecycle: 'planned', releaseTarget: 'unassigned' };
  f.catalog.specs.push(entry);
  f.saveCatalog();
  f.writeSpec(entry);
  assert.deepEqual(checkSpecVersions(f.root), { errors: [], checkedSpecs: 2 });
});

for (const field of ['catalog', 'package', 'frontmatter']) {
  test(`rejects product version drift in ${field}`, t => {
    const f = fixture(t);
    if (field === 'catalog') { f.catalog.productVersion = '0.2.0'; f.saveCatalog(); }
    if (field === 'package') f.write('package.json', '{"version":"0.2.0"}');
    if (field === 'frontmatter') f.writeSpec(undefined, { 'product-baseline': '0.2.0' });
    rejects(f, 'VERSION_MISMATCH');
  });
}

for (const version of ['0.1', '01.1.0', '1.0.0-01', 'v0.1.0', '1.0.0+']) {
  test(`rejects invalid spec SemVer ${version}`, t => {
    const f = fixture(t);
    f.catalog.specs[0].version = version;
    f.saveCatalog();
    f.writeSpec();
    rejects(f, 'INVALID_VERSION');
  });
}

test('rejects an invalid root VERSION even when every reference matches', t => {
  const f = fixture(t);
  f.write('VERSION', 'not-a-version');
  f.write('package.json', '{"version":"not-a-version"}');
  f.catalog.productVersion = 'not-a-version';
  f.saveCatalog();
  f.writeSpec(undefined, { 'product-baseline': 'not-a-version' });
  rejects(f, 'INVALID_VERSION');
});

for (const field of ['spec-id', 'spec-version', 'release-target', 'lifecycle']) {
  test(`rejects catalog/frontmatter drift for ${field}`, t => {
    const f = fixture(t);
    const values = { 'spec-id': 'wrong-id', 'spec-version': '0.1.1',
      'release-target': 'unassigned', lifecycle: 'planned' };
    f.writeSpec(undefined, { [field]: values[field] });
    rejects(f, 'METADATA_MISMATCH');
  });
}

for (const specPath of ['specs/unlisted/spec.md', 'changes/new-change/specs/unlisted/spec.md']) {
  test(`rejects an uncatalogued active spec at ${specPath}`, t => {
    const f = fixture(t);
    f.write(`openspec/${specPath}`, '# Not catalogued');
    rejects(f, 'CATALOG_MISSING_SPEC');
  });
}

test('rejects a catalog entry pointing to a missing spec', t => {
  const f = fixture(t);
  rmSync(path.join(f.root, 'openspec', f.catalog.specs[0].path));
  rejects(f, 'SPEC_MISSING');
});

test('rejects duplicate paths', t => {
  const f = fixture(t);
  f.catalog.specs.push({ ...f.catalog.specs[0], id: 'second-id' });
  f.saveCatalog();
  rejects(f, 'DUPLICATE_PATH');
});

test('rejects duplicate capability ids in the same lifecycle', t => {
  const f = fixture(t);
  const duplicate = { ...f.catalog.specs[0], path: 'specs/duplicate/spec.md' };
  f.catalog.specs.push(duplicate);
  f.saveCatalog();
  f.writeSpec(duplicate);
  rejects(f, 'DUPLICATE_ID');
});

for (const delivery of ['implemented', 'partial', 'experimental']) {
  test(`rejects planned specs reported as ${delivery}`, t => {
    const f = fixture(t);
    const entry = { id: 'future', path: 'changes/future/specs/future/spec.md',
      version: '0.1.0', lifecycle: 'planned', releaseTarget: 'unassigned' };
    f.catalog.specs.push(entry);
    f.saveCatalog();
    f.writeSpec(entry, { delivery });
    rejects(f, 'DELIVERY_LIFECYCLE');
  });
}

test('rejects planned delivery on a baseline', t => {
  const f = fixture(t);
  f.writeSpec(undefined, { delivery: 'planned' });
  rejects(f, 'DELIVERY_LIFECYCLE');
});

test('rejects unknown delivery values', t => {
  const f = fixture(t);
  f.writeSpec(undefined, { delivery: 'completed' });
  rejects(f, 'DELIVERY_INVALID');
});

test('rejects unregistered release targets mentioned only in plan prose', t => {
  const f = fixture(t);
  f.write('docs/version-plan.md', '## v0.1.0 — In development\nMaybe v0.2.0 later.\n');
  f.catalog.specs[0].releaseTarget = '0.2.0';
  f.saveCatalog();
  f.writeSpec();
  rejects(f, 'RELEASE_UNREGISTERED');
});

for (const specPath of ['../outside/spec.md', 'specs/../escape/spec.md',
  '/specs/absolute/spec.md', 'C:/outside/spec.md', 'specs\\windows\\spec.md',
  'changes/archive/specs/archived/spec.md']) {
  test(`rejects unsafe or unsupported catalog path ${specPath}`, t => {
    const f = fixture(t);
    f.catalog.specs[0].path = specPath;
    f.saveCatalog();
    rejects(f, 'SPEC_PATH_INVALID');
  });
}

test('rejects a spec directory symlink escaping openspec', t => {
  const f = fixture(t);
  f.write('outside/spec.md', '# Outside');
  symlinkSync(path.join(f.root, 'outside'), path.join(f.root, 'openspec/specs/escape'), 'junction');
  f.catalog.specs.push({ ...f.catalog.specs[0], id: 'escape', path: 'specs/escape/spec.md' });
  f.saveCatalog();
  rejects(f, 'SPEC_PATH_INVALID');
});

test('rejects lifecycle inconsistent with the spec directory', t => {
  const f = fixture(t);
  f.catalog.specs[0].lifecycle = 'planned';
  f.saveCatalog();
  f.writeSpec();
  rejects(f, 'SPEC_PATH_INVALID');
});

test('ignores archived specs when checking catalog coverage', t => {
  const f = fixture(t);
  f.write('openspec/changes/archive/2026-09-15-old/specs/old/spec.md', '# Historical metadata');
  assert.deepEqual(checkSpecVersions(f.root), { errors: [], checkedSpecs: 1 });
});

test('rejects an empty catalog even in an empty repository', t => {
  const f = fixture(t);
  f.catalog.specs = [];
  f.saveCatalog();
  rmSync(path.join(f.root, 'openspec/specs'), { recursive: true });
  rejects(f, 'CATALOG_EMPTY');
});

test('reports malformed JSON without throwing', t => {
  const f = fixture(t);
  f.write('openspec/catalog.json', '{broken');
  rejects(f, 'JSON_INVALID');
});

test('rejects unsupported catalog schemas', t => {
  const f = fixture(t);
  f.catalog.schemaVersion = 2;
  f.saveCatalog();
  rejects(f, 'CATALOG_SCHEMA');
});

test('rejects a missing mandatory frontmatter field', t => {
  const f = fixture(t);
  f.writeSpec(undefined, { delivery: undefined });
  rejects(f, 'FRONTMATTER_INVALID');
});

test('rejects duplicate frontmatter fields even when the final value is correct', t => {
  const f = fixture(t);
  f.write('openspec/specs/media-contract/spec.md', [
    '---', 'spec-id: media-contract', 'spec-id: media-contract', 'spec-version: 0.1.0',
    'product-baseline: 0.1.0', 'release-target: 0.1.0', 'lifecycle: baseline',
    'delivery: partial', '---', '# Fixture', '',
  ].join('\n'));
  rejects(f, 'FRONTMATTER_INVALID');
});

test('CLI accepts --root and default cwd, and exits nonzero on invalid specs', t => {
  const f = fixture(t);
  const valid = spawnSync(process.execPath, [cli, '--root', f.root], { encoding: 'utf8' });
  assert.equal(valid.status, 0, valid.stderr);
  assert.match(valid.stdout, /1 spec/);
  f.catalog.specs = [];
  f.saveCatalog();
  const invalid = spawnSync(process.execPath, [cli], { cwd: f.root, encoding: 'utf8' });
  assert.notEqual(invalid.status, 0);
  assert.match(invalid.stderr, /CATALOG_EMPTY/);
});

test('CLI rejects unknown arguments instead of silently validating the wrong root', t => {
  const f = fixture(t);
  const result = spawnSync(process.execPath, [cli, '--roo', f.root], { encoding: 'utf8' });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /Usage:/);
});
