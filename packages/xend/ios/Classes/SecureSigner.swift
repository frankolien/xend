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
/// an explicit, biometric-gated reveal.
///
/// For cross-device recovery, the phrase is also stored in the iCloud-synchronizable
/// keychain (`seedVaultService`, one item per wallet address), end-to-end encrypted by
/// Apple. This is the only item that leaves the device. On a new device, `loadOrRecover` finds the synced seed and rebuilds a
/// per-device signing key from it, with no phrase to copy. The Enclave-wrapped copies never
/// sync, since an Enclave key can't leave its device; iCloud Keychain, not the Enclave,
/// encrypts the travelling seed.
///
/// At signing time the Ed25519 key is decrypted into memory, used once, and its buffer
/// zeroed. The private key never crosses the platform channel.
protocol SecureSigning {
    func generateKeyPair(walletId: String) throws -> String
    func restore(walletId: String, mnemonic: String) throws -> String
    func loadOrRecover(walletId: String) throws -> [String: Any]?
    func revealMnemonic(walletId: String, reason: String) throws -> String
    func signMessage(walletId: String, message: Data, reason: String) throws -> Data
    func getPublicKey(walletId: String) throws -> String
    func deleteKey(walletId: String, wipeBackup: Bool) throws
}

/// Errors thrown by `SecureSigner`. Each case maps to a stable channel error code that the
/// Dart layer translates into a typed error.
enum SecureSignerError: Error {
    case authenticationCancelled // biometric prompt cancelled or failed
    case biometricsUnavailable
    case keyNotFound
    case keyInvalidated // wrapped key exists but its Enclave key is gone (biometrics changed)
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
    ///
    /// Items are keyed per wallet by `seedAccount(address)`, with the walletId in
    /// `kSecAttrGeneric`. Older builds used the walletId itself as the account; those items
    /// are still read and never overwritten.
    private static let seedVaultService = "ai.xend.seed"

    /// ECIES with an ephemeral key, X9.63 KDF, and AES-GCM: the standard algorithm for
    /// encrypting to a Secure Enclave P-256 key.
    private static let eciesAlgorithm: SecKeyAlgorithm =
        .eciesEncryptionCofactorVariableIVX963SHA256AESGCM

    private static func enclaveTag(_ walletId: String) -> Data {
        Data("ai.xend.enclave.\(walletId)".utf8)
    }

    private static func seedAccount(_ address: String) -> String {
        "seed:\(address)"
    }

    // MARK: Key generation & recovery

    /// Generates a fresh BIP-39 recovery phrase, derives the wallet's Ed25519 key from it,
    /// wraps the key and the phrase under a Secure Enclave key, persists them, and returns
    /// the address. The phrase is not returned; the app reads it via `revealMnemonic`.
    func generateKeyPair(walletId: String) throws -> String {
        let mnemonic: String
        do {
            mnemonic = try Mnemonic.generate()
        } catch Mnemonic.MnemonicError.randomFailed(let status) {
            throw SecureSignerError.keychain(status)
        }
        var privateKey = Mnemonic.solanaPrivateKey(from: mnemonic)
        defer { privateKey.zeroize() }

        let address = try establish(walletId: walletId, privateKey: privateKey, mnemonic: mnemonic)
        storeRecoverySeed(walletId: walletId, address: address, mnemonic: mnemonic)
        return address
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
        defer { privateKey.zeroize() }

        let address = try establish(walletId: walletId, privateKey: privateKey, mnemonic: mnemonic)
        storeRecoverySeed(walletId: walletId, address: address, mnemonic: mnemonic)
        return address
    }

    /// Provisions this device from a recovery seed synced in via iCloud Keychain, or reports
    /// the wallet already present here. Returns `nil` when neither a local key nor a synced
    /// seed exists (a new install that should call `generateKeyPair`).
    ///
    /// The result maps `"address"` to the base58 address and `"recovered"` to whether the
    /// signing key was rebuilt from a seed. Nothing here prompts.
    ///
    /// Throws `.keyInvalidated` when the local wallet's Enclave key is gone (for example
    /// after a Face ID re-enrollment) and no seed is available to rebuild it.
    func loadOrRecover(walletId: String) throws -> [String: Any]? {
        // Fast path: this device already has the wallet.
        if let address = try? getPublicKey(walletId: walletId) {
            if enclaveKeyExists(walletId: walletId) {
                return ["address": address, "recovered": false]
            }
            // The Enclave key was invalidated. Re-wrap from the seed if we have it.
            guard let mnemonic = findSeed(walletId: walletId, address: address) else {
                throw SecureSignerError.keyInvalidated
            }
            let rebuilt = try provision(walletId: walletId, mnemonic: mnemonic)
            return ["address": rebuilt, "recovered": true]
        }

        // Recovery path: no local key, but a seed may have synced in.
        guard let mnemonic = latestSeed(walletId: walletId) else { return nil }
        let address = try provision(walletId: walletId, mnemonic: mnemonic)
        return ["address": address, "recovered": true]
    }

