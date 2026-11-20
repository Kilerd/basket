// Creates the Ed25519 key pair that signs Basket updates (docs/updates.md).
// Usage: swift scripts/update-keygen.swift <private-key-file>
// Writes base64(raw 32-byte private key) to the file with mode 0600 (refuses to overwrite) and
// prints only the base64 public key.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: update-keygen.swift <private-key-file>\n".utf8)); exit(64)
}
let path = (args[1] as NSString).expandingTildeInPath
guard !FileManager.default.fileExists(atPath: path) else {
    FileHandle.standardError.write(Data("\(path) exists; not overwriting a signing key\n".utf8)); exit(1)
}
let key = Curve25519.Signing.PrivateKey()
try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
guard FileManager.default.createFile(
    atPath: path, contents: Data(key.rawRepresentation.base64EncodedString().utf8),
    attributes: [.posixPermissions: 0o600]) else { exit(1) }
print(key.publicKey.rawRepresentation.base64EncodedString())
