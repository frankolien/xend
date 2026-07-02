import Foundation
import LocalAuthentication
import Security
import CryptoKit

/// On-device key management for a wallet: key generation and recovery, secure storage,
/// biometric authentication, and Ed25519 signing. Operates only on the bytes it is given;
/// it knows nothing about the app, backend, or network.
///
/// Solana signs with Ed25519, but the Secure Enclave holds only P-256 keys. So the Enclave
/// doesn't store the signing key; it wraps it:
///
///   - The Ed25519 private key is stored as ECIES ciphertext, never in plaintext at rest.
///   - It is decrypted by a P-256 key generated in the Secure Enclave, which cannot be
///     extracted even on a compromised device.
///   - That decryption is gated by biometrics via the key's access control, so recovering
///     the Ed25519 key requires a live Face ID / Touch ID check.
///
/// The signing key is derived from a BIP-39 recovery phrase (SLIP-0010 ed25519 at
/// `m/44'/501'/0'/0'`), so the same phrase restores the same wallet in any BIP-39 wallet.
/// The phrase is wrapped and biometric-gated like the key, and is shown to the app only on
/// explicit generation or reveal.
///
/// For cross-device recovery, the phrase is also stored once in the iCloud-synchronizable
/// keychain (`seedVaultService`), end-to-end encrypted by Apple. This is the only item that
/// leaves the device. On a new device, `loadOrRecover` finds the synced seed and rebuilds a
/// per-device signing key from it, with no phrase to copy. The Enclave-wrapped copies never
/// sync, since an Enclave key can't leave its device; iCloud Keychain, not the Enclave,
/// encrypts the travelling seed.
///
/// At signing time the Ed25519 key is decrypted into memory, used once, and its buffer
/// zeroed. The private key never crosses the platform channel.
protocol SecureSigning {
    func generateKeyPair(walletId: String) throws -> (address: String, mnemonic: String)
    func restore(walletId: String, mnemonic: String) throws -> String
    func loadOrRecover(walletId: String) throws -> [String: Any]?
    func revealMnemonic(walletId: String, reason: String) throws -> String
    func signMessage(walletId: String, message: Data, reason: String) throws -> Data
    func getPublicKey(walletId: String) throws -> String
    func deleteKey(walletId: String) throws
}

/// Errors thrown by `SecureSigner`. Each case maps to a stable channel error code that the
/// Dart layer translates into a typed error.
enum SecureSignerError: Error {
    case authenticationCancelled // biometric prompt cancelled or failed
    case biometricsUnavailable
    case keyNotFound
    case keychain(OSStatus)
    case badPublicKeyData
    case badArguments(String) // missing or invalid channel argument
    case enclave(String) // a Secure Enclave or crypto operation failed
    case invalidMnemonic // recovery phrase is malformed or fails its checksum
}

final class SecureSigner: SecureSigning {

    /// Keychain service for the public address, readable without authentication.
    private static let pubService = "ai.xend.pub"
    /// Keychain service for the wrapped (encrypted) Ed25519 private key.
    private static let ciphertextService = "ai.xend.ct"
    /// Keychain service for the wrapped (encrypted) BIP-39 recovery phrase.
    private static let mnemonicService = "ai.xend.mn"
    /// Keychain service for the iCloud-synchronizable recovery seed: the plaintext BIP-39
    /// phrase, protected by iCloud Keychain's end-to-end encryption. The only item that
    /// leaves the device, and what lets a new device recover.
    private static let seedVaultService = "ai.xend.seed"

    /// ECIES with an ephemeral key, X9.63 KDF, and AES-GCM: the standard algorithm for
    /// encrypting to a Secure Enclave P-256 key.
    private static let eciesAlgorithm: SecKeyAlgorithm =
        .eciesEncryptionCofactorVariableIVX963SHA256AESGCM

    private static func enclaveTag(_ walletId: String) -> Data {
        Data("ai.xend.enclave.\(walletId)".utf8)
    }

    // MARK: Key generation & recovery

