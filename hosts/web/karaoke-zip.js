// SPDX-License-Identifier: AGPL-3.0-only
// MP3+G archives (OSC-CDG-DOWNLOADS): a .zip holding a song and its .cdg, as karaoke is usually
// downloaded. The archive is untrusted data, so the reader takes only the two entries it needs,
// in memory, and refuses anything it cannot read safely: an archive or entry over its size limit,
// too many entries, a name that would leave the archive, an encrypted or ZIP64 archive, a method
// other than stored or deflate, data that inflates past its declared size or fails its CRC, and an
// archive whose song cannot be told apart from another. hosts/apple/Sources/KaraokeZip.swift
// applies the same rules.

export const ZIP_LIMITS = Object.freeze({
  archive: 64 << 20, // bytes of .zip
  entries: 64,
  cdg: 32 << 20, // decompressed bytes: about 74 minutes of CD+G
  audio: 64 << 20,
});
export const AUDIO_EXTENSIONS = Object.freeze(['mp3', 'ogg', 'oga', 'opus', 'm4a', 'aac', 'wav', 'flac']);

const EOCD = 0x06054b50, CENTRAL = 0x02014b50, LOCAL = 0x04034b50;
const STORED = 0, DEFLATE = 8;

/** Whether `bytes` starts like a zip archive (a local header, or the end record of an empty one). */
export function looksLikeZip(bytes) {
  const b = new Uint8Array(bytes.buffer ?? bytes, bytes.byteOffset ?? 0, Math.min(bytes.byteLength, 4));
  return b.length === 4 && b[0] === 0x50 && b[1] === 0x4b && ((b[2] === 3 && b[3] === 4) || (b[2] === 5 && b[3] === 6));
}

/** Why `name` is not a safe archive path, or null: absolute, a drive letter, a backslash, a NUL
 * or a `..` component. */
export function unsafeName(name) {
  if (name.length === 0) return 'an empty name';
  if (name.startsWith('/')) return 'an absolute path';
  if (/^[A-Za-z]:/.test(name)) return 'a drive letter';
  if (name.includes('\\')) return 'a backslash';
  if (name.includes('\0')) return 'a NUL';
  if (name.split('/').includes('..')) return 'a .. component';
  return null;
}

/** The song and lyrics in an MP3+G archive, as { audio, cdg }, each { name, bytes }; throws an
 * Error saying why the archive is refused. */
export async function openKaraokeZip(input) {
  const zip = input instanceof Uint8Array ? input : new Uint8Array(input);
  if (zip.byteLength > ZIP_LIMITS.archive) throw new Error(`archive is over ${ZIP_LIMITS.archive >> 20} MiB`);
  const entries = centralDirectory(zip);
  const cdgs = [], audios = [];
  for (const e of entries) {
    const why = unsafeName(e.name);
    if (why) throw new Error(`entry ${JSON.stringify(e.name)} has ${why}`);
    if (ignored(e.name)) continue;
    if (/\.cdg$/i.test(e.name)) cdgs.push(e);
    else if (AUDIO_EXTENSIONS.includes(extension(e.name))) audios.push(e);
  }
  const [cdg, audio] = pair(cdgs, audios);
  return {
    audio: { name: basename(audio.name), bytes: await extract(zip, audio, ZIP_LIMITS.audio) },
    cdg: { name: basename(cdg.name), bytes: await extract(zip, cdg, ZIP_LIMITS.cdg) },
  };
}

// Directories and the AppleDouble files macOS adds to archives it makes.
function ignored(name) {
  return name.endsWith('/') || name.startsWith('__MACOSX/') || basename(name).startsWith('._');
}
const basename = name => name.slice(name.lastIndexOf('/') + 1);
const extension = name => { const b = basename(name), i = b.lastIndexOf('.'); return i < 0 ? '' : b.slice(i + 1).toLowerCase(); };
const stem = name => { const i = name.lastIndexOf('.'); return (i < 0 ? name : name.slice(0, i)).toLowerCase(); };

// One lyric file and one song are a pair whatever their names; otherwise the pair is the one stem
// (the path without its extension, ignoring case) with exactly one of each.
function pair(cdgs, audios) {
  if (cdgs.length === 0) throw new Error('archive has no .cdg file');
  if (audios.length === 0) throw new Error(`archive has no song (${AUDIO_EXTENSIONS.join(', ')})`);
  if (cdgs.length === 1 && audios.length === 1) return [cdgs[0], audios[0]];
  const matches = cdgs.filter(c => cdgs.filter(d => stem(d.name) === stem(c.name)).length === 1)
    .map(c => [c, audios.filter(a => stem(a.name) === stem(c.name))])
    .filter(([, a]) => a.length === 1);
  if (matches.length !== 1) {
    throw new Error(`archive holds ${cdgs.length} .cdg files and ${audios.length} songs, and no single pair shares a name`);
  }
  return [matches[0][0], matches[0][1][0]];
}

