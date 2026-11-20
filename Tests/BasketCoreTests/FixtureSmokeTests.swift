import Testing
import Foundation

@Test func fixturesAreBundled() throws {
    let url = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("container-list.json").path))
}
