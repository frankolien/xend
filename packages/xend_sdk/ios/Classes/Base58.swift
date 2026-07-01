import Foundation

/// Base58 (Bitcoin/Solana alphabet). A Solana address is the base58 encoding of a
/// 32-byte Ed25519 public key. Verified against known vectors + 1000 random 32-byte
/// roundtrips before landing here (see scratchpad/verify_crypto.swift).
///
/// Boring where it counts (philosophy #5): this is money-adjacent encoding, so it is
/// a plain, tested, allocation-simple implementation — no cleverness.
enum Base58 {
    private static let alphabet =
        Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".utf8)

    private static let map: [Int8] = {
        var m = [Int8](repeating: -1, count: 128)
        for (i, c) in alphabet.enumerated() { m[Int(c)] = Int8(i) }
        return m
    }()

    static func encode(_ bytes: [UInt8]) -> String {
        if bytes.isEmpty { return "" }
        var zeros = 0
        for b in bytes { if b == 0 { zeros += 1 } else { break } }

        var input = bytes
        var out = [UInt8]()
        var start = zeros
        while start < input.count {
            var remainder: UInt32 = 0
            var i = start
            while i < input.count {
                let acc = UInt32(input[i]) &+ remainder &* 256
                input[i] = UInt8(acc / 58)
                remainder = acc % 58
                i += 1
            }
            out.append(alphabet[Int(remainder)])
            if input[start] == 0 { start += 1 }
        }
        for _ in 0..<zeros { out.append(alphabet[0]) }
        return String(bytes: out.reversed(), encoding: .utf8)!
    }

    static func decode(_ s: String) -> [UInt8]? {
        if s.isEmpty { return [] }
        var zeros = 0
        for c in s.utf8 { if c == alphabet[0] { zeros += 1 } else { break } }

        var bytes = [UInt8]()
        for c in s.utf8 {
            if c >= 128 || map[Int(c)] == -1 { return nil }
            var carry = Int(map[Int(c)])
            for j in 0..<bytes.count {
                carry += Int(bytes[j]) * 58
                bytes[j] = UInt8(carry & 0xff)
                carry >>= 8
            }
            while carry > 0 { bytes.append(UInt8(carry & 0xff)); carry >>= 8 }
        }
        for _ in 0..<zeros { bytes.append(0) }
        return bytes.reversed()
    }
}
