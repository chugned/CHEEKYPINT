import Foundation
import CryptoKit

/// Nonce helpers for Sign in with Apple. A random nonce is generated, its SHA-256 is sent in
/// the Apple request, and the RAW nonce is forwarded to Supabase to bind the credential —
/// standard replay protection.
enum CryptoNonce {
    static func random(length: Int = 32) -> String {
        let charset = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-._")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in charset[Int.random(in: 0..<charset.count, using: &generator)] })
    }

    static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
