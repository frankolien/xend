//! Wallet service: registers a wallet's PUBLIC key and (Phase 2) reports balances.
//! It only ever knows public keys — it generates and stores no private key.

use axum::{extract::State, Json};
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use uuid::Uuid;

use crate::error::AppError;

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

/// `POST /v1/wallets` — register a base58 pubkey. Idempotent: registering an
/// already-known pubkey returns its existing wallet id rather than erroring, so a
/// client retry is safe (the same discipline the tx path will formalize with
/// idempotency keys in Phase 4).
pub async fn register(
    State(pool): State<PgPool>,
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
    .fetch_one(&pool)
    .await?;

    Ok(Json(RegisterWalletResponse {
        wallet_id: row.0,
        pubkey: req.pubkey,
    }))
}

/// A Solana address is a base58-encoded 32-byte Ed25519 public key. Reject anything
/// that isn't — storing a malformed address is a latent money bug.
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
