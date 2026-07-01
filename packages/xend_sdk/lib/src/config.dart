import 'backend_client.dart';

/// Configuration for the SDK. Set once at startup, Firebase-style:
/// ```dart
/// Xend.configure(const XendConfig(backendUrl: 'http://localhost:8080'));
/// ```
class XendConfig {
  const XendConfig({required this.backendUrl});

  /// Base URL of the Xend backend. iOS simulator can reach the host via `localhost`;
  /// a physical device must use your machine's LAN IP.
  final String backendUrl;
}

/// The SDK's global entry point. Holds configuration and shared clients so the rest of
/// the public API (`XendWallet.create`, …) reads clean and argument-light.
class Xend {
  Xend._();

  static XendConfig? _config;
  static BackendClient? _backend;

  static void configure(XendConfig config) {
    _config = config;
    _backend = BackendClient(baseUrl: config.backendUrl);
  }

  static XendConfig get config =>
      _config ?? (throw StateError('Call Xend.configure(XendConfig(...)) before using Xend.'));

  static BackendClient get backend =>
      _backend ?? (throw StateError('Call Xend.configure(XendConfig(...)) before using Xend.'));
}
