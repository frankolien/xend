import Foundation
import LocalAuthentication
import Security
import CryptoKit

/// The vault. It owns key generation, encrypted storage, biometric gating, and the
/// Ed25519 signature. It exposes a deliberately tiny surface — four operations — and
/// knows nothing about the backend, the API, or business logic. It signs bytes; it
/// asks no questions.
///
/// THE CENTRAL CONSTRAINT (docs/04-SECURITY.md): Solana signs with Ed25519; the Secure
/// Enclave only holds P-256 keys. So the enclave does NOT hold the signing key — it
/// *protects* it. The full at-rest scheme (enclave-P256 wraps AES wraps Ed25519, gated
/// by `.biometryCurrentSet`) plus transient decrypt-sign-zero lands in **Phase 2**.
///
/// PHASE STATUS:
///   • generateKeyPair / getPublicKey / deleteKey — implemented (Phase 1).
///   • signMessage — Phase 2 (biometric gate + enclave unwrap + zeroing). Stubbed.
///
/// Phase 1 storage is Keychain with `ThisDeviceOnly` accessibility — encrypted at rest
/// by iOS and non-syncable, but NOT yet enclave-wrapped or biometric-gated. That is the
/// deliberate P1/P2 split from the roadmap ("no storage hardening yet" in P1). The key
/// still never crosses the platform channel and never leaves the device.
protocol SecureSigning {
    func generateKeyPair(walletId: String) throws -> String
    func signMessage(walletId: String, message: Data, reason: String) throws -> Data
    func getPublicKey(walletId: String) throws -> String
    func deleteKey(walletId: String) throws
}

enum SecureSignerError: Error {
    case notImplemented(String)
    case authenticationCancelled // maps to Dart UserCancelledAuth — clean, recoverable
    case biometricsUnavailable
    case keyNotFound
    case keychain(OSStatus)
    case badPublicKeyData
    case badArguments(String) // missing/invalid channel argument
}

final class SecureSigner: SecureSigning {

    /// Two Keychain "services": the public address (readable without biometrics) and the
    /// private key (Phase 2: only readable behind Face ID through the enclave unwrap).
    private static let pubService = "ai.xend.pub"
    private static let privService = "ai.xend.key"

    // MARK: generate — Phase 1

    /// Create an Ed25519 keypair in software (CryptoKit's vetted Curve25519), derive the
    /// base58 address to return to Dart, then persist. The plaintext private key exists
    /// only briefly in RAM and our copy is zeroed before returning.
    func generateKeyPair(walletId: String) throws -> String {
        let sk = Curve25519.Signing.PrivateKey()
        let pub = [UInt8](sk.publicKey.rawRepresentation) // 32 bytes
        let address = Base58.encode(pub)

        var priv = [UInt8](sk.rawRepresentation)
        defer { for i in priv.indices { priv[i] = 0 } } // overwrite our copy

        try keychainSet(service: Self.privService, account: walletId, data: Data(priv))
        try keychainSet(service: Self.pubService, account: walletId, data: Data(address.utf8))
        return address
    }

    // MARK: sign — Phase 2

    func signMessage(walletId: String, message: Data, reason: String) throws -> Data {
        // Phase 2 APPROACH:
        // 1. LAContext with localizedReason = reason (opaque display text, D2), evaluate
        //    .deviceOwnerAuthenticationWithBiometrics OFF the main queue. Cancel/interrupt
        //    → throw .authenticationCancelled (nothing signed).
        // 2. That evaluation both proves presence AND releases the biometric-gated
        //    Keychain item — one gate, not two.
        // 3. enclave unwraps AES data key → AES.GCM.open → Ed25519 private bytes in a
        //    locked buffer.
        // 4. sig = try Curve25519.Signing.PrivateKey(rawRepresentation: bytes).signature(for: message)
        // 5. overwrite the key buffer, THEN return sig (64 bytes).
        _ = (walletId, message, reason) // reason is shown to the user; never parsed here.
        throw SecureSignerError.notImplemented("signMessage (Phase 2)")
    }

    // MARK: public key — Phase 1

    func getPublicKey(walletId: String) throws -> String {
        let data = try keychainGet(service: Self.pubService, account: walletId)
        guard let s = String(data: data, encoding: .utf8) else {
            throw SecureSignerError.badPublicKeyData
        }
        return s
    }

    // MARK: delete — Phase 1

    func deleteKey(walletId: String) throws {
        for service in [Self.privService, Self.pubService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: walletId,
            ]
            SecItemDelete(query as CFDictionary) // ignore errSecItemNotFound
        }
    }

    // MARK: - Keychain helpers

    private func keychainSet(service: String, account: String, data: Data) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary) // idempotent overwrite

        var add = base
        add[kSecValueData as String] = data
        // ThisDeviceOnly: keeps key material off iCloud Keychain backups (docs §11 T-Backup).
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
