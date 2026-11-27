//! Build, submit, and status endpoints. Signing happens on the device, not here; this
//! layer assembles and relays.
//!
//! `submit` is idempotent: a client attaches an `idempotency_key`, the ledger enforces its
//! uniqueness, and a duplicate returns the original result instead of broadcasting again.
//!
//! The key is bound to the payload it was first claimed with. That binding is what makes a
//! retry safe, because the underlying guarantee is narrower than it looks: re-broadcasting
//! is harmless only for *identical* bytes, which carry an identical signature the network
//! collapses into one transaction. The same key over different bytes is a different
//! transfer, so submit rejects it instead of moving funds twice.
//!
//! History is recorded from the signed transaction, not from the request. The sender,
//! recipient, amount and mint come from the bytes; client-supplied values are only checked
//! against them, and a mismatch is rejected.

use axum::{
    extract::{Path, State},
    Json,
};
use base64::Engine;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::chain::{Commitment, SignedTransfer, TransferIntent};
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
    /// Sender address. Optional; if present it must match the signed transaction.
    pub pubkey: Option<String>,
    /// Recipient address. Optional; if present it must match the signed transaction.
    pub to: Option<String>,
    /// Amount in base units as a decimal string. Optional; checked like `pubkey`.
    pub amount: Option<String>,
    /// Token mint. Optional; checked like `pubkey`. Omitted for the native asset.
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
/// If the same key already produced a signature, that signature is returned and nothing is
/// broadcast, so a client that retries after a lost response cannot double-send. Presenting
/// a different transaction under a key that is already taken is refused
/// ([`AppError::IdempotencyKeyReuse`]) rather than broadcast.
pub async fn submit(
    State(state): State<AppState>,
    Json(req): Json<SubmitRequest>,
) -> Result<Json<SubmitResponse>, AppError> {
    let signed = base64::engine::general_purpose::STANDARD
        .decode(&req.signed)
        .map_err(|_| AppError::BadRequest("signed transaction is not valid base64".into()))?;

    // Ties the key to this exact payload, so a retry has to present the same bytes.
    let signed_hash = base64::engine::general_purpose::STANDARD.encode(Sha256::digest(&signed));

    // Verify signatures and read what the transaction really does before anything is
    // claimed or recorded. Pure and local, so repeating it on a retry is harmless.
    let transfer = state
        .chain
        .validate_signed(&signed, req.to.as_deref())
        .await?;

    // Recorded fields come from the bytes. A transaction that is not a recognised transfer
    // is still relayed but not attached to any wallet's history.
    let (wallet_id, to, amount, mint) = match &transfer {
        Some(t) => {
            check_claims(&req, t)?;
            (
                store::wallets::find_id_by_pubkey(&state.pool, &t.from).await?,
                t.to.clone(),
                Some(t.amount.to_string()),
                t.mint.clone(),
            )
        }
        None => (None, None, None, None),
    };

    let claim = store::transactions::claim_or_get(
        &state.pool,
        wallet_id,
        &req.idempotency_key,
        &signed_hash,
        to.as_deref(),
        amount.as_deref(),
        mint.as_deref(),
    )
    .await?;

    // A key stands for one transaction. Reusing it for different bytes would broadcast a
    // second, distinct transfer, so reject it rather than relay it.
    if matches!(&claim.signed_hash, Some(bound) if *bound != signed_hash) {
        return Err(AppError::IdempotencyKeyReuse);
    }

    // Already broadcast under this key: return the original result and send nothing.
    if let Some(signature) = claim.signature {
        return Ok(Json(SubmitResponse {
            signature,
            status: claim.status,
        }));
    }

    // Claimed but not yet broadcast: either this is the first attempt, or an earlier one
    // died before it reached the network. The payload matches, so broadcasting now is safe
    // even if that attempt did get through: identical bytes carry the identical signature,
    // which the network treats as the same transaction.
    let signature = state.chain.broadcast(&signed).await?;
    store::transactions::mark_submitted(&state.pool, &req.idempotency_key, &signature).await?;

    Ok(Json(SubmitResponse {
        signature,
        status: "submitted".to_string(),
    }))
}

