import Foundation
import Testing
@testable import BasketCore

@Suite struct ContainerBundleOptionsTests {
    @Test func readsAutoRemoveFromTheBundle() throws {
        let dir = try TemporaryDirectory()
        defer { dir.cleanup() }
        func write(_ id: String, _ json: String) throws {
            let bundle = dir.url.appending(path: "containers/\(id)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try json.write(to: bundle.appending(path: "options.json"), atomically: true, encoding: .utf8)
        }
        // Verbatim from container 1.7.1 (`container run --rm` vs a plain run).
        try write("scratch", #"{"autoRemove":true}"#)
        try write("keeper", #"{"autoRemove":false}"#)
        try write("garbled", "not json")
        #expect(ContainerBundleOptions.removeOnStop(containerID: "scratch", appRoot: dir.url) == true)
        #expect(ContainerBundleOptions.removeOnStop(containerID: "keeper", appRoot: dir.url) == false)
        #expect(ContainerBundleOptions.removeOnStop(containerID: "garbled", appRoot: dir.url) == nil)
        #expect(ContainerBundleOptions.removeOnStop(containerID: "missing", appRoot: dir.url) == nil)
    }
}
