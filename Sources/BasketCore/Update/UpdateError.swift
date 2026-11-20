import Foundation

/// Why an update check or install stopped. `isSecurityFailure` errors mean the download is not
/// what Basket's maintainer published: it is deleted and never installed, and the UI offers no
/// way around it.
public enum UpdateError: Error, Equatable, Sendable {
    /// `latest.json` is malformed or breaks a rule of docs/updates.md.
    case invalidManifest(String)
    /// The server or the network failed (manifest or archive).
    case network(String)
    /// The archive is larger than `UpdatePolicy.maxArchiveBytes`.
    case tooLarge(Int64)
    /// The downloaded zip's SHA-256 is not the manifest's `sha256`.
    case checksumMismatch
    /// The Ed25519 signature doesn't verify with any of the built-in public keys.
    case badSignature
    /// The public keys compiled into the app (or the DEBUG test key) are missing or not valid
    /// Ed25519 keys.
    case invalidPublicKey
    /// The verified zip doesn't extract to exactly one app bundle.
    case invalidArchive(String)
    /// The extracted app isn't the Basket version the manifest announced.
    case bundleMismatch(String)
    /// The extracted app's code signature is invalid, not a notarized Developer ID signature, or
    /// not from this app's developer team.
    case codeSignature(String)
    /// The update isn't newer than the running version.
    case notNewer(current: String, offered: String)
    /// The update needs a newer macOS.
    case requiresNewerSystem(String)
    /// This copy of Basket can't update itself (ad-hoc signed, translocated, not writable…).
    case unavailable(String)
    /// Staging or launching the swap failed; Basket was not changed.
    case installFailed(String)

    public var isSecurityFailure: Bool {
        switch self {
        case .checksumMismatch, .badSignature, .bundleMismatch, .codeSignature: true
        default: false
        }
    }
}

extension UpdateError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let reason):
            "The update information from GitHub is invalid: \(reason)."
        case .network(let reason):
            "Couldn't reach the update server: \(reason)."
        case .tooLarge(let bytes):
            "The update is unexpectedly large (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))), so Basket stopped downloading it."
        case .checksumMismatch:
            "The downloaded update doesn't match its published checksum. It may have been altered, so it was deleted."
        case .badSignature:
            "The downloaded update isn't signed by Basket's maintainer. It may have been altered, so it was deleted."
        case .invalidPublicKey:
            "Basket's update key is invalid, so updates can't be verified."
        case .invalidArchive(let reason):
            "The downloaded update is damaged: \(reason)."
        case .bundleMismatch(let reason):
            "The downloaded app isn't the announced Basket version (\(reason)), so it was deleted."
        case .codeSignature(let reason):
            "The downloaded app doesn't carry the notarized Developer ID signature of Basket's developer (\(reason)), so it was deleted."
        case .notNewer(let current, let offered):
            "Basket \(offered) isn't newer than the installed \(current)."
        case .requiresNewerSystem(let version):
            "This update requires macOS \(version) or later."
        case .unavailable(let reason):
            reason
        case .installFailed(let reason):
            "The update couldn't be installed: \(reason). Basket was not changed."
        }
    }
}
