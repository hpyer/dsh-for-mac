// Offline, explicit compatibility recipes. Never print log contents or raw errors.
import * as fs from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import { createHash, randomUUID } from 'node:crypto';
import { zstdCompressSync, zstdDecompressSync, constants } from 'node:zlib';

const MAX_FILE = 64 * 1024 * 1024;
const MAX_TEXT = 256 * 1024 * 1024;
const JOB_TYPES = new Set(['job/registered', 'job/settled']);
const fail = code => { throw Object.assign(new Error(code), { repairCode: code }); };
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const isObject = value => value !== null && typeof value === 'object' && !Array.isArray(value);

// Node's one-shot decompressor reads only the first frame. DSH appends independent
// Zstandard frames, so scan and validate EVERY frame, including its checksum/tail.
export function decodeFrames(bytes) {
  const decoded = [];
  let offset = 0, total = 0;
  const need = length => { if (offset + length > bytes.length) fail('invalidLog'); };
  while (offset < bytes.length) {
    const start = offset;
    need(5);
    if (bytes.readUInt32LE(offset) !== 0xfd2fb528) fail('invalidLog');
    offset += 4;
    const descriptor = bytes[offset++];
    if (descriptor & 0x18) fail('invalidLog');
    const flag = descriptor >>> 6;
    const single = (descriptor & 0x20) !== 0;
    const dictionary = descriptor & 3;
    const headerBytes = (single ? 0 : 1) + (dictionary === 3 ? 4 : dictionary) +
      (flag === 0 ? (single ? 1 : 0) : 1 << flag);
    need(headerBytes); offset += headerBytes;
    for (;;) {
      need(3);
      const block = bytes.readUIntLE(offset, 3); offset += 3;
      const type = (block >>> 1) & 3;
      if (type === 3) fail('invalidLog');
      const size = type === 1 ? 1 : block >>> 3;
      need(size); offset += size;
      if (block & 1) break;
    }
    if (descriptor & 4) { need(4); offset += 4; }
    let frame;
    try { frame = zstdDecompressSync(bytes.subarray(start, offset), { maxOutputLength: MAX_TEXT - total }); }
    catch { fail('invalidLog'); }
    total += frame.length;
    if (!frame.length || frame[frame.length - 1] !== 10 || total >= MAX_TEXT) fail('invalidLog');
    decoded.push(frame);
  }
  if (!decoded.length) fail('invalidLog');
  try { return new TextDecoder('utf-8', { fatal: true }).decode(Buffer.concat(decoded)); }
  catch { fail('invalidLog'); }
}

async function regularFile(file) {
  const stat = await fs.lstat(file);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > MAX_FILE) fail('invalidFile');
  return stat;
}

// The bridge supplies no authority to access arbitrary paths or follow symlinks.
export async function sessionPath(root, file, sessionId) {
  if (!/^session-[a-zA-Z0-9-]{1,128}$/.test(sessionId)) fail('invalidFile');
  const base = path.resolve(root);
  const target = path.resolve(file);
  const parts = path.relative(base, target).split(path.sep);
  if (parts.length !== 3 || parts.some(p => !p || p === '.' || p === '..') ||
      parts[1] !== sessionId || parts[2] !== 'session.v4.jsonl.zstd') fail('invalidFile');
  if (await fs.realpath(base) !== base || await fs.realpath(target) !== target) fail('invalidFile');
  await regularFile(target);
  return target;
}

export async function loadTarget(directory, version, requiresRecipe = true) {
  const local = createRequire(path.join(directory, 'package.json'));
  const manifest = local.resolve('@deepseek-ai/dsh/package.json');
  const metadata = JSON.parse(await fs.readFile(manifest, 'utf8'));
  if (metadata.name !== '@deepseek-ai/dsh' || metadata.version !== version) fail('unsupportedVersion');
  const require = createRequire(manifest);
  let session, catalog;
  try {
    [session, catalog] = await Promise.all([
      import(pathToFileURL(require.resolve('@deepseek-ai/dsh-session')).href),
      import(pathToFileURL(require.resolve('@deepseek-ai/dsh-session-format-catalog')).href)
    ]);
  } catch { fail('unsupportedReader'); }
  // Match the installed reader's format and vocabulary, not a hard-coded DSH
  // release. A shared V4 header alone does not imply identical event support.
  if (requiresRecipe && (session.SESSION_FORMAT_VERSION !== 4 || catalog.sessionFormatCatalog?.currentVersion !== 4)) {
    fail('unsupportedFormat');
  }
  if (typeof session.KNOWN_SESSION_EVENT_TYPES?.has !== 'function' ||
      typeof catalog.sessionFormatCatalog?.createRestore !== 'function') fail('unsupportedReader');
  let lock;
  try {
    const locking = await import(pathToFileURL(require.resolve('@deepseek-ai/node-addon-system/flock')).href);
    lock = locking.tryLockExclusive;
  } catch { fail('unsupportedReader'); }
  if (typeof lock !== 'function') fail('unsupportedReader');
  return { catalog: catalog.sessionFormatCatalog, known: session.KNOWN_SESSION_EVENT_TYPES, lock };
}

