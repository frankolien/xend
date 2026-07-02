//! Wallet endpoints: register a public key and report balances. Only public keys are
//! handled here; private keys are never generated or stored.

use axum::{
    extract::{Path, Query, State},
    Json,
};
use chrono::{DateTime, Utc};
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

/// `POST /v1/wallets` registers a base58 public key. Idempotent: registering a known key
/// returns its existing wallet id rather than failing, so a retry is safe.
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

/// `GET /v1/wallets/:pubkey/balance` returns the wallet's balance in base units.
///
/// Reads through the active chain adapter. Balances are public, so no authentication is
/// required.
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

#[derive(Deserialize)]
pub struct HistoryQuery {
    /// Maximum number of records to return (clamped to 1..=100; defaults to 20).
    pub limit: Option<i64>,
    /// RFC3339 cursor: return only transactions created strictly before this instant.
    pub before: Option<String>,
}

#[derive(Serialize)]
pub struct TransactionRecord {
    pub signature: String,
    pub status: String,
    pub to: Option<String>,
    pub amount: Option<String>,
    pub mint: Option<String>,
    pub created_at: DateTime<Utc>,
}

#[derive(Serialize)]
pub struct HistoryResponse {
    pub transactions: Vec<TransactionRecord>,
}

/// `GET /v1/wallets/:pubkey/transactions` returns the wallet's transaction history, most
/// recent first. An unregistered wallet has no history and returns an empty list.
pub async fn history(
    State(state): State<AppState>,
    Path(pubkey): Path<String>,
    Query(query): Query<HistoryQuery>,
) -> Result<Json<HistoryResponse>, AppError> {
    validate_solana_pubkey(&pubkey)?;
    let limit = query.limit.unwrap_or(20).clamp(1, 100);

    let before = match query.before {
        Some(cursor) => Some(
            DateTime::parse_from_rfc3339(&cursor)
                .map_err(|_| AppError::BadRequest("before must be an RFC3339 timestamp".into()))?
                .with_timezone(&Utc),
        ),
        None => None,
    };

    let wallet_id = match store::wallets::find_id_by_pubkey(&state.pool, &pubkey).await? {
        Some(id) => id,
        None => return Ok(Json(HistoryResponse { transactions: vec![] })),
    };

    let records = store::transactions::list_for_wallet(&state.pool, wallet_id, limit, before).await?;
    let transactions = records
        .into_iter()
        .map(|r| TransactionRecord {
            signature: r.signature,
            status: r.status,
            to: r.to_address,
            amount: r.amount,
            mint: r.mint,
            created_at: r.created_at,
        })
        .collect();

    Ok(Json(HistoryResponse { transactions }))
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
