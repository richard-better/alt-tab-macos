import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 4,
      let signature = Data(base64Encoded: CommandLine.arguments[2]),
      let publicKey = Data(base64Encoded: CommandLine.arguments[3]) else {
    fail("Expected archive, Ed25519 signature, and public key")
}
let archive = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
guard key.isValidSignature(signature, for: archive) else {
    fail("The update signature does not match the app's SUPublicEDKey")
}
