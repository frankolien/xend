import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Clipboard
import 'package:xend/xend.dart';

// This app imports ONLY package:xend (and Flutter). No solana, no crypto, no RPC, no
// "blockhash" — the entire wallet is driven through the SDK surface. That is the
// abstraction test (docs/00-PRD.md invariant 4): an app developer never touches a chain.

/// The Xend backend. The iOS simulator reaches a backend on the host via localhost; a
/// physical device must use the host machine's LAN IP (for example `http://192.168.1.20:8080`).
const String backendUrl = 'http://localhost:8080';

void main() {
  Xend.configure(const XendConfig(backendUrl: backendUrl));
  runApp(const XendExampleApp());
}

class XendExampleApp extends StatelessWidget {
  const XendExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF14C7C7),
      brightness: Brightness.light,
    );
    return MaterialApp(
      title: 'Xend Example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: scheme,
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xFFF6F8F8),
      ),
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
  Balance? _balance;
  List<TxRecord>? _history;
  bool _busy = false; // create / delete in flight
  bool _loadingBalance = false;
  bool _loadingHistory = false;

  @override
  void initState() {
    super.initState();
    _loadExisting(); // the wallet must survive an app restart
  }

  Future<void> _loadExisting() async {
    final wallet = await XendWallet.load();
    if (!mounted) return;
    setState(() => _wallet = wallet);
    if (wallet != null) _refresh();
  }

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      // Silent, embedded-style onboarding: the wallet is provisioned on-device with no
      // recovery phrase shown. The phrase is available later under "Export recovery
      // phrase" for users who want to self-custody or import elsewhere.
      final wallet = await XendWallet.create(label: 'Main');
      if (!mounted) return;
      setState(() => _wallet = wallet);
      _refresh();
    } on XendError catch (e) {
      _toast(e.message); // e.g. NetworkError when the backend isn't running
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final phrase = await showDialog<String>(
      context: context,
      builder: (_) => const _RestoreDialog(),
    );
    if (phrase == null || phrase.isEmpty) return;
    setState(() => _busy = true);
    try {
      final wallet = await XendWallet.restore(phrase);
      if (!mounted) return;
      setState(() => _wallet = wallet);
      _refresh();
    } on XendError catch (e) {
      _toast(e.message); // e.g. InvalidRecoveryPhrase on a typo
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revealPhrase() async {
    final wallet = _wallet;
    if (wallet == null) return;
    try {
      final phrase = await wallet.revealRecoveryPhrase();
      if (mounted) await _showBackup(phrase, isReveal: true);
    } on XendError catch (e) {
      _toast(e.message); // e.g. UserCancelledAuth
    }
  }

  Future<void> _showBackup(String phrase, {required bool isReveal}) {
    return showDialog<void>(
      context: context,
      builder: (_) => _PhraseDialog(phrase: phrase, isReveal: isReveal),
    );
  }

  Future<void> _refreshBalance() async {
    final wallet = _wallet;
    if (wallet == null) return;
    setState(() => _loadingBalance = true);
    try {
      final balance = await wallet.balance();
      if (mounted) setState(() => _balance = balance);
    } on XendError catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _loadingBalance = false);
    }
  }

  Future<void> _refreshHistory() async {
    final wallet = _wallet;
    if (wallet == null) return;
    setState(() => _loadingHistory = true);
    try {
      final history = await wallet.history(limit: 20);
      if (mounted) setState(() => _history = history);
    } on XendError catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _loadingHistory = false);
    }
  }

  /// Refreshes balance and history together (after create, load, and each send).
  Future<void> _refresh() => Future.wait([_refreshBalance(), _refreshHistory()]);

  Future<void> _copyAddress() async {
    final wallet = _wallet;
    if (wallet == null) return;
    await Clipboard.setData(ClipboardData(text: wallet.receive()));
    _toast('Address copied');
  }

  Future<void> _openSend() async {
    final wallet = _wallet;
    if (wallet == null) return;
    final signature = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _SendSheet(wallet: wallet),
    );
    if (signature != null && mounted) {
      await showDialog<void>(
        context: context,
        builder: (_) => _SentDialog(wallet: wallet, signature: signature),
      );
      _refresh();
    }
  }

  Future<void> _delete() async {
    final wallet = _wallet;
    if (wallet == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete wallet?'),
        content: const Text(
          'This removes the key from the Secure Enclave. Without a recovery phrase the '
          'wallet cannot be recovered.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;
    await wallet.delete();
    if (!mounted) return;
    setState(() {
      _wallet = null;
      _balance = null;
    });
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final wallet = _wallet;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Xend'),
        backgroundColor: Colors.transparent,
        actions: [
          if (wallet != null)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz),
              onSelected: (value) {
                if (value == 'reveal') _revealPhrase();
                if (value == 'delete') _delete();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'reveal', child: Text('Export recovery phrase')),
                PopupMenuItem(value: 'delete', child: Text('Delete wallet')),
              ],
            ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: wallet == null
              ? _EmptyState(busy: _busy, onCreate: _create, onRestore: _restore)
              : _walletView(wallet),
        ),
      ),
    );
  }

  Widget _walletView(XendWallet wallet) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _BalanceCard(
          balance: _balance,
          loading: _loadingBalance,
          onRefresh: _refresh,
        ),
        const SizedBox(height: 16),
        _AddressCard(address: wallet.address, onCopy: _copyAddress),
        const SizedBox(height: 24),
        Row(
          children: [
            const Text('Recent activity',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const Spacer(),
            if (_loadingHistory)
              const SizedBox(
                  width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(child: _HistoryList(records: _history)),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _openSend,
          icon: const Icon(Icons.arrow_upward),
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(vertical: 16),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          label: const Text('Send'),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.busy, required this.onCreate, required this.onRestore});

  final bool busy;
  final VoidCallback onCreate;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.shield_outlined, size: 56, color: Color(0xFF14C7C7)),
          const SizedBox(height: 16),
          const Text('No wallet yet', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text(
            'A key pair is generated in the Secure Enclave and never leaves this device.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: busy ? null : onCreate,
            child: Text(busy ? 'Creating…' : 'Create wallet'),
          ),
          TextButton(
            onPressed: busy ? null : onRestore,
            child: const Text('Import a recovery phrase'),
          ),
        ],
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({
    required this.balance,
    required this.loading,
    required this.onRefresh,
  });

  final Balance? balance;
  final bool loading;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final amount = balance == null
        ? '—'
        : _formatUnits(balance!.amount, balance!.asset.decimals);
    return _Card(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Balance', style: TextStyle(color: Colors.grey)),
                const SizedBox(height: 6),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(amount, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w700)),
                    const SizedBox(width: 6),
                    const Padding(
                      padding: EdgeInsets.only(bottom: 4),
                      child: Text('SOL', style: TextStyle(fontSize: 16, color: Colors.grey)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: loading ? null : onRefresh,
            icon: loading
                ? const SizedBox(
                    width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }
}

class _AddressCard extends StatelessWidget {
  const _AddressCard({required this.address, required this.onCopy});

  final String address;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Receive to', style: TextStyle(color: Colors.grey)),
                const SizedBox(height: 6),
                Text(
                  _short(address),
                  style: const TextStyle(fontFamily: 'Menlo', fontSize: 15),
                ),
              ],
            ),
          ),
          IconButton(onPressed: onCopy, icon: const Icon(Icons.copy)),
        ],
      ),
    );
  }
}

