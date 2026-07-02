//! Chain-agnostic port. Every supported blockchain implements [`ChainAdapter`]; the rest
//! of the backend depends only on this trait and the domain types here.

use std::time::SystemTime;

use async_trait::async_trait;

use crate::error::AppError;

/// An unsigned transaction, ready to be sent to the device for signing.
pub struct UnsignedTx {
    /// Serialized transaction message to sign (base64-encoded at the API edge).
    pub message: Vec<u8>,
    /// Instant after which the transaction is no longer valid, e.g. when its blockhash
    /// expires. Past this point it must be rebuilt, not broadcast.
    pub valid_until: SystemTime,
    /// Fee payer's signature over [`message`] when fees are sponsored. The device adds its
    /// own signature; both go into the wire transaction in signer order. `None` when the
    /// sender pays their own fee.
    pub fee_payer_signature: Option<Vec<u8>>,
}

/// A transaction's finality level. The adapter reports the level reached; the client
/// decides which level counts as success.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Commitment {
    Processed,
    Confirmed,
    Finalized,
    Failed,
}

/// A chain-agnostic transfer request. `mint` of `None` means the chain's native asset;
/// `amount` is in the asset's smallest unit.
pub struct TransferIntent {
    pub from: String,
    pub to: String,
    pub amount: u128,
    pub mint: Option<String>,
}

/// The interface every supported chain implements.
///
/// `build_transfer` assembles an unsigned transfer, fetching data the device should not
/// compute (such as a recent blockhash). `validate_signed` checks a signed payload before
/// broadcast. `broadcast` submits already-signed bytes and returns the network signature.
/// `status` reports the current commitment for a signature. `balance` reads an address.
///
/// Re-broadcasting identical signed bytes is safe: the network treats them as the same
/// transaction, so retrying a stalled transaction is correct.
#[async_trait]
pub trait ChainAdapter: Send + Sync {
    /// Chain name, used in logs and metrics.
    fn chain(&self) -> &'static str;

    /// Assembles an unsigned transfer for the given intent.
    async fn build_transfer(&self, intent: &TransferIntent) -> Result<UnsignedTx, AppError>;

    /// Resolves a chain-native name (such as a Solana `.sol` domain) to an address. Returns
    /// [`AppError::InvalidRecipient`] when the name is malformed or unregistered.
    async fn resolve_name(&self, name: &str) -> Result<String, AppError>;

    /// Validates a signed payload before broadcast: well-formed, signature present, and
    /// consistent with the intent it was built from.
    async fn validate_signed(&self, signed: &[u8]) -> Result<(), AppError>;

    /// Broadcasts already-signed bytes and returns the network transaction signature.
    async fn broadcast(&self, signed: &[u8]) -> Result<String, AppError>;

    /// Returns the current commitment level for a transaction signature.
    async fn status(&self, signature: &str) -> Result<Commitment, AppError>;

    /// Returns the balance of `address` in base units. `mint` selects a token, or `None`
    /// for the native asset.
    async fn balance(&self, address: &str, mint: Option<&str>) -> Result<u128, AppError>;
}
