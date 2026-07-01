# Contributing to Xend

Thanks for your interest. Xend is built in the open, one shippable phase at a time.

## Ground rules

- **The signing boundary is sacred.** No change may put a private key into Dart, the backend,
  the network, a log, or plaintext on disk. If a PR touches `tx/`, `chain/`, `auth/`, or the
  native vault, it gets a security review.
- **Never hide the truth.** The SDK may hide the *mechanism* (blockhashes, commitment levels),
  never the *state*. Pending is pending.
- **Money is integers.** Amounts are base units (`BigInt` / `numeric`), formatted to decimals
  only at the UI edge — never `double`.
- **Honest status.** Unbuilt capabilities throw a typed `NotImplementedYet`, never fake success.

## Getting set up

See [`docs/05-GETTING-STARTED.md`](docs/05-GETTING-STARTED.md).

```bash
docker compose up -d --wait postgres
cd backend && cargo run          # backend on :8080
# in another shell:
cd packages/xend/example && flutter run
```

## Before you open a PR

```bash
# Backend
cd backend && cargo fmt && cargo clippy && cargo test

# SDK + example
cd packages/xend && dart format . && flutter analyze
cd example && flutter analyze && flutter test

# Native vault (types only, without a full iOS build)
cd packages/xend/ios/Classes && swiftc -typecheck Base58.swift SecureSigner.swift
```

## Commit style

Conventional commits (`feat(scope): …`, `fix:`, `docs:`, `chore:`, `test:`). Keep commits small
and legible — someone reading the history should be able to follow the build.

## Design decisions

Every non-obvious fork is recorded in [`docs/02-DECISIONS.md`](docs/02-DECISIONS.md). If your PR
changes a decision, update that file with the new reasoning in the same PR.
