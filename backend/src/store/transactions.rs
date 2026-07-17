//! Queries over the `transactions` ledger. The table records only public facts. Idempotent
//! submission relies on the UNIQUE `idempotency_key`: a repeated submission finds the
//! original row instead of broadcasting again.

use chrono::{DateTime, Utc};
use sqlx::PgPool;
use uuid::Uuid;

use crate::error::AppError;

/// The row an idempotency key resolves to, whether this caller claimed it or found it
/// already held.
pub struct Claim {
    /// Hash of the signed payload the key was claimed with. `None` for rows written before
    /// the column existed, which count as unbound.
    pub signed_hash: Option<String>,
    /// On-chain signature, or `None` if the key is claimed but not yet broadcast.
    pub signature: Option<String>,
    /// Lifecycle state.
    pub status: String,
}

/// Claims an idempotency key for `signed_hash`, or returns the row already holding it.
///
/// The insert and the read are one statement, so two concurrent submissions of the same key
/// cannot both come away believing they claimed it: the UNIQUE constraint picks a winner and
/// the loser reads the winner's row back. `do update` rather than `do nothing` because only
/// the former returns a row on conflict.
pub async fn claim_or_get(
    pool: &PgPool,
    wallet_id: Option<Uuid>,
    idempotency_key: &str,
    signed_hash: &str,
    to: Option<&str>,
    amount: Option<&str>,
    mint: Option<&str>,
) -> Result<Claim, AppError> {
    let (signed_hash, signature, status): (Option<String>, Option<String>, String) =
        sqlx::query_as(
            "insert into transactions (id, wallet_id, idempotency_key, status, to_address, amount, mint, signed_hash)
             values ($1, $2, $3, 'pending', $4, $5, $6, $7)
             on conflict (idempotency_key) do update set updated_at = now()
             returning signed_hash, signature, status",
        )
        .bind(Uuid::new_v4())
        .bind(wallet_id)
        .bind(idempotency_key)
        .bind(to)
        .bind(amount)
        .bind(mint)
        .bind(signed_hash)
        .fetch_one(pool)
        .await?;

    Ok(Claim {
        signed_hash,
        signature,
        status,
    })
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
