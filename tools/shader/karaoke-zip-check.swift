// SPDX-License-Identifier: AGPL-3.0-only
// Checks the Apple host's MP3+G reader (hosts/apple/Sources/KaraokeZip.swift) on the cases
// test-karaoke-zip.mjs --write DIR wrote for the web reader: the same pairs open and every
// refusal matches the same pattern. `make karaoke-zip-swift` builds and runs it.
import Foundation

@main
struct KaraokeZipCheck {
    struct Cases: Decodable {
        struct Case: Decodable {
            let name: String
            let pair: [String]?
            let refusal: String?
            enum CodingKeys: String, CodingKey { case name, want }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decode(String.self, forKey: .name)
                pair = try? c.decode([String].self, forKey: .want)
                refusal = pair == nil ? try c.decode(String.self, forKey: .want) : nil
            }
        }
        let song: Int
        let lyrics: Int
        let cases: [Case]
    }

    static func main() throws {
        let dir = URL(fileURLWithPath: CommandLine.arguments[1])
        let spec = try JSONDecoder().decode(Cases.self, from: Data(contentsOf: dir.appendingPathComponent("cases.json")))
        var failures: [String] = []
        for c in spec.cases {
            let data = try Data(contentsOf: dir.appendingPathComponent("\(c.name).zip"))
            do {
                let k = try KaraokeZip(data: data)
                guard let want = c.pair else { failures.append("\(c.name): opened \(k.audioName), want a refusal /\(c.refusal!)/"); continue }
                if [k.audioName, k.cdgName] != want { failures.append("\(c.name): paired \(k.audioName) + \(k.cdgName), want \(want)") }
                if k.audio.count != spec.song || k.cdg.count != spec.lyrics { failures.append("\(c.name): extracted \(k.audio.count) + \(k.cdg.count) bytes") }
                // the song is written under the host's name for the call, then deleted
                let file = try k.withAudioFile { url -> URL in
                    if (try? Data(contentsOf: url))?.count != spec.song { failures.append("\(c.name): no temporary song") }
                    return url
                }
                if file.lastPathComponent != "song.\((want[0] as NSString).pathExtension.lowercased())" { failures.append("\(c.name): temporary song \(file.lastPathComponent)") }
                if FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path) { failures.append("\(c.name): temporary song left behind") }
            } catch {
                let message = error.localizedDescription
                guard let pattern = c.refusal else { failures.append("\(c.name): refused (\(message)), want \(c.pair!)"); continue }
                if message.range(of: pattern, options: .regularExpression) == nil { failures.append("\(c.name): refused with \"\(message)\", want /\(pattern)/") }
            }
        }
        if !KaraokeZip.looksLikeZip(try Data(contentsOf: dir.appendingPathComponent("stored.zip"))) { failures.append("looksLikeZip") }
        if !failures.isEmpty {
            FileHandle.standardError.write(failures.joined(separator: "\n").appending("\n").data(using: .utf8)!)
            exit(1)
        }
        print("karaoke-zip-check: \(spec.cases.count) archives opened or refused as the web reader does")
    }
}
