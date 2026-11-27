// End-to-end check of the real SDK on a simulator or device: real platform channel, real
// keychain, real backend. Run with the backend up on localhost:8080:
//
//   flutter test integration_test -d <simulator-id>
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:xend/xend.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    Xend.configure(const XendConfig(backendUrl: 'http://localhost:8080'));
  });

  testWidgets('create, load, sign, balance, resolve, recover, wipe', (tester) async {
    // Start clean so the run is repeatable.
    final existing = await XendWallet.load();
    if (existing != null) await existing.delete(wipeBackup: true);

    final wallet = await XendWallet.create(label: 'Integration');
    expect(wallet.address.length, inInclusiveRange(32, 44));

    final reloaded = await XendWallet.load();
    expect(reloaded?.address, wallet.address);

    final sig = await wallet.sign(
      'Sign in to Xend'.codeUnits,
      reason: 'Sign in',
    );
    expect(sig.length, 64);

    final balance = await wallet.balance();
    expect(balance.amount >= BigInt.zero, isTrue);

    final resolved = await XendWallet.resolveName('bonfida.sol');
    expect(resolved.length, inInclusiveRange(32, 44));

    // A local delete keeps the backup, so load() silently recovers the same wallet.
    await wallet.delete();
    final recovered = await XendWallet.load();
    expect(recovered?.address, wallet.address);

    // Wiping the backup removes it for good.
    await recovered!.delete(wipeBackup: true);
    expect(await XendWallet.load(), isNull);
  });
}