export function convert(bytes, sessionId, target) {
  if (bytes.length > MAX_FILE) fail('invalidFile');
  const text = decodeFrames(bytes);
  if (!text.endsWith('\n')) fail('invalidLog');
  const lines = text.slice(0, -1).split('\n');
  let rows;
  try { rows = lines.map(line => JSON.parse(line)); } catch { fail('invalidLog'); }
  const header = rows[0];
  if (!isObject(header) || header.type !== 'session' || header.version !== 4 || header.id !== sessionId) fail('invalidLog');
  let changed = 0;
  for (let index = 1; index < rows.length; index++) {
    const row = rows[index];
    if (!isObject(row) || typeof row.type !== 'string') fail('invalidLog');
    if (!JOB_TYPES.has(row.type) || target.known.has(row.type) || row.ignorable === true) continue;
    // These lifecycle records carry no messages/surface operations. Keep all fields,
    // sequence numbers and payloads; only opt this audited pair into omission by
    // a target reader that does not already understand them.
    if (!Number.isSafeInteger(row.seq) || !isObject(row.data) ||
        row.surfaceOp !== undefined || row.sourceEventSeqs !== undefined ||
        Object.hasOwn(row, 'ignorable')) fail('invalidLog');
    rows[index] = { ...row, ignorable: true };
    // Insert only the new envelope flag. Preserve the original payload's bytes,
    // whitespace and numeric spellings rather than round-tripping them through JSON.
    const closing = lines[index].lastIndexOf('}');
    lines[index] = lines[index].slice(0, closing) + ',"ignorable":true' + lines[index].slice(closing);
    changed++;
  }
  if (!changed) fail('nothingToRepair');
  let artifact;
  try {
    const restore = target.catalog.createRestore(header, { recovery: 'strict', validation: 'current' });
    for (const row of rows.slice(1)) restore.decodeRow(row);
    artifact = restore.finish();
  } catch { fail('validationFailed'); }
  // Some codec layers preserve unknown envelopes; match the persistence gate too.
  if (artifact.events.some(event => !target.known.has(event.type) && event.ignorable !== true)) fail('unknownEvent');
  const options = { params: { [constants.ZSTD_c_checksumFlag]: 1 } };
  // Header and batches are complete line-aligned checksummed frames, as DSH writes.
  const frames = [zstdCompressSync(Buffer.from(lines[0] + '\n'), options)];
  let batch = '', size = 0;
  for (const line of lines.slice(1)) {
    const record = line + '\n';
    const length = Buffer.byteLength(record);
    if (size && size + length > 1024 * 1024) {
      frames.push(zstdCompressSync(Buffer.from(batch), options)); batch = ''; size = 0;
    }
    batch += record; size += length;
  }
  if (size) frames.push(zstdCompressSync(Buffer.from(batch), options));
  const output = Buffer.concat(frames);
  if (output.length > MAX_FILE) fail('invalidFile');
  if (decodeFrames(output) !== lines.join('\n') + '\n') fail('validationFailed');
  return { output, changed, eventCount: artifact.events.length };
}

async function withLease(file, target, action) {
  const lockPath = path.join(path.dirname(file), 'session.lock');
  const handle = await fs.open(lockPath, fsConstants.O_CREAT | fsConstants.O_RDWR | fsConstants.O_NOFOLLOW, 0o600);
  try {
    try { await target.lock(handle.fd); } catch (error) {
      fail(['EAGAIN', 'EWOULDBLOCK'].includes(error.code) ? 'sessionBusy' : 'unsupportedReader');
    }
    const held = await handle.stat();
    const current = await fs.lstat(lockPath);
    if (!current.isFile() || current.ino !== held.ino || current.dev !== held.dev) fail('sessionBusy');
    return await action();
  } finally { await handle.close(); }
}

async function durableWrite(file, bytes) {
  const handle = await fs.open(file, 'wx', 0o600);
  try { await handle.writeFile(bytes); await handle.sync(); } finally { await handle.close(); }
}

async function syncDirectory(directory) {
  const handle = await fs.open(directory, 'r');
  try { await handle.sync(); } finally { await handle.close(); }
}

async function prepareBackupRoot(root) {
  await fs.mkdir(root, { recursive: true, mode: 0o700 });
  if (await fs.realpath(root) !== path.resolve(root)) fail('invalidBackup');
}

