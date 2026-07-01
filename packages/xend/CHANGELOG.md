# Changelog

## 0.1.0 (unreleased) — Phase 1 · Foundation

- On-device wallet creation: Ed25519 keypair generated in the native iOS vault
  (Secure Enclave-protected Keychain); base58 Solana address returned to Dart.
- `Xend.configure` / `XendConfig` entry point.
- `XendWallet.create` / `load` / `delete`, `receive`, and `address`.
- Chain-agnostic public API (`Chain`, `Asset`, `Balance`, `TxHandle`, `TxStatus`, …) with a
  Solana-only implementation behind a chain-adapter seam.
- Sealed `XendError` hierarchy for exhaustive failure handling.
- Backend client for wallet registration (`POST /v1/wallets`).

Not yet implemented (throw `NotImplementedYet`): `send`, `balance`, `sign`, `watch`, `history`,
`restore`, `swap`, `bridge`. See the roadmap for the phase they land in.
