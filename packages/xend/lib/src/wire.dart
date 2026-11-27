import 'dart:typed_data';

/// Solana transaction wire encoding. Internal to the SDK; not part of the public API.

/// Assembles a signed Solana transaction in wire format: the compact-u16 count of
/// [signatures], each 64-byte signature in signer order, then the serialized [message].
/// A sponsored transfer has two signatures (fee payer, then sender); an unsponsored one
/// has a single sender signature.
Uint8List assembleSignedTransaction(
  List<Uint8List> signatures,
  Uint8List message,
) {
  final builder = BytesBuilder();
  builder.add(encodeShortVecLength(signatures.length));
  for (final signature in signatures) {
    builder.add(signature);
  }
  builder.add(message);
  return builder.toBytes();
}

/// Encodes [length] as a Solana compact-u16 (shortvec): 7 bits per byte, little-endian,
/// with the high bit marking continuation. Valid for 0..65535.
List<int> encodeShortVecLength(int length) {
  assert(
      length >= 0 && length <= 0xffff, 'shortvec length out of range: $length');
  final bytes = <int>[];
  var remaining = length;
  while (true) {
    final byte = remaining & 0x7f;
    remaining >>= 7;
    if (remaining == 0) {
      bytes.add(byte);
      return bytes;
    }
    bytes.add(byte | 0x80);
  }
}

const String _base58Alphabet =
    '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';

/// Encodes [bytes] as base58 (Bitcoin alphabet), the text form of Solana addresses.
String base58Encode(List<int> bytes) {
  var zeros = 0;
  while (zeros < bytes.length && bytes[zeros] == 0) {
    zeros++;
  }
  var value = BigInt.zero;
  for (final b in bytes) {
    value = (value << 8) | BigInt.from(b);
  }
  final out = StringBuffer();
  final base = BigInt.from(58);
  final digits = <String>[];
  while (value > BigInt.zero) {
    digits.add(_base58Alphabet[(value % base).toInt()]);
    value = value ~/ base;
  }
  out.write('1' * zeros);
  out.writeAll(digits.reversed);
  return out.toString();
}

/// Decodes a base58 string. Throws [FormatException] on a character outside the
/// alphabet.
Uint8List base58Decode(String input) {
  var zeros = 0;
  while (zeros < input.length && input[zeros] == '1') {
    zeros++;
  }
  var value = BigInt.zero;
  final base = BigInt.from(58);
  for (var i = 0; i < input.length; i++) {
    final digit = _base58Alphabet.indexOf(input[i]);
    if (digit < 0) throw FormatException('invalid base58 character', input, i);
    value = value * base + BigInt.from(digit);
  }
  final body = <int>[];
  while (value > BigInt.zero) {
    body.add((value & BigInt.from(0xff)).toInt());
    value = value >> 8;
  }
  return Uint8List.fromList([...List.filled(zeros, 0), ...body.reversed]);
}

/// Decodes a base58 Solana address to its 32 bytes, or returns null if [address] is not
/// valid base58 of exactly that length.
Uint8List? decodeAddress(String address) {
  try {
    final bytes = base58Decode(address);
    return bytes.length == 32 ? bytes : null;
  } on FormatException {
    return null;
  }
}
