# 01 · Architecture

## Three tiers, one boundary

```
DEVICE (authority)                 │ BACKEND (knowledge)          │ CHAIN
                                   │                              │
  Flutter UI ─calls→ Xend SDK      │  API Gateway                 │
                        │          │   (TLS·authn·rate-limit)     │
                 platform channel  │        │                     │
                        ▼          │   Auth·Wallet·Tx·Notify      │  Solana
  iOS Native (Swift)               │        │        │           │  validators
   Keychain · Secure Enclave       │   Postgres    Redis          │  (RPC·WSS)
   Face ID · Ed25519 sign          │                              │
   ── private key lives here ──    │                              │
                                   │                              │
        ╎ SIGNING BOUNDARY · the private key never crosses this line ✗
```

The backend receives only **public keys, unsigned tx requests, and already-signed tx** —
never key material.

## Mobile: three layers, dependencies point down only

| Layer | Owns | Must never |
|---|---|---|
| **UI** (Flutter) | Rendering, input, state, calling SDK, reacting to SDK streams | Import crypto/RPC, build a tx, touch the platform channel |
| **SDK** (Dart) | Public API, tx assembly, serialization, backend HTTP/WS, orchestrating native | Hold key *bytes*. It handles key *handles* (`walletId`), never bytes |
| **Native** (Swift) | Keygen, encrypted storage, biometric prompt, Ed25519 signature, zeroing RAM | Know your backend, API, or business logic. It signs bytes; asks no questions |

**Why the SDK layer exists (not UI→native direct):** the SDK is the reuse boundary. Same Dart
package powers your wallet and a stranger's app. It's a *product* boundary, not tidiness.

### The native surface — four methods, and only four

Channel `ai.xend/secure` (Flutter `MethodChannel`):

```
generateKeyPair(walletId)      → base58 pubkey; stores private securely
signMessage(walletId, bytes)   → prompts Face ID; returns 64-byte signature
getPublicKey(walletId)         → base58 pubkey; no biometric
deleteKey(walletId)            → wipes key material for this wallet
```

The key appears in **neither** the arguments nor the return of any method. The moment a key
crosses the channel as data, it's in Dart's heap and possibly a crash log. Discipline: the
native side *has* the key, identified by `walletId`; it never *hands it over*.

## Backend: one binary, five services' worth of seams

MVP is a single Rust binary (Tokio + Axum + sqlx + a Solana RPC/WSS client). Module boundaries
are drawn **now** exactly where service boundaries will later fall — so "extract the tx
service" is moving a folder, not untangling yarn.

```
backend/src/
  main.rs      wires router, db pool, rpc client, ws hub
  gateway/     middleware: auth, rate-limit, request-id      (bouncer, not brain)
  auth/        challenge/verify, session tokens
  wallet/      register pubkey, balances (RPC)               (public keys only)
  tx/          build · validate · submit · confirm · idempotency   ← the heart
  notify/      ws hub, event fan-out
  chain/       ChainAdapter trait + SolanaAdapter            ← the multi-chain seam
  db/          sqlx queries + migrations
  error.rs     one AppError enum → HTTP status mapping
```

Backend powers are strictly bounded by the signing boundary: read the chain, build unsigned
tx, relay signed tx, remember what happened. **It cannot sign.**

## The multi-chain seam (`chain/`) — the bridge to the North Star

v0.1 implements Solana only, but the *shape* is generic. `ChainAdapter` is the single interface
every chain plugs into: build an unsigned transfer, validate a signed blob, broadcast, and map
a signature to a status. The SDK's public API is likewise chain-agnostic (`send({chain, asset,
to, amount})`, defaulting to Solana). Adding Base or Bitcoin later means implementing one trait
+ one adapter — **not** rewriting the SDK. This is decision **D0**; see `02-DECISIONS.md`.

## Canonical send (every arrow is a contract)

1. UI calls `sdk.send(...)`.
2. SDK → backend **build** (fresh blockhash, token accounts, fee/priority).
3. Backend returns serialized **unsigned** tx.
4. SDK → native across channel; Face ID; decrypt key to RAM; sign; **zero** key.
5. SDK → backend **submit** (central idempotency, retry, index).
6. Backend broadcasts; records signature; subscribes for confirmation.
7. Confirmation → backend pushes WSS event → SDK updates stream → UI shows "confirmed."

The blockhash is a **clock** (~60–90s / ~150 slots). Everything after step 2 races it. Handling
that race correctly is Phase 4, and it is where toy wallets die.
