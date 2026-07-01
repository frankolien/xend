import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';

/// Talks HTTP(S) to the Xend backend. Maps backend error `code`s — which line up 1:1
/// with the Rust `AppError` variants — to typed [XendError]s, so callers can `switch`
/// on failures instead of parsing strings.
class BackendClient {
  BackendClient({required this.baseUrl, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;
  final http.Client _client;

  /// `POST /v1/wallets` — register a pubkey; returns the backend wallet id.
  Future<String> registerWallet(String pubkey, {String? label}) async {
    final body = await _post('/v1/wallets', {
      'pubkey': pubkey,
      if (label != null) 'label': label,
    });
    return body['wallet_id'] as String;
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> json) async {
    final http.Response resp;
    try {
      resp = await _client.post(
        Uri.parse('$baseUrl$path'),
        headers: const {'content-type': 'application/json'},
        body: jsonEncode(json),
      );
    } on Exception {
      throw const NetworkError();
    }

    final decoded = resp.body.isEmpty
        ? const <String, dynamic>{}
        : jsonDecode(resp.body) as Map<String, dynamic>;

    if (resp.statusCode >= 400) throw _mapError(resp.statusCode, decoded);
    return decoded;
  }

  XendError _mapError(int status, Map<String, dynamic> body) {
    final error = body['error'];
    final code = error is Map ? error['code'] as String? : null;
    final message = error is Map ? (error['message']?.toString() ?? '') : '';
    switch (code) {
      case 'insufficient_funds':
        return const InsufficientFunds();
      case 'invalid_recipient':
        return const InvalidRecipient();
      case 'blockhash_expired':
        return const BlockhashExpired();
      case 'chain_rejected':
        return ChainRejected(message);
      case 'rate_limited':
        final secs = (error is Map ? error['retry_after'] as int? : null) ?? 1;
        return RateLimited(Duration(seconds: secs));
      default:
        return NetworkError('backend error ($status): $message');
    }
  }
}
