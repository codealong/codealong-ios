import Foundation
import Security

/// This phone's device key: the 32 bytes your Macs know it by. It stays in this phone's Keychain
/// and never syncs, so a new phone is a new device you link again.
enum DeviceKey {
    private static let service = "Codealong device key"

    static func loadOrCreate() -> Data {
        if let key = read() {
            return key
        }
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        precondition(status == errSecSuccess, "The system gave no random bytes for the device key.")
        save(bytes)
        // A key the Keychain didn't keep would change on every launch and break every link.
        return read() ?? bytes
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
