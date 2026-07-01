import 'package:flutter/services.dart'; // re-exports Uint8List

/// The private bridge between Dart and the native signer, over the `ai.xend/secure`
/// method channel. It passes wallet identifiers and byte payloads only, never key
/// material. Internal to the SDK.
class SecureChannel {
  const SecureChannel();

  static const MethodChannel _channel = MethodChannel('ai.xend/secure');

  Future<String> generateKeyPair(String walletId) async {
    final pubkey = await _channel.invokeMethod<String>(
      'generateKeyPair',
      {'walletId': walletId},
    );
    return pubkey!;
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
