// SPDX-License-Identifier: AGPL-3.0-only
// Checks the web host's MP3+G reader (hosts/web/karaoke-zip.js) on synthetic archives: the pairs
// it opens and every archive it must refuse. `--write DIR` also writes each case as DIR/<name>.zip
// plus DIR/cases.json, for the Swift reader's check (make karaoke-zip-swift).
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { openKaraokeZip, looksLikeZip, ZIP_LIMITS } from '../../hosts/web/karaoke-zip.js';
import { zip } from './zip-fixture.mjs';

const bytes = (n, seed) => Uint8Array.from({ length: n }, (_, i) => (i * 31 + seed * 7 + (i >> 5)) & 0xff);
const SONG = bytes(5000, 1), LYRICS = bytes(24 * 300, 2);

const pair = (song = 'song.mp3', lyrics = 'song.cdg', method = 8) =>
  [{ name: song, data: SONG, method }, { name: lyrics, data: LYRICS, method }];
// [name, archive, want]: want is [audio name, cdg name] or a pattern the refusal must match.
const CASES = [
  ['stored', zip(pair('song.mp3', 'song.cdg', 0)), ['song.mp3', 'song.cdg']],
  ['deflate', zip(pair()), ['song.mp3', 'song.cdg']],
  ['one-of-each', zip(pair('Artist - Track.MP3', 'lyrics.CDG')), ['Artist - Track.MP3', 'lyrics.CDG']],
  ['nested', zip([{ name: 'Album/' }, ...pair('Album/01 Song.ogg', 'Album/01 song.cdg')]), ['01 Song.ogg', '01 song.cdg']],
  ['stem-match', zip([...pair('a.mp3', 'a.cdg'), { name: 'b.mp3', data: SONG }]), ['a.mp3', 'a.cdg']],
  ['extras', zip([{ name: 'readme.txt', data: SONG }, { name: 'cover.jpg', data: SONG }, ...pair('k.m4a', 'k.cdg')]), ['k.m4a', 'k.cdg']],
  ['appledouble', zip([...pair(), { name: '__MACOSX/._song.mp3', data: SONG }, { name: '._song.cdg', data: LYRICS }]), ['song.mp3', 'song.cdg']],
  ['comment', zip(pair(), { comment: 'downloaded karaoke' }), ['song.mp3', 'song.cdg']],
  ['two-pairs', zip([...pair('a.mp3', 'a.cdg'), ...pair('b.mp3', 'b.cdg')]), /2 \.cdg files and 2 songs/],
  ['two-cdg-one-stem', zip([...pair('a.mp3', 'a.cdg'), { name: 'A.CDG', data: LYRICS }]), /no single pair/],
  ['no-cdg', zip([{ name: 'song.mp3', data: SONG }]), /no \.cdg/],
  ['no-song', zip([{ name: 'song.cdg', data: LYRICS }, { name: 'song.mid', data: SONG }]), /no song/],
  ['empty', zip([]), /no \.cdg/],
  ['traversal', zip(pair('../song.mp3')), /\.\. component/],
  ['traversal-inner', zip(pair('song.mp3', 'a/../../song.cdg')), /\.\. component/],
  ['traversal-ignored', zip([...pair(), { name: '__MACOSX/../../x' }]), /\.\. component/],
  ['absolute', zip(pair('song.mp3', '/song.cdg')), /absolute path/],
  ['backslash', zip(pair('dir\\song.mp3')), /backslash/],
  ['drive', zip(pair('C:song.mp3')), /drive letter/],
  ['entries', zip([...pair(), ...Array.from({ length: ZIP_LIMITS.entries - 1 }, (_, i) => ({ name: `x${i}.txt` }))]), /entries, over/],
  ['declared-over-limit', zip([pair()[0], { name: 'song.cdg', data: LYRICS, size: ZIP_LIMITS.cdg + 1 }]), /over 32 MiB/],
  ['bomb', zip([pair()[0], { name: 'song.cdg', data: new Uint8Array(4 << 20), size: 24 * 300 }]), /inflates past its declared size/],
  ['short', zip([pair()[0], { name: 'song.cdg', data: LYRICS, size: LYRICS.length + 1 }]), /inflates to 7200 bytes/],
  ['method', zip([pair()[0], { name: 'song.cdg', data: LYRICS, methodDeclared: 12 }]), /compression method 12/],
  ['encrypted', zip([pair()[0], { name: 'song.cdg', data: LYRICS, flags: 1 }]), /encrypted/],
  ['crc', zip([pair()[0], { name: 'song.cdg', data: LYRICS, crc: 1 }]), /CRC/],
  ['stored-size', zip([pair()[0], { name: 'song.cdg', data: LYRICS, method: 0, size: 100 }]), /size mismatch/],
  ['corrupt-deflate', zip([pair()[0], { name: 'song.cdg', data: LYRICS, method: 0, methodDeclared: 8, size: 100 }]), /not valid deflate|inflates/],
  ['local-offset', zip([pair()[0], { name: 'song.cdg', data: LYRICS, local: 1 }]), /no local header/],
  ['past-end', zip([pair()[0], { name: 'song.cdg', data: LYRICS, compressed: 1 << 20 }]), /runs past/],
  ['zip64', zip(pair(), { count: 0xffff }), /ZIP64/],
  ['not-zip', new TextEncoder().encode('ID3 this is an mp3, not a zip'), /not a zip archive/],
  ['archive-over-limit', new Uint8Array(ZIP_LIMITS.archive + 1), /archive is over 64 MiB/],
];

const failures = [];
for (const [name, archive, want] of CASES) {
  let got;
  try {
    got = await openKaraokeZip(archive);
  } catch (e) {
    if (Array.isArray(want)) failures.push(`${name}: refused (${e.message}), want ${want}`);
    else if (!want.test(e.message)) failures.push(`${name}: refused with "${e.message}", want ${want}`);
    continue;
  }
  if (!Array.isArray(want)) { failures.push(`${name}: opened ${got.audio.name}, want a refusal ${want}`); continue; }
  if (got.audio.name !== want[0] || got.cdg.name !== want[1]) failures.push(`${name}: paired ${got.audio.name} + ${got.cdg.name}, want ${want}`);
  if (Buffer.compare(got.audio.bytes, SONG) || Buffer.compare(got.cdg.bytes, LYRICS)) failures.push(`${name}: extracted bytes differ`);
}
if (!looksLikeZip(CASES[0][1]) || !looksLikeZip(zip([])) || looksLikeZip(CASES.at(-2)[1])) failures.push('looksLikeZip');

const out = process.argv.indexOf('--write');
if (out > 0) {
  const dir = process.argv[out + 1];
  mkdirSync(dir, { recursive: true });
  const cases = CASES.filter(([name]) => name !== 'archive-over-limit').map(([name, archive, want]) => {
    writeFileSync(join(dir, `${name}.zip`), archive);
    return { name, want: Array.isArray(want) ? want : want.source };
  });
  writeFileSync(join(dir, 'cases.json'), JSON.stringify({ song: SONG.length, lyrics: LYRICS.length, cases }, null, 1));
}

if (failures.length) { console.error(failures.join('\n')); process.exit(1); }
console.log(`test-karaoke-zip: ${CASES.length} archives opened or refused as specified`);
