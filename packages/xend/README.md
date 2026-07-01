# Xend

Embedded, **non-custodial** payments for mobile apps. Create a wallet, hold tokens, and send
value — with every key generated and kept **on the device**, gated behind Face ID. You call
`Xend`; the SDK handles the chain, the signing, and the confirmation.

> **Status: v0.1 · pre-release.** Solana + iOS only, devnet. **Not audited — do not use with
> real funds yet.** See the [roadmap](https://github.com/EntryPointLabs/xend/blob/main/docs/03-ROADMAP.md).

## Install

```sh
flutter pub add xend
```

## Quick start

```dart
import 'package:xend/xend.dart';

// Configure once at startup.
Xend.configure(const XendConfig(backendUrl: 'https://your-backend'));

// Create a wallet. The private key is generated in the device's secure hardware and
// never leaves it — not to Dart, not to the network, not to disk in plaintext.
final wallet = await XendWallet.create(label: 'Main');
print(wallet.address); // base58 Solana address

// Reload it after an app restart:
final existing = await XendWallet.load();
```

Coming in Phase 2–5 (the signatures are stable now; the bodies are landing):

```dart
// Money is always base units — never a double.
final tx = await wallet.send(to: recipient, amount: BigInt.from(2000000)); // 2 USDC (6 dp)

// The stream never lies: pending → confirmed → finalized.
wallet.watch(tx).listen((s) => print(s.state));
```

Unbuilt capabilities throw a typed `NotImplementedYet` — Xend never fakes success.

## Principles

- **Keys never leave the device.** The backend is a witness, not a custodian.
- **Hide the chain, not the truth.** Pending is pending; `confirmed` ≠ `finalized`.
- **Typed failures.** Every error is a `XendError` you can `switch` on
  (`NetworkError`, `InsufficientFunds`, `UserCancelledAuth`, …).
- **Integer money.** Base units end to end; decimals only at the UI edge.

## Links

- [Architecture](https://github.com/EntryPointLabs/xend/blob/main/docs/01-ARCHITECTURE.md)
- [Security model & threat model](https://github.com/EntryPointLabs/xend/blob/main/docs/04-SECURITY.md)
- [Getting started](https://github.com/EntryPointLabs/xend/blob/main/docs/05-GETTING-STARTED.md)

Licensed under Apache-2.0.
