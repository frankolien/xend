/// The value types of the Xend public API.
///
/// Monetary amounts are always represented in an asset's smallest indivisible unit as a
/// [BigInt]; conversion to a human-readable decimal happens only at the presentation
/// layer.

/// The blockchains supported by the Xend SDK.
///
/// This release implements [solana]. The remaining values are defined so that the API
/// surface stays stable as support is added; requesting one today throws
/// [NotImplementedYet].
enum Chain {
  solana,
  ethereum,
  base,
  arbitrum,
  optimism,
  polygon,
  bnb,
  bitcoin,
}

/// An asset that can be held or transferred: either a chain's native currency or a
/// token identified by its contract or mint address.
class Asset {
  /// Creates an asset descriptor.
  ///
  /// [decimals] is the number of fractional digits the asset uses (for example, 9 for
  /// SOL, 6 for USDC) and is applied only when formatting amounts for display.
  const Asset({
    required this.chain,
    this.mint,
    required this.decimals,
    this.symbol,
  });

  /// Creates a descriptor for [chain]'s native currency, such as SOL on Solana.
  const Asset.native(this.chain)
      : mint = null,
        decimals = 9,
        symbol = null;

  /// The chain the asset belongs to.
  final Chain chain;

  /// The token's contract or mint address, or `null` for the chain's native currency.
  final String? mint;

  /// The number of fractional digits, used only for display formatting.
  final int decimals;

  /// An optional ticker symbol, such as `USDC`.
  final String? symbol;
}

/// An asset balance, expressed in the asset's smallest indivisible unit.
class Balance {
  const Balance({required this.asset, required this.amount});

  /// The asset this balance is denominated in.
  final Asset asset;

  /// The balance, in [asset]'s smallest indivisible unit.
  final BigInt amount;
}

/// An opaque reference to a submitted transaction, used to observe its progress with
/// [XendWallet.watch].
///
/// This is not the on-chain transaction signature, which may not yet exist when the
/// handle is created.
class TxHandle {
  const TxHandle(this.id);

  /// The opaque identifier.
  final String id;

  @override
  String toString() => 'TxHandle($id)';
}

/// The degree of finality a transaction has reached on the network.
///
/// Ordered from least to most final: [processed] < [confirmed] < [finalized]. A
/// [confirmed] transaction is highly likely to succeed but can, in rare cases, be
/// rolled back; a [finalized] transaction cannot.
enum TxCommitment { processed, confirmed, finalized }

/// A point-in-time status for a transaction, emitted by [XendWallet.watch].
class TxStatus {
  const TxStatus({
    required this.handle,
    required this.state,
    this.commitment,
    this.signature,
    this.error,
  });

  /// The transaction this status refers to.
  final TxHandle handle;

  /// The current lifecycle state: one of `building`, `pending`, `confirmed`,
  /// `finalized`, or `failed`.
  final String state;

  /// The commitment level reached, or `null` before the network has observed the
  /// transaction.
  final TxCommitment? commitment;

  /// The on-chain transaction signature, or `null` before broadcast.
  final String? signature;

  /// The failure, present only when [state] is `failed`.
  final Object? error;

  /// Whether the transaction has reached irreversible finality.
  bool get isTerminalSuccess => state == 'finalized';

  /// Whether the transaction has failed.
  bool get isFailed => state == 'failed';
}

/// A historical transaction record returned by [XendWallet.history].
class TxRecord {
  const TxRecord({
    required this.signature,
    required this.status,
    required this.to,
    required this.amount,
    required this.asset,
    required this.createdAt,
  });

  /// The on-chain transaction signature.
  final String signature;

  /// The transaction's final recorded state.
  final String status;

  /// The recipient address.
  final String to;

  /// The amount transferred, in [asset]'s smallest indivisible unit.
  final BigInt amount;

  /// The asset transferred.
  final Asset asset;

  /// When the transaction was created.
  final DateTime createdAt;
}
