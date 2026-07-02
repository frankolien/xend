import Foundation
import CryptoKit
import Security

/// BIP-39 mnemonics and the Solana key derivation built on them: SLIP-0010 ed25519 along
/// `m/44'/501'/0'/0'`, the path used by Phantom and other Solana wallets, so a phrase
/// generated here restores in them and vice versa.
///
/// Every operation runs on-device. A derived private key is produced here, wrapped by the
/// Secure Enclave, and never returned across the platform channel; only the public address
/// and — once, for the user to write down — the mnemonic leave this layer.
enum Mnemonic {

    enum MnemonicError: Error {
        case invalidWordCount
        case unknownWord(String)
        case invalidChecksum
    }

    /// Reverse index from word to its position, built once from the wordlist.
    private static let wordIndex: [String: Int] = {
        var index = [String: Int](minimumCapacity: Bip39Wordlist.words.count)
        for (position, word) in Bip39Wordlist.words.enumerated() {
            index[word] = position
        }
        return index
    }()

    // MARK: - Generation & validation

    /// Generates a fresh 12-word mnemonic from 128 bits of cryptographically secure entropy.
    static func generate() -> String {
        var entropy = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, entropy.count, &entropy)
        return encode(entropy: Data(entropy))
    }

    /// Encodes `entropy` as a mnemonic: append the checksum (the first ENT/32 bits of
    /// SHA-256(entropy)) and map each 11-bit group to a word.
    static func encode(entropy: Data) -> String {
        let checksumBits = entropy.count * 8 / 32
        let bits = bitString(entropy) + String(bitString(Data(SHA256.hash(data: entropy))).prefix(checksumBits))

        var words: [String] = []
        var start = bits.startIndex
        while start < bits.endIndex {
            let end = bits.index(start, offsetBy: 11)
            let index = Int(bits[start..<end], radix: 2)!
            words.append(Bip39Wordlist.words[index])
            start = end
        }
        return words.joined(separator: " ")
    }

    /// Validates a mnemonic's length, word membership, and checksum, throwing otherwise.
    static func validate(_ mnemonic: String) throws {
        _ = try entropy(from: mnemonic)
    }

    /// Recovers the entropy behind a mnemonic, throwing if a word is unknown or the
    /// checksum does not match.
    static func entropy(from mnemonic: String) throws -> Data {
        let words = normalize(mnemonic).split(separator: " ").map(String.init)
        guard [12, 15, 18, 21, 24].contains(words.count) else {
            throw MnemonicError.invalidWordCount
        }

        var bits = ""
        for word in words {
            guard let index = wordIndex[word] else { throw MnemonicError.unknownWord(word) }
            let binary = String(index, radix: 2)
            bits += String(repeating: "0", count: 11 - binary.count) + binary
        }

        let checksumLength = bits.count / 33
        let entropyLength = bits.count - checksumLength
        let entropyBits = String(bits.prefix(entropyLength))
        let checksumBits = String(bits.suffix(checksumLength))

        var entropy = Data()
        var start = entropyBits.startIndex
        while start < entropyBits.endIndex {
            let end = entropyBits.index(start, offsetBy: 8)
            entropy.append(UInt8(entropyBits[start..<end], radix: 2)!)
            start = end
        }

        let expected = String(bitString(Data(SHA256.hash(data: entropy))).prefix(checksumLength))
        guard checksumBits == expected else { throw MnemonicError.invalidChecksum }
        return entropy
    }

    // MARK: - Solana key derivation

    /// Derives the Solana signing key — a 32-byte ed25519 seed — from `mnemonic` along
    /// `m/44'/501'/0'/0'`.
    static func solanaPrivateKey(from mnemonic: String, passphrase: String = "") -> Data {
        solanaPrivateKey(fromSeed: seed(from: mnemonic, passphrase: passphrase))
    }

    /// The BIP-39 seed: PBKDF2-HMAC-SHA512 over the mnemonic with salt "mnemonic"+passphrase
    /// and 2048 iterations, producing 64 bytes.
    static func seed(from mnemonic: String, passphrase: String = "") -> Data {
        let password = Data(normalize(mnemonic).utf8)
        let salt = Data(("mnemonic" + normalize(passphrase)).utf8)
        return pbkdf2SHA512(password: password, salt: salt, iterations: 2048, length: 64)
    }

    /// Derives the ed25519 seed from a BIP-39 seed via SLIP-0010 along `m/44'/501'/0'/0'`.
    /// ed25519 supports only hardened derivation, so every level is hardened.
    static func solanaPrivateKey(fromSeed seed: Data) -> Data {
        var node = slip10Master(seed)
        for index in [44, 501, 0, 0] {
            node = slip10DeriveHardened(node, index: UInt32(index))
        }
        return node.key
    }

    private struct Slip10Node {
        let key: Data
        let chainCode: Data
    }

    private static func slip10Master(_ seed: Data) -> Slip10Node {
        let mac = HMAC<SHA512>.authenticationCode(
            for: seed,
            using: SymmetricKey(data: Data("ed25519 seed".utf8))
        )
        let bytes = Data(mac)
        return Slip10Node(key: Data(bytes.prefix(32)), chainCode: Data(bytes.suffix(32)))
    }

    private static func slip10DeriveHardened(_ node: Slip10Node, index: UInt32) -> Slip10Node {
        let hardened = index | 0x8000_0000
        var data = Data([0x00])
        data.append(node.key)
        data.append(contentsOf: withUnsafeBytes(of: hardened.bigEndian) { Data($0) })

        let mac = HMAC<SHA512>.authenticationCode(for: data, using: SymmetricKey(data: node.chainCode))
        let bytes = Data(mac)
        return Slip10Node(key: Data(bytes.prefix(32)), chainCode: Data(bytes.suffix(32)))
    }

    // MARK: - Primitives

    /// PBKDF2-HMAC-SHA512. The output is at most one SHA-512 block for our 64-byte length,
    /// but the block loop is written in full so the routine is correct for any length.
    private static func pbkdf2SHA512(password: Data, salt: Data, iterations: Int, length: Int) -> Data {
        let key = SymmetricKey(data: password)
        var output = Data()
        var blockIndex: UInt32 = 1

        while output.count < length {
            var salted = salt
            salted.append(contentsOf: withUnsafeBytes(of: blockIndex.bigEndian) { Data($0) })

            var u = Data(HMAC<SHA512>.authenticationCode(for: salted, using: key))
            var result = u
            for _ in 1..<iterations {
                u = Data(HMAC<SHA512>.authenticationCode(for: u, using: key))
                for i in 0..<result.count { result[i] ^= u[i] }
            }
            output.append(result)
            blockIndex += 1
        }
        return Data(output.prefix(length))
    }

    /// The big-endian bit string of `data`, one character per bit.
    private static func bitString(_ data: Data) -> String {
        data.map { byte in
            let binary = String(byte, radix: 2)
            return String(repeating: "0", count: 8 - binary.count) + binary
        }
        .joined()
    }

    /// BIP-39 requires NFKD normalization of the mnemonic and passphrase before use. The
    /// English wordlist is ASCII, so this is an identity for generated phrases, but it is
    /// applied for correctness with imported phrases and passphrases.
    private static func normalize(_ text: String) -> String {
        text.decomposedStringWithCompatibilityMapping
    }
}
