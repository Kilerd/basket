import CryptoKit
import Foundation

/// What an OCI image archive (`container image save` output: an uncompressed tar holding an OCI
/// layout) contains, read without extracting it: the reference names and platform manifests.
public struct ImageArchive: Sendable, Hashable {
    public struct Manifest: Sendable, Hashable {
        /// "linux/arm64/v8"
        public var platform: String
        public var digest: String
        public var annotations: [String: String]
    }

    public var url: URL
    public var fileSize: Int64
    /// Reference names from `index.json` annotations, as written by the CLI.
    public var references: [String]
    /// Platform manifests reachable from `index.json` (nested indexes followed, attestations skipped).
    public var manifests: [Manifest]
    /// Digest of the image index a reference points at after loading (the nested index, if any).
    public var indexDigest: String?

    static let referenceAnnotations = [
        "com.apple.containerization.image.name", "io.containerd.image.name", "org.opencontainers.image.ref.name",
    ]
    static let indexMediaTypes: Set<String> = [
        "application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json",
    ]

    /// Throws `ImageArchive.Invalid` when the file is not a readable OCI archive.
    public static func inspect(_ url: URL) throws -> ImageArchive {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes?[.size] as? NSNumber)?.int64Value else { throw Invalid(reason: "the archive \(url.lastPathComponent) does not exist") }
        guard size > 1024 else { throw Invalid(reason: "the archive is empty (\(size) bytes)") }
        let tar = try TarReader(url: url)
        guard let indexData = try tar.data(of: "index.json") else {
            throw Invalid(reason: "the archive has no index.json")
        }
        let index = try decodeIndex(indexData, name: "index.json")
        var references: [String] = []
        for descriptor in index {
            for key in referenceAnnotations {
                if let name = descriptor.annotations?[key], !name.isEmpty, !references.contains(name) {
                    references.append(name)
                }
            }
        }
        var manifests: [Manifest] = []
        var indexDigest: String?
        try collect(index, from: tar, depth: 0, into: &manifests, indexDigest: &indexDigest)
        return ImageArchive(
            url: url, fileSize: size, references: references, manifests: manifests, indexDigest: indexDigest)
    }

    public struct Invalid: Error, LocalizedError, Sendable, Equatable {
        public var reason: String
        public var errorDescription: String? { "Not a usable image archive: \(reason)." }
    }

    // MARK: Parsing

    struct Descriptor: Codable {
        var mediaType: String?
        var digest: String
        var size: Int64?
        var annotations: [String: String]?
        var platform: Platform?

        struct Platform: Codable {
            var os: String?
            var architecture: String?
            var variant: String?

            var string: String { [os ?? "unknown", architecture ?? "unknown", variant].compactMap { $0 }.joined(separator: "/") }
            var isAttestation: Bool { os == "unknown" || architecture == "unknown" }
        }
    }

    private struct Index: Codable {
        var mediaType: String?
        var manifests: [Descriptor]
    }

    static func decodeIndex(_ data: Data, name: String) throws -> [Descriptor] {
        do {
            return try JSONDecoder().decode(Index.self, from: data).manifests
        } catch {
            throw Invalid(reason: "\(name) is not an OCI index")
        }
    }

    private static func collect(
        _ descriptors: [Descriptor], from tar: TarReader, depth: Int,
        into manifests: inout [Manifest], indexDigest: inout String?
    ) throws {
        for descriptor in descriptors {
            if indexMediaTypes.contains(descriptor.mediaType ?? "") {
                guard depth < 3 else { continue }
                guard let data = try tar.data(of: blobPath(descriptor.digest)) else {
                    throw Invalid(reason: "the index blob \(descriptor.digest.prefix(19)) is missing")
                }
                if indexDigest == nil { indexDigest = descriptor.digest }
                try collect(decodeIndex(data, name: "index blob"), from: tar, depth: depth + 1, into: &manifests,
                            indexDigest: &indexDigest)
            } else if let platform = descriptor.platform, !platform.isAttestation,
                      descriptor.annotations?["vnd.docker.reference.type"] != "attestation-manifest" {
                manifests.append(
                    Manifest(platform: platform.string, digest: descriptor.digest, annotations: descriptor.annotations ?? [:]))
            }
        }
    }

    static func blobPath(_ digest: String) -> String {
        "blobs/" + digest.replacingOccurrences(of: ":", with: "/")
    }
}

