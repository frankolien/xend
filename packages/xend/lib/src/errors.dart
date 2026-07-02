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
