//! The chain-agnostic port. Every supported blockchain implements [`ChainAdapter`]; the
//! rest of the backend depends only on this trait and the domain types here, never on a
//! chain-specific client.

use std::time::SystemTime;

use async_trait::async_trait;

use crate::error::AppError;

/// An unsigned transaction, ready to be sent to the device for signing.
pub struct UnsignedTx {
    /// The serialized transaction message to sign (base64-encoded at the API edge).
    pub message: Vec<u8>,
    /// The instant after which the transaction is no longer valid (for example, when its
    /// blockhash expires). Past this point it must be rebuilt rather than broadcast.
    pub valid_until: SystemTime,
    /// When fees are sponsored, the fee payer's signature over [`message`], already
    /// produced by the backend. The device adds only its own signature; both are assembled
    /// into the wire transaction in signer order. `None` when the sender pays their own fee.
    pub fee_payer_signature: Option<Vec<u8>>,
}

/// A transaction's degree of finality on the network. The adapter reports the actual
/// level reached; the client decides which level to treat as success.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Commitment {
    Processed,
    Confirmed,
    Finalized,
    Failed,
}

/// A chain-agnostic transfer request. A `mint` of `None` denotes the chain's native
/// asset; `amount` is in the asset's smallest indivisible unit.
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
/// transaction, which is what makes retrying a stalled transaction correct.
#[async_trait]
pub trait ChainAdapter: Send + Sync {
    /// The chain's name, used in logs and metrics.
    fn chain(&self) -> &'static str;

    /// Assembles an unsigned transfer for the given intent.
    async fn build_transfer(&self, intent: &TransferIntent) -> Result<UnsignedTx, AppError>;

    /// Validates a signed payload before broadcast: well-formed, signature present, and
    /// consistent with the intent it was built from.
    async fn validate_signed(&self, signed: &[u8]) -> Result<(), AppError>;

    /// Broadcasts already-signed bytes and returns the network transaction signature.
    async fn broadcast(&self, signed: &[u8]) -> Result<String, AppError>;

    /// Returns the current commitment level for a transaction signature.
    async fn status(&self, signature: &str) -> Result<Commitment, AppError>;

    /// Returns the balance of `address` in base units. `mint` selects a token, or `None`
    /// for the chain's native asset.
    async fn balance(&self, address: &str, mint: Option<&str>) -> Result<u128, AppError>;
}
