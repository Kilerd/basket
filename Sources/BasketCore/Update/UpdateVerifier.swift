import CryptoKit
import Foundation

/// Checks a downloaded update archive: SHA-256 against the manifest, then the Ed25519 signature
/// with the public keys compiled into the app (docs/updates.md, "Keys").
public struct UpdateVerifier: Sendable {
    /// base64 of the raw 32-byte Ed25519 public keys whose private halves may sign releases. A
    /// signature is valid when any of them verifies it, so a key can be rotated without
    /// stranding installed copies (docs/updates.md, "Rotating the key"). The release workflow
    /// reads this list from the previous release's source: keep one `"…"` literal per line.
    public static let trustedPublicKeysBase64: [String] = [
        "M3D6KG3mzKDpqS1IjpL08pujoEBDtFGGH+ntnICNVcA=",
    ]

    /// Raw 32-byte public keys, in the order given.
    public let publicKeys: [Data]

    /// Refuses an empty list and any entry that isn't a valid Ed25519 public key.
    public init(trustedPublicKeysBase64: [String] = UpdateVerifier.trustedPublicKeysBase64) throws {
        guard !trustedPublicKeysBase64.isEmpty else { throw UpdateError.invalidPublicKey }
        publicKeys = try trustedPublicKeysBase64.map { encoded in
            guard let raw = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil
            else { throw UpdateError.invalidPublicKey }
            return raw
        }
    }

    /// Throws `checksumMismatch` or `badSignature`; returns only when both match.
    public func verify(archive: URL, sha256 expected: String, signature: Data) throws {
        let data: Data
        do {
            data = try Data(contentsOf: archive, options: .mappedIfSafe)
        } catch {
            throw UpdateError.invalidArchive("it can't be read (\(error.localizedDescription))")
        }
        try verify(data: data, sha256: expected, signature: signature)
    }

    public func verify(data: Data, sha256 expected: String, signature: Data) throws {
        guard Self.sha256Hex(data) == expected.lowercased() else { throw UpdateError.checksumMismatch }
        let keys = try publicKeys.map { raw in
            guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { throw UpdateError.invalidPublicKey }
            return key
        }
        guard keys.contains(where: { $0.isValidSignature(signature, for: data) }) else { throw UpdateError.badSignature }
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
