import CryptoKit
import Foundation

/// Checks a downloaded update archive: SHA-256 against the manifest, then the Ed25519 signature
/// with the public key compiled into the app (docs/updates.md, "Keys").
public struct UpdateVerifier: Sendable {
    /// base64 of the raw 32-byte Ed25519 public key whose private half signs releases.
    public static let publicKeyBase64 = "M3D6KG3mzKDpqS1IjpL08pujoEBDtFGGH+ntnICNVcA="

    /// Raw 32-byte public key.
    public let publicKey: Data

    public init(publicKeyBase64: String = UpdateVerifier.publicKeyBase64) throws {
        guard let raw = Data(base64Encoded: publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)),
              (try? Curve25519.Signing.PublicKey(rawRepresentation: raw)) != nil
        else { throw UpdateError.invalidPublicKey }
        publicKey = raw
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
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else {
            throw UpdateError.invalidPublicKey
        }
        guard key.isValidSignature(signature, for: data) else { throw UpdateError.badSignature }
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