    /// Generates a fresh BIP-39 recovery phrase, derives the wallet's Ed25519 key from it,
    /// wraps the key and the phrase under a Secure Enclave key, persists them, and returns
    /// the address and phrase. The plaintext private key's buffer is zeroed before returning.
    func generateKeyPair(walletId: String) throws -> (address: String, mnemonic: String) {
        let mnemonic = Mnemonic.generate()
        var privateKey = Mnemonic.solanaPrivateKey(from: mnemonic)
        defer { privateKey.resetBytes(in: 0..<privateKey.count) }

        let address = try establish(walletId: walletId, privateKey: privateKey, mnemonic: mnemonic)
        storeRecoverySeed(walletId: walletId, mnemonic: mnemonic)
        return (address, mnemonic)
    }

    /// Restores a wallet from a recovery phrase: validates it, re-derives the key, and
    /// persists it. Returns the base58 address. Throws `.invalidMnemonic` if the phrase is
    /// malformed or its checksum fails.
    func restore(walletId: String, mnemonic: String) throws -> String {
        do {
            try Mnemonic.validate(mnemonic)
        } catch {
            throw SecureSignerError.invalidMnemonic
        }
        var privateKey = Mnemonic.solanaPrivateKey(from: mnemonic)
        defer { privateKey.resetBytes(in: 0..<privateKey.count) }

        let address = try establish(walletId: walletId, privateKey: privateKey, mnemonic: mnemonic)
        storeRecoverySeed(walletId: walletId, mnemonic: mnemonic)
        return address
    }

    /// Provisions this device from a recovery seed synced in via iCloud Keychain, or reports
    /// the wallet already present here. Returns `nil` when neither a local key nor a synced
    /// seed exists (a new install that should call `generateKeyPair`).
    ///
    /// The result maps `"address"` to the base58 address and `"recovered"` to whether the
    /// signing key was rebuilt from a synced seed. Neither path prompts: the fast path finds
    /// an existing local key, and recovery derives the key from the seed and re-wraps it
    /// under a fresh Enclave key.
    func loadOrRecover(walletId: String) throws -> [String: Any]? {
        // Fast path: this device is already provisioned with a signing key.
        if let address = try? getPublicKey(walletId: walletId) {
            return ["address": address, "recovered": false]
        }

        // Recovery path: no local key, but a seed may have synced in.
        guard let mnemonic = loadRecoverySeed(walletId: walletId) else { return nil }
        var privateKey = Mnemonic.solanaPrivateKey(from: mnemonic)
        defer { privateKey.resetBytes(in: 0..<privateKey.count) }

        let address = try establish(walletId: walletId, privateKey: privateKey, mnemonic: mnemonic)
        return ["address": address, "recovered": true]
    }

    /// Derives the address from `privateKey`, wraps both the key and `mnemonic` under a
    /// fresh Enclave key, and persists everything. Shared by generation and restore.
    private func establish(walletId: String, privateKey: Data, mnemonic: String) throws -> String {
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKey)
        let address = Base58.encode([UInt8](signingKey.publicKey.rawRepresentation))

        let enclaveKey = try createEnclaveKey(walletId: walletId)
        guard let enclavePublicKey = SecKeyCopyPublicKey(enclaveKey) else {
            throw SecureSignerError.enclave("could not derive enclave public key")
        }
        guard SecKeyIsAlgorithmSupported(enclavePublicKey, .encrypt, Self.eciesAlgorithm) else {
            throw SecureSignerError.enclave("ECIES not supported by enclave key")
        }

        let keyCiphertext = try wrap(privateKey, to: enclavePublicKey, describedAs: "the private key")
        let phraseCiphertext = try wrap(Data(mnemonic.utf8), to: enclavePublicKey, describedAs: "the recovery phrase")

