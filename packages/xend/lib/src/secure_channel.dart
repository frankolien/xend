import 'package:flutter/services.dart'; // re-exports Uint8List

/// Bridge between Dart and the native signer, over the `ai.xend/secure` method channel.
/// Passes wallet identifiers and byte payloads only, never key material. Internal to the
/// SDK.
class SecureChannel {
  const SecureChannel();

  static const MethodChannel _channel = MethodChannel('ai.xend/secure');

  /// Generates a new key pair on-device and returns its base58 [address]. The recovery
  /// phrase stays on the device; read it with [revealMnemonic].
  Future<({String address})> generateKeyPair(String walletId) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'generateKeyPair',
      {'walletId': walletId},
    );
    return (address: result!['address'] as String);
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

  /// Loads the wallet already on this device, or recovers one whose seed synced in from
  /// another device via iCloud Keychain, rebuilding the local signing key. Returns the
  /// base58 [address] and whether recovery ran ([recovered]); returns null on a new
  /// install with nothing to load.
  Future<({String address, bool recovered})?> loadOrRecover(
      String walletId) async {
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

  Future<Uint8List> signMessage(
      String walletId, Uint8List bytes, String reason) async {
    final sig = await _channel.invokeMethod<Uint8List>('signMessage', {
      'walletId': walletId,
      'bytes': bytes,
      'reason': reason,
    });
    return sig!;
  }

  /// Deletes the wallet's key from this device. With [wipeBackup], also deletes the
  /// synced recovery seed, which removes the wallet from every device.
  Future<void> deleteKey(String walletId, {bool wipeBackup = false}) =>
      _channel.invokeMethod<void>(
        'deleteKey',
        {'walletId': walletId, 'wipeBackup': wipeBackup},
      );
}
