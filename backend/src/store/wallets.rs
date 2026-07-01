//! Queries over the `wallets` table. Wallets hold only a public key and an optional
//! label — never any private key material.

use sqlx::PgPool;
use uuid::Uuid;

use crate::error::AppError;

/// Inserts a wallet for `pubkey`, or returns the existing wallet's id if the key is
/// already registered, updating the label when a new one is supplied. Idempotent, so a
/// client retry is safe.
pub async fn upsert(pool: &PgPool, pubkey: &str, label: Option<&str>) -> Result<Uuid, AppError> {
    let row: (Uuid,) = sqlx::query_as(
        "insert into wallets (id, pubkey, label)
         values ($1, $2, $3)
         on conflict (pubkey)
             do update set label = coalesce(excluded.label, wallets.label)
         returning id",
    )
    .bind(Uuid::new_v4())
    .bind(pubkey)
    .bind(label)
    .fetch_one(pool)
    .await?;
    Ok(row.0)
}

/// Returns the wallet id registered for `pubkey`, or `None` if the key is unknown.
pub async fn find_id_by_pubkey(pool: &PgPool, pubkey: &str) -> Result<Option<Uuid>, AppError> {
    let id = sqlx::query_scalar("select id from wallets where pubkey = $1")
        .bind(pubkey)
        .fetch_optional(pool)
        .await?;
    Ok(id)
}
