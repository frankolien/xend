import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show PlatformException;

import 'config.dart';
import 'errors.dart';
import 'mappings.dart';
import 'models.dart';
import 'secure_channel.dart';
import 'wire.dart';

/// A non-custodial wallet: an on-device key pair plus the operations to observe and move
/// the value it controls.
///
/// The private key is generated in the device's secure hardware and stays there. Signing
/// happens on-device behind biometric authentication. The Xend service only handles
/// public keys, unsigned transaction requests, and signed transactions, and cannot move
/// funds on its own.
///
/// Obtain a wallet with [create] (a new key pair), [restore] (from a recovery phrase),
/// or [load] (an existing on-device wallet). Call [Xend.configure] once first.
///
/// Monetary amounts are always in an asset's smallest indivisible unit as a [BigInt];
/// formatting to a decimal is the caller's job. Operations take a [Chain] and default to
/// [Chain.solana]; other chains throw [NotImplementedYet].
///
/// ```dart
/// final wallet = await XendWallet.create(label: 'Main');
/// print(wallet.address);
/// ```
class XendWallet {
  XendWallet._(this._walletId, this.address, this.chain);

  /// Opaque handle for this wallet's key in the device's secure store. Never the key
  /// material itself.
  ///
  /// This release manages a single wallet under a fixed identifier so it can be reloaded
  /// after an app restart. Multiple concurrent wallets are planned.
  static const String _defaultWalletId = 'default';

  final String _walletId;

  /// The wallet's public address (base58-encoded on Solana).
  final String address;

  /// The blockchain this wallet operates on. Always [Chain.solana] in this release.
  final Chain chain;

  /// Creates a new wallet with a freshly generated key pair.
  ///
  /// The key pair is generated in the device's secure hardware; only the public [address]
  /// is returned. The public key is registered with the configured backend to serve
  /// balances and history.
  ///
  /// [label] is an optional name for the wallet. [chain] selects the target blockchain
  /// and defaults to [Chain.solana].
  ///
  /// Throws [NetworkError] if the backend is unreachable, or [NotImplementedYet] for a
  /// chain other than Solana.
  static Future<XendWallet> create({
    String? label,
    Chain chain = Chain.solana,
  }) async {
    _requireSolana(chain, 'XendWallet.create');
    const channel = SecureChannel();
    final String address;
    try {
      // The recovery phrase is generated and stored on-device but not returned here, so
      // onboarding stays silent (embedded-wallet style). Retrieve it later via
      // [revealRecoveryPhrase] if the user asks.
      address = (await channel.generateKeyPair(_defaultWalletId)).address;
    } on PlatformException catch (e) {
      throw mapNativeError(e);
    }
    await Xend.backend.registerWallet(address, label: label);
    return XendWallet._(_defaultWalletId, address, chain);
  }

  /// Loads the wallet for this user, or `null` if there is none.
  ///
  /// Usually called on startup. An existing on-device wallet is returned immediately, with
  /// no network request. On a fresh device where the user set up a wallet elsewhere, the
  /// recovery seed syncs in through iCloud Keychain and the signing key is rebuilt from it,
  /// with no recovery phrase to enter. In that recovery case only, the address is
  /// re-registered with the backend (idempotently) so balances and history resolve on the
  /// new device.
  static Future<XendWallet?> load({Chain chain = Chain.solana}) async {
    _requireSolana(chain, 'XendWallet.load');
    const channel = SecureChannel();
    final ({String address, bool recovered})? result;
    try {
      result = await channel.loadOrRecover(_defaultWalletId);
    } on PlatformException catch (e) {
      throw mapNativeError(e);
    }
    if (result == null) return null;
    if (result.recovered) {
      await Xend.backend.registerWallet(result.address);
    }
    return XendWallet._(_defaultWalletId, result.address, chain);
  }

  /// Restores a wallet from its BIP-39 recovery phrase, re-deriving the same key on-device
  /// and registering its address. Use this to move a wallet to a new device.
  ///
  /// Throws [InvalidRecoveryPhrase] if [mnemonic] is not valid BIP-39.
  static Future<XendWallet> restore(
    String mnemonic, {
    Chain chain = Chain.solana,
  }) async {
    _requireSolana(chain, 'XendWallet.restore');
    const channel = SecureChannel();
    final String address;
    try {
      address = await channel.restore(_defaultWalletId, mnemonic.trim());
    } on PlatformException catch (e) {
      throw mapNativeError(e);
    }
    await Xend.backend.registerWallet(address);
    return XendWallet._(_defaultWalletId, address, chain);
  }

  /// Reveals this wallet's recovery phrase behind biometric authentication so the user can
  /// back it up after creation. The returned phrase is sensitive: display it, let the user
  /// record it, then discard it. Never persist or transmit it.
  ///
  /// [reason] is shown in the authentication prompt. Throws [UserCancelledAuth] if the
  /// prompt is dismissed.
  Future<String> revealRecoveryPhrase({
    String reason = 'Reveal your recovery phrase',
  }) async {
    _requireSolana(chain, 'XendWallet.revealRecoveryPhrase');
    try {
      return await const SecureChannel().revealMnemonic(_walletId, reason);
    } on PlatformException catch (e) {
      throw mapNativeError(e);
    }
  }

  /// Permanently removes this wallet's key material from the device's secure store.
  ///
  /// This is irreversible: without the recovery phrase, the wallet cannot be recovered.
  Future<void> delete() => const SecureChannel().deleteKey(_walletId);