    /// Derives the key from `mnemonic`, wraps it under a fresh Enclave key, and makes sure
    /// the seed is stored under its per-address account (migrating legacy items).
    private func provision(walletId: String, mnemonic: String) throws -> String {
        var privateKey = Mnemonic.solanaPrivateKey(from: mnemonic)
        defer { privateKey.zeroize() }

        let address = try establish(walletId: walletId, privateKey: privateKey, mnemonic: mnemonic)
        storeRecoverySeed(walletId: walletId, address: address, mnemonic: mnemonic)
        return address
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

        var phraseBytes = Data(mnemonic.utf8)
        defer { phraseBytes.zeroize() }

        let keyCiphertext = try wrap(privateKey, to: enclavePublicKey, describedAs: "the private key")
        let phraseCiphertext = try wrap(phraseBytes, to: enclavePublicKey, describedAs: "the recovery phrase")

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

    /// Decrypts the item in `service` with the wallet's Enclave key, prompting for
    /// biometrics with `reason`. Returns the plaintext bytes; the caller must zeroize them.
    /// The CFData the Security framework returns is wiped before this returns.
    private func unwrap(walletId: String, service: String, reason: String, label: String) throws -> [UInt8] {
        // Missing ciphertext means there is no wallet here at all.
        let ciphertext = try keychainGet(service: service, account: walletId)

        let context = LAContext()
        context.localizedReason = reason

        let enclaveKey: SecKey
        do {
            enclaveKey = try loadEnclaveKey(walletId: walletId, context: context)
        } catch SecureSignerError.keyNotFound {
            // The wrapped blob is still here but its Enclave key is gone: with
            // `.biometryCurrentSet` that happens when Face ID / Touch ID is re-enrolled.
            throw SecureSignerError.keyInvalidated
        }

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
            if code == Int(errSecItemNotFound) || !enclaveKeyExists(walletId: walletId) {
                throw SecureSignerError.keyInvalidated
            }
            throw SecureSignerError.enclave("unwrapping \(label) failed (\(code ?? 0))")
        }

        let length = CFDataGetLength(plaintext)
        var bytes = [UInt8](repeating: 0, count: length)
        if let source = CFDataGetBytePtr(plaintext) {
            bytes.withUnsafeMutableBytes { dest in
                dest.baseAddress?.copyMemory(from: source, byteCount: length)
            }
            // Best effort: we hold the only reference to this buffer, so wipe it in place.
            memset_s(UnsafeMutableRawPointer(mutating: source), length, 0, length)
        }
        return bytes
    }

    /// Reveals the wallet's recovery phrase after biometric authentication. The phrase is
    /// decrypted only to be returned; nothing is stored in the clear.
    func revealMnemonic(walletId: String, reason: String) throws -> String {
        var bytes = try unwrap(walletId: walletId, service: Self.mnemonicService,
                               reason: reason, label: "the recovery phrase")
        defer { bytes.zeroize() }

        guard let mnemonic = String(bytes: bytes, encoding: .utf8) else {
            throw SecureSignerError.enclave("stored recovery phrase is corrupt")
        }
        return mnemonic
    }

    // MARK: Signing

    /// Signs `message` with the wallet's Ed25519 key after biometric authentication and
    /// returns a 64-byte signature. `reason` is shown in the authentication prompt. The
    /// key is decrypted only for the signature and its buffer zeroed immediately after.
    func signMessage(walletId: String, message: Data, reason: String) throws -> Data {
        var keyBytes = try unwrap(walletId: walletId, service: Self.ciphertextService,
                                  reason: reason, label: "the private key")
        defer { keyBytes.zeroize() }

        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: keyBytes)
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

    /// Removes this device's copy of the wallet: public address, wrapped key, wrapped
    /// phrase, Enclave key, and any local (non-synced) seed copy. The iCloud seed stays, so
    /// `loadOrRecover` can bring the wallet back here or on another device.
    ///
    /// With `wipeBackup`, also deletes the synced seed for this wallet's address, which
    /// removes it from every device on the iCloud account. Other wallets' seeds are never
    /// touched.
    func deleteKey(walletId: String, wipeBackup: Bool) throws {
        let address = try? getPublicKey(walletId: walletId)

        for service in [Self.ciphertextService, Self.mnemonicService, Self.pubService] {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: walletId,
            ]
            SecItemDelete(query as CFDictionary) // errSecItemNotFound is acceptable
        }
        deleteEnclaveKey(walletId: walletId)

        // Local-only seed copies (the fallback when the synced write was refused).
        deleteSeedItem(account: walletId, synchronizable: kCFBooleanFalse!)
        if let address {
            deleteSeedItem(account: Self.seedAccount(address), synchronizable: kCFBooleanFalse!)
        }

