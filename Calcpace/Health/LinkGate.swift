import Foundation
import Security

/// Whether the "apple-health" bridge component may take a "link" now, the
/// Android app's HcLinkGate. The WebView's JavaScript bridge is reachable
/// from any frame of the page, and HealthPages only sees the main frame's
/// URL, so a frame must not be able to hand the app another account's token
/// and collect this phone's runs there.
///
/// A granted "enable" opens the gate with a fresh random grant, which goes
/// back only in that "enable" reply. A "link" is taken only with that grant,
/// once, within `window`. Any "link" closes the gate, right or wrong: a frame
/// guessing grants only spoils the athlete's attempt, who taps again.
///
/// One per component instance, main thread.
final class LinkGate {
    static let window: TimeInterval = 5 * 60
    /// 256 bits: 43 base64url characters.
    static let grantBytes = 32

    private let clock: () -> Date
    private let random: (Int) -> [UInt8]
    private var grant: String?
    private var openedAt = Date.distantPast

    init(clock: @escaping () -> Date = Date.init, random: @escaping (Int) -> [UInt8] = LinkGate.secureRandom) {
        self.clock = clock
        self.random = random
    }

    /// The athlete just allowed the import on this page: the grant the
    /// "enable" reply carries. While one is still open (unused, unexpired)
    /// it is handed out again, so a second "enable" (a double tap) doesn't
    /// void the first one's grant.
    func open() -> String {
        if let grant, isFresh { return grant }
        let value = Self.base64URL(random(Self.grantBytes))
        grant = value
        openedAt = clock()
        return value
    }

    /// True for the open gate's own grant within `window` of `open`. Closes the gate either way.
    func consume(_ candidate: String?) -> Bool {
        guard let expected = grant else { return false }
        let fresh = isFresh
        grant = nil
        guard let candidate, fresh else { return false }
        return Self.constantTimeEqual(Array(expected.utf8), Array(candidate.utf8))
    }

    // MARK: Private

    private var isFresh: Bool {
        let age = clock().timeIntervalSince(openedAt)
        return age >= 0 && age <= Self.window
    }

    static func secureRandom(_ count: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "no secure random bytes")
        return bytes
    }

    private static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
