import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xend/src/mappings.dart';
import 'package:xend/xend.dart';

void main() {
  group('isSolName', () {
    test('true for .sol names, case-insensitive', () {
      expect(isSolName('gift.sol'), isTrue);
      expect(isSolName('GIFT.SOL'), isTrue);
      expect(isSolName('a.b.sol'), isTrue);
    });

    test('false for addresses and other input', () {
      expect(
          isSolName('7XGrbd3dmdesSR5vAu7siidiZ1YHyizzuPCQAnh2g2Lo'), isFalse);
      expect(isSolName('gift.eth'), isFalse);
      expect(isSolName('sol'), isFalse);
      expect(isSolName(''), isFalse);
    });
  });

  group('newIdempotencyKey', () {
    test('is 32 lowercase hex characters', () {
      expect(newIdempotencyKey(), matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('is distinct across calls', () {
      final keys = List.generate(200, (_) => newIdempotencyKey()).toSet();
      expect(keys.length, 200);
    });
  });

  group('txStatusFromBackend', () {
    const handle = TxHandle('sig123');

    test('finalized is terminal success', () {
      final s = txStatusFromBackend(handle, 'finalized');
      expect(s.state, 'finalized');
      expect(s.commitment, TxCommitment.finalized);
      expect(s.signature, 'sig123');
      expect(s.isTerminalSuccess, isTrue);
      expect(s.isFailed, isFalse);
    });

    test('confirmed is not reported as finalized', () {
      final s = txStatusFromBackend(handle, 'confirmed');
      expect(s.state, 'confirmed');
      expect(s.commitment, TxCommitment.confirmed);
      expect(s.isTerminalSuccess, isFalse);
    });

    test('failed carries a ChainRejected error and no commitment', () {
      final s = txStatusFromBackend(handle, 'failed');
      expect(s.state, 'failed');
      expect(s.isFailed, isTrue);
      expect(s.error, isA<ChainRejected>());
      expect(s.commitment, isNull);
    });

    test('processed and unknown values map to pending/processed', () {
      for (final raw in ['processed', 'something-else', '']) {
        final s = txStatusFromBackend(handle, raw);
        expect(s.state, 'pending', reason: 'raw="$raw"');
        expect(s.commitment, TxCommitment.processed, reason: 'raw="$raw"');
      }
    });
  });

  group('txRecordFromJson', () {
    Map<String, dynamic> row(Map<String, dynamic> overrides) => {
          'signature': 'sig',
          'status': 'finalized',
          'to': 'dest',
          'amount': '1000000',
          'created_at': '2026-07-01T10:00:00Z',
          ...overrides,
        };

    test('null mint yields the native asset', () {
      final r = txRecordFromJson(row({'mint': null}), Chain.solana);
      expect(r.signature, 'sig');
      expect(r.to, 'dest');
      expect(r.amount, BigInt.from(1000000));
      expect(r.asset.mint, isNull);
      expect(r.asset.chain, Chain.solana);
      expect(
        r.createdAt.isAtSameMomentAs(DateTime.utc(2026, 7, 1, 10)),
        isTrue,
      );
    });

    test('present mint yields a token asset', () {
      final r = txRecordFromJson(row({'mint': 'MINT'}), Chain.solana);
      expect(r.asset.mint, 'MINT');
    });

    test('missing amount and recipient default safely', () {
      final r = txRecordFromJson({
        'signature': 'sig',
        'status': 'submitted',
        'created_at': '2026-07-01T10:00:00Z',
      }, Chain.solana);
      expect(r.amount, BigInt.zero);
      expect(r.to, '');
    });
  });

  group('mapNativeError', () {
    test('user_cancelled_auth -> UserCancelledAuth', () {
      expect(
        mapNativeError(PlatformException(code: 'user_cancelled_auth')),
        isA<UserCancelledAuth>(),
      );
    });

    test('invalid_mnemonic -> InvalidRecoveryPhrase', () {
      expect(
        mapNativeError(PlatformException(code: 'invalid_mnemonic')),
        isA<InvalidRecoveryPhrase>(),
      );
    });

    test('biometrics_unavailable -> NetworkError', () {
      expect(
        mapNativeError(PlatformException(code: 'biometrics_unavailable')),
        isA<NetworkError>(),
      );
    });

    test('unknown code -> NetworkError carrying the native message', () {
      final e = mapNativeError(
        PlatformException(code: 'enclave_error', message: 'boom'),
      );
      expect(e, isA<NetworkError>());
      expect(e.message, contains('boom'));
    });
  });
}
