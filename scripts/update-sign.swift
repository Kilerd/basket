// Signs an update archive (docs/updates.md). Usage: BASKET_UPDATE_SIGNING_KEY=… swift scripts/update-sign.swift <file>
// Prints base64(Ed25519 signature over the file's bytes). Never prints the key.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 2,
      let encoded = ProcessInfo.processInfo.environment["BASKET_UPDATE_SIGNING_KEY"],
      let raw = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
    FileHandle.standardError.write(Data("usage: BASKET_UPDATE_SIGNING_KEY=<base64 key> update-sign.swift <file>\n".utf8)); exit(64)
}
let data = try Data(contentsOf: URL(fileURLWithPath: args[1]), options: .mappedIfSafe)
let signature = try key.signature(for: data)
guard key.publicKey.isValidSignature(signature, for: data) else { exit(1) }
print(signature.base64EncodedString())
