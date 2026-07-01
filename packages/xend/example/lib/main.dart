import 'package:flutter/material.dart';
import 'package:xend/xend.dart';

// NOTE: this file imports ONLY package:xend (and Flutter). No solana, no crypto,
// no RPC, no "blockhash". That is the SDK abstraction test (docs/00-PRD.md invariant 4).

void main() {
  // Configure once at startup. iOS simulator reaches the host backend via localhost;
  // a physical device must use your machine's LAN IP instead.
  Xend.configure(const XendConfig(backendUrl: 'http://localhost:8080'));
  runApp(const XendExampleApp());
}

class XendExampleApp extends StatelessWidget {
  const XendExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Xend Example',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF14C7C7), useMaterial3: true),
      home: const WalletScreen(),
    );
  }
}

class WalletScreen extends StatefulWidget {
  const WalletScreen({super.key});

  @override
  State<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends State<WalletScreen> {
  XendWallet? _wallet;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadExisting(); // P1 checkpoint: the address survives an app restart.
  }

  Future<void> _loadExisting() async {
    final wallet = await XendWallet.load();
    if (mounted) setState(() => _wallet = wallet);
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final wallet = await XendWallet.create(label: 'Main');
      if (mounted) setState(() => _wallet = wallet);
    } on XendError catch (e) {
      _toast(e.message); // e.g. NetworkError if the backend isn't running
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final wallet = _wallet;
    if (wallet == null) return;
    await wallet.delete();
    if (mounted) setState(() => _wallet = null);
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final wallet = _wallet;
    return Scaffold(
      appBar: AppBar(title: const Text('Xend')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (wallet == null) ...[
                const Text('No wallet yet.', style: TextStyle(fontSize: 18)),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _busy ? null : _create,
                  child: Text(_busy ? 'Creating…' : 'Create wallet'),
                ),
              ] else ...[
                const Text('Your Solana address',
                    style: TextStyle(fontSize: 14, color: Colors.grey)),
                const SizedBox(height: 8),
                SelectableText(
                  wallet.address,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontFamily: 'Menlo', fontSize: 16),
                ),
                const SizedBox(height: 24),
                OutlinedButton(onPressed: _delete, child: const Text('Delete wallet')),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