/// A modal sheet for composing and sending a transfer. Owns its own in-flight state and
/// surfaces typed errors inline; on success it pops with the transaction signature.
class _SendSheet extends StatefulWidget {
  const _SendSheet({required this.wallet});

  final XendWallet wallet;

  @override
  State<_SendSheet> createState() => _SendSheetState();
}

class _SendSheetState extends State<_SendSheet> {
  final _toController = TextEditingController();
  final _amountController = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _toController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final to = _toController.text.trim();
    final lamports = _parseUnits(_amountController.text, 9);
    if (to.isEmpty) {
      setState(() => _error = 'Enter a recipient address');
      return;
    }
    if (lamports == null || lamports <= BigInt.zero) {
      setState(() => _error = 'Enter an amount greater than zero');
      return;
    }

    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      // Approving here triggers Face ID; the key is unwrapped, used once, and zeroed.
      final tx = await widget.wallet.send(to: to, amount: lamports);
      if (mounted) Navigator.pop(context, tx.id);
    } on UserCancelledAuth {
      if (mounted) setState(() => _error = 'Authentication cancelled');
    } on InsufficientFunds {
      if (mounted) setState(() => _error = 'Insufficient funds');
    } on InvalidRecipient {
      if (mounted) setState(() => _error = 'That address is not valid on Solana');
    } on XendError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 8, 20, 20 + bottomInset),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Send SOL', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
          const SizedBox(height: 16),
          TextField(
            controller: _toController,
            enabled: !_sending,
            decoration: const InputDecoration(
              labelText: 'Recipient address',
              border: OutlineInputBorder(),
            ),
            style: const TextStyle(fontFamily: 'Menlo', fontSize: 14),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _amountController,
            enabled: !_sending,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Amount (SOL)',
              border: OutlineInputBorder(),
              hintText: '0.001',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _sending ? null : _send,
            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            child: _sending
                ? const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 18, height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      ),
                      SizedBox(width: 12),
                      Text('Approve with Face ID…'),
                    ],
                  )
                : const Text('Sign & send'),
          ),
        ],
      ),
    );
  }
}

