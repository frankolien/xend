# Xend

Embedded, **non-custodial** payments for mobile apps. Create a wallet, hold tokens, and send
value — with every key generated and kept **on the device**, gated behind Face ID. You call
`Xend`; the SDK handles the chain, the signing, fee sponsorship, name resolution, and
confirmation. No seed phrase to show, no raw web3 to touch.

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

// Get a wallet — embedded and silent. The private key is generated in the device's secure
// hardware and never leaves it (not to Dart, not to the network, not to disk in plaintext).
// No seed phrase is shown; on a new device the wallet recovers itself via iCloud Keychain.
final wallet = await XendWallet.load() ?? await XendWallet.create(label: 'Main');
print(wallet.address); // base58 Solana address

// Send. Money is always base units — never a double. `to` may be an address or a `.sol`
// name, resolved automatically. Fees are sponsored by the backend when it runs a paymaster,
// so the user needs no SOL. Signing happens on-device behind Face ID.
final tx = await wallet.send(to: 'gift.sol', amount: BigInt.from(2000000)); // 0.002 SOL, in lamports

// The stream never lies: pending → confirmed → finalized.
await for (final status in wallet.watch(tx)) {
  if (status.commitment == TxCommitment.confirmed) break;
}

// Read balance and history.
final balance = await wallet.balance();          // native SOL
final rows = await wallet.history();
```

Every method is à la carte — use only what your app needs:

```dart
final usdc = await wallet.send(to: dest, amount: amt, asset: someToken); // any SPL token
final addr = await XendWallet.resolveName('gift.sol');   // show a name's address
final sig  = await wallet.sign(bytes, reason: 'Sign in'); // wallet login / message signing
final phrase = await wallet.revealRecoveryPhrase();       // optional export screen
await wallet.delete();
```

Unbuilt capabilities (`swap`, `bridge`, non-Solana chains) throw a typed `NotImplementedYet` —
Xend never fakes success.

## What you get

- **Embedded onboarding.** `create()` is silent — no seed phrase, web2 feel. Recovery is
  automatic across the user's Apple devices via end-to-end-encrypted iCloud Keychain.
- **Hardware signing.** Ed25519 key derived on-device (BIP-39 / SLIP-0010), wrapped by a
  Secure Enclave key, decrypted only for the microseconds of a Face ID-gated signature.
- **Gasless.** When your backend runs a paymaster it becomes the fee payer, so users transact
  holding no SOL. The same `send()` call — sponsorship is invisible to your app.
- **Names.** Send to `gift.sol`; the SDK resolves Solana Name Service domains transparently.
- **Tokens.** SOL and any SPL token (USDC and friends); the recipient's token account is
  created automatically.
- **Truthful confirmations.** `watch()` reports pending → confirmed → finalized as it happens.

## Principles

- **Keys never leave the device.** The backend is a witness, not a custodian.
- **Hide the chain, not the truth.** Pending is pending; `confirmed` ≠ `finalized`.
- **Typed failures.** Every error is a `XendError` you can `switch` on
  (`NetworkError`, `InsufficientFunds`, `UserCancelledAuth`, `InvalidRecipient`, …).
- **Integer money.** Base units end to end; decimals only at the UI edge.

## Links

- [Architecture](https://github.com/EntryPointLabs/xend/blob/main/docs/01-ARCHITECTURE.md)
- [Security model & threat model](https://github.com/EntryPointLabs/xend/blob/main/docs/04-SECURITY.md)
- [Getting started](https://github.com/EntryPointLabs/xend/blob/main/docs/05-GETTING-STARTED.md)

Licensed under Apache-2.0.
