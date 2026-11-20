// Checks an update signature (docs/updates.md), the way the app does: exits 0 when <signature>
// (base64) is a valid Ed25519 signature over the bytes of <file> for any of the public keys
// (base64 of raw 32-byte keys, as in UpdateVerifier.trustedPublicKeysBase64). Every key must be
// a valid Ed25519 key.
// Usage: swift scripts/update-verify.swift <file> <signature-base64> <public-key-base64>...
import CryptoKit
import Foundation

let args = CommandLine.arguments
func usage() -> Never {
    FileHandle.standardError.write(Data("usage: update-verify.swift <file> <signature-base64> <public-key-base64>...\n".utf8)); exit(64)
}
guard args.count >= 4,
      let signature = Data(base64Encoded: args[2].trimmingCharacters(in: .whitespacesAndNewlines)) else { usage() }
var keys: [Curve25519.Signing.PublicKey] = []
for encoded in args[3...] {
    guard let raw = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
        FileHandle.standardError.write(Data("not an Ed25519 public key: \(encoded.prefix(60))\n".utf8)); exit(64)
    }
    keys.append(key)
}
let data = try Data(contentsOf: URL(fileURLWithPath: args[1]), options: .mappedIfSafe)
guard let index = keys.firstIndex(where: { $0.isValidSignature(signature, for: data) }) else {
    FileHandle.standardError.write(Data("the signature does not verify with \(keys.count == 1 ? "this public key" : "any of these \(keys.count) public keys")\n".utf8)); exit(1)
}
print("ok: the update signature verifies with \(keys[index].rawRepresentation.base64EncodedString())")
