import AppKit
import BasketCore

extension SelfTestRunner {
    /// Extras for the image safety flows: the image detail (Keep Only button) and the confirmation
    /// alerts for deleting an in-use image, removing unused images and keeping one platform.
    func captureImageExtras(_ window: NSWindow) async {
        store.selectedSection = .images
        let multi = store.images.first { ImageSlimmer.canSlim($0) && store.imageUsage.isUsed($0.reference) }
            ?? store.images.first { ImageSlimmer.canSlim($0) }
        guard let multi else { return }
        store.imageSelection = [multi.reference]
        try? await Task.sleep(for: .milliseconds(900))
        await capture(window, as: "images-detail")

        let confirmations: [(String, @MainActor () -> Void)] = [
            ("confirm-delete-image", { store.confirmDeleteImages([multi.reference]) }),
            ("confirm-prune-images", { store.confirmPruneImages() }),
            ("confirm-slim-image", { store.confirmSlimImage(multi.reference) }),
        ]
        for (name, show) in confirmations {
            show()
            try? await Task.sleep(for: .milliseconds(900))
            if let alert = window.attachedSheet {
                await capture(alert, as: name)
            } else {
                FileHandle.standardError.write(Data("basket selftest: \(name) did not appear\n".utf8))
            }
            store.confirmation = nil
            try? await Task.sleep(for: .milliseconds(500))
        }
        store.imageSelection = []
        await captureRecoveryArchive(window, reference: multi.reference)
    }

    /// The recovery-archive strip, from a synthetic archive in the UI-test archive directory.
    private func captureRecoveryArchive(_ window: NSWindow, reference: String) async {
        let directory = store.imageArchiveDirectory
        let archive = directory.appending(path: "\(ImageName(reference).repository.split(separator: "/").last ?? "image")-selftest.tar")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try await store.backend.saveImage(reference, platform: store.hostPlatform, to: archive)
        } catch {
            FileHandle.standardError.write(Data("basket selftest: recovery archive: \(error)\n".utf8))
            return
        }
        store.scanRecoveryArchives()
        try? await Task.sleep(for: .milliseconds(900))
        await capture(window, as: "images-recovery")
        try? FileManager.default.removeItem(at: directory)
        store.scanRecoveryArchives()
    }
}
