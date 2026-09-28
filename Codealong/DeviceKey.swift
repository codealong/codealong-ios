import Foundation
import Security

/// This phone's device key: the 32 bytes your Macs know it by. It stays in this phone's Keychain
/// and never syncs, so a new phone is a new device you link again.
enum DeviceKey {
    private static let service = "Codealong device key"

    /// The key, made the first time. Every link depends on it staying the same, so when the
    /// Keychain won't keep it (a build without the keychain entitlement, say) it goes in a file in
    /// `dir` instead, and into the Keychain once it takes it.
    static func loadOrCreate(fallback dir: URL) -> Data {
        if let key = read() {
            return key
        }
        let file = dir.appending(path: "device-key")
        if let kept = try? Data(contentsOf: file), kept.count == 32 {
            save(kept)
            if read() == kept {
                try? FileManager.default.removeItem(at: file)
            }
            return kept
        }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        precondition(status == errSecSuccess, "The system gave no random bytes for the device key.")
        save(bytes)
        if read() != bytes {
            try? bytes.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        return bytes
    }

    private static func read() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data, data.count == 32 else {
            return nil
        }
        return data
    }

    private static func save(_ key: Data) {
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: key,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(item as CFDictionary)
        SecItemAdd(item as CFDictionary, nil)
    }
}
