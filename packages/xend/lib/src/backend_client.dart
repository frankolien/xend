import 'dart:convert';

import 'package:http/http.dart' as http;

import 'errors.dart';

/// HTTP client for the Xend backend. Translates backend error codes into typed
/// [XendError]s so callers can branch on the failure rather than parse strings.
class BackendClient {
  BackendClient({required this.baseUrl, this.apiKey, http.Client? client})
      : _client = client ?? http.Client();

  final String baseUrl;

  /// Optional API key sent as `Authorization: Bearer <key>` on every request.
  final String? apiKey;

  final http.Client _client;

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        if (apiKey != null) 'authorization': 'Bearer $apiKey',
      };

  /// `POST /v1/wallets` — register a public key; returns the backend wallet id.
  Future<String> registerWallet(String pubkey, {String? label}) async {
    final body = await _post('/v1/wallets', {
      'pubkey': pubkey,
      if (label != null) 'label': label,
    });
    return body['wallet_id'] as String;
  }

  /// `POST /v1/tx/build` — request an unsigned transfer for the device to sign.
  ///
  /// Returns the base64-encoded transaction [message] and the Unix second [validUntil]
  /// after which it must be rebuilt rather than broadcast. [feePayerSignature] is present
  /// only when the backend sponsors the fee (gasless): it is the fee payer's base64
  /// signature over [message], which the device assembles ahead of its own.
  Future<({String message, int validUntil, String? feePayerSignature})> buildTransfer({
    required String from,
    required String to,
    required BigInt amount,
    String? mint,
  }) async {
    final body = await _post('/v1/tx/build', {
      'from': from,
      'to': to,
      'amount': amount.toString(),
      if (mint != null) 'mint': mint,
    });
    return (
      message: body['message'] as String,
      validUntil: body['valid_until'] as int,
      feePayerSignature: body['fee_payer_signature'] as String?,
    );
  }

  /// `POST /v1/tx/submit` — broadcast a signed transaction.
  ///
  /// [signed] is the base64-encoded, fully-signed transaction. [idempotencyKey] makes a
  /// retry safe: submitting the same key twice returns the original signature instead of
  /// broadcasting again. The remaining fields are recorded for history. Returns the
  /// on-chain [signature] and its recorded [status].
  Future<({String signature, String status})> submitTransaction({
    required String signed,
    required String idempotencyKey,
    String? from,
    String? to,
    BigInt? amount,
    String? mint,
  }) async {
    final body = await _post('/v1/tx/submit', {
      'signed': signed,
      'idempotency_key': idempotencyKey,
      if (from != null) 'pubkey': from,
      if (to != null) 'to': to,
      if (amount != null) 'amount': amount.toString(),
      if (mint != null) 'mint': mint,
    });
    return (
      signature: body['signature'] as String,
      status: body['status'] as String,
    );
  }

  /// `GET /v1/wallets/:pubkey/balance` — the wallet's balance in base units.
  Future<BigInt> getBalance(String pubkey, {String? mint}) async {
    final query = mint != null ? '?mint=$mint' : '';
    final body = await _get('/v1/wallets/$pubkey/balance$query');
    return BigInt.parse(body['amount'] as String);
  }

  /// `GET /v1/wallets/:pubkey/transactions` — the wallet's transaction history, most
  /// recent first. Each element is the raw record JSON; the caller maps it to a model.
  Future<List<Map<String, dynamic>>> getHistory(
    String pubkey, {
    int limit = 20,
    String? before,
  }) async {
    final params = <String, String>{
      'limit': '$limit',
      if (before != null) 'before': before,
    };
    final query = Uri(queryParameters: params).query;
    final body = await _get('/v1/wallets/$pubkey/transactions?$query');
    final list = body['transactions'] as List<dynamic>;
    return list.cast<Map<String, dynamic>>();
  }

  /// `GET /v1/tx/:signature` — the transaction's current commitment, one of
  /// `processed`, `confirmed`, `finalized`, or `failed`.
  Future<String> getTransactionStatus(String signature) async {
    final body = await _get('/v1/tx/$signature');
    return body['status'] as String;
  }

  Future<Map<String, dynamic>> _get(String path) async {
    final http.Response resp;
    try {
      resp = await _client.get(
        Uri.parse('$baseUrl$path'),
        headers: _headers,
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

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> json) async {
    final http.Response resp;
    try {
      resp = await _client.post(
        Uri.parse('$baseUrl$path'),
        headers: _headers,
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