async function backupOriginal(root, file, bytes, info) {
  await prepareBackupRoot(root);
  const id = randomUUID();
  const backup = path.join(root, id + '.zstd');
  const manifest = path.join(root, id + '.json');
  await durableWrite(backup, bytes);
  if (digest(await fs.readFile(backup)) !== digest(bytes)) fail('backupFailed');
  await durableWrite(manifest, JSON.stringify({ format: 1, file, backup: path.basename(backup),
    originalDigest: digest(bytes), createdAt: new Date().toISOString(), ...info }, null, 2));
  await syncDirectory(root);
  return manifest;
}

async function publish(file, bytes, originalDigest) {
  const temporary = path.join(path.dirname(file), '.dshformac-repair-' + randomUUID());
  try {
    await durableWrite(temporary, bytes);
    if (digest(await fs.readFile(temporary)) !== digest(bytes)) fail('validationFailed');
    await regularFile(file);
    if (digest(await fs.readFile(file)) !== originalDigest) fail('sessionChanged');
    await fs.rename(temporary, file);
    await syncDirectory(path.dirname(file));
  } finally { await fs.rm(temporary, { force: true }); }
}

export async function run(request) {
  const target = await loadTarget(request.runtimeDirectory, request.version, request.action !== 'restore');
  if (request.action === 'restore') {
    const root = path.resolve(request.backupRoot);
    const manifest = path.resolve(request.manifest);
    if (path.dirname(manifest) !== root || !/^[a-f0-9-]+\.json$/.test(path.basename(manifest)) ||
        await fs.realpath(root) !== root || await fs.realpath(manifest) !== manifest) fail('invalidBackup');
    await regularFile(manifest);
    const info = JSON.parse(await fs.readFile(manifest, 'utf8'));
    if (info.format !== 1 || !/^[a-f0-9-]+\.zstd$/.test(info.backup) ||
        !/^[a-f0-9]{64}$/.test(info.originalDigest) || !/^[a-f0-9]{64}$/.test(info.repairedDigest)) fail('invalidBackup');
    const file = await sessionPath(request.sessionsRoot, info.file, info.sessionId);
    return withLease(file, target, async () => {
      const backup = path.join(root, info.backup);
      if (await fs.realpath(backup) !== backup) fail('invalidBackup');
      await regularFile(backup);
      const original = await fs.readFile(backup);
      if (digest(original) !== info.originalDigest) fail('invalidBackup');
      const current = await fs.readFile(file);
      if (digest(current) !== info.repairedDigest) fail('sessionChanged');
      // Preserve the repaired branch too. Never restore over newly appended history.
      await backupOriginal(root, file, current, { sessionId: info.sessionId,
        version: request.version, repairedDigest: info.originalDigest, kind: 'beforeRestore' });
      await publish(file, original, info.repairedDigest);
      return { sessionId: info.sessionId };
    });
  }
  if (!['analyze', 'repair'].includes(request.action)) fail('invalidRequest');
  const file = await sessionPath(request.sessionsRoot, request.file, request.sessionId);
  if (request.action === 'analyze') {
    // Read-only snapshot: a changed/torn log refuses here or fails the digest check
    // after the managed server is stopped and an exclusive lease has been acquired.
    const original = await fs.readFile(file);
    const result = convert(original, request.sessionId, target);
    return { digest: digest(original), changed: result.changed, eventCount: result.eventCount };
  }
  return withLease(file, target, async () => {
    const original = await fs.readFile(file);
    const originalDigest = digest(original);
    if (originalDigest !== request.digest) fail('sessionChanged');
    // Back up and verify original compressed bytes BEFORE even generating repair output.
    const manifest = await backupOriginal(request.backupRoot, file, original,
      { sessionId: request.sessionId, version: request.version, kind: 'repair', repairedDigest: null });
    const result = convert(original, request.sessionId, target);
    // Publish the completed manifest before publishing the log. An interruption always
    // leaves the original backup and enough information to identify the repaired branch.
    const info = JSON.parse(await fs.readFile(manifest, 'utf8'));
    const completed = manifest + '.tmp';
    await durableWrite(completed, JSON.stringify({ ...info, repairedDigest: digest(result.output) }, null, 2));
    await fs.rename(completed, manifest);
    await syncDirectory(request.backupRoot);
    await publish(file, result.output, originalDigest);
    return { manifest, changed: result.changed, eventCount: result.eventCount };
  });
}

if (process.argv[1] && pathToFileURL(path.resolve(process.argv[1])).href === import.meta.url) {
  try { console.log(JSON.stringify({ ok: true, ...await run(JSON.parse(process.argv[2])) })); }
  catch (error) {
    // No third-party exception text: it may include session text, paths or credentials.
    console.log(JSON.stringify({ ok: false, code: error.repairCode ?? 'operationFailed' }));
    process.exitCode = 1;
  }
}
