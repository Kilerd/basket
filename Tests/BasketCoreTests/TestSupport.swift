import Foundation
import Testing
@testable import BasketCore

enum TestFixtures {
    /// Real `container` 1.7.1 output bundled with the tests.
    static var realDirectory: URL {
        Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    }

    static func real(_ name: String) throws -> Data {
        try Data(contentsOf: realDirectory.appendingPathComponent(name))
    }

    /// `Fixtures/<set>` at the repository root (demo, empty, stopped).
    static func set(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures").appendingPathComponent(name)
    }

    static func date(_ iso: String) -> Date {
        RawJSON.parseDate(iso)!
    }
}

/// A throwaway directory removed by `cleanup()`.
struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("basket-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    /// Writes an executable `/bin/sh` script and returns its path.
    func script(_ name: String, _ body: String) throws -> String {
        let path = url.appendingPathComponent(name).path
        try ("#!/bin/sh\n" + body).write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: url)
    }
}

func collect(_ stream: AsyncThrowingStream<String, Error>, limit: Int = .max) async throws -> [String] {
    var lines: [String] = []
    for try await line in stream {
        lines.append(line)
        if lines.count >= limit { break }
    }
    return lines
}
