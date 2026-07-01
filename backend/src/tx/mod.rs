//! The heart of the system. Builds unsigned transactions, validates signed ones,
//! broadcasts, tracks confirmation, and enforces idempotency. It **signs nothing** —
//! it assembles and relays; the device signs.
//!
//! Idempotency is the load-bearing correctness property (docs/04-SECURITY.md T10):
//! a client attaches an `idempotency_key` to every submit; the DB enforces uniqueness;
//! a duplicate returns the first result instead of broadcasting again. Combined with
//! Solana's deterministic signatures, a blind retry can never double-send.

use crate::chain::ChainAdapter;
use crate::error::AppError;

/// `POST /v1/tx/build` — assemble an unsigned transfer for the device to sign.
/// Delegates entirely to the [`ChainAdapter`]; the tx service is chain-agnostic.
pub async fn build(_adapter: &dyn ChainAdapter /*, req: BuildRequest */) -> Result<(), AppError> {
    // 1. validate the intent (recipient well-formed, amount > 0, funds sufficient).
    // 2. adapter.build_transfer(intent) → UnsignedTx.
    // 3. persist a `building` row (signature NULL) so a crash mid-flight is recoverable.
    // 4. return the serialized message (base64) + valid_until to the SDK.
    Err(AppError::Network("tx::build not implemented".into())) // Phase 2
}

/// `POST /v1/tx/submit` — broadcast a signed transaction, exactly once.
///
/// ```text
/// on submit(signed_tx, idem_key):
///   existing = db.find_by_idem(idem_key)
///   if existing: return existing.result          // already handled, no double-send
///   record = db.insert(idem_key, status=pending)  // UNIQUE(idem_key) guards the race
///   adapter.validate_signed(signed_tx)?
///   sig = adapter.broadcast(signed_tx)            // re-broadcast of same bytes is safe
///   db.update(record, signature=sig)
///   subscribe_for_confirmation(sig)               // notify/ hub, not polling
///   return { signature: sig }
/// ```
pub async fn submit(
    _adapter: &dyn ChainAdapter, /*, req: SubmitRequest */
) -> Result<(), AppError> {
    Err(AppError::Network("tx::submit not implemented".into())) // Phase 2
}

/// `GET /v1/tx/:signature` — the source of truth for "did it actually happen?".
/// Lets a client resolve timeout ambiguity without assuming (never treat a timeout
/// as failure — on a blockchain it may be success you didn't hear about).
pub async fn status(
    _adapter: &dyn ChainAdapter, /*, signature: String */
) -> Result<(), AppError> {
    Err(AppError::Network("tx::status not implemented".into())) // Phase 2
}
