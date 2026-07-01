//! Wallet endpoints: register a public key and report balances. Only public keys are
//! handled here; a private key is never generated or stored.

use axum::{
    extract::{Path, Query, State},
    Json,
};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::AppError;
use crate::state::AppState;
use crate::store;

#[derive(Deserialize)]
pub struct RegisterWalletRequest {
    pub pubkey: String,
    pub label: Option<String>,
}

#[derive(Serialize)]
pub struct RegisterWalletResponse {
    pub wallet_id: Uuid,
    pub pubkey: String,
}

/// `POST /v1/wallets` — register a base58 public key. Idempotent: registering an
/// already-known key returns its existing wallet id rather than failing, so a client
/// retry is safe.
pub async fn register(
    State(state): State<AppState>,
    Json(req): Json<RegisterWalletRequest>,
) -> Result<Json<RegisterWalletResponse>, AppError> {
    validate_solana_pubkey(&req.pubkey)?;
    let wallet_id = store::wallets::upsert(&state.pool, &req.pubkey, req.label.as_deref()).await?;
    Ok(Json(RegisterWalletResponse {
        wallet_id,
        pubkey: req.pubkey,
    }))
}

#[derive(Deserialize)]
pub struct BalanceQuery {
    /// Token mint to query, or omitted for the native asset.
    pub mint: Option<String>,
}

#[derive(Serialize)]
pub struct BalanceResponse {
    /// Balance in base units (lamports for SOL), as a string to preserve full precision.
    pub amount: String,
    /// The token mint queried, or null for the native asset.
    pub mint: Option<String>,
}

/// `GET /v1/wallets/:pubkey/balance` — the wallet's balance in base units.
///
/// Reads through the active chain adapter, so it stays chain-agnostic. Only public data
/// is involved; no authentication is required to read a public balance.
pub async fn balance(
    State(state): State<AppState>,
    Path(pubkey): Path<String>,
    Query(query): Query<BalanceQuery>,
) -> Result<Json<BalanceResponse>, AppError> {
    validate_solana_pubkey(&pubkey)?;
    let amount = state.chain.balance(&pubkey, query.mint.as_deref()).await?;
    Ok(Json(BalanceResponse {
        amount: amount.to_string(),
        mint: query.mint,
    }))
}

/// Validates that `pubkey` is a base58-encoded 32-byte Ed25519 public key. Rejecting a
/// malformed address here prevents storing one that could later misdirect funds.
fn validate_solana_pubkey(pubkey: &str) -> Result<(), AppError> {
    let decoded = bs58::decode(pubkey)
        .into_vec()
        .map_err(|_| AppError::BadRequest("pubkey is not valid base58".into()))?;

    if decoded.len() != 32 {
        return Err(AppError::BadRequest(format!(
            "pubkey must decode to 32 bytes, got {}",
            decoded.len()
        )));
    }
    Ok(())
}