/// Rejects a request whose optional transfer fields disagree with the signed transaction.
fn check_claims(req: &SubmitRequest, actual: &SignedTransfer) -> Result<(), AppError> {
    let mismatch = |field: &str| {
        Err(AppError::BadRequest(format!(
            "`{field}` does not match the signed transaction"
        )))
    };
    if matches!(&req.pubkey, Some(p) if *p != actual.from) {
        return mismatch("pubkey");
    }
    if req.to.is_some() && req.to != actual.to {
        return mismatch("to");
    }
    if let Some(amount) = &req.amount {
        if amount.parse::<u128>().ok() != Some(actual.amount) {
            return mismatch("amount");
        }
    }
    if req.mint.is_some() && req.mint != actual.mint {
        return mismatch("mint");
    }
    Ok(())
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

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    use sqlx::PgPool;

    use super::*;
    use crate::chain::UnsignedTx;

    /// Stands in for a chain, counting what actually reached the network.
    #[derive(Default)]
    struct MockChain {
        broadcasts: AtomicUsize,
    }

    impl MockChain {
        fn broadcast_count(&self) -> usize {
            self.broadcasts.load(Ordering::SeqCst)
        }
    }

    #[async_trait::async_trait]
    impl crate::chain::ChainAdapter for MockChain {
        fn chain(&self) -> &'static str {
            "mock"
        }

        async fn build_transfer(&self, _intent: &TransferIntent) -> Result<UnsignedTx, AppError> {
            unimplemented!("submit tests do not build")
        }

        async fn resolve_name(&self, _name: &str) -> Result<String, AppError> {
            unimplemented!("submit tests do not resolve")
        }

        /// Every payload reads back as the same transfer, so tests can check that history
        /// comes from here rather than from the request.
        async fn validate_signed(
            &self,
            _signed: &[u8],
            _claimed_to: Option<&str>,
        ) -> Result<Option<SignedTransfer>, AppError> {
            Ok(Some(SignedTransfer {
                from: "sender".to_string(),
                to: Some("recipient".to_string()),
                amount: 1000,
                mint: None,
            }))
        }

        /// Mirrors the property the whole guarantee rests on: a signature is a function of
        /// the signed bytes, so identical bytes always land as the same transaction.
        async fn broadcast(&self, signed: &[u8]) -> Result<String, AppError> {
            self.broadcasts.fetch_add(1, Ordering::SeqCst);
            Ok(format!("sig-{}", hash_of(signed)))
        }

        async fn status(&self, _signature: &str) -> Result<Commitment, AppError> {
            unimplemented!("submit tests do not poll status")
        }

        async fn balance(&self, _address: &str, _mint: Option<&str>) -> Result<u128, AppError> {
            unimplemented!("submit tests do not read balances")
        }
    }

    fn hash_of(signed: &[u8]) -> String {
        base64::engine::general_purpose::STANDARD.encode(Sha256::digest(signed))
    }

    fn state_for(pool: PgPool, chain: Arc<MockChain>) -> AppState {
        AppState { pool, chain }
    }

    fn request(signed: &[u8], idempotency_key: &str) -> SubmitRequest {
        SubmitRequest {
            signed: base64::engine::general_purpose::STANDARD.encode(signed),
            idempotency_key: idempotency_key.to_string(),
            pubkey: None,
            to: Some("recipient".to_string()),
            amount: Some("1000".to_string()),
            mint: None,
        }
    }

    #[sqlx::test]
    async fn duplicate_submit_returns_the_first_signature_without_re_broadcasting(pool: PgPool) {
        let chain = Arc::new(MockChain::default());
        let state = state_for(pool, chain.clone());

        let first = submit(State(state.clone()), Json(request(b"tx-bytes", "key-1")))
            .await
            .expect("first submit");
        let second = submit(State(state), Json(request(b"tx-bytes", "key-1")))
            .await
            .expect("retry");

        assert_eq!(first.signature, second.signature);
        assert_eq!(second.status, "submitted");
        assert_eq!(
            chain.broadcast_count(),
            1,
            "retry must not reach the network"
        );
    }

    #[sqlx::test]
    async fn reusing_a_key_for_different_bytes_is_rejected(pool: PgPool) {
        let chain = Arc::new(MockChain::default());
        let state = state_for(pool, chain.clone());

        let _ = submit(State(state.clone()), Json(request(b"pay-alice", "key-1")))
            .await
            .expect("first submit");
        let reused = submit(State(state), Json(request(b"pay-mallory", "key-1"))).await;

        assert!(matches!(reused, Err(AppError::IdempotencyKeyReuse)));
        assert_eq!(
            chain.broadcast_count(),
            1,
            "the second transfer must not be sent"
        );
    }

    /// The gap this column closes. A claim that never reached the network leaves a pending
    /// row; before the payload was bound, a different transaction could take over that key
    /// and broadcast on top of it.
    #[sqlx::test]
    async fn a_pending_claim_cannot_be_taken_over_by_different_bytes(pool: PgPool) {
        let chain = Arc::new(MockChain::default());
        let state = state_for(pool.clone(), chain.clone());

        // A submit that claimed the key, then died before broadcasting.
        store::transactions::claim_or_get(
            &pool,
            None,
            "key-1",
            &hash_of(b"pay-alice"),
            None,
            None,
            None,
        )
        .await
        .expect("claim");

        let taken_over = submit(State(state), Json(request(b"pay-mallory", "key-1"))).await;

        assert!(matches!(taken_over, Err(AppError::IdempotencyKeyReuse)));
        assert_eq!(chain.broadcast_count(), 0);
    }

    /// The recovery path the fall-through exists for stays open: same key, same bytes, after
    /// an attempt that claimed but never sent.
    #[sqlx::test]
    async fn a_pending_claim_is_resumed_by_the_same_bytes(pool: PgPool) {
        let chain = Arc::new(MockChain::default());
        let state = state_for(pool.clone(), chain.clone());

        store::transactions::claim_or_get(
            &pool,
            None,
            "key-1",
            &hash_of(b"pay-alice"),
            None,
            None,
            None,
        )
        .await
        .expect("claim");

        let resumed = submit(State(state), Json(request(b"pay-alice", "key-1")))
            .await
            .expect("resume");

        assert_eq!(resumed.signature, format!("sig-{}", hash_of(b"pay-alice")));
        assert_eq!(chain.broadcast_count(), 1);
    }

    /// Two submits racing on one key with different payloads. The claim is atomic, so one
    /// wins the key and the other is turned away rather than both reaching the network.
    #[sqlx::test]
    async fn concurrent_submits_on_one_key_broadcast_at_most_one_transfer(pool: PgPool) {
        let chain = Arc::new(MockChain::default());
        let state = state_for(pool, chain.clone());

        let alice = submit(State(state.clone()), Json(request(b"pay-alice", "key-1")));
        let mallory = submit(State(state), Json(request(b"pay-mallory", "key-1")));
        let (a, m) = tokio::join!(alice, mallory);

        let rejected = [&a, &m]
            .iter()
            .filter(|r| matches!(r, Err(AppError::IdempotencyKeyReuse)))
            .count();
        assert_eq!(rejected, 1, "exactly one of the two must lose the key");
        assert_eq!(chain.broadcast_count(), 1);
    }

    #[sqlx::test]
    async fn distinct_keys_are_independent(pool: PgPool) {
        let chain = Arc::new(MockChain::default());
        let state = state_for(pool, chain.clone());

        let _ = submit(State(state.clone()), Json(request(b"pay-alice", "key-1")))
            .await
            .expect("first");
        let _ = submit(State(state), Json(request(b"pay-bob", "key-2")))
            .await
            .expect("second");

        assert_eq!(chain.broadcast_count(), 2);
    }

    /// A request cannot write history the signed bytes do not back.
    #[sqlx::test]
    async fn submit_rejects_claims_that_contradict_the_signed_transaction(pool: PgPool) {
        let chain = Arc::new(MockChain::default());
        let state = state_for(pool.clone(), chain.clone());

        let mut forged_amount = request(b"tx", "key-1");
        forged_amount.amount = Some("999999".to_string());
        let mut forged_to = request(b"tx", "key-2");
        forged_to.to = Some("someone-else".to_string());
        let mut forged_from = request(b"tx", "key-3");
        forged_from.pubkey = Some("victim".to_string());

        for forged in [forged_amount, forged_to, forged_from] {
            let result = submit(State(state.clone()), Json(forged)).await;
            assert!(matches!(result, Err(AppError::BadRequest(_))));
        }
        assert_eq!(chain.broadcast_count(), 0);
        let rows: i64 = sqlx::query_scalar("select count(*) from transactions")
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(rows, 0, "a rejected submit leaves no ledger row");
    }

    /// With no claims at all, the recorded row still carries the transfer's real details.
    #[sqlx::test]
    async fn submit_records_history_from_the_signed_transaction(pool: PgPool) {
        let chain = Arc::new(MockChain::default());
        let state = state_for(pool.clone(), chain.clone());
        let wallet = store::wallets::upsert(&pool, "sender", None).await.unwrap();

        let mut bare = request(b"tx", "key-1");
        bare.to = None;
        bare.amount = None;
        let _ = submit(State(state), Json(bare)).await.expect("submit");

        let (wallet_id, to, amount): (Option<uuid::Uuid>, Option<String>, Option<String>) =
            sqlx::query_as(
                "select wallet_id, to_address, amount from transactions where idempotency_key = 'key-1'",
            )
            .fetch_one(&pool)
            .await
            .unwrap();
        assert_eq!(wallet_id, Some(wallet));
        assert_eq!(to.as_deref(), Some("recipient"));
        assert_eq!(amount.as_deref(), Some("1000"));
    }
}
