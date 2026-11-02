import CryptoKit
import Foundation
import Security

/// The verifier/challenge pair of RFC 7636, reused for handing a sign-in
/// from the web authentication session back to the app: the site binds the
/// one-time ticket to the challenge, and only this app ever held the
/// verifier. The Android app's Pkce.kt.
enum Pkce {
    /// 32 random bytes, base64url: 43 characters. Nil if the system has no
    /// randomness to give, and then there is no sign-in rather than a
    /// guessable one.
    static func newVerifier() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return base64url(Data(bytes))
    }

    /// base64url(SHA-256(verifier)), no padding: S256, as the site computes it
    /// (AppAuthTicket.challenge_for).
    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
