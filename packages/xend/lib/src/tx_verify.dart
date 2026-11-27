import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

import 'errors.dart';
import 'wire.dart';

/// Decoding of Solana transaction messages and checks that a backend-built transfer
/// matches the user's request before it is signed. Pure Dart; internal to the SDK.

const String systemProgramId = '11111111111111111111111111111111';
const String tokenProgramId = 'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA';
const String associatedTokenProgramId =
    'ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL';

/// One instruction as it appears in a message: indexes into the account key list.
class CompiledInstruction {
  const CompiledInstruction(this.programIdIndex, this.accounts, this.data);

  final int programIdIndex;
  final List<int> accounts;
  final Uint8List data;
}

/// A decoded Solana message. [version] is null for a legacy message and 0 for v0.
class SolanaMessage {
  const SolanaMessage({
    required this.version,
    required this.numRequiredSignatures,
    required this.numReadonlySigned,
    required this.numReadonlyUnsigned,
    required this.accountKeys,
    required this.recentBlockhash,
    required this.instructions,
    required this.lookupCount,
  });

  final int? version;
  final int numRequiredSignatures;
  final int numReadonlySigned;
  final int numReadonlyUnsigned;

  /// Static account keys, base58.
  final List<String> accountKeys;
  final Uint8List recentBlockhash;
  final List<CompiledInstruction> instructions;

  /// Number of address lookup tables (v0 only).
  final int lookupCount;

  String programOf(CompiledInstruction ix) => accountKeys[ix.programIdIndex];
  String accountOf(CompiledInstruction ix, int i) =>
      accountKeys[ix.accounts[i]];
}

class _Reader {
  _Reader(this.bytes);

  final Uint8List bytes;
  var offset = 0;

  int u8() {
    if (offset >= bytes.length) throw const FormatException('truncated');
    return bytes[offset++];
  }

  Uint8List take(int n) {
    if (offset + n > bytes.length) throw const FormatException('truncated');
    final out = Uint8List.sublistView(bytes, offset, offset + n);
    offset += n;
    return out;
  }

  /// Compact-u16 as Solana encodes it. Rejects overlong encodings and values past
  /// u16, as the runtime does.
  int shortVec() {
    var value = 0;
    for (var i = 0; i < 3; i++) {
      final b = u8();
      value |= (b & 0x7f) << (7 * i);
      if (b & 0x80 == 0) {
        if (i > 0 && b == 0) throw const FormatException('overlong shortvec');
        if (value > 0xffff) throw const FormatException('shortvec overflow');
        return value;
      }
      if (i == 2) throw const FormatException('shortvec overflow');
    }
    throw const FormatException('shortvec overflow');
  }
}

/// Decodes a legacy or v0 message. Throws [FormatException] unless [bytes] is exactly one
/// well-formed message: header counts consistent, unique keys, every index in range, and
/// no trailing bytes.
SolanaMessage decodeMessage(List<int> bytes) {
  final r = _Reader(Uint8List.fromList(bytes));
  int? version;
  var first = r.u8();
  if (first & 0x80 != 0) {
    version = first & 0x7f;
    if (version != 0) throw FormatException('unsupported version $version');
    first = r.u8();
  }
  final numRequired = first;
  final numReadonlySigned = r.u8();
  final numReadonlyUnsigned = r.u8();

  final keyCount = r.shortVec();
  final keys = <String>[];
  for (var i = 0; i < keyCount; i++) {
    keys.add(base58Encode(r.take(32)));
  }
  if (numRequired == 0 || numRequired > keyCount) {
    throw const FormatException('bad signer count');
  }
  if (numReadonlySigned >= numRequired) {
    throw const FormatException('fee payer must be writable');
  }
  if (numReadonlyUnsigned > keyCount - numRequired) {
    throw const FormatException('bad readonly count');
  }
  if (keys.toSet().length != keys.length) {
    throw const FormatException('duplicate account key');
  }

  final blockhash = Uint8List.fromList(r.take(32));

  final ixCount = r.shortVec();
  final instructions = <CompiledInstruction>[];
  for (var i = 0; i < ixCount; i++) {
    final program = r.u8();
    final accountCount = r.shortVec();
    final accounts = [for (var j = 0; j < accountCount; j++) r.u8()];
    final dataLen = r.shortVec();
    final data = Uint8List.fromList(r.take(dataLen));
    instructions.add(CompiledInstruction(program, accounts, data));
  }

  var lookupCount = 0;
  var lookupKeys = 0;
  if (version != null) {
    lookupCount = r.shortVec();
    for (var i = 0; i < lookupCount; i++) {
      r.take(32);
      final writable = r.shortVec();
      r.take(writable);
      final readonly = r.shortVec();
      r.take(readonly);
      lookupKeys += writable + readonly;
    }
  }
  if (r.offset != r.bytes.length) throw const FormatException('trailing bytes');

  final total = keyCount + lookupKeys;
  for (final ix in instructions) {
    // The runtime forbids the fee payer as a program and programs from lookup tables.
    if (ix.programIdIndex == 0 || ix.programIdIndex >= keyCount) {
      throw const FormatException('bad program index');
    }
    if (ix.accounts.any((a) => a >= total)) {
      throw const FormatException('bad account index');
    }
  }

  return SolanaMessage(
    version: version,
    numRequiredSignatures: numRequired,
    numReadonlySigned: numReadonlySigned,
    numReadonlyUnsigned: numReadonlyUnsigned,
    accountKeys: keys,
    recentBlockhash: blockhash,
    instructions: instructions,
    lookupCount: lookupCount,
  );
}

