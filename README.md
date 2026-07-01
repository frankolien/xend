# Xend

**Embedded, non-custodial payments for mobile apps.** Keys never leave the device; the
backend is a witness, not a custodian.

> Long-term North Star: *the Stripe for decentralized apps* — `await xend.send(...)` and the
> SDK handles keys, signing, chains, confirmation, and recovery. See
> [`docs/03-ROADMAP.md`](docs/03-ROADMAP.md).
>
> **What this repo is today (v0.1):** a real, buildable slice that proves the thesis — a
> Solana non-custodial wallet + SDK, Flutter + native iOS signing + a Rust backend witness.
> Everything else in the North Star is roadmap, and is labeled as such. We do not pretend to
> have built what we have not.

---

## The one hard rule

There is a **signing boundary**. The Ed25519 private key is generated on the device, stored
as ciphertext whose unwrap key lives in the Secure Enclave, and decrypted into RAM only for
the microseconds of a signature — always behind Face ID. It never crosses into Dart, never
reaches the backend, never touches disk in plaintext. Every design choice defers to this.

A total backend breach leaks **public keys and transaction history**. It cannot move a cent.

## Repository layout (monorepo)

```
xend/
├── docs/                       # the design, and the decisions we actually made
│   ├── 00-PRD.md               # what v0.1 is and is not
│   ├── 01-ARCHITECTURE.md      # tiers, signing boundary, module seams
│   ├── 02-DECISIONS.md         # the 10 forks — with our calls + reasoning
│   ├── 03-ROADMAP.md           # v0.1 → v3.0, honestly scoped
│   ├── 04-SECURITY.md          # threat model + mitigations
│   └── 05-GETTING-STARTED.md   # run the backend + example app
├── packages/
│   └── xend_sdk/               # THE PRODUCT: a Flutter plugin package.
│       ├── lib/                #   Dart: chain-agnostic API, channel + backend client
│       ├── ios/Classes/        #   THE VAULT (Swift): four methods, keys live here
│       └── example/            #   sample app — imports ONLY package:xend_sdk
└── backend/                    # THE WITNESS: Rust (Axum/Tokio/sqlx). Never signs.
```

## Design philosophy (first listed wins on conflict)

1. **Keys never leave the device.** The backend is non-custodial by construction.
2. **The device signs; the server witnesses.** Authority on the phone, knowledge on the server.
3. **Hide the chain, never the truth.** Pending is pending. The SDK absorbs mechanism, not state.
4. **Fail loud and recoverable.** Every failure is typed and either retried safely or surfaced honestly.
5. **Boring where it counts.** Crypto, money math, idempotency use dull, proven approaches. Save cleverness for DX.

## Status

| Component | State |
|---|---|
| Docs & decisions | Drafted; all 10 forks + D0 decided |
| Backend (Rust) | **✅ Phase 1**: builds; `/health` + `POST /v1/wallets` (base58-validated, idempotent) proven against real Postgres |
| Native vault (Swift) | **✅ Phase 1**: Ed25519 keygen (verified) + base58 + Keychain; compiles via Xcode/CocoaPods into the app. `signMessage` = Phase 2 |
| SDK (Dart) | **✅ Phase 1**: `create`/`load`/`delete` wired to native + backend; analyzes clean; widget tests pass. `send`/`balance`/`watch` = Phase 2+ |
| Flutter example | **✅ builds** for iOS simulator; imports only `package:xend_sdk`. Final tap-test: run per [docs/05](docs/05-GETTING-STARTED.md) |

**Next: Phase 2** — the signing path (`tx/build` → Face-ID `signMessage` → `tx/submit` → confirm) on Solana devnet.

Nothing here signs or moves money yet. That is Phase 2. See the roadmap.

### Verify Phase 1 backend yourself
```bash
docker compose up -d --wait postgres
cd backend && cargo run                      # binds :8080
curl -s localhost:8080/health                # → ok
curl -s -X POST localhost:8080/v1/wallets \
  -H 'content-type: application/json' \
  -d '{"pubkey":"7HEqBe5XA9T9K1T9BDz4HbBiwYsc56W2gSQ8jWsntFkX","label":"Main"}'
```
