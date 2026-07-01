//! The multi-chain seam (docs/02-DECISIONS.md#d0). v0.1 ships exactly one impl,
//! `SolanaAdapter`. Adding Base or Bitcoin later means implementing this one trait —
//! not rewriting the SDK or the tx service. The `tx/` module speaks only to this trait,
//! never to a chain-specific client directly.

use crate::error::AppError;

/// An unsigned transaction, ready to cross the signing boundary to the device.
pub struct UnsignedTx {
    /// Opaque serialized message the device signs (base64 at the API edge).
    pub message: Vec<u8>,
    /// When the validity window closes (blockhash expiry, nonce, etc.). The tx
    /// service races this clock; past it, rebuild rather than broadcast.
    pub valid_until: std::time::SystemTime,
}

/// Where a transaction is in its journey. "Done" is a choice among these (D6); the
/// adapter reports the truth, the SDK decides what to render as success.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Commitment {
    Processed,
    Confirmed,
    Finalized,
    Failed,
}

/// A transfer request, chain-agnostic. `mint: None` ⇒ the chain's native asset.
pub struct TransferIntent {
    pub from: String,
    pub to: String,
    pub amount: u128, // base units — integer money, always (docs §6 gotcha)
    pub mint: Option<String>,
}

/// Every chain plugs in here. Async in the real impl; shown sync-shaped for the
/// contract. `build` needs network (fresh blockhash, token accounts); `broadcast`
/// relays already-signed bytes; `status` maps a signature to a [`Commitment`].
pub trait ChainAdapter: Send + Sync {
    /// Human name for logs/metrics.
    fn chain(&self) -> &'static str;

    /// Assemble an unsigned transfer. Fetches whatever the device shouldn't compute
    /// alone (blockhash, fee/priority, token accounts).
    fn build_transfer(&self, intent: &TransferIntent) -> Result<UnsignedTx, AppError>;

    /// Validate a signed blob before broadcast (well-formed, signature present,
    /// matches the intent we built). Cheap defense against a malformed submit.
    fn validate_signed(&self, signed: &[u8]) -> Result<(), AppError>;

    /// Broadcast already-signed bytes. Returns the network signature/tx id.
    /// Re-broadcasting identical bytes is safe (the network dedupes) — this is what
    /// makes "rebroadcast the same bytes" the correct stuck-tx move.
    fn broadcast(&self, signed: &[u8]) -> Result<String, AppError>;

    /// Current commitment for a signature.
    fn status(&self, signature: &str) -> Result<Commitment, AppError>;
}

/// v0.1's only adapter. Wired to a pinned, credential-holding Solana RPC/WSS client
/// in Phase 2. All methods currently return the contract's not-yet-implemented shape.
pub struct SolanaAdapter {
    // rpc: SolanaRpcClient,   // Phase 2 — holds RPC creds; device never sees them.
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
        Err(AppError::Network("SolanaAdapter::build_transfer not implemented".into())) // Phase 2
    }

    fn validate_signed(&self, _signed: &[u8]) -> Result<(), AppError> {
        Err(AppError::Network("SolanaAdapter::validate_signed not implemented".into())) // Phase 2
    }

    fn broadcast(&self, _signed: &[u8]) -> Result<String, AppError> {
        Err(AppError::Network("SolanaAdapter::broadcast not implemented".into())) // Phase 2
    }

    fn status(&self, _signature: &str) -> Result<Commitment, AppError> {
        Err(AppError::Network("SolanaAdapter::status not implemented".into())) // Phase 2
    }
}
