import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xend/xend.dart';

import 'support/vectors.dart';

const _channel = MethodChannel('ai.xend/secure');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> nativeCalls;
  late List<Map<String, dynamic>> submits;
  late String buildMessage;
  String? feePayerSignature;
  PlatformException? signError;

  setUp(() {
    nativeCalls = [];
    submits = [];
    buildMessage = base64Encode(hex(rustNative));
    feePayerSignature = null;
    signError = null;

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      nativeCalls.add(call);
      switch (call.method) {
        case 'generateKeyPair':
          // No mnemonic over the channel any more.
          return {'address': user};
        case 'signMessage':
          if (signError != null) throw signError!;
          return Uint8List.fromList(List.filled(64, 0xAB));
        case 'deleteKey':
          return null;
      }
      throw MissingPluginException(call.method);
    });

    final mock = MockClient((req) async {
      final path = req.url.path;
      Map<String, dynamic> body() => jsonDecode(req.body);
      if (path == '/v1/wallets') {
        return http.Response(jsonEncode({'wallet_id': 'w1'}), 200);
      }
      if (path == '/v1/tx/build') {
        return http.Response(
          jsonEncode({
            'message': buildMessage,
            'valid_until': 0,
            if (feePayerSignature != null)
              'fee_payer_signature': feePayerSignature,
          }),
          200,
        );
      }
      if (path == '/v1/tx/submit') {
        submits.add(body());
        return http.Response(
            jsonEncode({'signature': 'SIG', 'status': 'submitted'}), 200);
      }
      return http.Response('{}', 404);
    });
    http.runWithClient(
      () => Xend.configure(const XendConfig(backendUrl: 'https://api.test')),
      () => mock,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  bool signed() => nativeCalls.any((c) => c.method == 'signMessage');

  test('create reads only the address from generateKeyPair', () async {
    final wallet = await XendWallet.create();
    expect(wallet.address, user);
  });

  group('send', () {
    test('verifies, previews, signs, and submits under the given key',
        () async {
      final wallet = await XendWallet.create();
      TransferPreview? seen;
      final handle = await wallet.send(
        to: recipient,
        amount: BigInt.from(1000000),
        idempotencyKey: 'intent-1',
        confirm: (p) async {
          seen = p;
          expect(signed(), isFalse, reason: 'confirm runs before signing');
          return true;
        },
      );
      expect(handle.id, 'SIG');
      expect(seen!.recipient, recipient);
      expect(seen!.amount, BigInt.from(1000000));
      expect(seen!.mint, isNull);
      expect(seen!.sponsored, isFalse);
      expect(seen!.recipientName, isNull);
      expect(signed(), isTrue);
      expect(submits.single['idempotency_key'], 'intent-1');
    });

    test('retries of one intent reuse the caller key', () async {
      final wallet = await XendWallet.create();
      for (var i = 0; i < 2; i++) {
        await wallet.send(
          to: recipient,
          amount: BigInt.from(1000000),
          idempotencyKey: 'same',
        );
      }
      expect(submits.map((s) => s['idempotency_key']), ['same', 'same']);
    });

    test('generates a fresh key when none is given', () async {
      final wallet = await XendWallet.create();
      await wallet.send(to: recipient, amount: BigInt.from(1000000));
      await wallet.send(to: recipient, amount: BigInt.from(1000000));
      final keys = submits.map((s) => s['idempotency_key'] as String).toList();
      expect(keys[0], matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(keys[0], isNot(keys[1]));
    });

    test('a tampered transaction is never signed or submitted', () async {
      final wallet = await XendWallet.create();
      await expectLater(
        wallet.send(to: recipient, amount: BigInt.from(999)),
        throwsA(isA<TransactionMismatch>()),
      );
      expect(signed(), isFalse);
      expect(submits, isEmpty);
    });

    test('declining in confirm throws UserCancelledAuth without signing',
        () async {
      final wallet = await XendWallet.create();
      await expectLater(
        wallet.send(
          to: recipient,
          amount: BigInt.from(1000000),
          confirm: (_) async => false,
        ),
        throwsA(isA<UserCancelledAuth>()),
      );
      expect(signed(), isFalse);
      expect(submits, isEmpty);
    });

    test('sponsored transfer puts the fee payer signature first', () async {
      buildMessage = base64Encode(hex(rustNativeSponsored));
      feePayerSignature = base64Encode(List.filled(64, 0x11));
      final wallet = await XendWallet.create();
      TransferPreview? seen;
      await wallet.send(
        to: recipient,
        amount: BigInt.from(1000000),
        confirm: (p) async {
          seen = p;
          return true;
        },
      );
      expect(seen!.sponsored, isTrue);
      final wire = base64Decode(submits.single['signed'] as String);
      expect(wire[0], 2);
      expect(wire.sublist(1, 65), List.filled(64, 0x11));
      expect(wire.sublist(65, 129), List.filled(64, 0xAB));
    });

    test('a fee payer signature on an unsponsored message is rejected',
        () async {
      feePayerSignature = base64Encode(List.filled(64, 0x11));
      final wallet = await XendWallet.create();
      await expectLater(
        wallet.send(to: recipient, amount: BigInt.from(1000000)),
        throwsA(isA<TransactionMismatch>()),
      );
      expect(signed(), isFalse);
    });

    test('an invalid recipient address is rejected before building', () async {
      final wallet = await XendWallet.create();
      await expectLater(
        wallet.send(to: 'not-an-address', amount: BigInt.one),
        throwsA(isA<InvalidRecipient>()),
      );
    });

    test('key_invalidated from the signer maps to KeyInvalidated', () async {
      signError = PlatformException(code: 'key_invalidated');
      final wallet = await XendWallet.create();
      await expectLater(
        wallet.send(to: recipient, amount: BigInt.from(1000000)),
        throwsA(isA<KeyInvalidated>()),
      );
    });
  });

  group('sign', () {
    test('refuses bytes that form a transaction message', () async {
      final wallet = await XendWallet.create();
      await expectLater(
        wallet.sign(hex(rustNative), reason: 'Sign in'),
        throwsA(isA<UnsafeSignRequest>()),
      );
      expect(signed(), isFalse);
    });

    test('signs ordinary sign-in text', () async {
      final wallet = await XendWallet.create();
      final sig = await wallet.sign(
        utf8.encode('Sign in to example.com\nNonce: 42'),
        reason: 'Sign in',
      );
      expect(sig, hasLength(64));
    });
  });

  group('delete', () {
    test('keeps the synced backup by default', () async {
      final wallet = await XendWallet.create();
      await wallet.delete();
      final call = nativeCalls.last;
      expect(call.method, 'deleteKey');
      expect(call.arguments, {'walletId': 'default', 'wipeBackup': false});
    });

    test('passes wipeBackup through', () async {
      final wallet = await XendWallet.create();
      await wallet.delete(wipeBackup: true);
      expect(nativeCalls.last.arguments['wipeBackup'], isTrue);
    });
  });
}
