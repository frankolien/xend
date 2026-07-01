//! Transaction handling: building unsigned transactions, validating signed ones,
//! broadcasting, tracking confirmation, and enforcing idempotency. This module never
//! signs — it assembles and relays; the device holds the key and signs.
//!
//! Idempotency is the core correctness property: a client attaches an `idempotency_key`
//! to every submission, the database enforces its uniqueness, and a duplicate returns
//! the original result instead of broadcasting again. Combined with the deterministic
//! signature of a signed transaction, a blind retry can never produce a double-send.

use axum::{
    extract::{Path, State},
    Json,
};
use base64::Engine;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::chain::{Commitment, TransferIntent};
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

#[derive(Deserialize)]
pub struct SubmitRequest {
    /// Base64-encoded, fully-signed transaction in the chain's wire format.
    pub signed: String,
    /// Client-supplied key that makes a retry safe: a duplicate never re-broadcasts.
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
    /// The on-chain transaction signature.
    pub signature: String,
    /// The recorded lifecycle state (`submitted` immediately after broadcast).
    pub status: String,
}

/// `POST /v1/tx/submit` — broadcast a signed transaction exactly once.
///
/// The idempotency key is the correctness pivot. If a submission with the same key has
/// already produced a signature, that signature is returned and nothing is broadcast —
/// so a client that retries after a lost response cannot double-send. Concurrent
/// submissions of the same key race on the table's `UNIQUE` constraint to a single
/// winning row; a loser proceeds too, which is safe because re-broadcasting identical
/// signed bytes yields the same on-chain signature.
pub async fn submit(
    State(state): State<AppState>,
    Json(req): Json<SubmitRequest>,
) -> Result<Json<SubmitResponse>, AppError> {
    let signed = base64::engine::general_purpose::STANDARD
        .decode(&req.signed)
        .map_err(|_| AppError::BadRequest("signed transaction is not valid base64".into()))?;

    // Fast path: this key already produced a signature. Return it without re-broadcasting.
    let existing: Option<(Option<String>, String)> =
        sqlx::query_as("select signature, status from transactions where idempotency_key = $1")
            .bind(&req.idempotency_key)
            .fetch_optional(&state.pool)
            .await?;

    if let Some((Some(signature), status)) = existing {
        return Ok(Json(SubmitResponse { signature, status }));
    }

    // First time we have seen this key: claim it. The UNIQUE constraint plus
    // `on conflict do nothing` makes concurrent claims collapse to one row.
    if existing.is_none() {
        let wallet_id: Option<Uuid> = match &req.pubkey {
            Some(pubkey) => {
                sqlx::query_scalar("select id from wallets where pubkey = $1")
                    .bind(pubkey)
                    .fetch_optional(&state.pool)
                    .await?
            }
            None => None,
        };

        sqlx::query(
            "insert into transactions (id, wallet_id, idempotency_key, status, to_address, amount, mint)
             values ($1, $2, $3, 'pending', $4, $5, $6)
             on conflict (idempotency_key) do nothing",
        )
        .bind(Uuid::new_v4())
        .bind(wallet_id)
        .bind(&req.idempotency_key)
        .bind(&req.to)
        .bind(&req.amount)
        .bind(&req.mint)
        .execute(&state.pool)
        .await?;
    }

    // Reject anything malformed or unsigned before it reaches the network.
    state.chain.validate_signed(&signed).await?;

    let signature = state.chain.broadcast(&signed).await?;

    sqlx::query(
        "update transactions
         set signature = $1, status = 'submitted', updated_at = now()
         where idempotency_key = $2",
    )
    .bind(&signature)
    .bind(&req.idempotency_key)
    .execute(&state.pool)
    .await?;

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

/// `GET /v1/tx/:signature` — report a transaction's current commitment.
///
/// This is the authoritative answer to "did it actually happen?" and lets a client
/// resolve the ambiguity of a timed-out submit: on a blockchain a timeout may hide a
/// success, so a client queries status rather than assuming failure.
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
