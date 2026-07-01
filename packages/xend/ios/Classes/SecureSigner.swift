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
/// protects it:
///
///   - The Ed25519 private key is stored as ECIES ciphertext, never in plaintext at rest.
///   - The key that decrypts it is a P-256 key generated inside the Secure Enclave, which
///     cannot be extracted even on a compromised device.
///   - Decryption is gated by biometrics via the key's access control, so the Ed25519 key
///     is recoverable only behind a live Face ID / Touch ID check.
///
/// At signing time the Ed25519 key is decrypted into memory, used once, and its buffer is
/// zeroed. The private key never crosses the platform channel and never leaves the device.
protocol SecureSigning {
    func generateKeyPair(walletId: String) throws -> String
    func signMessage(walletId: String, message: Data, reason: String) throws -> Data
    func getPublicKey(walletId: String) throws -> String
    func deleteKey(walletId: String) throws
}

/// Errors thrown by `SecureSigner`. Each case maps to a stable error code on the
/// platform channel, which the Dart layer translates into a typed error.
enum SecureSignerError: Error {
    case authenticationCancelled // biometric prompt cancelled or failed; nothing signed
    case biometricsUnavailable
    case keyNotFound
    case keychain(OSStatus)
    case badPublicKeyData
    case badArguments(String) // missing or invalid channel argument
    case enclave(String) // a Secure Enclave / crypto operation failed
}

final class SecureSigner: SecureSigning {

    /// Keychain service for the public address, readable without authentication.
    private static let pubService = "ai.xend.pub"
    /// Keychain service for the wrapped (encrypted) Ed25519 private key.
    private static let ciphertextService = "ai.xend.ct"

    /// ECIES with an ephemeral key, X9.63 KDF, and AES-GCM — the standard algorithm for
    /// encrypting to a Secure Enclave P-256 key.
    private static let eciesAlgorithm: SecKeyAlgorithm =
        .eciesEncryptionCofactorVariableIVX963SHA256AESGCM

    private static func enclaveTag(_ walletId: String) -> Data {
        Data("ai.xend.enclave.\(walletId)".utf8)
    }

    // MARK: Key generation

    /// Generates an Ed25519 key pair, wraps the private key with a freshly generated
    /// Secure-Enclave P-256 key, persists the ciphertext, and returns the base58 public
    /// address. The plaintext private key is held in memory only briefly and its buffer
    /// is zeroed before returning.
    func generateKeyPair(walletId: String) throws -> String {
        let signingKey = Curve25519.Signing.PrivateKey()
        let publicKey = [UInt8](signingKey.publicKey.rawRepresentation) // 32 bytes
        let address = Base58.encode(publicKey)

        let enclaveKey = try createEnclaveKey(walletId: walletId)
        guard let enclavePublicKey = SecKeyCopyPublicKey(enclaveKey) else {
            throw SecureSignerError.enclave("could not derive enclave public key")
        }
        guard SecKeyIsAlgorithmSupported(enclavePublicKey, .encrypt, Self.eciesAlgorithm) else {
            throw SecureSignerError.enclave("ECIES not supported by enclave key")
        }

        var privateKey = [UInt8](signingKey.rawRepresentation)
        defer { for i in privateKey.indices { privateKey[i] = 0 } } // zero the local copy

        var encryptError: Unmanaged<CFError>?
        guard let ciphertext = SecKeyCreateEncryptedData(
            enclavePublicKey,
            Self.eciesAlgorithm,
            Data(privateKey) as CFData,
            &encryptError
        ) else {
            throw SecureSignerError.enclave("wrapping the private key failed")
        }

        try keychainSet(service: Self.ciphertextService, account: walletId, data: ciphertext as Data)
        try keychainSet(service: Self.pubService, account: walletId, data: Data(address.utf8))
        return address
    }

    // MARK: Signing

    /// Signs `message` with the wallet's Ed25519 key after biometric authentication and
    /// returns a 64-byte signature. `reason` is shown to the user in the authentication
    /// prompt and is not otherwise inspected.
    ///
    /// The Ed25519 key is decrypted only for the duration of the signature; its buffer is
    /// zeroed immediately afterwards.
    func signMessage(walletId: String, message: Data, reason: String) throws -> Data {
        let context = LAContext()
        context.localizedReason = reason

        let enclaveKey = try loadEnclaveKey(walletId: walletId, context: context)
        let ciphertext = try keychainGet(service: Self.ciphertextService, account: walletId)

        // Decrypting with the enclave key triggers the biometric prompt (its access
        // control requires a live biometric). A cancelled prompt surfaces here.
        var decryptError: Unmanaged<CFError>?
        guard let plaintext = SecKeyCreateDecryptedData(
            enclaveKey,
            Self.eciesAlgorithm,
            ciphertext as CFData,
            &decryptError
        ) else {
            let code = decryptError.map { CFErrorGetCode($0.takeRetainedValue()) }
            // -128 = errSecUserCanceled, -2 = LAError.userCancel
            if code == -128 || code == -2 || code == Int(errSecAuthFailed) {
                throw SecureSignerError.authenticationCancelled
            }
            throw SecureSignerError.enclave("unwrapping the private key failed (\(code ?? 0))")
        }

        var keyBytes = [UInt8](plaintext as Data)
        defer { for i in keyBytes.indices { keyBytes[i] = 0 } } // zero after signing

        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(keyBytes))
        let signature = try signingKey.signature(for: message)
        return Data(signature) // 64 bytes
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

    /// Removes the wallet's public address, wrapped private key, and Enclave key.
    func deleteKey(walletId: String) throws {
        for service in [Self.ciphertextService, Self.pubService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: walletId,
            ]
            SecItemDelete(query as CFDictionary) // errSecItemNotFound is acceptable
        }
        deleteEnclaveKey(walletId: walletId)
    }

    // MARK: - Secure Enclave key management

    /// Creates the P-256 key that wraps the Ed25519 private key, gated by the current
    /// enrolled biometrics. On hardware with a Secure Enclave the key is generated inside
    /// it and cannot be extracted; where no Enclave is available (for example, a
    /// simulator) it falls back to a software-protected keychain key, which is intended
    /// for development only. Any existing key for the wallet is removed first.
    private func createEnclaveKey(walletId: String) throws -> SecKey {
        deleteEnclaveKey(walletId: walletId)

        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            &accessError
        ) else {
            throw SecureSignerError.enclave("could not build access control")
        }

        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: Self.enclaveTag(walletId),
                kSecAttrAccessControl as String: access,
            ],
        ]
        if SecureEnclave.isAvailable {
            attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        }

        var createError: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &createError) else {
            throw SecureSignerError.enclave("wrapping-key generation failed")
        }
        return key
    }

    /// Loads the wallet's Enclave key, attaching `context` so the biometric prompt uses
    /// the caller's reason string.
    private func loadEnclaveKey(walletId: String, context: LAContext) throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.enclaveTag(walletId),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecUseAuthenticationContext as String: context,
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw SecureSignerError.keyNotFound }
        guard status == errSecSuccess, let ref = result else {
            throw SecureSignerError.keychain(status)
        }
        return ref as! SecKey
    }

    private func deleteEnclaveKey(walletId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.enclaveTag(walletId),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ]
        SecItemDelete(query as CFDictionary)
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
