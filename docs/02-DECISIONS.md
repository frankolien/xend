# 02 · Decisions

The PDF hands forks, not answers. Here are the calls, each with the reasoning I'd defend at
3am. Format: **Call** · **Why** · **Cost we accept**. Override any of these — but write the new
reason before you build past it.

---

### D0 · Chain-agnostic API, Solana-only implementation *(new — the bridge decision)*

**Call:** Public API is generic (`send({chain, asset, to, amount})`, `chain` defaults to
`Chain.solana`). Backend has a `ChainAdapter` trait; v0.1 ships exactly one impl, `SolanaAdapter`.
**Why:** the North Star is multi-chain; the PDF is Solana-only. Shaping the *surface* generic now
costs one enum + one trait. Not doing it means a breaking API rev the first time chain #2 lands —
and breaking a payments SDK's signature is a forever-cost. Absorb mechanism, not the fact that
chains differ.
**Cost:** a hair more indirection in v0.1 for a chain we haven't shipped. Cheap insurance.

### D1 · Who broadcasts — **backend**

**Why:** payments product. Central idempotency, retry, and indexing live in one place; the device
never holds RPC credentials; the signed bytes are relayed, not re-created. Device-direct is one
hop faster but scatters retry/index logic and leaks RPC creds onto phones.
**Cost:** one extra hop; backend must be up to broadcast. Acceptable — and mitigated by the queue
at scale (D10).

### D2 · Face ID reason string — **structured summary, opaque to the vault**

**Call:** The SDK composes a human-readable reason (`"Send 2 USDC to Ada…9f3"`) and passes it as
an **opaque display string** to `signMessage`. Native shows it; native does **not** parse the tx.
**Why:** the reason string is the last line of defense against a malicious caller signing
something unintended — the user authenticates *intent*, not just the act. But teaching the vault to
parse transactions widens its attack surface. Splitting it (SDK composes, native only displays)
gets intent-auth without making the vault a transaction parser.
**Cost:** the summary is only as trustworthy as the SDK that composed it. Backend attests amounts;
SDK renders; native displays. Defense in depth, not a single gate.

### D3 · `biometryCurrentSet` vs `biometryAny` — **`biometryCurrentSet` (strict)**

**Why:** security-first (principle 1 beats principle 4). If an attacker enrolls their face, the key
becomes unusable — exactly what we want on a money key. Seed-phrase restore is the recovery
backstop.
**Cost:** a legitimate user who re-enrolls Face ID must restore from seed. Real UX friction. We pay
it, and make restore excellent (that's why `restore(mnemonic)` is v0.1, not roadmap).

### D4 · Auth model — **signature-based (nonce challenge)**

**Call:** `POST /auth/challenge` → single-use nonce; device signs; `POST /auth/verify` → session
token. Optional account layer is roadmap.
**Why:** embeddable SDK; keyless on the server; ties identity to the key the user already controls;
no password to breach. Also kills auth-replay for free (nonce is single-use).
**Cost:** no human-account features (email recovery, multi-device) in v0.1. Fine — wallet identity
is the v0.1 need.

### D5 · Index strategy — **the free uniques + one history index; defer the rest**

**Call now:** `UNIQUE(idempotency_key)` and `UNIQUE(signature)` (they're correctness constraints,
not optional) + a btree on `(wallet_id, created_at DESC)` for history — the hottest read path.
**Defer:** partial/status indexes until a query plan hurts.
**Why:** the uniques are load-bearing for idempotency (D+§10); history is the query users hit every
open. Everything else is premature until `EXPLAIN` says otherwise.
**Cost:** a possible future migration for a status index. Cheap and reversible.

### D6 · Which commitment is "done" — **`confirmed` = success, silently upgrade to `finalized`; threshold gates high value**

**Call:** UI shows success at `confirmed`; SDK keeps the `watch` stream alive and emits `finalized`
when rooted. For amounts over a configurable threshold, withhold the success checkmark until
`finalized`. SDK **exposes both** so the consuming app decides.
**Why:** `confirmed` is ~1–2s and honest for everyday UX; `finalized` is irreversible but slower.
Snappy default, honest state, and the app can be conservative with big transfers.
**Cost:** two-stage UX to implement. Worth it — this *is* "hide the chain, not the truth."

### D7 · SDK auto-recovery — **transparent for `BlockhashExpired` (but re-prompt Face ID), bounded retry for `NetworkError`, everything else surfaced**

**Call:** `BlockhashExpired` → SDK auto-rebuilds + **re-prompts Face ID** (never signs silently over
new bytes), capped at N auto-rebuilds. `NetworkError` → auto-retry with idempotency + exp. backoff,
surface after N. `InsufficientFunds`/`InvalidRecipient` → terminal, never retried. Policy documented
in the SDK's dartdoc.
**Why:** invisible magic in a money SDK erodes trust faster than a little verbosity. Auto-recovery is
fine only where it's provably safe (idempotency makes network retry safe; re-prompt keeps signing
honest).
**Cost:** a second Face ID prompt the developer didn't ask for on expiry. Documented, bounded, honest.

### D8 · Chain subscriptions — **backend fan-out**

**Why:** device holds one socket to us; RPC creds stay server-side; we coalesce duplicate
subscriptions and can layer push notifications for backgrounded apps. Device-direct is faster to
prototype but drains battery and scatters creds.
**Cost:** we build the multiplexer hub. It's the §9 work; worth it for a product.

### D9 · Rate limits — **per-tier, `build` cheaper ceiling than `submit`; numbers committed here**

**Call (starting numbers, documented so they're not a 3am mystery):** free tier —
`build` 60/min, `submit` 20/min, `auth/challenge` 10/min, per session **and** per IP, Redis-backed.
Return `429` + `retryAfter` → surfaces as `RateLimited(retryAfter)`.
**Why:** `build` is read-ish and cheap; `submit` is a real broadcast against finite RPC quota. Split
ceilings protect the budget without punishing readers. Undocumented limits are future incidents.
**Cost:** power users/merchants may need higher tiers — that's the tiering, added when demanded.

### D10 · When to introduce the queue — **trigger on contention, instrument from P5**

**Call:** stay synchronous through v0.1. Introduce a queue (Redis Streams/NATS) when
**confirmation-tracking work starts contending with request handling**. Instrument the signal now:
gauge `pending_confirmations_tracked` and request-handler saturation from Phase 5.
**Why:** the queue is a complexity multiplier. Too early = an async pipeline for 10 tx/min. Too late
= request threads block on confirmation subscriptions and submits time out. Let the metric decide.
**Cost:** we must actually watch the gauge. Cheap; it's one dashboard line.
