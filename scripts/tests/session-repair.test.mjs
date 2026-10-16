import test from 'node:test';
import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { zstdCompressSync, constants } from 'node:zlib';
import { decodeFrames, convert, loadTarget, run, sessionPath } from '../../Sources/DshForMac/Resources/session-repair.mjs';

const frame = text => zstdCompressSync(Buffer.from(text), { params: { [constants.ZSTD_c_checksumFlag]: 1 } });
const encode = rows => Buffer.concat(rows.map(row => frame(JSON.stringify(row) + '\n')));
const header = { type: 'session', version: 4, id: 'session-fixture', createdAt: 1,
  isSeeded: false, delegationDepth: 0, cwd: '/tmp/fixture' };
const job = { type: 'job/registered', seq: 0, time: 1,
  data: { id: 'job-fixture', kind: 'bash', label: 'fixture', startedAt: 1 } };
const settled = { ...job, type: 'job/settled', seq: 1, data: { ...job.data, status: 'completed', settledAt: 2 } };
const original = encode([header, job, settled]);
const runtimeDirectory = process.env.DSH_REPAIR_TEST_RUNTIME;
const integration = { skip: runtimeDirectory ? false : 'Set DSH_REPAIR_TEST_RUNTIME to an installed 0.2.0-rc.2 runtime' };
const code = expected => error => error.repairCode === expected;

test('decodes all independent frames, including header and every appended batch', () => {
  assert.equal(decodeFrames(original), [header, job, settled].map(row => JSON.stringify(row) + '\n').join(''));
});

test('refuses torn frames, trailing junk, checksum corruption and incomplete JSONL', () => {
  for (const bytes of [original.subarray(0, -1), Buffer.concat([original, Buffer.from('junk')]), frame('{}')]) {
    assert.throws(() => decodeFrames(bytes), code('invalidLog'));
  }
  const corrupt = Buffer.from(original); corrupt[corrupt.length - 1] ^= 1;
  assert.throws(() => decodeFrames(corrupt), code('invalidLog'));
});

