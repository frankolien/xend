# 05 · Getting Started (v0.1 — Phase 1)

Run the backend + the example wallet app, tap **Create wallet**, and see a real Solana
address that persists across restarts and is registered in Postgres.

## Prerequisites
- Flutter (3.22+), Xcode + an iOS simulator
- Docker (for Postgres), Rust (stable)

## 1. Backend + database
```bash
cd xend
docker compose up -d --wait postgres          # Postgres on :5432 (Redis too)
cd backend
cargo run                                      # binds 0.0.0.0:8080, runs migrations
```
Smoke-test it:
```bash
curl -s localhost:8080/health                  # → ok
```

## 2. The example app
```bash
cd packages/xend/example
flutter pub get
open -a Simulator                              # boot an iOS simulator
flutter run                                    # pick the simulator
```
The app is configured for `http://localhost:8080` (the simulator reaches the host via
localhost). On a **physical device**, change `backendUrl` in `example/lib/main.dart` to
your machine's LAN IP.

## 3. Prove the Phase 1 checkpoint
1. Tap **Create wallet** → a base58 Solana address appears. The private key was generated
   in the native vault and never crossed into Dart.
2. Confirm the pubkey landed in Postgres:
   ```bash
   docker compose exec postgres psql -U xend -d xend -c \
     "select pubkey, label, created_at from wallets;"
   ```
3. Fully close and relaunch the app → the **same address** loads (survives restart).

## What works today vs. what doesn't
- ✅ create / load / delete wallet, pubkey registration, base58 validation, typed errors.
- ⛔ send / balance / sign / watch → throw `NotImplementedYet` (Phase 2+). This is honest,
  not a bug: the SDK never pretends a capability exists before it does.

## Verify the abstraction hasn't leaked
```bash
cd packages/xend/example
grep -rniE 'solana|blockhash|ed25519|rpc' lib/    # → zero hits
```
The sample app knows nothing about the chain. That's the whole point (docs/00-PRD.md #4).
