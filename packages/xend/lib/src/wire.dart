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
  assert(length >= 0 && length <= 0xffff, 'shortvec length out of range: $length');
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
