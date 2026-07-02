/// The base type for every recoverable failure surfaced by the Xend SDK.
///
/// All fallible operations fail with a subtype of [XendError], so callers can handle
/// each condition explicitly rather than inspecting error strings:
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

  /// A human-readable description of the failure. Intended for logs and developers, not
  /// for direct display to end users without localization.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// A transient failure while communicating with the Xend backend or network.
///
/// Safe to retry. Operations are idempotent, so a retried request is not applied twice.
final class NetworkError extends XendError {
  const NetworkError([super.message = 'Network unavailable']);
}

/// The wallet's balance cannot cover the requested amount plus fees.
///
/// Terminal: do not retry.
final class InsufficientFunds extends XendError {
  const InsufficientFunds([super.message = 'Insufficient funds']);
}

/// Biometric authentication was cancelled or interrupted before signing completed.
///
/// No transaction was signed or submitted and no funds moved. The operation may be
/// retried.
final class UserCancelledAuth extends XendError {
  const UserCancelledAuth([super.message = 'Authentication cancelled']);
}

/// The transaction's validity window elapsed before it could be broadcast.
///
/// Depending on the SDK's recovery policy, this may be handled automatically by
/// rebuilding and re-signing the transaction.
final class BlockhashExpired extends XendError {
  const BlockhashExpired([super.message = 'Transaction expired before broadcast']);
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
/// Usually terminal for the submitted transaction. See [reason] for details.
final class ChainRejected extends XendError {
  const ChainRejected(this.reason) : super('Chain rejected: $reason');

  /// The reason reported by the network, such as a simulation or program error.
  final String reason;
}

/// The supplied recovery phrase is not a valid BIP-39 mnemonic (wrong length, an unknown
/// word, or a failed checksum).
///
/// Terminal: correct the phrase and try again.
final class InvalidRecoveryPhrase extends XendError {
  const InvalidRecoveryPhrase([super.message = 'Invalid recovery phrase']);
}

/// The requested capability is not available in this release.
///
/// The method's signature is stable, but its implementation is planned for a future
/// version. Consult the package changelog for availability.
final class NotImplementedYet extends XendError {
  const NotImplementedYet(String what)
      : super('$what is not available in this version');
}
