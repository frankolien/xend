import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xend/src/wire.dart';

void main() {
  group('encodeShortVecLength', () {
    test('encodes 0..127 as a single byte', () {
      expect(encodeShortVecLength(0), [0x00]);
      expect(encodeShortVecLength(1), [0x01]);
      expect(encodeShortVecLength(2), [0x02]);
      expect(encodeShortVecLength(127), [0x7f]);
    });

    test('encodes 128..16383 as two bytes (little-endian, continuation bit)',
        () {
      expect(encodeShortVecLength(128), [0x80, 0x01]);
      expect(encodeShortVecLength(129), [0x81, 0x01]);
      expect(encodeShortVecLength(16383), [0xff, 0x7f]);
    });

    test('encodes 16384..65535 as three bytes', () {
      expect(encodeShortVecLength(16384), [0x80, 0x80, 0x01]);
      expect(encodeShortVecLength(65535), [0xff, 0xff, 0x03]);
    });
  });

  group('assembleSignedTransaction', () {
    Uint8List sig(int fill) => Uint8List.fromList(List.filled(64, fill));
    final message = Uint8List.fromList([1, 2, 3, 4]);

    test('one signature: 0x01 | sig | message', () {
      final s = sig(0xAA);
      final wire = assembleSignedTransaction([s], message);
      expect(wire.length, 1 + 64 + 4);
      expect(wire[0], 0x01);
      expect(wire.sublist(1, 65), s);
      expect(wire.sublist(65), message);
    });

    test('two signatures keep signer order: 0x02 | feePayer | sender | message',
        () {
      final feePayer = sig(0x11);
      final sender = sig(0x22);
      final wire = assembleSignedTransaction([feePayer, sender], message);
      expect(wire.length, 1 + 64 + 64 + 4);
      expect(wire[0], 0x02);
      expect(wire.sublist(1, 65), feePayer);
      expect(wire.sublist(65, 129), sender);
      expect(wire.sublist(129), message);
    });

    test('count prefix reflects the number of signatures', () {
      expect(assembleSignedTransaction([], message)[0], 0x00);
      expect(assembleSignedTransaction([sig(1)], message)[0], 0x01);
    });
  });
}
