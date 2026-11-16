// SPDX-License-Identifier: AGPL-3.0-only
// MP3+G archives (OSC-CDG-DOWNLOADS): a .zip holding a song and its .cdg, as karaoke is usually
// downloaded. The archive is untrusted data, so the reader takes only the two entries it needs,
// in memory, and refuses anything it cannot read safely: an archive or entry over its size limit,
// too many entries, a name that would leave the archive, an encrypted or ZIP64 archive, a method
// other than stored or deflate, data that inflates past its declared size or fails its CRC, and an
// archive whose song cannot be told apart from another. The rules and messages are those of
// hosts/web/karaoke-zip.js; `make karaoke-zip-swift` checks this reader on its cases.
import Compression
import Foundation

struct KaraokeZipError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct KaraokeZip {
    static let archiveLimit = 64 << 20
    static let entryLimit = 64
    /// decompressed bytes: about 74 minutes of CD+G
    static let cdgLimit = 32 << 20
    static let audioLimit = 64 << 20
    static let audioExtensions = ["mp3", "ogg", "oga", "opus", "m4a", "aac", "wav", "flac"]

    let audioName: String
    let audio: Data
    let cdgName: String
    let cdg: Data

    /// Reads the archive at `url`, refusing one over the size limit before reading it.
    init(url: URL) throws {
        if let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > Self.archiveLimit {
            throw KaraokeZipError("archive is over \(Self.archiveLimit >> 20) MiB")
        }
        try self.init(data: try Data(contentsOf: url))
    }

    init(data: Data) throws {
        guard data.count <= Self.archiveLimit else { throw KaraokeZipError("archive is over \(Self.archiveLimit >> 20) MiB") }
        let zip = [UInt8](data)
        var cdgs: [Entry] = [], audios: [Entry] = []
        for e in try Self.centralDirectory(zip) {
            if let why = Self.unsafeName(e.name) { throw KaraokeZipError("entry \"\(e.name)\" has \(why)") }
            if Self.ignored(e.name) { continue }
            let ext = Self.extensionOf(e.name)
            if ext == "cdg" { cdgs.append(e) } else if Self.audioExtensions.contains(ext) { audios.append(e) }
        }
        let (c, a) = try Self.pair(cdgs, audios)
        audioName = Self.basename(a.name)
        audio = try Self.extract(zip, a, limit: Self.audioLimit)
        cdgName = Self.basename(c.name)
        cdg = try Self.extract(zip, c, limit: Self.cdgLimit)
    }

    /// Whether `data` starts like a zip archive (a local header, or the end record of an empty one).
    static func looksLikeZip(_ data: Data) -> Bool {
        let b = [UInt8](data.prefix(4))
        return b.count == 4 && b[0] == 0x50 && b[1] == 0x4b && ((b[2] == 3 && b[3] == 4) || (b[2] == 5 && b[3] == 6))
    }

    /// Runs `body` on the song written to a new temporary directory under a name this host
    /// chooses (`song.<its extension>`, which is on the audio list), and deletes it after.
    func withAudioFile<R>(_ body: (URL) throws -> R) throws -> R {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oscillux-karaoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("song.\(Self.extensionOf(audioName))")
        try audio.write(to: file)
        return try body(file)
    }

    private struct Entry {
        var name: String
        var flags: Int, method: Int
        var crc: UInt32
        var compressed: Int, size: Int, local: Int, cdOffset: Int
    }

