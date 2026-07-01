//! Wallet service: registers a wallet's public key and reports balances. It only ever
//! handles public keys and never generates or stores a private key.

use axum::{extract::State, Json};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::AppError;
use crate::state::AppState;

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

    let id = Uuid::new_v4();
    let row: (Uuid,) = sqlx::query_as(
        "insert into wallets (id, pubkey, label)
         values ($1, $2, $3)
         on conflict (pubkey)
             do update set label = coalesce(excluded.label, wallets.label)
         returning id",
    )
    .bind(id)
    .bind(&req.pubkey)
    .bind(&req.label)
    .fetch_one(&state.pool)
    .await?;

    Ok(Json(RegisterWalletResponse {
        wallet_id: row.0,
        pubkey: req.pubkey,
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
