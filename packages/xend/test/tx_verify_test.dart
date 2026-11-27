import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xend/src/tx_verify.dart';
import 'package:xend/src/wire.dart';
import 'package:xend/xend.dart';

import 'support/vectors.dart';

/// An instruction for [buildMessage], with accounts given by address.
class Ix {
  Ix(this.program, this.accounts, this.data);
  final String program;
  final List<String> accounts;
  final List<int> data;
}

/// Builds a legacy message. [keys] is the full ordered key list; the caller sets the
/// header so malformed layouts can be tested too.
Uint8List buildMessage({
  required List<String> keys,
  required int signers,
  int readonlySigned = 0,
  int readonlyUnsigned = 0,
  required List<Ix> ixs,
}) {
  final b = BytesBuilder()
    ..add([signers, readonlySigned, readonlyUnsigned])
    ..add(encodeShortVecLength(keys.length));
  for (final k in keys) {
    b.add(base58Decode(k));
  }
  b.add(List.filled(32, 7));
  b.add(encodeShortVecLength(ixs.length));
  for (final ix in ixs) {
    b.addByte(keys.indexOf(ix.program));
    b.add(encodeShortVecLength(ix.accounts.length));
    for (final a in ix.accounts) {
      b.addByte(keys.indexOf(a));
    }
    b.add(encodeShortVecLength(ix.data.length));
    b.add(ix.data);
  }
  return b.toBytes();
}

List<int> u64(int v) => [for (var i = 0; i < 8; i++) (v >> (8 * i)) & 0xff];

Ix systemTransfer(String from, String to, int lamports) =>
    Ix(systemProgramId, [from, to], [2, 0, 0, 0, ...u64(lamports)]);

Ix createAta(String funder, String ata, String owner, String mint) => Ix(
      associatedTokenProgramId,
      [funder, ata, owner, mint, systemProgramId, tokenProgramId],
      [1],
    );

Ix transferChecked(
        String src, String mint, String dst, String auth, int amount) =>
    Ix(tokenProgramId, [src, mint, dst, auth], [12, ...u64(amount), 6]);

