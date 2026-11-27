# Changelog

## 0.2.0

Security hardening. **Still devnet and not audited — do not use with real funds.**

### Breaking
- `delete()` now removes only this device's keys; the iCloud backup stays and `load()`
  recovers from it. Use `delete(wipeBackup: true)` to remove the backup everywhere.
- `sign()` throws `UnsafeSignRequest` for bytes that decode as a Solana transaction.
- Secure-hardware failures map to `SecureElementError` instead of `NetworkError`.

### Security
- `send()` decodes and verifies the backend-built transaction on-device before signing:
  allowed programs, signer layout, recipient, amount, and mint must match the request,
  otherwise it throws `TransactionMismatch`.
- New `confirm:` callback on `send()` receives a `TransferPreview` before Face ID.
- iOS: each wallet's backup is stored under its own address and is never overwritten, so
  creating a wallet on a new device can no longer erase another device's backup.
- iOS: Face ID re-enrollment is detected (`KeyInvalidated`) and the wallet re-wraps itself
  from its backup when one exists.
- iOS: the recovery phrase no longer crosses the platform channel at creation; plaintext
  key material is zeroized after use (best effort).
- Backend (separate service): paymaster can no longer be named as sender or recipient,
  co-signing is gated by a program/role policy, sponsorship is capped per sender, the rate
  limiter runs after auth, and history is read from the signed transaction.

### Added
- `TransferPreview`, `TransactionMismatch`, `UnsafeSignRequest`, `KeyInvalidated`,
  `BackupUnavailable`, `SecureElementError`.
- Example app integration test (real channel, keychain, and backend).

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