  /// Returns the balance of [asset], or the chain's native asset when [asset] is omitted,
  /// in the asset's smallest indivisible unit.
  ///
  /// Pass a token [asset] (one with a `mint`) to read an SPL token balance, such as USDC.
  Future<Balance> balance({Asset? asset}) async {
    _requireSolana(chain, 'XendWallet.balance');
    final amount = await Xend.backend.getBalance(address, mint: asset?.mint);
    return Balance(asset: asset ?? Asset.native(chain), amount: amount);
  }

  /// Sends [amount] of [asset] to [to], which may be an address or a `.sol` name (such as
  /// `gift.sol`) that is resolved automatically.
  ///
  /// The transaction is built by the backend, signed on-device behind biometric
  /// authentication, then broadcast. Returns a [TxHandle] as soon as the transaction is
  /// submitted, without waiting for confirmation; use [watch] to observe it.
  ///
  /// [amount] is in the asset's smallest indivisible unit (lamports for SOL). [asset]
  /// defaults to the native asset of [chain]. Supply [idempotencyKey] to make a retry
  /// safe; if omitted, one is generated per call. [successAt] selects the commitment level
  /// at which [watch] reports success.
  ///
  /// In this release the handle's id is the on-chain signature, which can be looked up on
  /// a block explorer. Pass a token [asset] (one with a `mint`) to send an SPL token such
  /// as USDC; the recipient's token account is created automatically if needed.
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
    if (amount <= BigInt.zero) {
      throw ArgumentError.value(amount, 'amount', 'must be greater than zero');
    }
    final mint = asset?.mint;

    // Resolve a `.sol` name to its address up front, so building, signing, and the
    // recorded recipient all use the same address. A plain address passes through.
    final recipient = await resolveName(to);

    // 1. The backend assembles the unsigned transfer, including the recent blockhash the
    //    device must not compute itself. For sponsored fees it also returns the fee
    //    payer's signature, so the user can send holding no SOL.
    final built = await Xend.backend.buildTransfer(
      from: address,
      to: recipient,
      amount: amount,
      mint: mint,
    );
    final message = base64Decode(built.message);

    // 2. Sign on-device behind biometric authentication. The private key stays in secure
    //    hardware; only the 64-byte signature is returned.
    final Uint8List signature;
    try {
      signature = await const SecureChannel().signMessage(
        _walletId,
        message,
        'Approve sending to $to',
      );
    } on PlatformException catch (e) {
      throw mapNativeError(e);
    }

    // 3. Assemble the signed transaction in wire format and broadcast it. A sponsored
    //    transfer carries the fee payer's signature ahead of the sender's, in signer
    //    order; an unsponsored one carries the sender's alone. The idempotency key makes
    //    the whole build-sign-submit round trip safe to retry.
    final feePayerSignature = built.feePayerSignature;
    final signatures = <Uint8List>[
      if (feePayerSignature != null) base64Decode(feePayerSignature),
      signature,
    ];
    final signed = assembleSignedTransaction(signatures, message);
    final result = await Xend.backend.submitTransaction(
      signed: base64Encode(signed),
      idempotencyKey: idempotencyKey ?? newIdempotencyKey(),
      from: address,
      to: recipient,
      amount: amount,
      mint: mint,
    );

    return TxHandle(result.signature);
  }

  /// Returns the address at which this wallet can receive funds.
  String receive() => address;

  /// Resolves a name to an address, for displaying or validating a destination before
  /// sending. Solana `.sol` domains (such as `gift.sol`) resolve through the Solana Name
  /// Service; a value that is already an address is returned unchanged.
  ///
  /// [send] resolves automatically, so call this first only to show the resolved address.
  /// Throws [InvalidRecipient] if the name is not registered.
  static Future<String> resolveName(String nameOrAddress) async {
    if (!isSolName(nameOrAddress)) return nameOrAddress;
    return Xend.backend.resolveName(nameOrAddress);
  }

  /// Swaps [amount] of [from] into [to], optionally bounding slippage with [maxSlippage].
  ///
  /// Not yet available; throws [NotImplementedYet].
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
  /// Not yet available; throws [NotImplementedYet].
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
  /// [reason] is shown in the authentication prompt so the user can confirm what they are
  /// approving. Useful for wallet-based sign-in and message signing, where the caller
  /// needs a signature without moving funds.
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
      throw mapNativeError(e);
    }
  }

  /// Emits a [TxStatus] each time the transaction's commitment advances (processed →
  /// confirmed → finalized) or it fails, once per change. Completes on finalized/failed or
  /// after [timeout].
  ///
  /// This release polls the backend every [pollInterval]; a push-based (WebSocket) stream
  /// is planned. Cancel the subscription to stop watching early, for example once the
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
      final status = txStatusFromBackend(handle, raw);

      // Emit on the first observation and whenever the commitment advances, so a listener
      // sees each transition once rather than a status per poll.
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

  /// Returns up to [limit] past transactions, most recent first. Pass [before] (an RFC3339
  /// timestamp, such as the [TxRecord.createdAt] of the last row seen) to page through
  /// older records.
  Future<List<TxRecord>> history({int limit = 20, String? before}) async {
    _requireSolana(chain, 'XendWallet.history');
    final raw =
        await Xend.backend.getHistory(address, limit: limit, before: before);
    return raw.map((json) => txRecordFromJson(json, chain)).toList();
  }

  static void _requireSolana(Chain chain, String call) {
    if (chain != Chain.solana) {
      throw NotImplementedYet('$call on ${chain.name}');
    }
  }
}