// MARK: - Tar

/// Minimal reader for uncompressed ustar/pax/GNU tar files: indexes entry names, reads small entries.
struct TarReader {
    private let handle: FileHandle
    private var entries: [String: (offset: UInt64, size: Int64)] = [:]

    init(url: URL) throws {
        do { handle = try FileHandle(forReadingFrom: url) } catch {
            throw ImageArchive.Invalid(reason: "the archive can't be opened")
        }
        var offset: UInt64 = 0
        var longName: String?
        while true {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 512), header.count == 512 else { break }
            if header.allSatisfy({ $0 == 0 }) { break }
            let bytes = [UInt8](header)
            guard let size = Self.number(bytes[124..<136]) else {
                throw ImageArchive.Invalid(reason: "the archive is not a tar file")
            }
            let type = bytes[156]
            let dataOffset = offset + 512
            var name = Self.string(bytes[0..<100])
            if bytes[257..<262].elementsEqual("ustar".utf8) {
                let prefix = Self.string(bytes[345..<500])
                if !prefix.isEmpty { name = prefix + "/" + name }
            }
            switch type {
            case UInt8(ascii: "L"):  // GNU long name for the next entry
                try handle.seek(toOffset: dataOffset)
                longName = Self.string([UInt8](try handle.read(upToCount: Int(size)) ?? Data())[...])
            case UInt8(ascii: "x"):  // pax header: only `path` matters here
                try handle.seek(toOffset: dataOffset)
                let text = String(decoding: try handle.read(upToCount: Int(size)) ?? Data(), as: UTF8.self)
                for record in text.split(separator: "\n") {
                    if let range = record.range(of: " path=") { longName = String(record[range.upperBound...]) }
                }
            default:
                let full = longName ?? name
                let resolved = full.hasPrefix("./") ? String(full.dropFirst(2)) : full
                longName = nil
                if type == 0 || type == UInt8(ascii: "0") { entries[resolved] = (dataOffset, size) }
            }
            offset = dataOffset + UInt64((size + 511) / 512 * 512)
        }
    }

    /// Contents of a regular file entry (refuses entries over `limit` bytes: only JSON is read).
    func data(of name: String, limit: Int64 = 16 << 20) throws -> Data? {
        guard let entry = entries[name] else { return nil }
        guard entry.size <= limit else { throw ImageArchive.Invalid(reason: "\(name) is unexpectedly large") }
        try handle.seek(toOffset: entry.offset)
        return try handle.read(upToCount: Int(entry.size)) ?? Data()
    }

    var names: [String] { Array(entries.keys) }

    private static func string(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }

    /// Octal (NUL/space padded) or GNU base-256 (high bit set) numeric field.
    private static func number(_ field: ArraySlice<UInt8>) -> Int64? {
        if let first = field.first, first & 0x80 != 0 {
            return field.dropFirst().reduce(Int64(first & 0x7F)) { $0 << 8 | Int64($1) }
        }
        let text = string(field).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? 0 : Int64(text, radix: 8)
    }
}

/// Writes uncompressed ustar files. `appendSparse` reserves an entry's bytes as a hole, so test and
/// fixture archives can claim realistic sizes without using the disk.
struct TarWriter {
    private let handle: FileHandle
    private var offset: UInt64 = 0
    private var holes: [Range<UInt64>] = []

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    mutating func append(_ name: String, _ data: Data) throws {
        try header(name, size: Int64(data.count))
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
        try pad()
    }