        try keychainSet(service: Self.ciphertextService, account: walletId, data: keyCiphertext)
        try keychainSet(service: Self.mnemonicService, account: walletId, data: phraseCiphertext)
        try keychainSet(service: Self.pubService, account: walletId, data: Data(address.utf8))
        return address
    }

    /// ECIES-encrypts `plaintext` to the Enclave key's public key.
    private func wrap(_ plaintext: Data, to enclavePublicKey: SecKey, describedAs label: String) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let ciphertext = SecKeyCreateEncryptedData(
            enclavePublicKey,
            Self.eciesAlgorithm,
            plaintext as CFData,
            &error
        ) else {
            throw SecureSignerError.enclave("wrapping \(label) failed")
        }
        return ciphertext as Data
    }

    /// Reveals the wallet's recovery phrase after biometric authentication. The phrase is
    /// decrypted only to be returned; nothing is stored in the clear.
    func revealMnemonic(walletId: String, reason: String) throws -> String {
        let context = LAContext()
        context.localizedReason = reason

        let enclaveKey = try loadEnclaveKey(walletId: walletId, context: context)
        let ciphertext = try keychainGet(service: Self.mnemonicService, account: walletId)

        var decryptError: Unmanaged<CFError>?
        guard let plaintext = SecKeyCreateDecryptedData(
            enclaveKey,
            Self.eciesAlgorithm,
            ciphertext as CFData,
            &decryptError
        ) else {
            let code = decryptError.map { CFErrorGetCode($0.takeRetainedValue()) }
            if code == -128 || code == -2 || code == Int(errSecAuthFailed) {
                throw SecureSignerError.authenticationCancelled
            }
            throw SecureSignerError.enclave("unwrapping the recovery phrase failed (\(code ?? 0))")
        }

        guard let mnemonic = String(data: plaintext as Data, encoding: .utf8) else {
            throw SecureSignerError.enclave("stored recovery phrase is corrupt")
        }
        return mnemonic
    }

    // MARK: Signing

    /// Signs `message` with the wallet's Ed25519 key after biometric authentication and
    /// returns a 64-byte signature. `reason` is shown in the authentication prompt. The
    /// key is decrypted only for the signature and its buffer zeroed immediately after.
    func signMessage(walletId: String, message: Data, reason: String) throws -> Data {
        let context = LAContext()
        context.localizedReason = reason

        let enclaveKey = try loadEnclaveKey(walletId: walletId, context: context)
        let ciphertext = try keychainGet(service: Self.ciphertextService, account: walletId)

        // Decrypting with the enclave key triggers the biometric prompt, since its access
        // control requires a live biometric. A cancelled prompt surfaces here.
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
        defer { for i in keyBytes.indices { keyBytes[i] = 0 } } // zero after use

        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(keyBytes))
        let signature = try signingKey.signature(for: message)
        return Data(signature) // 64 bytes
    }

    // MARK: Public key

    /// Returns the stored base58 address for `walletId`. No authentication required.
    func getPublicKey(walletId: String) throws -> String {
        let data = try keychainGet(service: Self.pubService, account: walletId)
        guard let s = String(data: data, encoding: .utf8) else {
            throw SecureSignerError.badPublicKeyData
        }
        return s
    }

    // MARK: Deletion

    /// Removes the wallet's public address, wrapped private key, wrapped recovery phrase,
    /// and Enclave key. Also removes the iCloud-synchronizable recovery seed, which
    /// propagates the deletion to the user's other devices.
    func deleteKey(walletId: String) throws {
        for service in [Self.ciphertextService, Self.mnemonicService, Self.pubService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: walletId,
            ]
            SecItemDelete(query as CFDictionary) // errSecItemNotFound is acceptable
        }
        // `kSecAttrSynchronizableAny` matches both the synced item and any local fallback.
        let vaultQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.seedVaultService,
            kSecAttrAccount as String: walletId,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
        ]
        SecItemDelete(vaultQuery as CFDictionary)
        deleteEnclaveKey(walletId: walletId)
    }

    // MARK: - Recovery seed vault (iCloud Keychain)

    /// Stores the recovery seed in the iCloud-synchronizable keychain so it can travel,
    /// end-to-end encrypted, to the user's other devices. Best-effort: wallet creation must
    /// not fail because iCloud is unavailable. If the synchronizable write is refused (for
    /// example, on a simulator without iCloud Keychain), it falls back to a local copy. The
    /// wallet still works and reloads here; only new-device recovery is unavailable until
    /// the app runs on real hardware.
    private func storeRecoverySeed(walletId: String, mnemonic: String) {
        let data = Data(mnemonic.utf8)
        do {
            try keychainSetSeed(walletId: walletId, data: data, synchronizable: true)
        } catch {
            try? keychainSetSeed(walletId: walletId, data: data, synchronizable: false)
            NSLog("Xend: recovery seed stored locally only (iCloud Keychain unavailable): \(error)")
        }
    }

    /// Reads the recovery seed, preferring the synced item and falling back to any local
    /// copy. Returns `nil` when neither exists.
    private func loadRecoverySeed(walletId: String) -> String? {
        for synchronizable in [true, false] {
            if let data = try? keychainGetSeed(walletId: walletId, synchronizable: synchronizable),
               let mnemonic = String(data: data, encoding: .utf8) {
                return mnemonic
            }
        }
        return nil
    }

    private func keychainSetSeed(walletId: String, data: Data, synchronizable: Bool) throws {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.seedVaultService,
            kSecAttrAccount as String: walletId,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
        ]
        SecItemDelete(base as CFDictionary) // overwrite any existing item

        var add = base
        add[kSecValueData as String] = data
        // A synchronizable item must not be ThisDeviceOnly; `WhenUnlocked` keeps it out of
        // reach until the device is unlocked while still allowing iCloud sync.
        add[kSecAttrAccessible as String] = synchronizable
            ? kSecAttrAccessibleWhenUnlocked
            : kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecureSignerError.keychain(status) }
    }

    private func keychainGetSeed(walletId: String, synchronizable: Bool) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.seedVaultService,
            kSecAttrAccount as String: walletId,
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
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

    // MARK: - Secure Enclave key management

    /// Creates the P-256 key that wraps the Ed25519 private key. On a real device this is a
    /// non-extractable Secure Enclave key gated by the enrolled biometrics. Generation tries
    /// configurations strongest-first: the biometric gate is requested only when a biometric
    /// is enrolled, and the Enclave only when it can produce a key. A real device succeeds on
    /// the first attempt; a fresh simulator (Enclave present but no biometric enrolled) falls
    /// through to a key it can create. Any existing key for the wallet is removed first.
    private func createEnclaveKey(walletId: String) throws -> SecKey {
        deleteEnclaveKey(walletId: walletId)

        let enclaveAvailable = SecureEnclave.isAvailable
        let biometricsEnrolled = LAContext()
            .canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)

        // Strongest-first. `.privateKeyUsage` is valid only for an Enclave key;
        // `.biometryCurrentSet` needs an enrolled biometric to bind to.
        var attempts: [(flags: SecAccessControlCreateFlags, inEnclave: Bool)] = []
        if enclaveAvailable && biometricsEnrolled {
            attempts.append(([.privateKeyUsage, .biometryCurrentSet], true))
        }

        #if targetEnvironment(simulator)
        // Development fallbacks, compiled ONLY into simulator builds, never shipped to a
        // device. A simulator may report an Enclave that cannot mint keys and usually has
        // no enrolled biometric, so relax down to whatever it can create.
        if enclaveAvailable {
            attempts.append(([.privateKeyUsage], true))
        }
        if biometricsEnrolled {
            attempts.append(([.biometryCurrentSet], false))
        }
        attempts.append(([], false))
        #else
        // Real device: signing must always require user authentication. If no biometric is
        // enrolled, fall back to the device passcode via `.userPresence`, never to an
        // unguarded key. A device with neither passcode nor biometrics fails here rather
        // than creating a signing key anyone could use.
        if !biometricsEnrolled {
            attempts.append(([.privateKeyUsage, .userPresence], true))
        }
        #endif

        var lastError: Error = SecureSignerError.enclave("wrapping-key generation failed")
        for attempt in attempts {
            do {
                return try makeWrappingKey(
                    walletId: walletId,
                    flags: attempt.flags,
                    inSecureEnclave: attempt.inEnclave
                )
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Generates one wrapping key with the given access-control `flags`, in the Secure
    /// Enclave when `inSecureEnclave` is set.
    private func makeWrappingKey(
        walletId: String,
        flags: SecAccessControlCreateFlags,
        inSecureEnclave: Bool
    ) throws -> SecKey {
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            flags,
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
        if inSecureEnclave {
            attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        }

        var createError: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &createError) else {
            let detail = createError
                .map { CFErrorCopyDescription($0.takeRetainedValue()) as String } ?? "unknown error"
            throw SecureSignerError.enclave("wrapping-key generation failed: \(detail)")
        }
        return key
    }

    /// Loads the wallet's Enclave key, attaching `context` so the biometric prompt uses the
    /// caller's reason string.
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
