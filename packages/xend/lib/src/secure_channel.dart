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

  /// Returns the stored base58 address, or null if this wallet has no key yet. Used by
  /// the app-restart read path.
  Future<String?> getPublicKeyOrNull(String walletId) async {
    try {
      return await _channel.invokeMethod<String>('getPublicKey', {'walletId': walletId});
    } on PlatformException catch (e) {
      if (e.code == 'key_not_found') return null;
      rethrow;
    }
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
