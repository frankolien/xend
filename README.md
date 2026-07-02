# Xend

**Embedded, non-custodial payments for mobile apps.** Keys never leave the device; the
backend is a witness, not a custodian.

> Long-term North Star: *the Stripe for decentralized apps* — `await xend.send(...)` and the
> SDK handles keys, signing, chains, confirmation, and recovery. See
> [`docs/03-ROADMAP.md`](docs/03-ROADMAP.md).
>
> **What this repo is today (v0.1):** a real, buildable slice that proves the thesis — a
> Solana non-custodial wallet + SDK that **sends real value on devnet**. Flutter + native iOS
> signing + a Rust backend witness, with embedded onboarding, iCloud recovery, gasless fees,
> and `.sol` name resolution all working. Everything else in the North Star is roadmap, and is
> labeled as such. We do not pretend to have built what we have not.

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
│   └── xend/               # THE PRODUCT: a Flutter plugin package.
│       ├── lib/                #   Dart: chain-agnostic API, channel + backend client
│       ├── ios/Classes/        #   THE VAULT (Swift): four methods, keys live here
│       └── example/            #   sample app — imports ONLY package:xend
└── backend/                    # THE WITNESS: Rust (Axum/Tokio/sqlx). Never signs.
```

## Design philosophy (first listed wins on conflict)

1. **Keys never leave the device.** The backend is non-custodial by construction.
2. **The device signs; the server witnesses.** Authority on the phone, knowledge on the server.
3. **Hide the chain, never the truth.** Pending is pending. The SDK absorbs mechanism, not state.
4. **Fail loud and recoverable.** Every failure is typed and either retried safely or surfaced honestly.
5. **Boring where it counts.** Crypto, money math, idempotency use dull, proven approaches. Save cleverness for DX.

## Status

Proven end-to-end on Solana **devnet** — real transfers, finalized on-chain. iOS only; not
audited; no real funds.

| Component | State |
|---|---|
| Docs & decisions | Drafted; all 10 forks + D0 decided |
| Backend (Rust) | **✅** Clean layered adapter/handlers/store; build → submit → status, balance, history, **`.sol` resolution**, **gasless paymaster**; gateway (API-key auth, rate limit, request-id); idempotent. Proven against real Postgres + devnet |
| Native vault (Swift) | **✅** Ed25519 key from BIP-39/SLIP-0010 (spec-verified), Secure Enclave-wrapped, **Face ID signing**; **iCloud Keychain** recovery. Compiles via Xcode/CocoaPods into the app |
| SDK (Dart) | **✅** `create`/`load`/`restore`/`delete`/`send`/`balance`/`watch`/`history`/`sign`/`resolveName`; SOL + SPL tokens; gasless + SNS transparent. Analyzes clean |
| Flutter example | **✅** Full wallet UI on iOS simulator (send, balance, live watch, history); imports only `package:xend` |

**Built & proven:** embedded silent onboarding, on-device Face ID signing, SOL + SPL/USDC
transfers, confirmation tracking, history, iCloud recovery, **gasless** fee sponsorship, and
**`.sol`** name resolution — all sending real value on devnet.

**Roadmap:** Android, passkey/Squads Grid smart accounts, Solana Pay, session keys, WSS push
for `watch()`, `swap`/`bridge`. See [docs/03-ROADMAP.md](docs/03-ROADMAP.md).

### Verify the backend yourself
```bash
cd backend && cargo run                      # binds :8080 (needs Postgres + a devnet RPC)
curl -s localhost:8080/health                # → ok
curl -s 'localhost:8080/v1/resolve?name=bonfida.sol'   # → {"name":...,"address":...}
```
Turn on gasless by setting `XEND_PAYMASTER_SECRET` (mint one with
`cargo run --bin paymaster_keygen`, then airdrop it devnet SOL); the backend logs
`gasless enabled` and every `send` is then fee-sponsored.
