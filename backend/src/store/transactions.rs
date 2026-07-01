//! Queries over the `transactions` ledger. The table records only public facts and is
//! the mechanism behind idempotent submission: `idempotency_key` is UNIQUE, so a repeated
//! submission finds the original row instead of broadcasting again.

use sqlx::PgPool;
use uuid::Uuid;

use crate::error::AppError;

/// The idempotency-relevant fields of a stored transaction.
pub struct Existing {
    /// The on-chain signature, or `None` if the row was claimed but not yet broadcast.
    pub signature: Option<String>,
    /// The recorded lifecycle state.
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
/// `on conflict do nothing` means concurrent claims for the same key collapse to a single
/// row; callers that lose the race still proceed safely, since re-broadcasting identical
/// signed bytes yields the same on-chain signature.
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
