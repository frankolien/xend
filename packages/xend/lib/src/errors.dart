/// Base type for every recoverable failure from the Xend SDK.
///
/// Fallible operations throw a subtype of [XendError], so callers can handle each
/// condition by type instead of inspecting error strings:
///
/// ```dart
/// try {
///   await wallet.send(to: recipient, amount: amount);
/// } on InsufficientFunds {
///   // Balance too low — inform the user.
/// } on NetworkError {
///   // Transient — safe to retry.
/// } on XendError catch (e) {
///   // Fallback for any other failure.
/// }
/// ```
sealed class XendError implements Exception {
  const XendError(this.message);

  /// Human-readable description of the failure, for logs and developers. Not for direct
  /// display to end users without localization.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// A transient failure talking to the backend or network.
///
/// Safe to retry: operations are idempotent, so a retried request is not applied twice.
final class NetworkError extends XendError {
  const NetworkError([super.message = 'Network unavailable']);
}

/// The wallet's balance cannot cover the requested amount plus fees.
///
/// Terminal: do not retry.
final class InsufficientFunds extends XendError {
  const InsufficientFunds([super.message = 'Insufficient funds']);
}

/// Biometric authentication was cancelled or interrupted before signing.
///
/// Nothing was signed or submitted and no funds moved. Safe to retry.
final class UserCancelledAuth extends XendError {
  const UserCancelledAuth([super.message = 'Authentication cancelled']);
}

/// The transaction's validity window elapsed before it could be broadcast.
///
/// May be handled automatically by rebuilding and re-signing, depending on the SDK's
/// recovery policy.
final class BlockhashExpired extends XendError {
  const BlockhashExpired(
      [super.message = 'Transaction expired before broadcast']);
}

/// The recipient address is not valid for the target chain.
///
/// Terminal.
final class InvalidRecipient extends XendError {
  const InvalidRecipient([super.message = 'Invalid recipient address']);
}

/// The idempotency key was already used for a different transaction.
///
/// A key stands for exactly one transaction, so submitting different signed bytes under a
/// key that is already taken is refused rather than sent. Nothing was broadcast, and the
/// transaction the key already refers to is unaffected.
///
/// Terminal: retrying cannot help. Build the transaction again under a fresh key.
final class IdempotencyKeyReuse extends XendError {
  const IdempotencyKeyReuse(
      [super.message =
          'Idempotency key already used for a different transaction']);
}

/// The request was rejected because a rate limit was exceeded.
final class RateLimited extends XendError {
  const RateLimited(this.retryAfter, [String? message])
      : super(message ?? 'Rate limited');

  /// The minimum duration to wait before retrying.
  final Duration retryAfter;
}

/// The network rejected the transaction.
///
/// Usually terminal for the submitted transaction. See [reason].
final class ChainRejected extends XendError {
  const ChainRejected(this.reason) : super('Chain rejected: $reason');

  /// The reason reported by the network, such as a simulation or program error.
  final String reason;
}

/// The recovery phrase is not a valid BIP-39 mnemonic: wrong length, unknown word, or
/// failed checksum.
///
/// Terminal: correct the phrase and try again.
final class InvalidRecoveryPhrase extends XendError {
  const InvalidRecoveryPhrase([super.message = 'Invalid recovery phrase']);
}

/// The requested capability is not available in this release.
///
/// The method signature is stable; the implementation is planned for a future version.
/// See the package changelog for availability.
final class NotImplementedYet extends XendError {
  const NotImplementedYet(String what)
      : super('$what is not available in this version');
}

/// The transaction returned by the backend does not match what was asked for, so it was
/// not signed. See [reason].
///
/// Nothing was signed or submitted. Terminal: treat it as a fault or compromise of the
/// backend, not a condition to retry around.
final class TransactionMismatch extends XendError {
  const TransactionMismatch(this.reason)
      : super('Transaction does not match the request: $reason');

  /// What differed, such as an unexpected recipient or amount.
  final String reason;
}

/// [XendWallet.sign] was given bytes that decode as a Solana transaction message.
///
/// Signing them would authorize that transaction, so the request is refused. Use
/// [XendWallet.send] to move funds. Terminal.
final class UnsafeSignRequest extends XendError {
  const UnsafeSignRequest(
      [super.message = 'Refusing to sign bytes that form a transaction']);
}

/// The device signing key is gone because biometric enrollment changed (for example, a
/// new face or fingerprint was added).
///
/// Terminal for this key. Load the wallet again to rebuild the key from its synced seed,
/// or restore it from the recovery phrase.
final class KeyInvalidated extends XendError {
  const KeyInvalidated(
      [super.message = 'Signing key invalidated by a biometric change']);
}

/// The recovery seed could not be backed up or read from the platform keychain sync, for
/// example because iCloud Keychain is turned off.
///
/// The on-device key still works; only cross-device recovery is affected.
final class BackupUnavailable extends XendError {
  const BackupUnavailable([super.message = 'Keychain backup unavailable']);
}

/// The device's secure storage or secure element failed, or biometrics are unavailable.
///
/// Not a network condition. Retrying the same call rarely helps; check device settings.
final class SecureElementError extends XendError {
  const SecureElementError([super.message = 'Secure element error']);
}