/// Whether [bytes] decode as a Solana transaction message (legacy or v0).
bool isTransactionMessage(List<int> bytes) {
  try {
    decodeMessage(bytes);
    return true;
  } on FormatException {
    return false;
  }
}

// Ed25519 field constants, for the on-curve check in program address derivation.
final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _d =
    (BigInt.from(-121665) * BigInt.from(121666).modPow(_p - BigInt.two, _p)) %
        _p;

/// Whether the 32 [bytes] decompress to a point on the Ed25519 curve, matching
/// curve25519-dalek's `CompressedEdwardsY::decompress` as used by Solana.
bool isOnCurve(List<int> bytes) {
  assert(bytes.length == 32);
  var y = BigInt.zero;
  for (var i = 31; i >= 0; i--) {
    y = (y << 8) | BigInt.from(i == 31 ? bytes[i] & 0x7f : bytes[i]);
  }
  y %= _p;
  final yy = y * y % _p;
  final u = (yy - BigInt.one) % _p;
  final v = (_d * yy + BigInt.one) % _p;
  final w = u * v.modPow(_p - BigInt.two, _p) % _p;
  if (w == BigInt.zero) return true;
  return w.modPow((_p - BigInt.one) >> 1, _p) == BigInt.one;
}

/// Solana `find_program_address`: the first bump from 255 down whose hash is off-curve.
String findProgramAddress(List<List<int>> seeds, String programId) {
  final program = base58Decode(programId);
  const marker = 'ProgramDerivedAddress';
  for (var bump = 255; bump >= 0; bump--) {
    final input = <int>[
      for (final s in seeds) ...s,
      bump,
      ...program,
      ...marker.codeUnits,
    ];
    final hash = sha256.convert(input).bytes;
    if (!isOnCurve(hash)) return base58Encode(hash);
  }
  throw StateError('no program address found');
}

/// The canonical associated token account of [owner] for [mint].
String associatedTokenAddress(String owner, String mint) => findProgramAddress(
      [
        base58Decode(owner),
        base58Decode(tokenProgramId),
        base58Decode(mint),
      ],
      associatedTokenProgramId,
    );

BigInt _u64le(Uint8List data, int offset) {
  var v = BigInt.zero;
  for (var i = 7; i >= 0; i--) {
    v = (v << 8) | BigInt.from(data[offset + i]);
  }
  return v;
}