/// Shows a submitted transaction and tracks its confirmation live by listening to
/// [XendWallet.watch] — Confirming… → Confirmed → Finalized.
class _SentDialog extends StatefulWidget {
  const _SentDialog({required this.wallet, required this.signature});

  final XendWallet wallet;
  final String signature;

  @override
  State<_SentDialog> createState() => _SentDialogState();
}

class _SentDialogState extends State<_SentDialog> {
  late final Stream<TxStatus> _statuses =
      widget.wallet.watch(TxHandle(widget.signature));

  String get _explorerUrl =>
      'https://explorer.solana.com/tx/${widget.signature}?cluster=devnet';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Sent ✓'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StreamBuilder<TxStatus>(
            stream: _statuses,
            builder: (context, snapshot) => _StatusRow(state: snapshot.data?.state ?? 'pending'),
          ),
          const SizedBox(height: 16),
          const Text('Transaction', style: TextStyle(color: Colors.grey)),
          const SizedBox(height: 4),
          SelectableText(
            _explorerUrl,
            style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: _explorerUrl));
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Link copied')));
            }
          },
          child: const Text('Copy link'),
        ),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('Done')),
      ],
    );
  }
}

/// Renders a transaction's lifecycle state as an icon + label, with a spinner while it is
/// still confirming.
class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.state});

  final String state;

  @override
  Widget build(BuildContext context) {
    IconData? icon;
    Color? color;
    final String label;
    if (state == 'confirmed') {
      icon = Icons.check_circle;
      color = Colors.green;
      label = 'Confirmed';
    } else if (state == 'finalized') {
      icon = Icons.verified;
      color = Colors.green;
      label = 'Finalized';
    } else if (state == 'failed') {
      icon = Icons.error;
      color = Colors.red;
      label = 'Failed';
    } else {
      label = 'Confirming…';
    }
    return Row(
      children: [
        if (icon == null)
          const SizedBox(
              width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
        else
          Icon(icon, size: 20, color: color),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(fontSize: 16, color: color)),
      ],
    );
  }
}

/// The wallet's recent transactions, or a placeholder while loading / when empty.
class _HistoryList extends StatelessWidget {
  const _HistoryList({required this.records});

  final List<TxRecord>? records;

  @override
  Widget build(BuildContext context) {
    final records = this.records;
    if (records == null) {
      return const Center(child: Text('—', style: TextStyle(color: Colors.grey)));
    }
    if (records.isEmpty) {
      return const Center(
        child: Text('No transactions yet', style: TextStyle(color: Colors.grey)),
      );
    }
    return ListView.separated(
      itemCount: records.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) => _HistoryRow(record: records[i]),
    );
  }
}