void main() {
  group('base58', () {
    test('round-trips addresses, including leading-zero keys', () {
      for (final a in [user, systemProgramId, tokenProgramId, usdc]) {
        expect(base58Encode(base58Decode(a)), a);
      }
      expect(base58Decode(systemProgramId), List.filled(32, 0));
    });

    test('decodeAddress rejects bad input', () {
      expect(decodeAddress('0OIl'), isNull);
      expect(decodeAddress('abc'), isNull);
      expect(decodeAddress(user), hasLength(32));
    });
  });

  group('program addresses', () {
    test('on-curve check', () {
      expect(isOnCurve(base58Decode(user)), isTrue);
      expect(isOnCurve(base58Decode(usdc)), isTrue);
      expect(isOnCurve(base58Decode(userAta)), isFalse);
      expect(isOnCurve(base58Decode(recipientAta)), isFalse);
    });

    test('associated token address matches Solana (bump 255 and 254)', () {
      expect(associatedTokenAddress(user, usdc), userAta);
      // This one needs bump 254, so it exercises the off-curve rejection.
      expect(associatedTokenAddress(recipient, usdc), recipientAta);
    });
  });

  group('decodeMessage', () {
    test('decodes a Rust-serialized native transfer', () {
      final m = decodeMessage(hex(rustNative));
      expect(m.version, isNull);
      expect(m.numRequiredSignatures, 1);
      expect(m.accountKeys, [user, recipient, systemProgramId]);
      expect(m.instructions, hasLength(1));
      expect(m.recentBlockhash, List.filled(32, 7));
    });

    test('rejects trailing bytes, truncation, and bad indexes', () {
      final good = hex(rustNative);
      expect(() => decodeMessage([...good, 0]), throwsFormatException);
      expect(() => decodeMessage(good.sublist(0, good.length - 1)),
          throwsFormatException);
      final badProgram = Uint8List.fromList(good);
      // The program index byte follows the blockhash and instruction count.
      badProgram[3 + 1 + 96 + 32 + 1] = 9;
      expect(() => decodeMessage(badProgram), throwsFormatException);
    });

    test('rejects an overlong shortvec', () {
      expect(() => decodeMessage([1, 0, 0, 0x81, 0x00]), throwsFormatException);
    });

    test('decodes a v0 message with a lookup table', () {
      final legacy = hex(rustNative);
      final v0 = [0x80, ...legacy, 1, ...List.filled(32, 9), 1, 0, 0];
      expect(decodeMessage(v0).version, 0);
      expect(decodeMessage(v0).lookupCount, 1);
    });

    test('isTransactionMessage is false for sign-in text', () {
      final text = 'Sign in to example.com\nNonce: 12345'.codeUnits;
      expect(isTransactionMessage(text), isFalse);
      expect(isTransactionMessage([]), isFalse);
      expect(isTransactionMessage(hex(rustTokenSponsored)), isTrue);
    });
  });

  group('verifyTransfer accepts', () {
    test('Rust native transfer', () {
      expect(
        verifyTransfer(hex(rustNative),
            user: user,
            recipient: recipient,
            amount: BigInt.from(1000000),
            sponsored: false),
        isNull,
      );
    });

    test('Rust sponsored native transfer', () {
      expect(
        verifyTransfer(hex(rustNativeSponsored),
            user: user,
            recipient: recipient,
            amount: BigInt.from(1000000),
            sponsored: true),
        isNull,
      );
    });

    test('Rust sponsored token transfer, returning decimals', () {
      expect(
        verifyTransfer(hex(rustTokenSponsored),
            user: user,
            recipient: recipient,
            amount: BigInt.from(1500000),
            mint: usdc,
            sponsored: true),
        6,
      );
    });

    test('unsponsored token transfer with the user funding the account', () {
      final msg = buildMessage(
        keys: [
          user,
          userAta,
          recipientAta,
          recipient,
          usdc,
          systemProgramId,
          tokenProgramId,
          associatedTokenProgramId
        ],
        signers: 1,
        readonlyUnsigned: 5,
        ixs: [
          createAta(user, recipientAta, recipient, usdc),
          transferChecked(userAta, usdc, recipientAta, user, 42),
        ],
      );
      expect(
        verifyTransfer(msg,
            user: user,
            recipient: recipient,
            amount: BigInt.from(42),
            mint: usdc,
            sponsored: false),
        6,
      );
    });

    test('token transfer without the create instruction', () {
      final msg = buildMessage(
        keys: [user, userAta, recipientAta, usdc, tokenProgramId],
        signers: 1,
        readonlyUnsigned: 2,
        ixs: [transferChecked(userAta, usdc, recipientAta, user, 42)],
      );
      expect(
        verifyTransfer(msg,
            user: user,
            recipient: recipient,
            amount: BigInt.from(42),
            mint: usdc,
            sponsored: false),
        6,
      );
    });
  });

  group('verifyTransfer rejects', () {
    Matcher mismatch(String reason) => throwsA(isA<TransactionMismatch>()
        .having((e) => e.reason, 'reason', contains(reason)));

    void native(Uint8List msg, String reason,
        {bool sponsored = false, int amount = 1000}) {
      expect(
        () => verifyTransfer(msg,
            user: user,
            recipient: recipient,
            amount: BigInt.from(amount),
            sponsored: sponsored),
        mismatch(reason),
      );
    }

    test('wrong recipient', () {
      native(
        buildMessage(
          keys: [user, attacker, systemProgramId],
          signers: 1,
          readonlyUnsigned: 1,
          ixs: [systemTransfer(user, attacker, 1000)],
        ),
        'wrong recipient',
      );
    });

    test('wrong amount', () {
      native(hex(rustNative), 'wrong amount', amount: 999);
    });

    test('extra instruction', () {
      native(
        buildMessage(
          keys: [user, recipient, attacker, systemProgramId],
          signers: 1,
          readonlyUnsigned: 1,
          ixs: [
            systemTransfer(user, recipient, 1000),
            systemTransfer(user, attacker, 5000),
          ],
        ),
        'exactly one instruction',
      );
    });

    test('unknown program', () {
      native(
        buildMessage(
          keys: [user, recipient, attacker],
          signers: 1,
          readonlyUnsigned: 1,
          ixs: [
            Ix(attacker, [user, recipient], [2, 0, 0, 0, ...u64(1000)])
          ],
        ),
        'unexpected program',
      );
    });

    test('non-transfer System instruction', () {
      native(
        buildMessage(
          keys: [user, recipient, systemProgramId],
          signers: 1,
          readonlyUnsigned: 1,
          // Assign (discriminator 1) the user's account to another owner.
          ixs: [
            Ix(systemProgramId, [user], [1, 0, 0, 0, ...base58Decode(attacker)])
          ],
        ),
        'System transfer',
      );
    });

    test('sponsored flag but the user pays fees', () {
      native(hex(rustNative), 'expected 2 signers',
          sponsored: true, amount: 1000000);
    });

    test('unsponsored flag but someone else is fee payer', () {
      native(hex(rustNativeSponsored), 'expected 1 signer', amount: 1000000);
    });

    test('sponsored, user is fee payer next to an extra signer', () {
      native(
        buildMessage(
          keys: [user, attacker, recipient, systemProgramId],
          signers: 2,
          readonlyUnsigned: 1,
          ixs: [systemTransfer(user, recipient, 1000)],
        ),
        'user is fee payer',
        sponsored: true,
      );
    });

    test('sponsored, user funds a drain from the fee payer slot', () {
      // Fee payer is someone else, but a second transfer moves the user's lamports.
      native(
        buildMessage(
          keys: [payer, user, recipient, attacker, systemProgramId],
          signers: 2,
          readonlyUnsigned: 1,
          ixs: [
            systemTransfer(user, recipient, 1000),
            systemTransfer(user, attacker, 1000000),
          ],
        ),
        'exactly one instruction',
        sponsored: true,
      );
    });

    test('versioned message', () {
      native(Uint8List.fromList([0x80, ...hex(rustNative), 0]), 'versioned',
          amount: 1000000);
    });

    test('garbage', () {
      native(Uint8List.fromList([1, 2, 3]), 'malformed');
    });

    void token(Uint8List msg, String reason,
        {bool sponsored = true, int amount = 42}) {
      expect(
        () => verifyTransfer(msg,
            user: user,
            recipient: recipient,
            amount: BigInt.from(amount),
            mint: usdc,
            sponsored: sponsored),
        mismatch(reason),
      );
    }

    List<String> tokenKeys(List<String> extra) => [
          payer,
          user,
          ...extra,
          systemProgramId,
          tokenProgramId,
          associatedTokenProgramId,
        ];

    test('token sent to an account the recipient does not own', () {
      token(
        buildMessage(
          keys: tokenKeys([userAta, attacker, usdc]),
          signers: 2,
          readonlySigned: 1,
          readonlyUnsigned: 4,
          ixs: [transferChecked(userAta, usdc, attacker, user, 42)],
        ),
        'wrong recipient',
      );
    });

    test('token create for the attacker then transfer to it', () {
      final attackerAta = associatedTokenAddress(attacker, usdc);
      token(
        buildMessage(
          keys: tokenKeys([userAta, attackerAta, attacker, usdc]),
          signers: 2,
          readonlySigned: 1,
          readonlyUnsigned: 5,
          ixs: [
            createAta(payer, attackerAta, attacker, usdc),
            transferChecked(userAta, usdc, attackerAta, user, 42),
          ],
        ),
        'wrong token account created',
      );
    });

    test('sponsored token where the user funds the account rent', () {
      token(
        buildMessage(
          keys: tokenKeys([userAta, recipientAta, recipient, usdc]),
          signers: 2,
          readonlySigned: 0,
          readonlyUnsigned: 5,
          ixs: [
            createAta(user, recipientAta, recipient, usdc),
            transferChecked(userAta, usdc, recipientAta, user, 42),
          ],
        ),
        'not funded by fee payer',
      );
    });

    test('token wrong amount', () {
      token(hex(rustTokenSponsored), 'wrong amount');
    });

    test('token wrong mint', () {
      expect(
        () => verifyTransfer(hex(rustTokenSponsored),
            user: user,
            recipient: recipient,
            amount: BigInt.from(1500000),
            mint: tokenProgramId,
            sponsored: true),
        throwsA(isA<TransactionMismatch>()),
      );
    });

    test('token instruction other than TransferChecked', () {
      token(
        buildMessage(
          keys: tokenKeys([userAta, attacker, usdc]),
          signers: 2,
          readonlySigned: 1,
          readonlyUnsigned: 4,
          // Approve (tag 4) a delegate over the user's token account.
          ixs: [
            Ix(tokenProgramId, [userAta, attacker, user], [4, ...u64(42)])
          ],
        ),
        'TransferChecked',
      );
    });

    test('native transfer when a token was requested', () {
      token(hex(rustNativeSponsored), 'token', amount: 1000000);
    });
  });
}
