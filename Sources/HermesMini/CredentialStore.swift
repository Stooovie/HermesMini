import Foundation

/// Credential storage for the Hermes Mini server password.
///
/// NOTE: deliberately NOT the Keychain. Ad-hoc codesigning (no stable signing
/// identity) makes macOS treat every rebuilt binary as a new app, so
/// SecItemCopyMatching hangs on an invisible access prompt for LSUIElement
/// apps. UserDefaults avoids the hang entirely. Trade-off accepted for v1:
/// single-user Mac, password protects a LAN/reverse-proxied server.
enum CredentialStore {
    private static let defaultsKey = "StoredPassword"

    static func save(_ value: String, key: String) {
        UserDefaults.standard.set(value, forKey: defaultsKey)
        // Force an immediate disk write — a killed process (pkill / crash) can
        // otherwise lose a pending defaults flush, which looked like "login not
        // remembered" across restarts.
        UserDefaults.standard.synchronize()
        hmLog("CredentialStore.save key=\(key) written")
    }

    static func load(_ key: String) -> String? {
        let value = UserDefaults.standard.string(forKey: defaultsKey)
        hmLog("CredentialStore.load key=\(key) found=\(value == nil ? "no" : "yes")")
        return value
    }

    static func delete(_ key: String) {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        hmLog("CredentialStore.delete key=\(key)")
    }
}
