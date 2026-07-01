import Foundation
import LocalAuthentication
import Security
import CryptoKit

/// On-device key management for a wallet: key generation, secure storage, biometric
/// authentication, and Ed25519 signing. This type exposes four operations and has no
/// knowledge of the application, backend, or network; it operates only on the bytes it
/// is given.
///
/// Design constraint: Solana signs with Ed25519, while the Secure Enclave can hold only
/// P-256 keys. The Enclave therefore does not store the signing key directly — it
/// protects it. The full at-rest scheme (an Enclave-held P-256 key wrapping an AES key
/// that encrypts the Ed25519 private key, released only after biometric authentication,
/// decrypted transiently, and zeroed after use) is implemented alongside `signMessage`.
///
/// Availability: `generateKeyPair`, `getPublicKey`, and `deleteKey` are implemented;
/// `signMessage` is not yet implemented.
///
/// In the current implementation, keys are stored in the Keychain with `ThisDeviceOnly`
/// accessibility — encrypted at rest by iOS and excluded from iCloud backups, though not
/// yet Enclave-wrapped or biometric-gated. The private key never crosses the platform
/// channel and never leaves the device.
protocol SecureSigning {
    func generateKeyPair(walletId: String) throws -> String
    func signMessage(walletId: String, message: Data, reason: String) throws -> Data
    func getPublicKey(walletId: String) throws -> String
    func deleteKey(walletId: String) throws
}

/// Errors thrown by `SecureSigner`. Each case maps to a stable error code on the
/// platform channel, which the Dart layer translates into a typed error.
enum SecureSignerError: Error {
    case notImplemented(String)
    /// Biometric authentication was cancelled or interrupted; nothing was signed.
    case authenticationCancelled
    case biometricsUnavailable
    case keyNotFound
    case keychain(OSStatus)
    case badPublicKeyData
    /// A required channel argument was missing or of the wrong type.
    case badArguments(String)
}

final class SecureSigner: SecureSigning {

    /// Keychain service for the public address, readable without authentication.
    private static let pubService = "ai.xend.pub"
    /// Keychain service for the private key.
    private static let privService = "ai.xend.key"

    // MARK: Key generation

    /// Generates an Ed25519 key pair, persists the private key, and returns the base58
    /// public address.
    ///
    /// The key is generated with CryptoKit's Curve25519. The plaintext private key is
    /// held in memory only briefly, and the local copy is zeroed before returning.
    func generateKeyPair(walletId: String) throws -> String {
        let sk = Curve25519.Signing.PrivateKey()
        let pub = [UInt8](sk.publicKey.rawRepresentation) // 32 bytes
        let address = Base58.encode(pub)

        var priv = [UInt8](sk.rawRepresentation)
        defer { for i in priv.indices { priv[i] = 0 } } // zero the local copy

        try keychainSet(service: Self.privService, account: walletId, data: Data(priv))
        try keychainSet(service: Self.pubService, account: walletId, data: Data(address.utf8))
        return address
    }

    // MARK: Signing

    /// Signs `message` with the wallet's Ed25519 key after biometric authentication and
    /// returns a 64-byte signature. `reason` is shown to the user in the authentication
    /// prompt and is not otherwise inspected.
    ///
    /// Not yet implemented. The planned implementation:
    ///   1. Evaluate biometric authentication off the main thread, mapping cancellation
    ///      to `authenticationCancelled` with nothing signed.
    ///   2. Release the biometric-gated Keychain item; the Enclave unwraps the AES key,
    ///      which decrypts the Ed25519 private key into a transient buffer.
    ///   3. Sign the message, then overwrite the key buffer before returning.
    func signMessage(walletId: String, message: Data, reason: String) throws -> Data {
        _ = (walletId, message, reason)
        throw SecureSignerError.notImplemented("signMessage")
    }

    // MARK: Public key

    /// Returns the stored base58 public address for `walletId`. Requires no
    /// authentication.
    func getPublicKey(walletId: String) throws -> String {
        let data = try keychainGet(service: Self.pubService, account: walletId)
        guard let s = String(data: data, encoding: .utf8) else {
            throw SecureSignerError.badPublicKeyData
        }
        return s
    }

    // MARK: Deletion

    /// Removes all Keychain items associated with `walletId`.
    func deleteKey(walletId: String) throws {
        for service in [Self.privService, Self.pubService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: walletId,
            ]
            SecItemDelete(query as CFDictionary) // errSecItemNotFound is acceptable
        }
    }

    // MARK: - Keychain helpers

    private func keychainSet(service: String, account: String, data: Data) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary) // overwrite any existing item

        var add = base
        add[kSecValueData as String] = data
        // ThisDeviceOnly excludes the item from iCloud Keychain backups.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecureSignerError.keychain(status) }
    }

    private func keychainGet(service: String, account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { throw SecureSignerError.keyNotFound }
        guard status == errSecSuccess, let data = out as? Data else {
            throw SecureSignerError.keychain(status)
        }
        return data
    }
}
