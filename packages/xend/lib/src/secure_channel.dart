import 'package:flutter/services.dart'; // re-exports Uint8List

/// The private bridge between Dart and the native signer, over the `ai.xend/secure`
/// method channel. It passes wallet identifiers and byte payloads only, never key
/// material. Internal to the SDK.
class SecureChannel {
  const SecureChannel();

  static const MethodChannel _channel = MethodChannel('ai.xend/secure');

  /// Generates a new key pair and its recovery phrase on-device. Returns the base58
  /// [address] and the BIP-39 [mnemonic] (shown once for the user to back up).
  Future<({String address, String mnemonic})> generateKeyPair(String walletId) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'generateKeyPair',
      {'walletId': walletId},
    );
    return (
      address: result!['address'] as String,
      mnemonic: result['mnemonic'] as String,
    );
  }

  /// Restores a wallet from its recovery phrase on-device, returning the base58 address.
  Future<String> restore(String walletId, String mnemonic) async {
    final address = await _channel.invokeMethod<String>(
      'restore',
      {'walletId': walletId, 'mnemonic': mnemonic},
    );
    return address!;
  }

  /// Reveals the stored recovery phrase behind biometric authentication.
  Future<String> revealMnemonic(String walletId, String reason) async {
    final mnemonic = await _channel.invokeMethod<String>(
      'revealMnemonic',
      {'walletId': walletId, 'reason': reason},
    );
    return mnemonic!;
  }

  /// Loads the wallet already on this device, or silently recovers one whose seed synced
  /// in from another device via iCloud Keychain, rebuilding the local signing key. Returns
  /// the base58 [address] and whether recovery had to run ([recovered]); returns null when
  /// this is a genuinely new install with nothing to load.
  Future<({String address, bool recovered})?> loadOrRecover(String walletId) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'loadOrRecover',
      {'walletId': walletId},
    );
    if (result == null) return null;
    return (
      address: result['address'] as String,
      recovered: (result['recovered'] as bool?) ?? false,
    );
  }

  Future<Uint8List> signMessage(String walletId, Uint8List bytes, String reason) async {
    final sig = await _channel.invokeMethod<Uint8List>('signMessage', {
      'walletId': walletId,
      'bytes': bytes,
      'reason': reason,
    });
    return sig!;
  }

  Future<void> deleteKey(String walletId) =>
      _channel.invokeMethod<void>('deleteKey', {'walletId': walletId});
}
