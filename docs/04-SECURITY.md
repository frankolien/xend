# 04 · Security Model & Threat Model

The load-bearing guarantee: **the private key is generated on-device, stored as ciphertext whose
unwrap key never leaves the Secure Enclave, decrypted only transiently behind biometrics, and present
in plaintext only in RAM during a signature.** The backend, the network, and the SDK's Dart layer
never see it. A full server breach leaks public keys and history — embarrassing, not catastrophic. No
funds move.

## Key storage, precisely (iOS)

Solana signs with **Ed25519**; Apple's Secure Enclave only does **P-256 (secp256r1)**. So the enclave
**cannot be the signer** — it is the *protector*:

- **At rest:** `ciphertext(ed25519_priv)` wrapped by an AES key, which is sealed by a P-256 key held
  *inside* the enclave (`kSecAttrTokenIDSecureEnclave`). Stored as a Keychain item with
  `kSecAccessControlBiometryCurrentSet` + `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
  `ThisDeviceOnly` keeps the ciphertext off iCloud backups.
- **At signing:** Face ID (`LAContext`) → enclave unwraps AES key → AES-GCM decrypts Ed25519 key into a
  locked RAM buffer → `ed25519_sign(bytes)` → **overwrite** the buffer (do not just free) → return the
  64-byte signature. Plaintext key exists for milliseconds.

## Threat model

| # | Threat | Vector | Mitigation |
|---|---|---|---|
| T1 | **Key compromise at rest** | Stolen/jailbroken phone reads storage | Ciphertext only; unwrap key is in enclave hardware, non-exportable even on jailbreak. Biometric gate on decrypt. |
| T2 | **Key exfil via the channel** | Key crosses platform channel as data → Dart heap → crash log | Channel passes *bytes to sign* and *signatures*, never keys. `walletId` is a handle, not the key. |
| T3 | **Stolen phone, unlocked** | Attacker signs without the owner | Authenticate **every** signature; no reuse grace window on a payments key. At the prompt they meet *your* face. |
| T4 | **Signature spoofing / blind signing** | Malicious caller gets user to approve a tx they didn't mean | Human-readable reason string (D2): user approves *intent*. v1.0 adds simulation (dry-run) before signing. |
| T5 | **On-chain replay** | Re-broadcast an old signed tx | Solana's recent-blockhash: valid ~60–90s, once. Old bytes are long-expired. |
| T6 | **API replay** | Attacker replays a captured `submit` | Idempotency key (dedupes to a no-op) + authed, **TLS-pinned** sessions (fails auth). |
| T7 | **Auth replay** | Reuse a captured login signature | Challenge is a **single-use nonce** (D4). |
| T8 | **Phishing** | Fake app/site asks user to sign or reveal seed | SDK never asks for the seed to *operate*; restore is explicit and rare. Reason string names the real recipient. Cert pinning stops MITM downgrade. User education in docs. |
| T9 | **MITM / rogue CA** | Intercept traffic, swap unsigned tx | TLS everywhere (incl. staging) + **certificate pinning** on backend and RPC provider. |
| T10 | **Double-send / lost funds on failure** | Crash/network mid-send | Idempotency key + deterministic signature = retry-safe. Crash recovery reconciles pending on relaunch. Rebuild **only** on true blockhash expiry. Invariant: exactly one tx, or none. |
| T11 | **Rate-abuse / RPC drain** | Hostile client hammers `build`/`submit` | Redis rate limits per session+IP, `submit` tighter than `build` (D9). |
| T12 | **Malicious plugin** *(v3.0)* | Third-party plugin sees a signing request or key | Plugins **never** touch the signing boundary or run in the vault's process. Capability-scoped, code-signed manifests, sandboxed. Signing stays native-only, always. |
| T13 | **Supply-chain / dependency attack** | Compromised crate/pub/pod pulls key or exfils | Pin + audit deps (`cargo audit`, `pub` advisories, SPM checksums). Vet the Ed25519 lib specifically — it's the crypto core. Minimal dependency surface in the vault. Reproducible builds where possible. Lockfiles committed for the shipping binary. |
| T14 | **Social engineering (seed extraction)** | Support impersonation, "verify your wallet" scams | The system *cannot* produce the seed (non-custodial) — support literally can't ask for what would help an attacker. Docs teach: Xend never needs your seed to help you. |
| T15 | **Server breach** | Full DB + code exfil | Leaks public keys + history only. No key material exists server-side to steal (schema has no such column — that absence is the design). |

## What we log vs never log

**Never:** private keys, seed phrases, full signed payloads with PII, biometric data. **Always:**
request IDs (trace a payment end-to-end), status transitions, error classes. A single payment is
traceable by request ID across device and backend without any secret appearing.

## Review gates
- No Phase 2 ("done") without a security pass on the enclave wrapping + zeroing.
- No v1.0 without the secp256k1 path reviewed to the same bar as Ed25519.
- `security-review` on every diff that touches `tx/`, `chain/`, `auth/`, or the native vault.