    mutating func appendSparse(_ name: String, size: Int64) throws {
        try header(name, size: size)
        holes.append(offset..<offset + UInt64(size))
        offset += UInt64(size)
        try pad()
    }

    mutating func close() throws {
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data(count: 1024))
        // APFS fills a gap left by seeking once something is written after it; punch it out again.
        for hole in holes {
            let start = (hole.lowerBound + 4095) / 4096 * 4096
            let end = hole.upperBound / 4096 * 4096
            guard end > start else { continue }
            var punch = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(start), fp_length: off_t(end - start))
            _ = fcntl(handle.fileDescriptor, F_PUNCHHOLE, &punch)
        }
        try handle.close()
    }

    private mutating func header(_ name: String, size: Int64) throws {
        var block = [UInt8](repeating: 0, count: 512)
        func put(_ text: String, at start: Int, width: Int) {
            for (index, byte) in text.utf8.prefix(width).enumerated() { block[start + index] = byte }
        }
        put(name, at: 0, width: 100)
        put("0000644\0", at: 100, width: 8)
        put("0000000\0", at: 108, width: 8)
        put("0000000\0", at: 116, width: 8)
        put(String(format: "%011llo\0", size), at: 124, width: 12)
        put(String(format: "%011llo\0", 0), at: 136, width: 12)
        put("        ", at: 148, width: 8)
        block[156] = UInt8(ascii: "0")
        put("ustar\0" + "00", at: 257, width: 8)
        let checksum = block.reduce(0) { $0 + Int($1) }
        put(String(format: "%06o\0 ", checksum), at: 148, width: 8)
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data(block))
        offset += 512
    }

    private mutating func pad() throws {
        let remainder = offset % 512
        if remainder != 0 { offset += 512 - remainder }
    }
}

// MARK: - Synthetic archives (FixtureBackend, tests)

extension ImageArchive {
    /// Annotation carrying a variant's size in synthetic archives (real manifests list their layers).
    static let fixtureSizeAnnotation = "dev.basket.fixture.size"

    /// Writes an OCI-layout tar shaped like `container image save` output: `index.json` naming
    /// `reference` → a nested index with one manifest per variant. Each variant's bytes are a sparse
    /// hole of its size, so the archive is as large as the real one without using the disk.
    static func writeSynthetic(reference: String, variants: [ImageVariant], to url: URL) throws {
        func json(_ object: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        let manifests: [[String: Any]] = variants.map { variant in
            let parts = variant.platform.split(separator: "/").map(String.init)
            var platform: [String: String] = ["os": parts.first ?? "linux", "architecture": parts.count > 1 ? parts[1] : "unknown"]
            if parts.count > 2 { platform["variant"] = parts[2] }
            return [
                "mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": variant.digest,
                "size": variant.sizeBytes, "platform": platform,
                "annotations": [fixtureSizeAnnotation: String(variant.sizeBytes)],
            ]
        }
        let inner = try json([
            "schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": manifests,
        ])
        let innerDigest = "sha256:" + SHA256.hash(data: inner).map { String(format: "%02x", $0) }.joined()
        let names = Dictionary(uniqueKeysWithValues: referenceAnnotations.map { ($0, reference) })
        let index = try json([
            "schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json",
            "manifests": [[
                "mediaType": "application/vnd.oci.image.index.v1+json", "digest": innerDigest, "size": inner.count,
                "annotations": names,
            ]],
        ])
        var tar = try TarWriter(url: url)
        try tar.append("oci-layout", Data(#"{"imageLayoutVersion":"1.0.0"}"#.utf8))
        try tar.append(blobPath(innerDigest), inner)
        for variant in variants { try tar.appendSparse(blobPath(variant.digest), size: variant.sizeBytes) }
        try tar.append("index.json", index)
        try tar.close()
    }
}
