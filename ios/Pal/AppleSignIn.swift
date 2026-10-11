import CryptoKit
import Foundation
import Security

// Apple receives the SHA-256 hash; Supabase verifies it against the original nonce.
enum AppleSignInNonce {
    static func make() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw PalFailure(message: "Unable to start a secure sign-in. Please try again.")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    static func hash(_ nonce: String) -> String {
        SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
