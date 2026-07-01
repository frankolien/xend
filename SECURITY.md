# Security Policy

Xend is a **non-custodial** wallet SDK: private keys are generated on the device, stored as
ciphertext protected by the Secure Enclave, and never leave the device. The backend never
holds, sees, or can reconstruct a private key.

## Status

**Pre-1.0. Not audited. Not for production or real funds.** v0.1 targets Solana **devnet**.
Do not use this to hold value you are unwilling to lose until it has been independently audited.

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

- Preferred: GitHub → **Security → Report a vulnerability** (private advisory) on this repo.
- Or email: `security@entrypointlabs.dev` *(update to your real address)*.

Include repro steps and impact. We aim to acknowledge within 72 hours and to coordinate a fix
and disclosure timeline with you.

## Scope we care about most

- Any path where a private key, seed, or plaintext key material could leak (logs, crash reports,
  the platform channel, the network, a backup).
- Signature spoofing / blind-signing (approving a transaction the user did not intend).
- Idempotency / replay flaws that could cause a double-send or lost funds.
- Auth, session, or rate-limit bypass.

See [`docs/04-SECURITY.md`](docs/04-SECURITY.md) for the full threat model.

## What Xend will never do

Xend **cannot** produce your seed phrase — it is non-custodial by construction. No one from the
project, and no support channel, will ever ask you for your seed phrase or private key. Anyone
who does is attacking you.
