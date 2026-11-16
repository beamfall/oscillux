// SPDX-License-Identifier: AGPL-3.0-only
// Synthetic zip archives for the MP3+G reader's checks (test-karaoke-zip.mjs, cdg-host-check.mjs).
import { deflateRawSync } from 'node:zlib';
import { crc32 } from '../../hosts/web/karaoke-zip.js';

// A zip of `files`, each { name, data, method (0 stored or 8 deflate, the default), and overrides
// of what the headers declare: size, crc, flags, methodDeclared, compressed, local (the offset) };
// `count` overrides the entry count, `comment` sets the archive comment.
export function zip(files, { count, comment = '' } = {}) {
  const enc = new TextEncoder(), locals = [], central = [];
  let offset = 0;
  for (const f of files) {
    const name = enc.encode(f.name), data = f.data ?? new Uint8Array(0);
    const method = f.method ?? 8;
    const body = method === 8 ? deflateRawSync(data) : data;
    const crc = f.crc ?? crc32(data), size = f.size ?? data.length;
    const local = new DataView(new ArrayBuffer(30));
    local.setUint32(0, 0x04034b50, true);
    local.setUint16(4, 20, true);
    local.setUint16(8, f.flags ?? 0, true);
    local.setUint16(10, f.method ?? method, true);
    local.setUint32(14, crc, true);
    local.setUint32(18, body.length, true);
    local.setUint32(22, size, true);
    local.setUint16(26, name.length, true);
    locals.push(new Uint8Array(local.buffer), name, body);
    const c = new DataView(new ArrayBuffer(46));
    c.setUint32(0, 0x02014b50, true);
    c.setUint16(4, 20, true);
    c.setUint16(6, 20, true);
    c.setUint16(8, f.flags ?? 0, true);
    c.setUint16(10, f.methodDeclared ?? method, true);
    c.setUint32(16, crc, true);
    c.setUint32(20, f.compressed ?? body.length, true);
    c.setUint32(24, size, true);
    c.setUint16(28, name.length, true);
    c.setUint32(42, f.local ?? offset, true);
    central.push(new Uint8Array(c.buffer), name);
    offset += 30 + name.length + body.length;
  }
  const cd = concat(central), note = enc.encode(comment);
  const end = new DataView(new ArrayBuffer(22));
  end.setUint32(0, 0x06054b50, true);
  end.setUint16(8, count ?? files.length, true);
  end.setUint16(10, count ?? files.length, true);
  end.setUint32(12, cd.length, true);
  end.setUint32(16, offset, true);
  end.setUint16(20, note.length, true);
  return concat([...locals, cd, new Uint8Array(end.buffer), note]);
}
export function concat(parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  let n = 0;
  for (const p of parts) { out.set(p, n); n += p.length; }
  return out;
}
