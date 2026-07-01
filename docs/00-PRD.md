# 00 · Product Requirements — Xend v0.1

**Status:** Draft. **Scope owner:** you. **Rule:** if it isn't listed under *In scope*, it is
roadmap, not v0.1.

## Problem

A mobile developer who wants to move value has four sharp edges: **key custody** (the wrong
answer is "our backend"), **on-device signing** behind biometrics, **truth about the chain**
("did it go through?" is not a boolean), and **reusability** (solving it as a library a
stranger adopts in an afternoon). Xend collapses these into an SDK call while keeping keys on
the device.

## The two products, one name

- **The SDK is the product.** A Dart package a stranger integrates in an afternoon.
- **The wallet is the proof.** A thin Flutter skin over the SDK. If the SDK is well-shaped,
  the wallet — and the next app — is nearly free.

## In scope for v0.1

| Capability | Definition of done |
|---|---|
| Create wallet | On-device Ed25519 keypair; base58 address shown; pubkey registered in Postgres. Key never leaves device. |
| Restore wallet | From seed phrase → same address. |
| Balance | SOL + SPL token balance via backend (RPC). |
| Send (SOL + SPL) | Build unsigned → Face ID sign on device → backend broadcasts → confirm. Integer base units end-to-end. |
| Receive | Address + reconcile-on-foreground so incoming funds appear. |
| Watch | Live `pending → confirmed → finalized` stream, no polling in the app. |
| History | Paginated, from backend index. |
| Typed errors | Sealed `XendError`; every failure is a nameable variant. |
| Resilience | Crash/network at any send stage → exactly one on-chain tx, or none. Never two, never lost funds. |

**Chain:** Solana only. **Client:** Flutter + iOS (Swift). **Backend:** single Rust binary.

## Explicitly OUT of scope for v0.1 (→ roadmap)

EVM/Bitcoin/other chains · swap · bridge · fiat on/off-ramp · NFT transfers · gas sponsorship ·
tx simulation · WalletConnect · ENS/SNS · Android/RN/Web/Unity · push notifications · plugin
marketplace. The **public API is shaped to accept these later** (chain-agnostic signatures,
`ChainAdapter` seam) — see [`02-DECISIONS.md#d0`](02-DECISIONS.md).

## Non-negotiable invariants (test these, not the compiler)

1. **No plaintext key** ever on disk, in a log, in Dart's heap, or over the network.
2. **A crash never loses money and never double-sends.** (Idempotency + deterministic signatures.)
3. **The SDK never lies about state.** Pending is pending; `confirmed ≠ finalized` is exposed.
4. **Consuming app imports zero crypto/RPC packages.** Grep for `solana|ed25519|blockhash`
   outside the SDK → zero hits. If the sample app must learn what a blockhash is, the
   abstraction has leaked.

## Success metric

A developer, starting from a blank Flutter app and reading only Getting Started, can
`create → address → send → watch(confirmed)` in **under 30 minutes**, importing only
`package:xend`.
