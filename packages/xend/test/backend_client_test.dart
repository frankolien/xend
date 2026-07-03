import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xend/src/backend_client.dart';
import 'package:xend/xend.dart';

/// A JSON response with the given [body] and [status].
http.Response _json(Object body, {int status = 200}) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

BackendClient _client(MockClientHandler handler) =>
    BackendClient(baseUrl: 'https://api.test', client: MockClient(handler));

void main() {
  group('BackendClient success paths', () {
    test('resolveName returns the address and hits GET /v1/resolve', () async {
      late http.Request captured;
      final client = _client((req) async {
        captured = req;
        return _json({'name': 'gift.sol', 'address': 'ADDR123'});
      });

      expect(await client.resolveName('gift.sol'), 'ADDR123');
      expect(captured.method, 'GET');
      expect(captured.url.path, '/v1/resolve');
      expect(captured.url.queryParameters['name'], 'gift.sol');
    });

    test('buildTransfer parses message, validUntil, and fee-payer signature',
        () async {
      final client = _client((req) async => _json({
            'message': 'BASE64MSG',
            'valid_until': 1234,
            'fee_payer_signature': 'FEESIG',
          }));

      final r = await client.buildTransfer(
          from: 'A', to: 'B', amount: BigInt.from(5));
      expect(r.message, 'BASE64MSG');
      expect(r.validUntil, 1234);
      expect(r.feePayerSignature, 'FEESIG');
    });

    test('buildTransfer leaves feePayerSignature null when unsponsored',
        () async {
      final client =
          _client((req) async => _json({'message': 'M', 'valid_until': 1}));
      final r =
          await client.buildTransfer(from: 'A', to: 'B', amount: BigInt.one);
      expect(r.feePayerSignature, isNull);
    });

    test(
        'buildTransfer sends amount as a base-unit string with no precision loss',
        () async {
      late Map<String, dynamic> sent;
      final client = _client((req) async {
        sent = jsonDecode(req.body) as Map<String, dynamic>;
        return _json({'message': 'M', 'valid_until': 1});
      });

      // u64 max — would lose precision as a double.
      final amount = BigInt.parse('18446744073709551615');
      await client.buildTransfer(
          from: 'A', to: 'B', amount: amount, mint: 'MINT');
      expect(sent['amount'], '18446744073709551615');
      expect(sent['mint'], 'MINT');
    });

    test('submitTransaction returns signature and status', () async {
      final client = _client(
        (req) async => _json({'signature': 'SIG', 'status': 'submitted'}),
      );
      final r =
          await client.submitTransaction(signed: 'S', idempotencyKey: 'K');
      expect(r.signature, 'SIG');
      expect(r.status, 'submitted');
    });

    test('getBalance parses the base-unit string into a BigInt', () async {
      final client = _client((req) async => _json({'amount': '9000000000'}));
      expect(await client.getBalance('A'), BigInt.from(9000000000));
    });
  });

  group('BackendClient error mapping', () {
    test('invalid_recipient -> InvalidRecipient', () {
      final client = _client((req) async => _json(
            {
              'error': {'code': 'invalid_recipient', 'message': 'nope'}
            },
            status: 422,
          ));
      expect(client.resolveName('nope.sol'), throwsA(isA<InvalidRecipient>()));
    });

    test('insufficient_funds -> InsufficientFunds', () {
      final client = _client((req) async => _json(
            {
              'error': {'code': 'insufficient_funds', 'message': 'low'}
            },
            status: 422,
          ));
      expect(
        client.submitTransaction(signed: 'S', idempotencyKey: 'K'),
        throwsA(isA<InsufficientFunds>()),
      );
    });

    test('rate_limited -> RateLimited with retry_after seconds', () {
      final client = _client((req) async => _json(
            {
              'error': {
                'code': 'rate_limited',
                'message': 'slow',
                'retry_after': 7
              }
            },
            status: 429,
          ));
      expect(
        client.getBalance('A'),
        throwsA(isA<RateLimited>().having(
          (e) => e.retryAfter,
          'retryAfter',
          const Duration(seconds: 7),
        )),
      );
    });

    test('unknown error code -> NetworkError', () {
      final client = _client(
        (req) async => _json({
          'error': {'code': 'weird'}
        }, status: 500),
      );
      expect(client.getBalance('A'), throwsA(isA<NetworkError>()));
    });

    test('transport failure -> NetworkError', () {
      final client = _client((req) async => throw http.ClientException('boom'));
      expect(client.getBalance('A'), throwsA(isA<NetworkError>()));
    });
  });
}