test('refuses paths outside the session root, traversal, wrong IDs and symlinks', async () => {
  const root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-repair-path-')));
  try {
    const sessions = path.join(root, 'sessions');
    const directory = path.join(sessions, 'project', header.id);
    await fs.mkdir(directory, { recursive: true });
    const file = path.join(directory, 'session.v4.jsonl.zstd');
    await fs.writeFile(file, original);
    assert.equal(await sessionPath(sessions, file, header.id), file);
    await assert.rejects(sessionPath(root, file, header.id), code('invalidFile'));
    await assert.rejects(sessionPath(sessions, file, '../escape'), code('invalidFile'));
    await assert.rejects(sessionPath(sessions, file, 'session-other'), code('invalidFile'));
    const alias = path.join(root, 'alias'); await fs.symlink(sessions, alias);
    await assert.rejects(sessionPath(alias, path.join(alias, 'project', header.id, path.basename(file)), header.id), code('invalidFile'));
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});

async function fixture(action, target = { runtimeDirectory, version: '0.2.0-rc.2' }) {
  const root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-repair-test-')));
  try {
    const sessionsRoot = path.join(root, 'sessions');
    const file = path.join(sessionsRoot, 'project', header.id, 'session.v4.jsonl.zstd');
    await fs.mkdir(path.dirname(file), { recursive: true });
    await fs.writeFile(file, original);
    const request = { action: 'analyze', ...target,
      sessionsRoot, backupRoot: path.join(root, 'backups'), file, sessionId: header.id };
    await action(request);
  } finally { await fs.rm(root, { recursive: true, force: true }); }
}

test('actual rc.2 reader validates repaired events; newer reader retains original payloads', integration, async () => {
  const target = await loadTarget(runtimeDirectory, '0.2.0-rc.2');
  // Include an ordinary user message so the strict installed surface/message restorer runs.
  const message = { type: 'user/message', seq: 2, time: 3, surfaceOp: 'append',
    data: { role: 'user', id: 'message-fixture', source: { kind: 'user' },
      content: [{ type: 'text', text: 'fixture text' }] } };
  const result = convert(encode([header, job, settled, message]), header.id, target);
  const rows = decodeFrames(result.output).trimEnd().split('\n').map(JSON.parse);
  assert.equal(result.changed, 2); assert.equal(result.eventCount, 3);
  assert.deepEqual(rows, [header, { ...job, ignorable: true }, { ...settled, ignorable: true }, message]);
  const spelling = JSON.stringify(job).replace('"startedAt":1', '"startedAt":1.0000');
  const spelled = convert(Buffer.concat([frame(JSON.stringify(header) + '\n'), frame(spelling + '\n')]), header.id, target);
  assert.ok(decodeFrames(spelled.output).includes('"startedAt":1.0000'));
  assert.throws(() => convert(encode([header, { ...job, type: 'future/required' }, settled]), header.id, target));
  assert.throws(() => convert(encode([header, job, { ...settled, seq: 4 }]), header.id, target), code('validationFailed'));
  const newer = process.env.DSH_REPAIR_TEST_NEWER_RUNTIME;
  if (newer) {
    const reader = await loadTarget(newer, '0.2.1-alpha.4', false);
    for (const bytes of [encode([header, job, settled, message]), result.output]) {
      const [first, ...body] = decodeFrames(bytes).trimEnd().split('\n').map(JSON.parse);
      const restore = reader.catalog.createRestore(first, { recovery: 'strict', validation: 'current' });
      body.forEach(row => restore.decodeRow(row));
      assert.equal(restore.finish().events.length, 3);
    }
  }
});

test('analysis is read-only; repair saves byte-identical backup and restores it exactly', integration, async () => {
  await fixture(async request => {
    const plan = await run(request);
    assert.equal(plan.changed, 2);
    assert.deepEqual(await fs.readFile(request.file), original);
    await assert.rejects(fs.access(request.backupRoot));
    const repair = await run({ ...request, action: 'repair', digest: plan.digest });
    const info = JSON.parse(await fs.readFile(repair.manifest, 'utf8'));
    assert.deepEqual(await fs.readFile(path.join(request.backupRoot, info.backup)), original);
    assert.notDeepEqual(await fs.readFile(request.file), original);
    await run({ ...request, action: 'restore', manifest: repair.manifest });
    assert.deepEqual(await fs.readFile(request.file), original);
    assert.equal((await fs.readdir(request.backupRoot)).filter(name => name.endsWith('.zstd')).length, 2);
  });
});

test('a failed backup leaves original untouched', integration, async () => {
  await fixture(async request => {
    const plan = await run(request);
    await fs.writeFile(request.backupRoot, 'not a directory');
    await assert.rejects(run({ ...request, action: 'repair', digest: plan.digest }));
    assert.deepEqual(await fs.readFile(request.file), original);
  });
});

test('newly appended history refuses stale repair and refuses overwriting on restore', integration, async () => {
  await fixture(async request => {
    const plan = await run(request);
    const appended = Buffer.concat([original, frame(JSON.stringify({ ...job, type: 'job/settled', seq: 2 }) + '\n')]);
    await fs.writeFile(request.file, appended);
    await assert.rejects(run({ ...request, action: 'repair', digest: plan.digest }), code('sessionChanged'));
    assert.deepEqual(await fs.readFile(request.file), appended);
    await fs.writeFile(request.file, original);
    const repair = await run({ ...request, action: 'repair', digest: plan.digest });
    const current = Buffer.concat([await fs.readFile(request.file), frame(JSON.stringify({ ...job, seq: 2 }) + '\n')]);
    await fs.writeFile(request.file, current);
    await assert.rejects(run({ ...request, action: 'restore', manifest: repair.manifest }), code('sessionChanged'));
    assert.deepEqual(await fs.readFile(request.file), current);
  });
});

test('corrupt backup refuses restore without changing the repaired log', integration, async () => {
  await fixture(async request => {
    const plan = await run(request);
    const repair = await run({ ...request, action: 'repair', digest: plan.digest });
    const repaired = await fs.readFile(request.file);
    const info = JSON.parse(await fs.readFile(repair.manifest, 'utf8'));
    await fs.writeFile(path.join(request.backupRoot, info.backup), frame('corrupt\n'));
    await assert.rejects(run({ ...request, action: 'restore', manifest: repair.manifest }), code('invalidBackup'));
    assert.deepEqual(await fs.readFile(request.file), repaired);
  });
});

test('a live DSH lease blocks repair; lock inode survives the operation', integration, async () => {
  await fixture(async request => {
    const plan = await run(request);
    const target = await loadTarget(runtimeDirectory, request.version);
    const lockPath = path.join(path.dirname(request.file), 'session.lock');
    const held = await fs.open(lockPath, 'w');
    try {
      await target.lock(held.fd);
      await assert.rejects(run({ ...request, action: 'repair', digest: plan.digest }), code('sessionBusy'));
      assert.deepEqual(await fs.readFile(request.file), original);
    } finally { await held.close(); }
    const before = await fs.stat(lockPath);
    await run({ ...request, action: 'repair', digest: plan.digest });
    assert.equal((await fs.stat(lockPath)).ino, before.ino);
  });
});

test('unsupported targets and malformed/unknown events never publish a repair', integration, async () => {
  await fixture(async request => {
    await assert.rejects(run({ ...request, version: '0.1.6' }), code('unsupportedVersion'));
    await fs.writeFile(request.file, encode([header, job, { ...settled, type: 'future/required' }]));
    const before = await fs.readFile(request.file);
    await assert.rejects(run(request));
    assert.deepEqual(await fs.readFile(request.file), before);
    await fs.writeFile(request.file, encode([header, { ...job, surfaceOp: 'append' }]));
    await assert.rejects(run(request), code('invalidLog'));
  });
});

const versionsRoot = process.env.DSH_REPAIR_TEST_VERSIONS_ROOT;
if (versionsRoot) {
  for (const entry of await fs.readdir(versionsRoot, { withFileTypes: true })) {
    if (!entry.isDirectory() || !/^\d+\.\d+\.\d+/.test(entry.name)) continue;
    const version = entry.name;
    const directory = path.join(versionsRoot, version);
    test(`installed ${version}: use actual vocabulary, back up and restore without a release allowlist`, async () => {
      const reader = await loadTarget(directory, version);
      await fixture(async request => {
        const unknownJobs = [job, settled].filter(event => !reader.known.has(event.type)).length;
        if (!unknownJobs) {
          await assert.rejects(run(request), code('nothingToRepair'));
          assert.deepEqual(await fs.readFile(request.file), original);
          await assert.rejects(fs.access(request.backupRoot));
          return;
        }
        const plan = await run(request);
        assert.equal(plan.changed, unknownJobs);
        const result = await run({ ...request, action: 'repair', digest: plan.digest });
        const manifest = JSON.parse(await fs.readFile(result.manifest, 'utf8'));
        assert.equal(manifest.version, version);
        assert.deepEqual(await fs.readFile(path.join(request.backupRoot, manifest.backup)), original);
        const [first, ...rows] = decodeFrames(await fs.readFile(request.file)).trimEnd().split('\n').map(JSON.parse);
        const restore = reader.catalog.createRestore(first, { recovery: 'strict', validation: 'current' });
        rows.forEach(row => restore.decodeRow(row));
        assert.equal(restore.finish().events.length, 2);
        await run({ ...request, action: 'restore', manifest: result.manifest });
        assert.deepEqual(await fs.readFile(request.file), original);
      }, { runtimeDirectory: directory, version });
    });
  }
}

test('reader capability checks reject other formats and missing strict restoration APIs', async () => {
  const root = await fs.realpath(await fs.mkdtemp(path.join(os.tmpdir(), 'dsh-repair-reader-')));
  try {
    for (const [name, format, catalogSource, expected] of [
      ['format3', 3, 'export const sessionFormatCatalog = {currentVersion:3,createRestore(){}};', 'unsupportedFormat'],
      ['noStrictReader', 4, 'export const sessionFormatCatalog = {currentVersion:4};', 'unsupportedReader'],
    ]) {
      const directory = path.join(root, name);
      const packages = path.join(directory, 'node_modules/@deepseek-ai');
      for (const pkg of ['dsh', 'dsh-session', 'dsh-session-format-catalog']) {
        const location = path.join(packages, pkg);
        await fs.mkdir(location, { recursive: true });
        await fs.writeFile(path.join(location, 'package.json'), JSON.stringify({
          name: '@deepseek-ai/' + pkg, version: '0.1.7-rc.2', type: 'module', main: 'index.js'
        }));
      }
      await fs.writeFile(path.join(packages, 'dsh-session/index.js'),
        `export const SESSION_FORMAT_VERSION=${format}; export const KNOWN_SESSION_EVENT_TYPES=new Set();`);
      await fs.writeFile(path.join(packages, 'dsh-session-format-catalog/index.js'), catalogSource);
      await assert.rejects(loadTarget(directory, '0.1.7-rc.2'), code(expected));
    }
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});
