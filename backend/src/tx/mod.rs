//! Transaction handling: building unsigned transactions, validating signed ones,
//! broadcasting, tracking confirmation, and enforcing idempotency. This module never
//! signs — it assembles and relays; the device holds the key and signs.
//!
//! Idempotency is the core correctness property: a client attaches an `idempotency_key`
//! to every submission, the database enforces its uniqueness, and a duplicate returns
//! the original result instead of broadcasting again. Combined with the deterministic
//! signature of a signed transaction, a blind retry can never produce a double-send.

use crate::chain::ChainAdapter;
use crate::error::AppError;

/// `POST /v1/tx/build` — assemble an unsigned transfer for the device to sign.
/// Delegates to the [`ChainAdapter`], keeping this module chain-agnostic.
///
/// Not yet implemented. The steps:
///   1. Validate the intent (recipient well-formed, amount positive, funds sufficient).
///   2. Build the unsigned transaction via the adapter.
///   3. Persist a `building` record (with a null signature) so an interruption is
///      recoverable.
///   4. Return the serialized message and its validity deadline.
pub async fn build(_adapter: &dyn ChainAdapter) -> Result<(), AppError> {
    Err(AppError::Network("tx::build not implemented".into()))
}

/// `POST /v1/tx/submit` — broadcast a signed transaction exactly once.
///
/// Not yet implemented. The intended logic:
///
/// ```text
/// on submit(signed_tx, idempotency_key):
///   existing = db.find_by_idempotency(idempotency_key)
///   if existing: return existing.result                 // already handled; no double-send
///   record = db.insert(idempotency_key, status=pending) // UNIQUE constraint guards the race
///   adapter.validate_signed(signed_tx)?
///   signature = adapter.broadcast(signed_tx)            // re-broadcasting the same bytes is safe
///   db.update(record, signature)
///   subscribe_for_confirmation(signature)
///   return { signature }
/// ```
pub async fn submit(_adapter: &dyn ChainAdapter) -> Result<(), AppError> {
    Err(AppError::Network("tx::submit not implemented".into()))
}

/// `GET /v1/tx/:signature` — report a transaction's current status.
///
/// This is the authoritative answer to "did it actually happen?" and lets a client
/// resolve the ambiguity of a timed-out request: on a blockchain a timeout may hide a
/// success, so a client should query status rather than assume failure.
///
/// Not yet implemented.
pub async fn status(_adapter: &dyn ChainAdapter) -> Result<(), AppError> {
    Err(AppError::Network("tx::status not implemented".into()))
}
