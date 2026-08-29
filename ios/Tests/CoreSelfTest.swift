import Foundation
import CryptoKit
import Darwin

@main
struct CoreSelfTest {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cdrom-ios-core-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }

        let binURL = root.appendingPathComponent("fixture.bin")
        var bin = Data()
        for _ in 0..<588 { bin.append(contentsOf: [0x12, 0x34, 0xff, 0xfe]) }
        for _ in 0..<588 { bin.append(contentsOf: [0x80, 0x00, 0x7f, 0xff]) }
        try bin.write(to: binURL)
        require(sha256(bin) == "70ab904dfa5c7b50c2cdcd02f19f12b2e66dd6d8d76783251c1b755331ca7407", "fixture BIN hash")

        let tocURL = root.appendingPathComponent("fixture.toc")
        let toc = """
        CD_DA
        TRACK AUDIO
        FILE "fixture.bin" 0 00:00:01
        TRACK AUDIO
        FILE "fixture.bin" 588 0
        """
        try toc.write(to: tocURL, atomically: true, encoding: .utf8)
        let tracks = try TOCParser.parse(url: tocURL, binSize: Int64(bin.count))
        require(tracks.count == 2, "TOC track count")
        require(tracks[0].offsetBytes == 0 && tracks[0].lengthBytes == 2_352, "first track range")
        require(tracks[1].offsetBytes == 2_352 && tracks[1].lengthBytes == 2_352, "zero length means EOF")

        let identity = try DiscIdentity.musicBrainz(tracks: tracks, binSize: Int64(bin.count))
        require(identity.trackOffsets == [150, 151], "MusicBrainz offsets")
        require(identity.leadoutSector == 152, "MusicBrainz leadout")

        let pregapTracks = try TOCParser.parse(
            text: """
            CD_DA
            TRACK AUDIO
            FILE "fixture.bin" 0 00:00:01
            START 00:00:01
            TRACK AUDIO
            FILE "fixture.bin" 588 0
            """,
            binSize: Int64(bin.count)
        )
        let pregapIdentity = try DiscIdentity.musicBrainz(tracks: pregapTracks, binSize: Int64(bin.count))
        require(pregapIdentity.trackOffsets[0] == 151, "START contributes to INDEX 01")

        try testConversion(format: .wav, root: root, binURL: binURL, tocURL: tocURL)
        try testConversion(format: .flac, root: root, binURL: binURL, tocURL: tocURL)
        try testFLACAcrossChunkBoundary(root: root)
        print("IOS CORE SELF-TEST PASS: TOC, pregap Disc ID, WAV, chunked FLAC, and decoded PCM verification")
    }

    private static func testConversion(format: AudioOutputFormat, root: URL, binURL: URL, tocURL: URL) throws {
        let outputParent = root.appendingPathComponent("output-\(format.rawValue)", isDirectory: true)
        let summary = try NativeAudioConverter.convert(
            NativeConversionRequest(
                binURL: binURL,
                tocURL: tocURL,
                outputParentURL: outputParent,
                format: format,
                verifyAudio: true,
                album: nil,
                coverData: nil,
                appVersion: IOSAppVersion.fallback
            ),
            progress: { _ in }
        )
        require(summary.tracks.count == 2, "\(format.rawValue) track count")
        require(summary.audioVerification == "passed", "\(format.rawValue) verification state")
        require(summary.tracks.allSatisfy(\.verified), "\(format.rawValue) per-track verification")
        require(
            summary.tracks.map(\.sourceSegmentSHA256) == [
                "0ca147508e4f0d789ac794d57753aff9f93918ec5d4b787a4a9ecf1cc7a6446b",
                "a5932dab71115b7537307dce4e96d9c50dc1a93ee4af91dc6892a5c55a719802",
            ],
            "\(format.rawValue) source hashes"
        )
        require(
            summary.tracks.map(\.decodedOutputPCMSHA256) == summary.tracks.map { Optional($0.sourceSegmentSHA256) },
            "\(format.rawValue) decoded hashes"
        )
        let files = try FileManager.default.contentsOfDirectory(atPath: summary.outputDirectory.path)
        require(files.contains("conversion-metadata.json"), "\(format.rawValue) metadata manifest")
        require(files.contains("SHA256SUMS.txt"), "\(format.rawValue) checksums")
        require(files.filter { $0.hasSuffix(".\(format.rawValue)") }.count == 2, "\(format.rawValue) output files")
        if format == .flac {
            for name in files.filter({ $0.hasSuffix(".flac") }) {
                let url = summary.outputDirectory.appendingPathComponent(name)
                let header = try Data(contentsOf: url, options: .mappedIfSafe).prefix(4)
                require(header == Data("fLaC".utf8), "FLAC native container marker")
            }
        }
    }

    private static func testFLACAcrossChunkBoundary(root: URL) throws {
        // 112 CD sectors contain 65,856 stereo frames, slightly more than the
        // converter's 65,536-frame input chunk. This catches encoders that lose
        // a buffered tail when the write calls do not end on a FLAC packet.
        let binURL = root.appendingPathComponent("chunk-boundary.bin")
        let tocURL = root.appendingPathComponent("chunk-boundary.toc")
        try Data(repeating: 0x5a, count: 112 * 2_352).write(to: binURL)
        try """
        CD_DA
        TRACK AUDIO
        FILE "chunk-boundary.bin" 0 00:01:37
        """.write(to: tocURL, atomically: true, encoding: .utf8)

        let summary = try NativeAudioConverter.convert(
            NativeConversionRequest(
                binURL: binURL,
                tocURL: tocURL,
                outputParentURL: root.appendingPathComponent("output-flac-chunked", isDirectory: true),
                format: .flac,
                verifyAudio: true,
                album: nil,
                coverData: nil,
                appVersion: IOSAppVersion.fallback
            ),
            progress: { _ in }
        )
        require(summary.tracks.count == 1, "chunked FLAC track count")
        require(summary.tracks[0].sampleCount == 65_856, "chunked FLAC sample count")
        require(summary.tracks[0].verified, "chunked FLAC decoded verification")
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else {
            FileHandle.standardError.write(Data("IOS CORE SELF-TEST FAIL: \(label)\n".utf8))
            Darwin.exit(1)
        }
    }
}
