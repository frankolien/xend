# 03 · Roadmap — from a Solana wallet to "the Stripe for dApps"

Honest scoping. Each version is *shippable and demonstrable*, not a slide. The mega-brief's
enormous surface (8 chains, swap/bridge/on-ramp, 6 platforms, plugin marketplace) is the destination
— sequenced here so we're never blocked on two hard things at once.

> A note on effort: v1.0 alone is a multi-quarter effort for a small team. The full North Star is a
> multi-year, multi-team company. Naming that is not pessimism — it's the difference between a plan
> and a wish.

---

## v0.1 — *Foundation & proof* (the PDF's Xend Lite)
**Goal:** prove the thesis on one chain. **Chain:** Solana. **Clients:** Flutter + iOS.
**Ships:** create/restore/balance/send/receive/watch/history, typed errors, crash-and-network
resilience (exactly-once), backend witness, WSS fan-out.
**Milestones:** the six phases in [`../docs`](.) / PDF §13. Each has an observable Build Checkpoint.
**Risks:** Secure Enclave wrapping done wrong (money-destroying); blockhash-expiry race; leaking a
crypto import into the sample app. Mitigation: §04 security review before P2 "done"; resilience
checkpoint gates P4.

## v0.5 — *Hardened SDK & Android*
**Goal:** the SDK is genuinely reusable and cross-platform on mobile.
**Features:** Android native vault (Kotlin: StrongBox/TEE + BiometricPrompt, mirroring the Swift
contract), push notifications (backend `accountSubscribe`-driven), address book + QR receive/pay,
price display, structured logging + metrics + rate limits + cert pinning (PDF Phase 6).
**Risks:** Android keystore ≠ Secure Enclave semantics; the four-method contract must hold across
both. Mitigation: the native contract is the same; only the impl differs.

## v1.0 — *Multi-chain via the adapter seam*
**Goal:** flip on EVM. **Chains:** + Ethereum, Base, Arbitrum, Optimism, Polygon, BNB via
`ChainAdapter` (D0). secp256k1 signing path in the vault alongside Ed25519. ENS resolution.
Cross-chain *address book*, not yet routing.
**Features:** NFT transfers, gas estimation, transaction **simulation** (dry-run before signing —
huge for intent verification), human-readable signing prompts per chain.
**Risks:** each chain is its own confirmation/finality model — the `watch` abstraction must not
lie across them. Mitigation: `ChainAdapter` owns status mapping; the SDK contract stays honest.

## v2.0 — *Money movement beyond send*
**Goal:** the verbs that make it "Stripe."
**Features:** `swap` (aggregator integration), `bridge` (cross-chain routing), fiat **on/off-ramp**
(partner KYC/provider), payment links, contact payments, gas **sponsorship** (paymaster / fee
relay), WalletConnect, deep linking, portfolio API, history/analytics.
**Risks:** custody/regulatory surface (on-ramp, sponsorship) — legal, not just technical; swap/bridge
MEV & slippage honesty. Mitigation: partners own custody/KYC; SDK never hides slippage or route risk.

## v3.0 — *Platform & ecosystem*
**Goal:** a platform others build on.
**Features:** React Native + Web + Unity bindings over the same core, **plugin system** (third-party
chains/features) with a capability-scoped, sandboxed, signed-manifest model (see §04 — malicious
plugins are a first-class threat), on-ramp marketplace, developer dashboard, SLAs, multi-tenant.
**Risks:** plugin security is existential — a malicious plugin that sees a signing request is game
over. Mitigation: plugins never touch the signing boundary; capability scopes; code-signed manifests;
no plugin runs in the vault's process.

---

## Sequencing principle
Boring scaffolding before cryptography. One wallet before reliability. Correctness before scale.
One chain before many. Send before swap. Mobile before web. We earn each expansion with a working,
demonstrable predecessor — never with architecture fashion.
