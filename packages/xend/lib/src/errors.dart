/// A sealed set of failures — exhaustive by design. A developer must be able to
/// `switch` on the failure and respond correctly: on a wallet, the right response
/// to "network down" (retry) is the opposite of "insufficient funds" (stop and
/// tell the user). No stringly-typed errors, no generic exceptions.
sealed class XendError implements Exception {
  const XendError(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Transient. Safe to retry (idempotency makes a blind retry safe). The SDK may
/// auto-retry with backoff, then surface — see docs/02-DECISIONS.md#d7.
final class NetworkError extends XendError {
  const NetworkError([super.message = 'Network unavailable']);
}

/// Terminal. Do not retry; inform the user. Never broadcast.
final class InsufficientFunds extends XendError {
  const InsufficientFunds([super.message = 'Insufficient funds']);
}

/// Face ID dismissed or interrupted (e.g. app backgrounded mid-prompt). Clean and
/// recoverable: nothing was signed, nothing sent, no money moved. Offer retry.
final class UserCancelledAuth extends XendError {
  const UserCancelledAuth([super.message = 'Authentication cancelled']);
}

/// The blockhash expired before broadcast. The SDK may auto-handle by rebuilding
/// and re-prompting Face ID (bounded; never silent) — see docs/02-DECISIONS.md#d7.
final class BlockhashExpired extends XendError {
  const BlockhashExpired([super.message = 'Blockhash expired; rebuild required']);
}

/// Terminal. The recipient address is malformed or invalid for the chain.
final class InvalidRecipient extends XendError {
  const InvalidRecipient([super.message = 'Invalid recipient address']);
}

/// Backend/RPC rate limit. Back off for [retryAfter], then retry.
final class RateLimited extends XendError {
  const RateLimited(this.retryAfter, [String? message])
      : super(message ?? 'Rate limited');
  final Duration retryAfter;
}

/// The network refused the transaction. Inspect [reason] (e.g. simulation failure,
/// program error). Usually terminal for these exact bytes.
final class ChainRejected extends XendError {
  const ChainRejected(this.reason) : super('Chain rejected: $reason');
  final String reason;
}

/// A capability whose *signature* is stable but whose *implementation* is roadmap
/// (e.g. swap/bridge/on-ramp, or a non-Solana chain in v0.1). Thrown honestly so a
/// developer never mistakes "not built yet" for "failed at runtime".
final class NotImplementedYet extends XendError {
  const NotImplementedYet(String what)
      : super('$what is not implemented in this version. See docs/03-ROADMAP.md');
}
