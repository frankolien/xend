/// Value types for the Xend public API. All money is in integer base units,
/// never a double — display formatting happens at the very edge (UI), nowhere else.

/// A supported chain. v0.1 implements only [Chain.solana]; the rest exist so the
/// API surface is stable when they light up (see docs/02-DECISIONS.md#d0).
enum Chain {
  solana,
  ethereum, // v1.0
  base, // v1.0
  arbitrum, // v1.0
  optimism, // v1.0
  polygon, // v1.0
  bnb, // v1.0
  bitcoin, // future
}

/// What is being moved. `null` mint on Solana ⇒ native SOL.
class Asset {
  const Asset({required this.chain, this.mint, required this.decimals, this.symbol});

  /// Native asset of a chain (SOL, ETH, …). Decimals filled per chain.
  const Asset.native(this.chain)
      : mint = null,
        decimals = 9, // SOL. EVM natives override in v1.0.
        symbol = null;

  final Chain chain;

  /// Token contract / mint address. `null` ⇒ the chain's native asset.
  final String? mint;

  /// Base-unit decimals (SOL = 9, USDC = 6, …). Used only for edge formatting.
  final int decimals;

  final String? symbol;
}

/// A balance in integer base units. `amount` is authoritative; `decimals` is for
/// display only.
class Balance {
  const Balance({required this.asset, required this.amount});
  final Asset asset;
  final BigInt amount; // base units
}

/// An opaque handle to an in-flight transaction. Hand it to [XendWallet.watch].
/// It is *not* the on-chain signature (which may not exist yet at build time).
class TxHandle {
  const TxHandle(this.id);
  final String id;

  @override
  String toString() => 'TxHandle($id)';
}

/// Commitment level. "Done" is a choice among these — see docs/02-DECISIONS.md#d6.
enum TxCommitment { processed, confirmed, finalized }

/// A point-in-time status emitted by [XendWallet.watch]. The stream never lies:
/// pending is pending; [TxCommitment.confirmed] is not [TxCommitment.finalized].
class TxStatus {
  const TxStatus({
    required this.handle,
    required this.state,
    this.commitment,
    this.signature,
    this.error,
  });

  final TxHandle handle;

  /// building → pending → confirmed → finalized | failed
  final String state;

  /// Present once the network has a view. Null while still building/pending.
  final TxCommitment? commitment;

  /// The on-chain signature, once broadcast. Null while still building.
  final String? signature;

  /// Present iff [state] == 'failed'.
  final Object? error;

  bool get isTerminalSuccess => state == 'finalized';
  bool get isFailed => state == 'failed';
}

/// A historical transaction record from the backend index.
class TxRecord {
  const TxRecord({
    required this.signature,
    required this.status,
    required this.to,
    required this.amount,
    required this.asset,
    required this.createdAt,
  });

  final String signature;
  final String status;
  final String to;
  final BigInt amount; // base units
  final Asset asset;
  final DateTime createdAt;
}
