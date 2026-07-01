//! Transaction handling: building unsigned transactions, validating signed ones,
//! broadcasting, tracking confirmation, and enforcing idempotency. This module never
//! signs — it assembles and relays; the device holds the key and signs.
//!
//! Idempotency is the core correctness property: a client attaches an `idempotency_key`
//! to every submission, the database enforces its uniqueness, and a duplicate returns
//! the original result instead of broadcasting again. Combined with the deterministic
//! signature of a signed transaction, a blind retry can never produce a double-send.

use axum::{extract::State, Json};
use base64::Engine;
use serde::{Deserialize, Serialize};

use crate::chain::{ChainAdapter, TransferIntent};
use crate::error::AppError;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct BuildRequest {
    pub from: String,
    pub to: String,
    /// Amount in base units (lamports for SOL), as a string to preserve full precision.
    pub amount: String,
    /// Token mint address, or omitted/null for the chain's native asset.
    pub mint: Option<String>,
}

#[derive(Serialize)]
pub struct BuildResponse {
    /// Base64-encoded unsigned transaction message for the device to sign.
    pub message: String,
    /// Unix timestamp (seconds) after which the transaction is no longer valid.
    pub valid_until: u64,
}

/// `POST /v1/tx/build` — assemble an unsigned transfer for the device to sign.
/// Delegates to the active [`ChainAdapter`], keeping this handler chain-agnostic.
pub async fn build(
    State(state): State<AppState>,
    Json(req): Json<BuildRequest>,
) -> Result<Json<BuildResponse>, AppError> {
    let amount: u128 = req
        .amount
        .parse()
        .map_err(|_| AppError::BadRequest("amount must be a base-unit integer".into()))?;

    let intent = TransferIntent {
        from: req.from,
        to: req.to,
        amount,
        mint: req.mint,
    };

    let unsigned = state.chain.build_transfer(&intent).await?;

    let message = base64::engine::general_purpose::STANDARD.encode(&unsigned.message);
    let valid_until = unsigned
        .valid_until
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    Ok(Json(BuildResponse { message, valid_until }))
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
pub async fn submit(_chain: &dyn ChainAdapter) -> Result<(), AppError> {
    Err(AppError::Network("tx::submit not implemented".into()))
}

/// `GET /v1/tx/:signature` — report a transaction's current status.
///
/// This is the authoritative answer to "did it actually happen?" and lets a client
/// resolve the ambiguity of a timed-out request: on a blockchain a timeout may hide a
/// success, so a client should query status rather than assume failure.
///
/// Not yet implemented.
pub async fn status(_chain: &dyn ChainAdapter) -> Result<(), AppError> {
    Err(AppError::Network("tx::status not implemented".into()))
}
