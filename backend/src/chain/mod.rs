//! The chain abstraction. Every supported blockchain implements [`ChainAdapter`]; the
//! transaction module depends only on this trait, never on a chain-specific client.
//! Adding a new chain is a matter of providing another implementation. This release
//! ships a single implementation, [`SolanaAdapter`].

use crate::error::AppError;

/// An unsigned transaction, ready to be sent to the device for signing.
pub struct UnsignedTx {
    /// The serialized transaction message to sign (base64-encoded at the API edge).
    pub message: Vec<u8>,
    /// The instant after which the transaction is no longer valid (for example, when its
    /// blockhash expires). Past this point it must be rebuilt rather than broadcast.
    pub valid_until: std::time::SystemTime,
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
/// compute (such as a recent blockhash and fee parameters). `validate_signed` checks a
/// signed payload before broadcast. `broadcast` submits already-signed bytes and returns
/// the network signature. `status` reports the current commitment for a signature.
///
/// Re-broadcasting identical signed bytes is safe: the network treats them as the same
/// transaction, which is what makes retrying a stalled transaction correct.
pub trait ChainAdapter: Send + Sync {
    /// The chain's name, used in logs and metrics.
    fn chain(&self) -> &'static str;

    /// Assembles an unsigned transfer for the given intent.
    fn build_transfer(&self, intent: &TransferIntent) -> Result<UnsignedTx, AppError>;

    /// Validates a signed payload before broadcast: well-formed, signature present, and
    /// consistent with the intent it was built from.
    fn validate_signed(&self, signed: &[u8]) -> Result<(), AppError>;

    /// Broadcasts already-signed bytes and returns the network transaction signature.
    fn broadcast(&self, signed: &[u8]) -> Result<String, AppError>;

    /// Returns the current commitment level for a transaction signature.
    fn status(&self, signature: &str) -> Result<Commitment, AppError>;
}

/// The Solana implementation of [`ChainAdapter`]. It owns the RPC/WebSocket client and
/// is the only component with RPC credentials. The operations below are not yet
/// implemented.
pub struct SolanaAdapter {
    // rpc: SolanaRpcClient,
}

impl SolanaAdapter {
    pub fn new() -> Self {
        Self {}
    }
}

impl Default for SolanaAdapter {
    fn default() -> Self {
        Self::new()
    }
}

impl ChainAdapter for SolanaAdapter {
    fn chain(&self) -> &'static str {
        "solana"
    }

    fn build_transfer(&self, _intent: &TransferIntent) -> Result<UnsignedTx, AppError> {
        Err(AppError::Network("SolanaAdapter::build_transfer not implemented".into()))
    }

    fn validate_signed(&self, _signed: &[u8]) -> Result<(), AppError> {
        Err(AppError::Network("SolanaAdapter::validate_signed not implemented".into()))
    }

    fn broadcast(&self, _signed: &[u8]) -> Result<String, AppError> {
        Err(AppError::Network("SolanaAdapter::broadcast not implemented".into()))
    }

    fn status(&self, _signature: &str) -> Result<Commitment, AppError> {
        Err(AppError::Network("SolanaAdapter::status not implemented".into()))
    }
}