/// Checks that [message] does exactly what the user asked and nothing else, before it is
/// signed. Throws [TransactionMismatch] on any difference.
///
/// [sponsored] says whether the backend supplied a fee payer signature. If so, account 0
/// must be a different fee payer and the user must be signer 1; otherwise the user is the
/// sole signer and fee payer. Only the System, SPL Token, and Associated Token programs
/// may appear, in the exact shapes the backend builds.
///
/// Returns the token decimals from the transfer, or null for a native transfer.
int? verifyTransfer(
  List<int> message, {
  required String user,
  required String recipient,
  required BigInt amount,
  String? mint,
  required bool sponsored,
}) {
  Never fail(String reason) => throw TransactionMismatch(reason);

  final SolanaMessage m;
  try {
    m = decodeMessage(message);
  } on FormatException catch (e) {
    fail('malformed message (${e.message})');
  }
  if (m.version != null) fail('versioned messages are not accepted');

  // Signer layout must match how send() assembles signatures.
  final keys = m.accountKeys;
  if (sponsored) {
    if (m.numRequiredSignatures != 2) fail('expected 2 signers');
    if (keys[0] == user) fail('user is fee payer on a sponsored transfer');
    if (keys[1] != user) fail('user is not the second signer');
  } else {
    if (m.numRequiredSignatures != 1) fail('expected 1 signer');
    if (keys[0] != user) fail('user is not the fee payer');
  }
  final payer = keys[0];

  const allowed = {systemProgramId, tokenProgramId, associatedTokenProgramId};
  for (final ix in m.instructions) {
    if (!allowed.contains(m.programOf(ix))) {
      fail('unexpected program ${m.programOf(ix)}');
    }
  }

  if (mint == null) {
    if (m.instructions.length != 1) fail('expected exactly one instruction');
    final ix = m.instructions.single;
    if (m.programOf(ix) != systemProgramId) fail('expected a System transfer');
    final d = ix.data;
    if (d.length != 12 || d[0] != 2 || d[1] != 0 || d[2] != 0 || d[3] != 0) {
      fail('expected a System transfer');
    }
    if (ix.accounts.length != 2) fail('unexpected transfer accounts');
    if (m.accountOf(ix, 0) != user) fail('transfer source is not the user');
    if (m.accountOf(ix, 1) != recipient) fail('wrong recipient');
    if (_u64le(d, 4) != amount) fail('wrong amount');
    return null;
  }

  // Token transfer: optional idempotent ATA create for the recipient, then one
  // TransferChecked between the two owners' associated accounts.
  final n = m.instructions.length;
  if (n != 1 && n != 2) fail('unexpected instruction count');
  final String userAta;
  final String recipientAta;
  try {
    userAta = associatedTokenAddress(user, mint);
    recipientAta = associatedTokenAddress(recipient, mint);
  } on FormatException {
    fail('invalid address');
  }

  if (n == 2) {
    final create = m.instructions[0];
    if (m.programOf(create) != associatedTokenProgramId ||
        create.data.length != 1 ||
        create.data[0] != 1) {
      fail('expected an idempotent token account create');
    }
    if (create.accounts.length != 6) fail('unexpected create accounts');
    // In a sponsored transfer the user must not fund rent; the fee payer does.
    if (m.accountOf(create, 0) != payer)
      fail('account create not funded by fee payer');
    if (m.accountOf(create, 1) != recipientAta)
      fail('wrong token account created');
    if (m.accountOf(create, 2) != recipient)
      fail('token account for wrong owner');
    if (m.accountOf(create, 3) != mint) fail('token account for wrong mint');
    if (m.accountOf(create, 4) != systemProgramId ||
        m.accountOf(create, 5) != tokenProgramId) {
      fail('unexpected create accounts');
    }
  }

  final ix = m.instructions.last;
  if (m.programOf(ix) != tokenProgramId) fail('expected a token transfer');
  final d = ix.data;
  if (d.length != 10 || d[0] != 12) fail('expected TransferChecked');
  if (ix.accounts.length != 4) fail('unexpected transfer accounts');
  if (m.accountOf(ix, 0) != userAta) fail('transfer source is not the user');
  if (m.accountOf(ix, 1) != mint) fail('wrong mint');
  if (m.accountOf(ix, 2) != recipientAta) fail('wrong recipient');
  if (m.accountOf(ix, 3) != user) fail('transfer authority is not the user');
  if (_u64le(d, 1) != amount) fail('wrong amount');
  return d[9];
}
