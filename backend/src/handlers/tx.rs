//! Build, submit, and status endpoints. Signing happens on the device, not here; this
//! layer assembles and relays.
//!
//! `submit` is idempotent: a client attaches an `idempotency_key`, the ledger enforces
//! its uniqueness, and a duplicate returns the original result instead of broadcasting
//! again. With the deterministic signature of a signed transaction, a blind retry cannot
//! double-send.

use axum::{
    extract::{Path, State},
    Json,
};
use base64::Engine;
use serde::{Deserialize, Serialize};

use crate::chain::{Commitment, TransferIntent};
use crate::error::AppError;
use crate::state::AppState;
use crate::store;

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
    /// Base64-encoded fee-payer signature over `message`, present only when fees are
    /// sponsored. The device assembles it ahead of its own signature. When absent, the
    /// sender pays their own fee and signs alone.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fee_payer_signature: Option<String>,
}

/// `POST /v1/tx/build` assembles an unsigned transfer for the device to sign. Delegates
/// to the active chain adapter.
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

    let encoder = base64::engine::general_purpose::STANDARD;
    let message = encoder.encode(&unsigned.message);
    let fee_payer_signature = unsigned
        .fee_payer_signature
        .as_ref()
        .map(|sig| encoder.encode(sig));
    let valid_until = unsigned
        .valid_until
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    Ok(Json(BuildResponse {
        message,
        valid_until,
        fee_payer_signature,
    }))
}

#[derive(Deserialize)]
pub struct SubmitRequest {
    /// Base64-encoded, fully-signed transaction in the chain's wire format.
    pub signed: String,
    /// Client-supplied key that makes a retry safe: a duplicate does not re-broadcast.
    pub idempotency_key: String,
    /// Sender address, used to associate the transaction with a registered wallet.
    pub pubkey: Option<String>,
    /// Recipient address, recorded for history.
    pub to: Option<String>,
    /// Amount in base units as a decimal string, recorded for history.
    pub amount: Option<String>,
    /// Token mint, or omitted/null for the native asset.
    pub mint: Option<String>,
}

#[derive(Serialize)]
pub struct SubmitResponse {
    /// On-chain transaction signature.
    pub signature: String,
    /// Recorded lifecycle state (`submitted` immediately after broadcast).
    pub status: String,
}

/// `POST /v1/tx/submit` broadcasts a signed transaction exactly once.
///
/// If the same key already produced a signature, that signature is returned and nothing
/// is broadcast, so a client that retries after a lost response cannot double-send.
pub async fn submit(
    State(state): State<AppState>,
    Json(req): Json<SubmitRequest>,
) -> Result<Json<SubmitResponse>, AppError> {
    let signed = base64::engine::general_purpose::STANDARD
        .decode(&req.signed)
        .map_err(|_| AppError::BadRequest("signed transaction is not valid base64".into()))?;

    // Fast path: this key already produced a signature, so return it without
    // re-broadcasting. Otherwise claim the key with a pending row so a retry finds it here.
    if let Some(existing) = store::transactions::find_by_idempotency(&state.pool, &req.idempotency_key).await? {
        if let Some(signature) = existing.signature {
            return Ok(Json(SubmitResponse {
                signature,
                status: existing.status,
            }));
        }
    } else {
        let wallet_id = match &req.pubkey {
            Some(pubkey) => store::wallets::find_id_by_pubkey(&state.pool, pubkey).await?,
            None => None,
        };
        store::transactions::insert_pending(
            &state.pool,
            wallet_id,
            &req.idempotency_key,
            req.to.as_deref(),
            req.amount.as_deref(),
            req.mint.as_deref(),
        )
        .await?;
    }

    // Reject anything malformed or unsigned before it reaches the network.
    state.chain.validate_signed(&signed).await?;

    let signature = state.chain.broadcast(&signed).await?;
    store::transactions::mark_submitted(&state.pool, &req.idempotency_key, &signature).await?;

    Ok(Json(SubmitResponse {
        signature,
        status: "submitted".to_string(),
    }))
}

#[derive(Serialize)]
pub struct StatusResponse {
    pub signature: String,
    /// Commitment level: `processed`, `confirmed`, `finalized`, or `failed`.
    pub status: String,
}

/// `GET /v1/tx/:signature` reports a transaction's current commitment.
///
/// Lets a client resolve a timed-out submit: a timeout may hide a success, so the client
/// queries status rather than assuming failure.
pub async fn status(
    State(state): State<AppState>,
    Path(signature): Path<String>,
) -> Result<Json<StatusResponse>, AppError> {
    let commitment = state.chain.status(&signature).await?;
    let status = match commitment {
        Commitment::Processed => "processed",
        Commitment::Confirmed => "confirmed",
        Commitment::Finalized => "finalized",
        Commitment::Failed => "failed",
    };
    Ok(Json(StatusResponse {
        signature,
        status: status.to_string(),
    }))
}
