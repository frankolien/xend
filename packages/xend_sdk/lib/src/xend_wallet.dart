import 'dart:async';

import 'config.dart';
import 'errors.dart';
import 'models.dart';
import 'secure_channel.dart';

/// The public face of Xend. Signatures are the contract; bodies fill in across
/// Phases 1–5 (see docs/00-PRD.md). This is the *entire* public vocabulary.
///
/// Design rules encoded here:
///  * Money is always [BigInt] base units — never a double.
///  * The API is chain-agnostic (D0): every call takes a [Chain], defaulting to
///    Solana. v0.1 implements Solana; other chains throw [NotImplementedYet].
///  * [send] returns fast with a [TxHandle]; callers [watch] for the rest. It does
///    NOT block until final confirmation — that would conflate "submitted" with "done".
///  * Every failure is a typed [XendError] variant.
class XendWallet {
  XendWallet._(this._walletId, this.address, this.chain);

  /// v0.1 is single-wallet: the key is stored under a fixed native id so it survives an
  /// app restart. Multi-wallet (generated ids + a local index) is a later enhancement.
  static const String _defaultWalletId = 'default';

  /// Opaque handle the native vault uses to find this wallet's key. Never the key.
  final String _walletId;

  /// base58 (Solana) / hex (EVM) public address.
  final String address;

  /// The chain this wallet operates on. v0.1: always [Chain.solana].
  final Chain chain;

  // ── Lifecycle ────────────────────────────────────────────────────────────

  /// Creates a new keypair *on the device* (native vault), then registers the public
  /// address with the backend. Only the public address ever leaves native.
  static Future<XendWallet> create({
    String? label,
    Chain chain = Chain.solana,
  }) async {
    _requireSolana(chain, 'XendWallet.create');
    const channel = SecureChannel();
    final address = await channel.generateKeyPair(_defaultWalletId);
    await Xend.backend.registerWallet(address, label: label);
    return XendWallet._(_defaultWalletId, address, chain);
  }

  /// Loads the existing on-device wallet, or null if none has been created yet. This is
  /// the app-restart read path (P1 checkpoint: the address survives a restart).
  static Future<XendWallet?> load({Chain chain = Chain.solana}) async {
    _requireSolana(chain, 'XendWallet.load');
    const channel = SecureChannel();
    final address = await channel.getPublicKeyOrNull(_defaultWalletId);
    if (address == null) return null;
    return XendWallet._(_defaultWalletId, address, chain);
  }

  /// Restores a wallet from a seed phrase. The recovery path for a re-enrolled
  /// biometric (D3). Needs BIP39 → Ed25519 derivation in the native vault — Phase 2.
  static Future<XendWallet> restore(
    String mnemonic, {
    Chain chain = Chain.solana,
  }) {
    _requireSolana(chain, 'XendWallet.restore');
    throw const NotImplementedYet('XendWallet.restore'); // Phase 2
  }

  /// Wipes this wallet's key material from the native vault.
  Future<void> delete() => const SecureChannel().deleteKey(_walletId);

  // ── Identity & balance ───────────────────────────────────────────────────

  /// Balance of [asset] (defaults to the chain's native asset). Served by the backend
  /// over RPC — the device never hits a node directly.
  Future<Balance> balance({Asset? asset}) {
    throw const NotImplementedYet('XendWallet.balance'); // Phase 2
  }

  // ── Money movement ─────────────────────────────────────────────────────────

  /// The headline call. Build → Face ID sign on device → backend broadcasts → confirm.
  /// Returns a [TxHandle] quickly; [watch] it to observe confirmation.
  ///
  /// Throws [InsufficientFunds] / [InvalidRecipient] (terminal), [UserCancelledAuth],
  /// [BlockhashExpired] (may auto-handle, D7), [NetworkError] / [RateLimited] (retryable).
  Future<TxHandle> send({
    required String to,
    required BigInt amount, // base units, never a double
    Asset? asset, // defaults to native asset of [chain]
    String? idempotencyKey, // auto-generated if omitted
    TxCommitment successAt = TxCommitment.confirmed, // D6
  }) {
    throw const NotImplementedYet('XendWallet.send'); // Phase 2
  }

  /// Where to receive. Returns [address]; incoming funds appear via
  /// reconcile-on-foreground (docs §9), so no socket must be held while closed.
  String receive() => address;

  // ── Money movement · roadmap verbs (stable signatures, no impl) ────────────

  /// Swap one asset for another. **v2.0** — throws [NotImplementedYet] today.
  Future<TxHandle> swap({
    required Asset from,
    required Asset to,
    required BigInt amount,
    double? maxSlippage,
  }) {
    throw const NotImplementedYet('XendWallet.swap');
  }

  /// Bridge an asset across chains. **v2.0** — throws [NotImplementedYet] today.
  Future<TxHandle> bridge({
    required Asset asset,
    required BigInt amount,
    required Chain toChain,
    required String toAddress,
  }) {
    throw const NotImplementedYet('XendWallet.bridge');
  }

  /// Sign an arbitrary message (behind Face ID). Native signing is Phase 2.
  Future<List<int>> sign(List<int> message, {required String reason}) {
    throw const NotImplementedYet('XendWallet.sign'); // Phase 2
  }

  // ── Observation ────────────────────────────────────────────────────────────

  /// Live status for a transaction: emits pending → confirmed → finalized (or failed).
  /// Backed by backend WSS fan-out, not polling. Every event is idempotent and
  /// state-setting, so reconnects are safe.
  Stream<TxStatus> watch(TxHandle handle) {
    throw const NotImplementedYet('XendWallet.watch'); // Phase 5
  }

  /// Paginated history from the backend index.
  Future<List<TxRecord>> history({int limit = 20, String? before}) {
    throw const NotImplementedYet('XendWallet.history'); // Phase 2/3
  }

  // ── internal ───────────────────────────────────────────────────────────────

  static void _requireSolana(Chain chain, String call) {
    if (chain != Chain.solana) {
      throw NotImplementedYet('$call on ${chain.name} (v0.1 is Solana-only)');
    }
  }
}