/// A single transaction row: amount sent, recipient, status, and how long ago.
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.record});

  final TxRecord record;

  @override
  Widget build(BuildContext context) {
    final amount = _formatUnits(record.amount, record.asset.decimals);
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const CircleAvatar(radius: 18, child: Icon(Icons.arrow_upward, size: 18)),
      title: Text('Sent $amount SOL'),
      subtitle: Text(
        'To ${_short(record.to)}  ·  ${record.status}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: Text(
        _shortAge(record.createdAt),
        style: const TextStyle(fontSize: 12, color: Colors.grey),
      ),
    );
  }
}

/// Displays a recovery phrase for backup — the numbered words, a warning, and a copy
/// action. Shown once after creation and again on demand via "Reveal recovery phrase".
class _PhraseDialog extends StatelessWidget {
  const _PhraseDialog({required this.phrase, required this.isReveal});

  final String phrase;
  final bool isReveal;

  @override
  Widget build(BuildContext context) {
    final words = phrase.split(' ');
    return AlertDialog(
      title: Text(isReveal ? 'Recovery phrase' : 'Back up your wallet'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Write these words down in order and keep them somewhere safe. Anyone with them '
            'controls the wallet, and Xend cannot recover them for you.',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < words.length; i++)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0F4F4),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('${i + 1}. ${words[i]}',
                      style: const TextStyle(fontFamily: 'Menlo', fontSize: 13)),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: phrase));
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Recovery phrase copied')));
            }
          },
          child: const Text('Copy'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: Text(isReveal ? 'Done' : "I've saved it"),
        ),
      ],
    );
  }
}

/// Prompts for a recovery phrase and returns it (trimmed) to restore a wallet.
class _RestoreDialog extends StatefulWidget {
  const _RestoreDialog();

  @override
  State<_RestoreDialog> createState() => _RestoreDialogState();
}

class _RestoreDialogState extends State<_RestoreDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Restore wallet'),
      content: TextField(
        controller: _controller,
        maxLines: 3,
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'Enter your 12-word recovery phrase',
          border: OutlineInputBorder(),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Restore'),
        ),
      ],
    );
  }
}

/// A rounded surface used for the balance and address cards.
class _Card extends StatelessWidget {
  const _Card({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Color(0x0F000000), blurRadius: 12, offset: Offset(0, 4)),
        ],
      ),
      child: child,
    );
  }
}

/// A compact age label for a timestamp, such as `now`, `5m`, `3h`, or `2d`.
String _shortAge(DateTime time) {
  final d = DateTime.now().difference(time);
  if (d.inMinutes < 1) return 'now';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return '${d.inHours}h';
  return '${d.inDays}d';
}

/// Shortens an address to `head…tail` for compact display.
String _short(String address) =>
    address.length <= 12 ? address : '${address.substring(0, 6)}…${address.substring(address.length - 6)}';

/// Formats a base-unit [amount] as a decimal string with [decimals] fractional digits,
/// trimming trailing zeros (for example, 1_500_000_000 lamports → "1.5").
String _formatUnits(BigInt amount, int decimals) {
  if (decimals == 0) return amount.toString();
  final padded = amount.toString().padLeft(decimals + 1, '0');
  final whole = padded.substring(0, padded.length - decimals);
  final frac = padded.substring(padded.length - decimals).replaceAll(RegExp(r'0+$'), '');
  return frac.isEmpty ? whole : '$whole.$frac';
}

/// Parses a human-entered decimal [input] into base units with [decimals] fractional
/// digits, or `null` if it is malformed or more precise than the asset allows.
BigInt? _parseUnits(String input, int decimals) {
  final trimmed = input.trim();
  if (trimmed.isEmpty) return null;
  final parts = trimmed.split('.');
  if (parts.length > 2) return null;
  final whole = parts[0].isEmpty ? '0' : parts[0];
  var frac = parts.length == 2 ? parts[1] : '';
  if (!RegExp(r'^\d+$').hasMatch(whole) || (frac.isNotEmpty && !RegExp(r'^\d+$').hasMatch(frac))) {
    return null;
  }
  if (frac.length > decimals) return null;
  frac = frac.padRight(decimals, '0');
  final scale = BigInt.from(10).pow(decimals);
  return BigInt.parse(whole) * scale + (frac.isEmpty ? BigInt.zero : BigInt.parse(frac));
}