        guard wipeBackup, let address else { return }
        deleteSeedItem(account: Self.seedAccount(address), synchronizable: kSecAttrSynchronizableAny)
        // A legacy item shares the walletId account across wallets, so remove it only if
        // it really holds this wallet's seed.
        if let legacy = seedItems().first(where: { $0.account == walletId }),
           Self.address(of: legacy.mnemonic) == address {
            deleteSeedItem(account: walletId, synchronizable: kSecAttrSynchronizableAny)
        }
    }

    // MARK: - Recovery seed vault (iCloud Keychain)

    /// Stores the recovery seed in the iCloud-synchronizable keychain under its own
    /// per-address account. Never deletes or overwrites: if an item for this address is
    /// already there (same address means same seed), that counts as success.
    ///
    /// Best-effort: wallet creation must not fail because of the vault. If the synced write
    /// is refused (for example on a simulator), it falls back to a local copy.
    ///
    /// Note: SecItemAdd with synchronizable=true also succeeds when iCloud Keychain is
    /// turned off; the item just never leaves the device. We cannot see that from here, so
    /// nothing in this class reports the backup as verified.
    private func storeRecoverySeed(walletId: String, address: String, mnemonic: String) {
        var data = Data(mnemonic.utf8)
        defer { data.zeroize() }
        let account = Self.seedAccount(address)

        let status = addSeedItem(account: account, walletId: walletId, data: data, synchronizable: true)
        if status == errSecSuccess || status == errSecDuplicateItem { return }

        let local = addSeedItem(account: account, walletId: walletId, data: data, synchronizable: false)
        NSLog("Xend: recovery seed not synced (status \(status)); local copy status \(local)")
    }

    private func addSeedItem(account: String, walletId: String, data: Data, synchronizable: Bool) -> OSStatus {
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.seedVaultService,
            kSecAttrAccount as String: account,
            kSecAttrGeneric as String: Data(walletId.utf8),
            kSecAttrSynchronizable as String: synchronizable ? kCFBooleanTrue! : kCFBooleanFalse!,
            kSecValueData as String: data,
            // A synchronizable item must not be ThisDeviceOnly; `WhenUnlocked` keeps it out
            // of reach until the device is unlocked while still allowing iCloud sync.
            kSecAttrAccessible as String: synchronizable
                ? kSecAttrAccessibleWhenUnlocked
                : kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(add as CFDictionary, nil)
    }

    private func deleteSeedItem(account: String, synchronizable: Any) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.seedVaultService,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: synchronizable,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private struct SeedItem {
        let account: String
        let walletId: String?
        let mnemonic: String
        let modified: Date
    }

    /// Every seed in the vault, synced or local, with valid phrases only.
    private func seedItems() -> [SeedItem] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.seedVaultService,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let rows = out as? [[String: Any]] else { return [] }

        return rows.compactMap { row in
            guard let account = row[kSecAttrAccount as String] as? String,
                  let data = row[kSecValueData as String] as? Data,
                  let mnemonic = String(data: data, encoding: .utf8),
                  (try? Mnemonic.validate(mnemonic)) != nil else { return nil }
            let walletId = (row[kSecAttrGeneric as String] as? Data).flatMap { String(data: $0, encoding: .utf8) }
            let modified = row[kSecAttrModificationDate as String] as? Date ?? .distantPast
            return SeedItem(account: account, walletId: walletId, mnemonic: mnemonic, modified: modified)
        }
    }

    /// The most recently modified seed belonging to `walletId`: new-format items tagged
    /// with it, or the legacy item whose account is the walletId.
    private func latestSeed(walletId: String) -> String? {
        seedItems()
            .filter { $0.walletId == walletId || $0.account == walletId }
            .max { $0.modified < $1.modified }?
            .mnemonic
    }

    /// The seed for a known `address`, checked by re-deriving it.
    private func findSeed(walletId: String, address: String) -> String? {
        let account = Self.seedAccount(address)
        let candidates = seedItems()
            .filter { $0.account == account || $0.account == walletId }
            .sorted { $0.modified > $1.modified }
        return candidates.first { Self.address(of: $0.mnemonic) == address }?.mnemonic
    }

    private static func address(of mnemonic: String) -> String? {
        var privateKey = Mnemonic.solanaPrivateKey(from: mnemonic)
        defer { privateKey.zeroize() }
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateKey) else { return nil }
        return Base58.encode([UInt8](key.publicKey.rawRepresentation))
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

    /// Whether the wallet's Enclave key is still in the keychain. Asking for a reference
    /// does not use the key, so this never prompts.
    private func enclaveKeyExists(walletId: String) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Self.enclaveTag(walletId),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // errSecInteractionNotAllowed still means the key is there.
        return status == errSecSuccess || status == errSecInteractionNotAllowed
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
