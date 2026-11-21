import AppKit
import BasketCore

extension SelfTestRunner {
    /// Extras for updates: the sheet for `<fixtures>/update/latest.json` (offer, download, a
    /// security failure, up to date). Shown from fixture data only; nothing is fetched.
    func captureUpdateExtras(_ window: NSWindow) async {
        guard let file = store.options.fixturesDirectory?.appending(path: "update/latest.json"),
              let data = try? Data(contentsOf: file) else { return }
        let offer: UpdateOffer
        do {
            offer = try UpdateManifest.decode(data).validated(policy: .production)
        } catch {
            FileHandle.standardError.write(Data("basket selftest: update fixture: \(error)\n".utf8))
            return
        }
        let updates = store.updates
        let size: Int64 = 9_650_000  // synthetic, the size of a typical Basket.zip
        let states: [(String, UpdatePhase, UpdateOffer?)] = [
            ("sheet-update", .available, offer),
            ("sheet-update-progress", .downloading(received: 3_870_000, expected: size), offer),
            ("sheet-update-error", .failed(updates.failure(UpdateError.badSignature, retry: .install)), nil),
            ("sheet-update-uptodate", .upToDate, nil),
        ]
        for (name, phase, offer) in states {
            updates.showForSelfTest(phase, offer: offer, size: size)
            store.activeSheet = .update
            try? await Task.sleep(for: .milliseconds(900))
            if let sheet = window.attachedSheet {
                await capture(sheet, as: name)
            } else {
                FileHandle.standardError.write(Data("basket selftest: \(name) did not appear\n".utf8))
            }
            store.activeSheet = nil
            try? await Task.sleep(for: .milliseconds(500))
        }
        updates.showForSelfTest(.idle, offer: nil, size: nil)
    }
}
