#!/usr/bin/env node
/** Rebuild pinned EPK audio from official cached assets and metadata (Node 20+). */

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const INDEX_SHA1 = '981aab8147520cdc1f0d4a84f46c161929021fee';
const METADATA_SHA256 = '69cc6cfeccf235d71ffb307aa9150c784690c48f510be3036dd42f7e3050ce98';
const PAKO_210_SHA256 = 'ede2693a4a6a5126b9d35669062b358ecab6ae7b9b86a1cf302feb45a8514907';
const PINS = {
  sounds: '94bc8bfcf4132c52c6d5f61f3f92e50532a6fad1f5bc901ee25a462db8ba4fc6',
  music: 'f01cdaf62a9686438998b11ffed5407a1b890e14960c63f71b57401d02216a4e',
};
const COUNTS = { sounds: 4779, music: 92 };
const END = Buffer.from(':::YEE:>');
const SHA1 = /^[0-9a-f]{40}$/;
const SHA256 = /^[0-9a-f]{64}$/;
const MAX_OBJECT_BYTES = 12 * 1024 * 1024;
const DEFAULT_PAKO = path.join(path.dirname(fileURLToPath(import.meta.url)),
  'vendor', 'pako-2.1.0', 'pako.min.js');

function hash(data, algorithm = 'sha256') {
  return createHash(algorithm).update(data).digest('hex');
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function checkedBuffer(file, maxBytes) {
  rejectSymlinks(file);
  const stat = fs.statSync(file);
  assert(stat.isFile() && stat.size <= maxBytes, `file missing, not regular, or too large: ${file}`);
  return fs.readFileSync(file);
}

function rejectSymlinks(target) {
  let current = path.resolve(target);
  while (true) {
    if (fs.existsSync(current)) assert(!fs.lstatSync(current).isSymbolicLink(), `symlink in path: ${current}`);
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
}

function u32(value) {
  const buffer = Buffer.alloc(4);
  buffer.writeUInt32BE(value >>> 0);
  return buffer;
}

const OGG_CRC_TABLE = new Uint32Array(256);
for (let i = 0; i < 256; i++) {
  let value = i << 24;
  for (let bit = 0; bit < 8; bit++) value = (value & 0x80000000) ? ((value << 1) ^ 0x04c11db7) : (value << 1);
  OGG_CRC_TABLE[i] = value >>> 0;
}

function oggCrc(buffer, start, end) {
  let crc = 0;
  for (let pos = start; pos < end; pos++) crc = ((crc << 8) ^ OGG_CRC_TABLE[((crc >>> 24) ^ buffer[pos]) & 255]) >>> 0;
  return crc;
}

const ZIP_CRC_TABLE = new Uint32Array(256);
for (let i = 0; i < 256; i++) {
  let value = i;
  for (let bit = 0; bit < 8; bit++) value = (value & 1) ? ((value >>> 1) ^ 0xedb88320) : (value >>> 1);
  ZIP_CRC_TABLE[i] = value >>> 0;
}

function recordCrc(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) crc = (ZIP_CRC_TABLE[(crc ^ byte) & 255] ^ (crc >>> 8)) >>> 0;
  return (crc ^ 0xffffffff) >>> 0;
}

function pages(buffer, visit) {
  let pos = 0;
  let count = 0;
  while (pos < buffer.length) {
    assert(pos + 27 <= buffer.length && buffer.toString('ascii', pos, pos + 4) === 'OggS', `invalid Ogg page at ${pos}`);
    const segmentCount = buffer[pos + 26];
    const tableEnd = pos + 27 + segmentCount;
    assert(tableEnd <= buffer.length, 'truncated Ogg lacing table');
    let end = tableEnd;
    for (let cursor = pos + 27; cursor < tableEnd; cursor++) end += buffer[cursor];
    assert(end <= buffer.length, 'truncated Ogg page body');
    visit(pos, end, count);
    pos = end;
    count++;
  }
  assert(count > 0, 'empty Ogg payload');
  return count;
}

function normalizedOgg(source) {
  const output = Buffer.from(source);
  pages(output, (pos) => {
    output.fill(0, pos + 14, pos + 18);
    output.fill(0, pos + 22, pos + 26);
  });
  return output;
}

function restoreOgg(source, serials) {
  const output = Buffer.from(source);
  let serialIndex = 0;
  let active = null;
  pages(output, (pos, end, pageNo) => {
    if (pageNo === 0 || (output[pos + 5] & 0x02) !== 0) {
      assert(serialIndex < serials.length, 'more Ogg streams than pinned serials');
      active = Buffer.from(serials[serialIndex++], 'hex');
      assert(active.length === 4, 'invalid pinned Ogg serial');
    }
    active.copy(output, pos + 14);
    output.fill(0, pos + 22, pos + 26);
    output.writeUInt32LE(oggCrc(output, pos, end), pos + 22);
  });
  assert(serialIndex === serials.length, 'fewer Ogg streams than pinned serials');
  return output;
}

function parseArgs(argv) {
  const args = {};
  const names = new Set(['metadata', 'index', 'objects', 'ffmpeg', 'pako', 'output', 'group', 'max-members', 'max-seconds']);
  for (let i = 0; i < argv.length; i += 2) {
    const name = argv[i].replace(/^--/, '');
    assert(argv[i].startsWith('--') && names.has(name) && argv[i + 1] !== undefined && args[name] === undefined,
      `invalid argument: ${argv[i]}`);
    args[name] = argv[i + 1];
  }
  for (const name of ['metadata', 'index', 'objects', 'ffmpeg', 'output', 'group']) {
    assert(args[name], `missing --${name}`);
  }
  assert(['sounds', 'music', 'both'].includes(args.group), 'group must be sounds, music, or both');
  args.pako ??= DEFAULT_PAKO;
  args['max-members'] = args['max-members'] === undefined ? 0 : Number(args['max-members']);
  args['max-seconds'] = args['max-seconds'] === undefined ? 1800 : Number(args['max-seconds']);
  assert(Number.isInteger(args['max-members']) && args['max-members'] >= 0, 'invalid --max-members');
  assert(Number.isInteger(args['max-seconds']) && args['max-seconds'] > 0, 'invalid --max-seconds');
  return args;
}

function validateInputs(args) {
  assert(Number(process.versions.node.split('.')[0]) >= 20, 'Node 20+ is required');
  const metadataBytes = checkedBuffer(args.metadata, 2_000_000);
  assert(hash(metadataBytes) === METADATA_SHA256, 'pinned audio metadata SHA-256 mismatch');
  const metadata = JSON.parse(metadataBytes.toString('utf8'));
  assert(metadata.format === 'eagler-26.2-audio-epk-metadata-v1', 'audio metadata format mismatch');
  assert(Object.keys(metadata.groups).sort().join(',') === 'music,sounds', 'audio metadata groups mismatch');
  const indexBytes = checkedBuffer(args.index, 2_000_000);
  assert(hash(indexBytes, 'sha1') === INDEX_SHA1, 'official asset index SHA-1 mismatch');
  const index = JSON.parse(indexBytes.toString('utf8')).objects;
  assert(index && typeof index === 'object', 'official asset index missing objects map');
  const indexedOgg = Object.keys(index).filter(name => name.startsWith('minecraft/sounds/') && name.endsWith('.ogg'));
  assert(indexedOgg.length === 4871, 'official index OGG count mismatch');
  const groups = args.group === 'both' ? ['sounds', 'music'] : [args.group];
  let pako = null;
  if (groups.includes('sounds')) {
    const pakoBytes = checkedBuffer(args.pako, 300_000);
    assert(hash(pakoBytes) === PAKO_210_SHA256, 'pako 2.1.0 artifact SHA-256 mismatch');
    pako = createRequire(import.meta.url)(path.resolve(args.pako));
    assert(typeof pako.gzip === 'function', 'pako artifact lacks gzip function');
  }
  const seen = new Set();
  for (const group of groups) {
    const meta = metadata.groups[group];
    assert(meta.archive_sha256 === PINS[group], `${group} archive pin mismatch`);
    assert(meta.compression === (group === 'sounds' ? 'G' : '0'), `${group} EPK compression mismatch`);
    assert(meta.version === 'ver2.0', `${group} EPK version mismatch`);
    assert(Array.isArray(meta.rows) && meta.rows.length === meta.declared_records, `${group} EPK record count mismatch`);
    const header = Buffer.from(meta.header_prefix_hex, 'hex');
    assert(header.toString('ascii', 0, 8) === 'EAGPKG$$' && header.at(-1) === meta.compression.charCodeAt(0),
      `${group} EPK header mismatch`);
    const files = meta.rows.filter(row => row.tag === 'FILE');
    assert(files.length === COUNTS[group], `${group} member count mismatch`);
    for (const row of files) {
      assert(row.name.startsWith('assets/minecraft/sounds/') && row.name.endsWith('.ogg'), 'invalid audio member path');
      assert(!seen.has(row.name), `duplicate audio member: ${row.name}`);
      assert(SHA256.test(row.sha256) && SHA256.test(row.normalized_sha256), 'invalid member digest');
      assert(Array.isArray(row.serials) && row.serials.length > 0 && row.serials.every(serial => /^[0-9a-f]{8}$/.test(serial)),
        'invalid pinned Ogg serial');
      assert(index[row.name.slice(7)], `member absent from official index: ${row.name}`);
      seen.add(row.name);
    }
  }
  if (args.group === 'both') assert(seen.size === indexedOgg.length, 'EPK members do not cover official OGG index');
  rejectSymlinks(args.objects);
  assert(fs.statSync(args.objects).isDirectory(), 'objects root is not a directory');
  assert(path.isAbsolute(args.ffmpeg), 'explicit --ffmpeg path must be absolute');
  rejectSymlinks(args.ffmpeg);
  const version = spawnSync(args.ffmpeg, ['-version'], { encoding: 'utf8', timeout: 10000 });
  assert(version.status === 0 && version.stdout.startsWith('ffmpeg version 6.1.1'),
    `FFmpeg 6.1.1 required: ${version.error || version.stdout?.split('\n')[0] || version.stderr}`);
  return { metadata, index, groups, version: version.stdout.split('\n')[0], pako };
}

function createOutput(directory) {
  rejectSymlinks(directory);
  assert(!fs.existsSync(directory), 'output directory already exists');
  const parent = path.dirname(path.resolve(directory));
  assert(fs.statSync(parent).isDirectory(), 'output parent must exist');
  fs.mkdirSync(directory, { recursive: false });
}

function encodeFile(row, objectPath, group, ffmpeg, scratch, deadline) {
  const entry = row.name.slice(7);
  const source = checkedBuffer(objectPath, MAX_OBJECT_BYTES);
  const indexEntry = scratch.index[entry];
  assert(indexEntry && SHA1.test(indexEntry.hash) && source.length === indexEntry.size
    && hash(source, 'sha1') === indexEntry.hash, `official object size/SHA-1 mismatch: ${entry}`);
  let generated = source;
  let recipe = 'official-object';
  if (hash(source) !== row.sha256) {
    const output = path.join(scratch.output, 'transcode.ogg');
    const settings = group === 'sounds'
      ? ['-c:a', 'libvorbis', '-ar', '22050', '-ac', '1', '-q:a', '0']
      : ['-c:a', 'libopus', '-ac', '1', '-b:a', entry.startsWith('minecraft/sounds/records/') ? '16k' : '12k'];
    const remaining = Math.min(120000, Math.max(1000, deadline - Date.now()));
    const run = spawnSync(ffmpeg, ['-v', 'error', '-y', '-i', objectPath, ...settings, output],
      { encoding: 'utf8', timeout: remaining, maxBuffer: 512 * 1024 });
    assert(run.status === 0, `FFmpeg failed for ${entry}: ${run.error || run.stderr?.slice(-500)}`);
    generated = fs.readFileSync(output);
    fs.unlinkSync(output);
    assert(hash(normalizedOgg(generated)) === row.normalized_sha256, `normalized Ogg mismatch: ${entry}`);
    recipe = settings.join(' ');
  }
  const payload = restoreOgg(generated, row.serials);
  assert(payload.length === row.size && hash(payload) === row.sha256, `pinned member mismatch: ${entry}`);
  return { payload, recipe, officialSha1: indexEntry.hash };
}

function frameRecords(rows, members) {
  const parts = [];
  for (const row of rows) {
    const name = Buffer.from(row.name, 'utf8');
    assert(name.length <= 255, 'EPK record name too long');
    const tag = Buffer.from(row.tag, 'ascii');
    const prefix = Buffer.concat([tag, Buffer.from([name.length]), name]);
    if (row.tag === 'HEAD') {
      const data = Buffer.from(row.head_hex, 'hex');
      assert(data.length === row.size, 'HEAD metadata size mismatch');
      parts.push(Buffer.concat([prefix, u32(data.length), data, Buffer.from('>')]));
    } else if (row.tag === 'FILE') {
      const data = members.get(row.name);
      assert(data, `missing rebuilt member: ${row.name}`);
      parts.push(Buffer.concat([prefix, u32(data.length + 5), u32(recordCrc(data)), data, Buffer.from(':>')]));
    } else {
      throw new Error(`unknown EPK record tag: ${row.tag}`);
    }
  }
  parts.push(Buffer.from('END$'));
  return Buffer.concat(parts);
}

function rebuildGroup(group, metadata, index, args, deadline, pako) {
  const meta = metadata.groups[group];
  const rows = meta.rows.filter(row => row.tag === 'FILE');
  const selected = args['max-members'] > 0 ? rows.slice(0, args['max-members']) : rows;
  const members = new Map();
  const counts = {};
  const journal = path.join(args.output, `${group}-members.jsonl`);
  const fd = fs.openSync(journal, 'wx');
  try {
    for (const row of selected) {
      assert(Date.now() < deadline, `run deadline reached after ${members.size} ${group} members`);
      const key = row.name.slice(7);
      const object = index[key];
      assert(object && SHA1.test(object.hash), `official index entry invalid: ${key}`);
      const objectPath = path.join(args.objects, object.hash.slice(0, 2), object.hash);
      const result = encodeFile(row, objectPath, group, args.ffmpeg, { index, output: args.output }, deadline);
      members.set(row.name, result.payload);
      counts[result.recipe] = (counts[result.recipe] || 0) + 1;
      fs.writeSync(fd, JSON.stringify({ member: row.name, official_sha1: result.officialSha1,
        output_sha256: hash(result.payload), expected_sha256: row.sha256, recipe: result.recipe }) + '\n');
    }
  } finally {
    fs.closeSync(fd);
  }
  const result = { expected_members: rows.length, processed_members: members.size, recipe_counts: counts };
  if (selected.length !== rows.length) {
    result.status = 'partial-fixture';
    result.remaining_members = rows.length - members.size;
    return result;
  }
  const recordStream = frameRecords(meta.rows, members);
  result.candidate_records_sha256 = hash(recordStream);
  result.expected_records_sha256 = meta.records_sha256;
  assert(result.candidate_records_sha256 === meta.records_sha256, `${group} EPK record stream mismatch`);
  let encoded = recordStream;
  if (meta.compression === 'G') {
    encoded = Buffer.from(pako.gzip(recordStream, { level: 9, mtime: 0 }));
  }
  const archive = Buffer.concat([Buffer.from(meta.header_prefix_hex, 'hex'), encoded, END]);
  result.candidate_archive_sha256 = hash(archive);
  result.expected_archive_sha256 = PINS[group];
  assert(result.candidate_archive_sha256 === PINS[group], `${group} archive SHA-256 mismatch`);
  const target = path.join(args.output, `${group}.epk`);
  fs.writeFileSync(target, archive, { flag: 'wx' });
  result.archive_path = target;
  result.archive_size = archive.length;
  result.remaining_members = 0;
  result.status = 'exact';
  return result;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const start = Date.now();
  const receipt = { status: 'precheck-failed', started_unix: Math.floor(start / 1000), groups: {} };
  let createdOutput = false;
  try {
    createOutput(args.output);
    createdOutput = true;
    const { metadata, index, groups, version, pako } = validateInputs(args);
    receipt.status = 'running';
    receipt.metadata_sha256 = METADATA_SHA256;
    receipt.index_sha1 = INDEX_SHA1;
    receipt.ffmpeg = version;
    receipt.pako_sha256 = pako ? PAKO_210_SHA256 : null;
    receipt.objects_root = path.resolve(args.objects);
    receipt.output = path.resolve(args.output);
    const deadline = start + args['max-seconds'] * 1000;
    for (const group of groups) receipt.groups[group] = rebuildGroup(group, metadata, index, args, deadline, pako);
    receipt.status = Object.values(receipt.groups).every(result => result.status === 'exact') ? 'exact' : 'partial-fixture';
  } catch (error) {
    receipt.error = String(error?.message || error);
    if (receipt.status === 'running') receipt.status = 'failed';
  }
  receipt.elapsed_seconds = Number(((Date.now() - start) / 1000).toFixed(3));
  if (createdOutput) {
    fs.writeFileSync(path.join(args.output, 'final.json'), JSON.stringify(receipt, null, 2) + '\n', { flag: 'wx' });
  }
  process.stdout.write(JSON.stringify(receipt) + '\n');
  process.exitCode = receipt.status === 'exact' || receipt.status === 'partial-fixture' ? 0 : 2;
}

main();
