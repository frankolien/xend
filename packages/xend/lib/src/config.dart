import 'backend_client.dart';

/// Configuration for the Xend SDK.
///
/// Pass an instance to [Xend.configure] once at startup, before creating or loading a
/// wallet.
class XendConfig {
  /// Creates a configuration targeting the Xend backend at [backendUrl].
  const XendConfig({required this.backendUrl, this.apiKey});

  /// The base URL of the Xend backend, without a trailing slash.
  final String backendUrl;

  /// Optional API key, sent as `Authorization: Bearer <key>` on every request. Required
  /// when the backend has authentication enabled; omit it against a dev backend with auth
  /// disabled.
  final String? apiKey;
}

/// The entry point to the Xend SDK.
///
/// Call [configure] exactly once, before using any wallet:
///
/// ```dart
/// void main() {
///   Xend.configure(const XendConfig(backendUrl: 'https://api.example.com'));
///   runApp(const MyApp());
/// }
/// ```
class Xend {
  Xend._();

  static XendConfig? _config;
  static BackendClient? _backend;

  /// Initializes the SDK with [config]. Must be called before any other Xend API.
  static void configure(XendConfig config) {
    _config = config;
    _backend = BackendClient(baseUrl: config.backendUrl, apiKey: config.apiKey);
  }

  /// The active configuration.
  ///
  /// Throws a [StateError] if [configure] has not been called.
  static XendConfig get config =>
      _config ??
      (throw StateError('Xend.configure() must be called before use.'));

  /// The shared backend client. For internal SDK use.
  static BackendClient get backend =>
      _backend ??
      (throw StateError('Xend.configure() must be called before use.'));
}
