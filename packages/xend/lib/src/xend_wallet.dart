import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;

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
    final String address;
    try {
      address = await channel.generateKeyPair(_defaultWalletId);
    } on PlatformException catch (e) {
      throw _mapNativeError(e);
    }
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
  /// Only native SOL is supported in this release; passing a token [asset] throws
  /// [NotImplementedYet].
  Future<Balance> balance({Asset? asset}) async {
    _requireSolana(chain, 'XendWallet.balance');
    if (asset?.mint != null) {
      throw const NotImplementedYet('SPL token balances');
    }
    final amount = await Xend.backend.getBalance(address, mint: asset?.mint);
    return Balance(asset: asset ?? Asset.native(chain), amount: amount);
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
  /// [successAt] selects the commitment level at which [watch] reports success.
  ///
  /// In this release the returned handle's id is the on-chain transaction signature,
  /// which can be looked up on a block explorer. Only native SOL transfers are
  /// supported; passing a token [asset] throws [NotImplementedYet].
  ///
  /// Throws:
  ///  * [InsufficientFunds] if the balance cannot cover the amount and fees.
  ///  * [InvalidRecipient] if [to] is not valid for [chain].
  ///  * [UserCancelledAuth] if biometric authentication is dismissed.
  ///  * [BlockhashExpired] if the validity window elapsed before broadcast.
  ///  * [ChainRejected] if the network rejected the transaction.
  ///  * [NetworkError] or [RateLimited] for transient failures that may be retried.
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
  }) async {
    _requireSolana(chain, 'XendWallet.send');
    if (asset?.mint != null) {
      throw const NotImplementedYet('SPL token transfers');
    }
    if (amount <= BigInt.zero) {
      throw ArgumentError.value(amount, 'amount', 'must be greater than zero');
    }

    // 1. The backend assembles the unsigned transfer, fetching the recent blockhash the
    //    device must not compute for itself.
    final built = await Xend.backend.buildTransfer(
      from: address,
      to: to,
      amount: amount,
    );
    final message = base64Decode(built.message);

    // 2. Sign on-device behind biometric authentication. The private key never leaves the
    //    device's secure hardware; only the 64-byte signature is returned.
    final Uint8List signature;
    try {
      signature = await const SecureChannel().signMessage(
        _walletId,
        message,
        'Approve sending to $to',
      );
    } on PlatformException catch (e) {
      throw _mapNativeError(e);
    }

    // 3. Assemble the signed transaction in wire format and broadcast it. The idempotency
    //    key makes the whole build-sign-submit round trip safe to retry.
    final signed = _assembleSignedTransaction(signature, message);
    final result = await Xend.backend.submitTransaction(
      signed: base64Encode(signed),
      idempotencyKey: idempotencyKey ?? _newIdempotencyKey(),
      from: address,
      to: to,
      amount: amount,
    );

    return TxHandle(result.signature);
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

  /// Signs an arbitrary [message] on-device behind biometric authentication and returns
  /// the 64-byte Ed25519 signature.
  ///
  /// [reason] is shown to the user in the authentication prompt so they can confirm what
  /// they are approving. Useful for wallet-based sign-in and message signing, where the
  /// caller needs a signature without moving funds.
  ///
  /// Throws [UserCancelledAuth] if the biometric prompt is dismissed.
  Future<List<int>> sign(List<int> message, {required String reason}) async {
    _requireSolana(chain, 'XendWallet.sign');
    try {
      return await const SecureChannel().signMessage(
        _walletId,
        Uint8List.fromList(message),
        reason,
      );
    } on PlatformException catch (e) {
      throw _mapNativeError(e);
    }
  }

  /// Returns a stream of [TxStatus] updates for the transaction identified by [handle],
  /// reporting its progress truthfully as it advances from pending to confirmed to
  /// finalized — a confirmed transaction is never reported as finalized. The stream emits
  /// once per commitment change and completes when the transaction is finalized or fails,
  /// or after [timeout] elapses.
  ///
  /// This release polls the backend every [pollInterval]; a push-based (WebSocket) stream
  /// is planned. Cancel the subscription to stop watching early — for example, once the
  /// commitment your app treats as success is reached.
  ///
  /// ```dart
  /// await for (final status in wallet.watch(tx)) {
  ///   if (status.commitment == TxCommitment.confirmed) break;
  /// }
  /// ```
  Stream<TxStatus> watch(
    TxHandle handle, {
    Duration pollInterval = const Duration(seconds: 2),
    Duration timeout = const Duration(seconds: 90),
  }) async* {
    _requireSolana(chain, 'XendWallet.watch');
    final deadline = DateTime.now().add(timeout);
    TxCommitment? lastEmitted;
    var hasEmitted = false;

    while (true) {
      final raw = await Xend.backend.getTransactionStatus(handle.id);
      final status = _statusFromBackend(handle, raw);

      // Emit on the first observation and whenever the commitment advances, so a listener
      // sees each transition once rather than a status on every poll.
      if (!hasEmitted || status.commitment != lastEmitted || status.isFailed) {
        yield status;
        hasEmitted = true;
        lastEmitted = status.commitment;
      }

      if (status.isFailed || status.state == 'finalized') return;
      if (DateTime.now().isAfter(deadline)) return;
      await Future<void>.delayed(pollInterval);
    }
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

/// Assembles a signed Solana transaction in wire format: the compact-u16 signature count
/// (the byte `0x01` for a single signer), the 64-byte signature, then the serialized
/// message. This is the exact byte layout the backend parses back before broadcasting.
Uint8List _assembleSignedTransaction(Uint8List signature, Uint8List message) {
  final builder = BytesBuilder();
  builder.addByte(0x01);
  builder.add(signature);
  builder.add(message);
  return builder.toBytes();
}

/// Generates a random 128-bit idempotency key as lowercase hex. A distinct key per call
/// keeps sends independent, while a caller who wants retry safety can supply their own.
String _newIdempotencyKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Translates a backend commitment string (`processed` | `confirmed` | `finalized` |
/// `failed`) into a [TxStatus] for the transaction identified by [handle].
TxStatus _statusFromBackend(TxHandle handle, String raw) {
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

/// Maps a native secure-element failure into a typed [XendError]. A cancelled biometric
/// prompt is the case callers routinely branch on; other device failures surface as a
/// retryable [NetworkError], since they mean the operation did not complete.
XendError _mapNativeError(PlatformException e) {
  switch (e.code) {
    case 'user_cancelled_auth':
      return const UserCancelledAuth();
    case 'biometrics_unavailable':
      return const NetworkError('Biometric authentication is unavailable on this device');
    default:
      return NetworkError('secure element error: ${e.message ?? e.code}');
  }
}
