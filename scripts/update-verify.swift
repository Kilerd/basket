// Checks an update signature (docs/updates.md), the way the app does: exits 0 when <signature>
// (base64) is a valid Ed25519 signature over the bytes of <file> for <public-key> (base64 of the
// raw 32-byte key, as in UpdateVerifier.publicKeyBase64).
// Usage: swift scripts/update-verify.swift <file> <signature-base64> <public-key-base64>
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4,
      let signature = Data(base64Encoded: args[2].trimmingCharacters(in: .whitespacesAndNewlines)),
      let rawKey = Data(base64Encoded: args[3].trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey) else {
    FileHandle.standardError.write(Data("usage: update-verify.swift <file> <signature-base64> <public-key-base64>\n".utf8)); exit(64)
}
let data = try Data(contentsOf: URL(fileURLWithPath: args[1]), options: .mappedIfSafe)
guard key.isValidSignature(signature, for: data) else {
    FileHandle.standardError.write(Data("the signature does not verify with this public key\n".utf8)); exit(1)
}
print("ok: the update signature verifies with the public key")
