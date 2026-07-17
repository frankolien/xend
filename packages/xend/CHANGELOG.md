# Changelog

## 0.1.0

First public pre-release. **Solana + iOS, devnet. Not audited — do not use with real funds.**

### Wallet
- Embedded, silent onboarding: `XendWallet.create` generates an Ed25519 key on-device
  (BIP-39 / SLIP-0010), wrapped by a Secure Enclave key — no seed phrase shown.
- `XendWallet.load` returns the on-device wallet, or silently recovers it on a new device
  from an end-to-end-encrypted iCloud Keychain seed.
- `XendWallet.restore` from a recovery phrase; `revealRecoveryPhrase` for an optional export.
- `delete`, `receive`, and `address`.

### Payments
- `send` — build → Face ID signature → submit, on Solana devnet. Native SOL and any SPL
  token (the recipient's token account is created automatically).
- Gasless: when the backend runs a paymaster it co-signs as fee payer, so users transact
  holding no SOL — the same `send()` call.
- `.sol` name resolution: `send(to: 'gift.sol', ...)` and `XendWallet.resolveName`.
- `balance` (SOL or SPL), `history`, and `watch` (pending → confirmed → finalized).
- `sign` arbitrary messages for wallet-based login.
- Exactly-once submission: an idempotency key is bound to the transaction it was claimed
  with, so a retry returns the original signature, and a key reused for different bytes is
  rejected (`IdempotencyKeyReuse`) instead of broadcast as a second transfer.

### Foundation
- `Xend.configure` / `XendConfig` (backend URL + optional API key).
- Chain-agnostic API (`Chain`, `Asset`, `Balance`, `TxHandle`, `TxStatus`, `TxRecord`).
- Sealed `XendError` hierarchy for exhaustive failure handling.
- Keys never cross the platform channel; the backend is a witness, never a custodian.

Not yet implemented (throw `NotImplementedYet`): `swap`, `bridge`, and non-Solana chains.
