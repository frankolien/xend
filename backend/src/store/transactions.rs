//! Queries over the `transactions` ledger. The table records only public facts. Idempotent
//! submission relies on the UNIQUE `idempotency_key`: a repeated submission finds the
//! original row instead of broadcasting again.

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use crate::error::AppError;

/// Idempotency-relevant fields of a stored transaction.
pub struct Existing {
    /// On-chain signature, or `None` if the row was claimed but not yet broadcast.
    pub signature: Option<String>,
    /// Lifecycle state.
    pub status: String,
}

/// Looks up a transaction by its idempotency key.
pub async fn find_by_idempotency(
    pool: &PgPool,
    idempotency_key: &str,
) -> Result<Option<Existing>, AppError> {
    let row: Option<(Option<String>, String)> =
        sqlx::query_as("select signature, status from transactions where idempotency_key = $1")
            .bind(idempotency_key)
            .fetch_optional(pool)
            .await?;
    Ok(row.map(|(signature, status)| Existing { signature, status }))
}

/// Claims an idempotency key by inserting a pending row. The UNIQUE constraint plus
/// `on conflict do nothing` collapse concurrent claims for the same key to a single row.
/// A caller that loses the race is still safe: re-broadcasting identical signed bytes
/// yields the same on-chain signature.
pub async fn insert_pending(
    pool: &PgPool,
    wallet_id: Option<Uuid>,
    idempotency_key: &str,
    to: Option<&str>,
    amount: Option<&str>,
    mint: Option<&str>,
) -> Result<(), AppError> {
    sqlx::query(
        "insert into transactions (id, wallet_id, idempotency_key, status, to_address, amount, mint)
         values ($1, $2, $3, 'pending', $4, $5, $6)
         on conflict (idempotency_key) do nothing",
    )
    .bind(Uuid::new_v4())
    .bind(wallet_id)
    .bind(idempotency_key)
    .bind(to)
    .bind(amount)
    .bind(mint)
    .execute(pool)
    .await?;
    Ok(())
}

/// A broadcast transaction as recorded in the ledger, used for history.
pub struct Record {
    pub signature: String,
    pub status: String,
    pub to_address: Option<String>,
    pub amount: Option<String>,
    pub mint: Option<String>,
    pub created_at: DateTime<Utc>,
}

/// Lists a wallet's broadcast transactions, most recent first, up to `limit`. If `before`
/// is set, returns only transactions created strictly before it (cursor pagination). Rows
/// not yet broadcast (no signature) are omitted.
pub async fn list_for_wallet(
    pool: &PgPool,
    wallet_id: Uuid,
    limit: i64,
    before: Option<DateTime<Utc>>,
) -> Result<Vec<Record>, AppError> {
    let rows: Vec<(
        String,
        String,
        Option<String>,
        Option<String>,
        Option<String>,
        DateTime<Utc>,
    )> = sqlx::query_as(
        "select signature, status, to_address, amount, mint, created_at
         from transactions
         where wallet_id = $1
           and signature is not null
           and ($2::timestamptz is null or created_at < $2)
         order by created_at desc
         limit $3",
    )
    .bind(wallet_id)
    .bind(before)
    .bind(limit)
    .fetch_all(pool)
    .await?;

    Ok(rows
        .into_iter()
        .map(
            |(signature, status, to_address, amount, mint, created_at)| Record {
                signature,
                status,
                to_address,
                amount,
                mint,
                created_at,
            },
        )
        .collect())
}

/// Records the on-chain signature for a claimed key and marks it broadcast.
pub async fn mark_submitted(
    pool: &PgPool,
    idempotency_key: &str,
    signature: &str,
) -> Result<(), AppError> {
    sqlx::query(
        "update transactions
         set signature = $1, status = 'submitted', updated_at = now()
         where idempotency_key = $2",
    )
    .bind(signature)
    .bind(idempotency_key)
    .execute(pool)
    .await?;
    Ok(())
}
