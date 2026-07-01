// Smoke test for the example. Mocks the native channel `ai.xend/secure` in-process, so
// the create-wallet UI + SecureChannel wiring are verified WITHOUT an iOS device.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xend_example/main.dart';
import 'package:xend_sdk/xend_sdk.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ai.xend/secure');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    Xend.configure(const XendConfig(backendUrl: 'http://localhost:8080'));
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  testWidgets('shows "Create wallet" when the vault has no key', (tester) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getPublicKey') return null; // no wallet yet
      return null;
    });

    await tester.pumpWidget(const XendExampleApp());
    await tester.pumpAndSettle();

    expect(find.text('Create wallet'), findsOneWidget);
    expect(find.text('No wallet yet.'), findsOneWidget);
  });

  testWidgets('shows the address when the vault already has a key', (tester) async {
    const fakeAddress = '7HEqBe5XA9T9K1T9BDz4HbBiwYsc56W2gSQ8jWsntFkX';
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getPublicKey') return fakeAddress; // restart read path
      return null;
    });

    await tester.pumpWidget(const XendExampleApp());
    await tester.pumpAndSettle();

    expect(find.text(fakeAddress), findsOneWidget);
    expect(find.text('Your Solana address'), findsOneWidget);
  });
}
