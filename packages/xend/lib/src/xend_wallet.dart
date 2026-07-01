import 'dart:async';

import 'config.dart';
import 'errors.dart';
import 'models.dart';
import 'secure_channel.dart';

/// A non-custodial wallet: an on-device key pair together with the operations to
/// observe and move the value it controls.
///
/// The private key is generated on the device's secure hardware and never leaves it.
/// Signing happens on-device behind biometric authentication; the Xend service only
/// ever handles public keys, unsigned transaction requests, and already-signed
/// transactions, and can never move funds on its own.
///
/// Obtain a wallet with [create] (a new key pair), [restore] (from a recovery phrase),
/// or [load] (an existing on-device wallet). Call [Xend.configure] once before any of
/// these.
///
/// Monetary amounts are always expressed in an asset's smallest indivisible unit as a
/// [BigInt]; formatting to a human-readable decimal is the caller's responsibility.
/// Operations accept a [Chain] and default to [Chain.solana]; other chains are not yet
/// supported and throw [NotImplementedYet].
///
/// ```dart
/// final wallet = await XendWallet.create(label: 'Main');
/// print(wallet.address);
/// ```
class XendWallet {
  XendWallet._(this._walletId, this.address, this.chain);

  /// Opaque handle used to reference this wallet's key within the device's secure
  /// store. It is never the key material itself.
  ///
  /// This release manages a single wallet, stored under a fixed identifier so it can be
  /// reloaded after the app restarts. Support for multiple concurrent wallets is
  /// planned.
  static const String _defaultWalletId = 'default';

  final String _walletId;

  /// The wallet's public address (base58-encoded on Solana).
  final String address;

  /// The blockchain this wallet operates on. Always [Chain.solana] in this release.
  final Chain chain;

  /// Creates a new wallet with a freshly generated key pair.
  ///
  /// The key pair is generated inside the device's secure hardware; only the public
  /// [address] is returned. The public key is registered with the configured Xend
  /// backend so that balances and history can be served.
  ///
  /// [label] is an optional human-readable name for the wallet. [chain] selects the
  /// target blockchain and defaults to [Chain.solana].
  ///
  /// Throws [NetworkError] if the backend cannot be reached, or [NotImplementedYet] if
  /// a chain other than Solana is requested.
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

  /// Loads the wallet already stored on this device, or `null` if none exists.
  ///
  /// Typically called on startup to restore a previously created wallet. No network
  /// request is made and the key never leaves the device.
  static Future<XendWallet?> load({Chain chain = Chain.solana}) async {
    _requireSolana(chain, 'XendWallet.load');
    const channel = SecureChannel();
    final address = await channel.getPublicKeyOrNull(_defaultWalletId);
    if (address == null) return null;
    return XendWallet._(_defaultWalletId, address, chain);
  }

  /// Restores a wallet from its recovery phrase.
  ///
  /// Not yet available in this release; currently throws [NotImplementedYet].
  static Future<XendWallet> restore(
    String mnemonic, {
    Chain chain = Chain.solana,
  }) {
    _requireSolana(chain, 'XendWallet.restore');
    throw const NotImplementedYet('XendWallet.restore');
  }

  /// Permanently removes this wallet's key material from the device's secure store.
  ///
  /// This is irreversible: without the recovery phrase, the wallet cannot be recovered.
  Future<void> delete() => const SecureChannel().deleteKey(_walletId);

  /// Returns the balance of [asset], or the chain's native asset when [asset] is
  /// omitted. The value is expressed in the asset's smallest indivisible unit.
  ///
  /// Not yet available in this release; currently throws [NotImplementedYet].
  Future<Balance> balance({Asset? asset}) {
    throw const NotImplementedYet('XendWallet.balance');
  }

  /// Sends [amount] of [asset] to the address [to].
  ///
  /// The transaction is built by the Xend backend, signed on this device behind
  /// biometric authentication, and then broadcast. The method returns as soon as the
  /// transaction is submitted, yielding a [TxHandle]; use [watch] to observe
  /// confirmation. It intentionally does not wait for final confirmation.
  ///
  /// [amount] is expressed in the asset's smallest indivisible unit (for example,
  /// lamports for SOL). [asset] defaults to the native asset of [chain]. Supply
  /// [idempotencyKey] to make a retry safe; if omitted, one is generated per call.
  /// [successAt] selects the commitment level at which the transaction is considered
  /// successful.
  ///
  /// Throws:
  ///  * [InsufficientFunds] if the balance cannot cover the amount and fees.
  ///  * [InvalidRecipient] if [to] is not valid for [chain].
  ///  * [UserCancelledAuth] if biometric authentication is dismissed.
  ///  * [NetworkError] or [RateLimited] for transient failures that may be retried.
  ///
  /// Not yet available in this release; currently throws [NotImplementedYet].
  ///
  /// ```dart
  /// final tx = await wallet.send(to: recipient, amount: BigInt.from(1000000));
  /// await for (final status in wallet.watch(tx)) {
  ///   if (status.isTerminalSuccess) break;
  /// }
  /// ```
  Future<TxHandle> send({
    required String to,
    required BigInt amount,
    Asset? asset,
    String? idempotencyKey,
    TxCommitment successAt = TxCommitment.confirmed,
  }) {
    throw const NotImplementedYet('XendWallet.send');
  }

  /// Returns the address at which this wallet can receive funds.
  String receive() => address;

  /// Swaps [amount] of [from] into [to], optionally bounding slippage with
  /// [maxSlippage].
  ///
  /// Not yet available in this release; currently throws [NotImplementedYet].
  Future<TxHandle> swap({
    required Asset from,
    required Asset to,
    required BigInt amount,
    double? maxSlippage,
  }) {
    throw const NotImplementedYet('XendWallet.swap');
  }

  /// Bridges [amount] of [asset] to [toAddress] on [toChain].
  ///
  /// Not yet available in this release; currently throws [NotImplementedYet].
  Future<TxHandle> bridge({
    required Asset asset,
    required BigInt amount,
    required Chain toChain,
    required String toAddress,
  }) {
    throw const NotImplementedYet('XendWallet.bridge');
  }

  /// Signs an arbitrary [message] on-device behind biometric authentication.
  ///
  /// [reason] is shown to the user in the authentication prompt so they can confirm
  /// what they are approving.
  ///
  /// Not yet available in this release; currently throws [NotImplementedYet].
  Future<List<int>> sign(List<int> message, {required String reason}) {
    throw const NotImplementedYet('XendWallet.sign');
  }

  /// Returns a stream of [TxStatus] updates for the transaction identified by [handle].
  ///
  /// The stream reports state truthfully as the transaction progresses from pending to
  /// confirmed to finalized: a confirmed transaction is never reported as finalized.
  /// Updates are delivered as they occur rather than by polling.
  ///
  /// Not yet available in this release; currently throws [NotImplementedYet].
  Stream<TxStatus> watch(TxHandle handle) {
    throw const NotImplementedYet('XendWallet.watch');
  }

  /// Returns up to [limit] past transactions, most recent first. Pass [before] to page
  /// through older records.
  ///
  /// Not yet available in this release; currently throws [NotImplementedYet].
  Future<List<TxRecord>> history({int limit = 20, String? before}) {
    throw const NotImplementedYet('XendWallet.history');
  }

  static void _requireSolana(Chain chain, String call) {
    if (chain != Chain.solana) {
      throw NotImplementedYet('$call on ${chain.name}');
    }
  }
}
