import 'dart:math';

import 'package:flutter/services.dart' show PlatformException;

import 'errors.dart';
import 'models.dart';

/// Pure translations between wire/native values and the public model types. Internal to
/// the SDK; not part of the public API.

/// Whether [value] is a name to resolve rather than a raw address. `.sol` domains end in
/// `.sol`; base58 addresses do not.
bool isSolName(String value) => value.toLowerCase().endsWith('.sol');

/// A random 128-bit idempotency key as lowercase hex (32 characters). A distinct key per
/// call keeps sends independent; a caller who wants retry safety can supply their own.
String newIdempotencyKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Builds a [TxRecord] from a backend history record. A `null` mint denotes the chain's
/// native asset; amounts are decimal strings in base units.
TxRecord txRecordFromJson(Map<String, dynamic> json, Chain chain) {
  final mint = json['mint'] as String?;
  return TxRecord(
    signature: json['signature'] as String,
    status: json['status'] as String,
    to: (json['to'] as String?) ?? '',
    amount: BigInt.tryParse((json['amount'] as String?) ?? '0') ?? BigInt.zero,
    asset: mint == null
        ? Asset.native(chain)
        : Asset(chain: chain, mint: mint, decimals: 0),
    createdAt: DateTime.parse(json['created_at'] as String),
  );
}

/// Translates a backend commitment string (`processed` | `confirmed` | `finalized` |
/// `failed`) into a [TxStatus] for the transaction identified by [handle]. An unknown
/// value is treated as `processed`.
TxStatus txStatusFromBackend(TxHandle handle, String raw) {
  switch (raw) {
    case 'finalized':
      return TxStatus(
        handle: handle,
        state: 'finalized',
        commitment: TxCommitment.finalized,
        signature: handle.id,
      );
    case 'confirmed':
      return TxStatus(
        handle: handle,
        state: 'confirmed',
        commitment: TxCommitment.confirmed,
        signature: handle.id,
      );
    case 'failed':
      return TxStatus(
        handle: handle,
        state: 'failed',
        signature: handle.id,
        error: const ChainRejected('transaction failed on-chain'),
      );
    case 'processed':
    default:
      return TxStatus(
        handle: handle,
        state: 'pending',
        commitment: TxCommitment.processed,
        signature: handle.id,
      );
  }
}

/// Maps a native secure-element failure to a typed [XendError]. A cancelled biometric
/// prompt is the case callers branch on; other device failures surface as a retryable
/// [NetworkError], since they mean the operation did not complete.
XendError mapNativeError(PlatformException e) {
  switch (e.code) {
    case 'user_cancelled_auth':
      return const UserCancelledAuth();
    case 'invalid_mnemonic':
      return const InvalidRecoveryPhrase();
    case 'biometrics_unavailable':
      return const NetworkError(
        'Biometric authentication is unavailable on this device',
      );
    default:
      return NetworkError('secure element error: ${e.message ?? e.code}');
  }
}
