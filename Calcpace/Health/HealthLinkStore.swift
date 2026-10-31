import Foundation
import HealthKit
import Security

/// What this iPhone keeps of its Apple Health link: the token the page
/// handed over (the Keychain, readable after the first unlock so a
/// background delivery can send, never backed up to another phone) and the
/// HealthKit anchor of the last sync the server answered (UserDefaults).
/// The token is never logged.
final class HealthLinkStore {
    static let shared = HealthLinkStore()

    private let service: String
    private let defaults: UserDefaults
    private let lock = NSLock()

    private static let tokenAccount = "link-token"
    private static let anchorKey = "appleHealth.anchor"
    private static let installedKey = "appleHealth.installed"

    init(service: String = "app.calcpace.ios.apple-health", defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    var token: String? {
        lock.lock()
        defer { lock.unlock() }
        return readToken()
    }

    var anchor: HKQueryAnchor? {
        guard let data = defaults.data(forKey: Self.anchorKey) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }

    /// A new link: its token, and a fresh start (the initial 30 days).
    @discardableResult
    func link(token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        defaults.removeObject(forKey: Self.anchorKey)
        return writeToken(token)
    }

    /// Saved only while `token` is still the link: a sync that finished
    /// after a "forget" or a new link must not leave its anchor behind.
    func save(anchor: HKQueryAnchor?, for token: String) {
        lock.lock()
        defer { lock.unlock() }
        guard readToken() == token else { return }
        if let anchor, let data = try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true) {
            defaults.set(data, forKey: Self.anchorKey)
        }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        SecItemDelete(baseQuery as CFDictionary)
        defaults.removeObject(forKey: Self.anchorKey)
    }

    /// The Keychain outlives the app; UserDefaults doesn't. An app installed
    /// again starts unlinked, as the page expects of a fresh install.
    func forgetPreviousInstall() {
        guard !defaults.bool(forKey: Self.installedKey) else { return }
        clear()
        defaults.set(true, forKey: Self.installedKey)
    }

    // MARK: Private

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.tokenAccount
        ]
    }

    private func readToken() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeToken(_ token: String) -> Bool {
        SecItemDelete(baseQuery as CFDictionary)
        var query = baseQuery
        query[kSecValueData as String] = Data(token.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
}
