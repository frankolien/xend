import 'backend_client.dart';

/// Configuration for the Xend SDK.
///
/// Create an instance and pass it to [Xend.configure] once during application startup,
/// before creating or loading a wallet.
class XendConfig {
  /// Creates a configuration targeting the Xend backend at [backendUrl].
  const XendConfig({required this.backendUrl});

  /// The base URL of the Xend backend, without a trailing slash.
  final String backendUrl;
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
    _backend = BackendClient(baseUrl: config.backendUrl);
  }

  /// The active configuration.
  ///
  /// Throws a [StateError] if [configure] has not been called.
  static XendConfig get config =>
      _config ?? (throw StateError('Xend.configure() must be called before use.'));

  /// The shared backend client. Intended for internal use within the SDK.
  static BackendClient get backend =>
      _backend ?? (throw StateError('Xend.configure() must be called before use.'));
}