    /// Why `name` is not a safe archive path, or nil: absolute, a drive letter, a backslash, a
    /// NUL or a `..` component.
    static func unsafeName(_ name: String) -> String? {
        if name.isEmpty { return "an empty name" }
        if name.hasPrefix("/") { return "an absolute path" }
        let u = Array(name.utf8)
        if u.count >= 2, u[1] == UInt8(ascii: ":"), (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(u[0] & 0xdf) { return "a drive letter" }
        if name.contains("\\") { return "a backslash" }
        if name.utf8.contains(0) { return "a NUL" }
        if name.split(separator: "/", omittingEmptySubsequences: false).contains("..") { return "a .. component" }
        return nil
    }

    /// Directories and the AppleDouble files macOS adds to archives it makes.
    private static func ignored(_ name: String) -> Bool {
        name.hasSuffix("/") || name.hasPrefix("__MACOSX/") || basename(name).hasPrefix("._")
    }
    private static func basename(_ name: String) -> String {
        name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
    }
    private static func extensionOf(_ name: String) -> String {
        let b = basename(name)
        guard let dot = b.lastIndex(of: ".") else { return "" }
        return b[b.index(after: dot)...].lowercased()
    }
    private static func stem(_ name: String) -> String {
        guard let dot = name.lastIndex(of: ".") else { return name.lowercased() }
        return name[..<dot].lowercased()
    }

    /// One lyric file and one song are a pair whatever their names; otherwise the pair is the
    /// one stem (the path without its extension, ignoring case) with exactly one of each.
    private static func pair(_ cdgs: [Entry], _ audios: [Entry]) throws -> (Entry, Entry) {
        if cdgs.isEmpty { throw KaraokeZipError("archive has no .cdg file") }
        if audios.isEmpty { throw KaraokeZipError("archive has no song (\(audioExtensions.joined(separator: ", ")))") }
        if cdgs.count == 1 && audios.count == 1 { return (cdgs[0], audios[0]) }
        let matches = cdgs.filter { c in cdgs.filter { stem($0.name) == stem(c.name) }.count == 1 }
            .map { c in (c, audios.filter { stem($0.name) == stem(c.name) }) }
            .filter { $0.1.count == 1 }
        guard matches.count == 1 else {
            throw KaraokeZipError("archive holds \(cdgs.count) .cdg files and \(audios.count) songs, and no single pair shares a name")
        }
        return (matches[0].0, matches[0].1[0])
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
    private static func u32(_ b: [UInt8], _ i: Int) -> Int { u16(b, i) | u16(b, i + 2) << 16 }

    private static func centralDirectory(_ zip: [UInt8]) throws -> [Entry] {
        // the end record is the last 22 bytes plus a comment of up to 65535
        var end = -1
        var i = zip.count - 22
        while i >= max(0, zip.count - 22 - 0xffff) {
            if u32(zip, i) == 0x06054b50 && i + 22 + u16(zip, i + 20) == zip.count { end = i; break }
            i -= 1
        }
        guard end >= 0 else { throw KaraokeZipError("not a zip archive (no end record)") }
        let count = u16(zip, end + 10), size = u32(zip, end + 12), offset = u32(zip, end + 16)
        guard u16(zip, end + 4) == 0, u16(zip, end + 6) == 0, u16(zip, end + 8) == count else {
            throw KaraokeZipError("multi-part archives are not supported")
        }
        if count == 0xffff || size == 0xffff_ffff || offset == 0xffff_ffff { throw KaraokeZipError("ZIP64 archives are not supported") }
        if count > entryLimit { throw KaraokeZipError("archive has \(count) entries, over \(entryLimit)") }
        guard offset + size <= end else { throw KaraokeZipError("central directory is out of range") }
        var entries: [Entry] = []
        var p = offset
        for _ in 0..<count {
            guard p + 46 <= offset + size, u32(zip, p) == 0x02014b50 else { throw KaraokeZipError("central directory is corrupt") }
            let nameLen = u16(zip, p + 28)
            let next = p + 46 + nameLen + u16(zip, p + 30) + u16(zip, p + 32)
            guard next <= offset + size else { throw KaraokeZipError("central directory is corrupt") }
            entries.append(Entry(
                name: String(decoding: zip[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self),
                flags: u16(zip, p + 8), method: u16(zip, p + 10), crc: UInt32(u32(zip, p + 16)),
                compressed: u32(zip, p + 20), size: u32(zip, p + 24), local: u32(zip, p + 42), cdOffset: offset))
            p = next
        }
        return entries
    }

    private static func extract(_ zip: [UInt8], _ e: Entry, limit: Int) throws -> Data {
        let name = "\"\(e.name)\""
        if e.flags & 1 != 0 { throw KaraokeZipError("\(name) is encrypted") }
        if e.size > limit { throw KaraokeZipError("\(name) is over \(limit >> 20) MiB") }
        guard e.local + 30 <= e.cdOffset, u32(zip, e.local) == 0x04034b50 else { throw KaraokeZipError("\(name) has no local header") }
        let start = e.local + 30 + u16(zip, e.local + 26) + u16(zip, e.local + 28)
        guard start + e.compressed <= e.cdOffset else { throw KaraokeZipError("\(name) runs past its archive") }
        let data = zip[start..<(start + e.compressed)]
        let out: [UInt8]
        switch e.method {
        case 0:
            guard e.compressed == e.size else { throw KaraokeZipError("\(name) is stored with a size mismatch") }
            out = Array(data)
        case 8:
            out = try inflate(data, size: e.size, name: name)
        default:
            throw KaraokeZipError("\(name) uses compression method \(e.method); only stored and deflate are supported")
        }
        guard crc32(out) == e.crc else { throw KaraokeZipError("\(name) fails its CRC check") }
        return Data(out)
    }

    /// Raw deflate (COMPRESSION_ZLIB is RFC 1951) into a buffer one byte past the declared size,
    /// so output past it is refused and a zip bomb costs no more memory than its declared (and
    /// limited) size.
    private static func inflate(_ src: ArraySlice<UInt8>, size: Int, name: String) throws -> [UInt8] {
        guard !src.isEmpty else { throw KaraokeZipError("\(name) is not valid deflate data") }
        var out = [UInt8](repeating: 0, count: size + 1)
        let n = src.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                compression_decode_buffer(d.baseAddress!, d.count, s.baseAddress!, s.count, nil, COMPRESSION_ZLIB)
            }
        }
        if n > size { throw KaraokeZipError("\(name) inflates past its declared size") }
        if n == 0 && size > 0 { throw KaraokeZipError("\(name) is not valid deflate data") }
        if n != size { throw KaraokeZipError("\(name) inflates to \(n) bytes, not its declared \(size)") }
        out.removeLast()
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xedb8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }
    static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xffff_ffff
        for b in bytes { c = crcTable[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) }
        return c ^ 0xffff_ffff
    }
}