function centralDirectory(zip) {
  const v = new DataView(zip.buffer, zip.byteOffset, zip.byteLength);
  // the end record is the last 22 bytes plus a comment of up to 65535
  let end = -1;
  for (let i = zip.byteLength - 22; i >= Math.max(0, zip.byteLength - 22 - 0xffff); i--) {
    if (v.getUint32(i, true) === EOCD && i + 22 + v.getUint16(i + 20, true) === zip.byteLength) { end = i; break; }
  }
  if (end < 0) throw new Error('not a zip archive (no end record)');
  const disk = v.getUint16(end + 4, true), cdDisk = v.getUint16(end + 6, true);
  const onDisk = v.getUint16(end + 8, true), count = v.getUint16(end + 10, true);
  const size = v.getUint32(end + 12, true), offset = v.getUint32(end + 16, true);
  if (disk !== 0 || cdDisk !== 0 || onDisk !== count) throw new Error('multi-part archives are not supported');
  if (count === 0xffff || size === 0xffffffff || offset === 0xffffffff) throw new Error('ZIP64 archives are not supported');
  if (count > ZIP_LIMITS.entries) throw new Error(`archive has ${count} entries, over ${ZIP_LIMITS.entries}`);
  if (offset + size > end) throw new Error('central directory is out of range');
  const entries = [];
  let p = offset;
  for (let n = 0; n < count; n++) {
    if (p + 46 > offset + size || v.getUint32(p, true) !== CENTRAL) throw new Error('central directory is corrupt');
    const nameLen = v.getUint16(p + 28, true), extraLen = v.getUint16(p + 30, true), commentLen = v.getUint16(p + 32, true);
    const next = p + 46 + nameLen + extraLen + commentLen;
    if (next > offset + size) throw new Error('central directory is corrupt');
    entries.push({
      name: new TextDecoder().decode(zip.subarray(p + 46, p + 46 + nameLen)),
      flags: v.getUint16(p + 8, true),
      method: v.getUint16(p + 10, true),
      crc: v.getUint32(p + 16, true),
      compressed: v.getUint32(p + 20, true),
      size: v.getUint32(p + 24, true),
      local: v.getUint32(p + 42, true),
      cdOffset: offset,
    });
    p = next;
  }
  return entries;
}

async function extract(zip, e, limit) {
  const name = JSON.stringify(e.name);
  if (e.flags & 1) throw new Error(`${name} is encrypted`);
  if (e.size > limit) throw new Error(`${name} is over ${limit >> 20} MiB`);
  const v = new DataView(zip.buffer, zip.byteOffset, zip.byteLength);
  if (e.local + 30 > e.cdOffset || v.getUint32(e.local, true) !== LOCAL) throw new Error(`${name} has no local header`);
  const start = e.local + 30 + v.getUint16(e.local + 26, true) + v.getUint16(e.local + 28, true);
  if (start + e.compressed > e.cdOffset) throw new Error(`${name} runs past its archive`);
  const data = zip.subarray(start, start + e.compressed);
  let out;
  if (e.method === STORED) {
    if (e.compressed !== e.size) throw new Error(`${name} is stored with a size mismatch`);
    out = data.slice();
  } else if (e.method === DEFLATE) {
    out = await inflate(data, e.size, name);
  } else {
    throw new Error(`${name} uses compression method ${e.method}; only stored and deflate are supported`);
  }
  if (crc32(out) !== e.crc) throw new Error(`${name} fails its CRC check`);
  return out;
}

// Raw deflate into at most `size` bytes: output past the declared size is refused as it arrives,
// so a zip bomb costs no more memory than its declared (and limited) size.
async function inflate(data, size, name) {
  const reader = new Blob([data]).stream().pipeThrough(new DecompressionStream('deflate-raw')).getReader();
  const out = new Uint8Array(size);
  let n = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (n + value.length > size) {
        reader.cancel().catch(() => {});
        throw new Error(`${name} inflates past its declared size`);
      }
      out.set(value, n);
      n += value.length;
    }
  } catch (err) {
    if (err.message?.startsWith(name)) throw err;
    throw new Error(`${name} is not valid deflate data`);
  }
  if (n !== size) throw new Error(`${name} inflates to ${n} bytes, not its declared ${size}`);
  return out;
}

let CRC_TABLE = null;
export function crc32(bytes) {
  if (!CRC_TABLE) {
    CRC_TABLE = new Uint32Array(256);
    for (let i = 0; i < 256; i++) {
      let c = i;
      for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
      CRC_TABLE[i] = c >>> 0;
    }
  }
  let c = 0xffffffff;
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8);
  return (c ^ 0xffffffff) >>> 0;
}
