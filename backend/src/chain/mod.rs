//! The chain abstraction. Every supported blockchain implements [`ChainAdapter`]; the
//! transaction module depends only on this trait, never on a chain-specific client.
//! Adding a new chain is a matter of providing another implementation. This release
//! ships a single implementation, [`SolanaAdapter`].

use std::str::FromStr;
use std::time::{Duration, SystemTime};

use async_trait::async_trait;
use solana_sdk::hash::Hash;
use solana_sdk::instruction::{AccountMeta, Instruction};
use solana_sdk::message::Message;
use solana_sdk::pubkey::Pubkey;

use crate::error::AppError;

/// An unsigned transaction, ready to be sent to the device for signing.
pub struct UnsignedTx {
    /// The serialized transaction message to sign (base64-encoded at the API edge).
    pub message: Vec<u8>,
    /// The instant after which the transaction is no longer valid (for example, when its
    /// blockhash expires). Past this point it must be rebuilt rather than broadcast.
    pub valid_until: SystemTime,
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
/// `status` reports the current commitment for a signature.
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
}

/// The Solana implementation of [`ChainAdapter`]. It holds the RPC endpoint — the only
/// component with RPC credentials — and an HTTP client for JSON-RPC calls.
pub struct SolanaAdapter {
    rpc_url: String,
    http: reqwest::Client,
}

impl SolanaAdapter {
    pub fn new(rpc_url: impl Into<String>) -> Self {
        Self {
            rpc_url: rpc_url.into(),
            http: reqwest::Client::new(),
        }
    }

    /// Fetches a recent blockhash to anchor a new transaction to.
    async fn latest_blockhash(&self) -> Result<Hash, AppError> {
        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getLatestBlockhash",
            "params": [{ "commitment": "finalized" }],
        });

        let response = self
            .http
            .post(&self.rpc_url)
            .json(&request)
            .send()
            .await
            .map_err(|e| AppError::Network(format!("rpc request failed: {e}")))?;

        let body: serde_json::Value = response
            .json()
            .await
            .map_err(|e| AppError::Network(format!("rpc decode failed: {e}")))?;

        let blockhash = body["result"]["value"]["blockhash"]
            .as_str()
            .ok_or_else(|| AppError::Network("rpc response missing blockhash".into()))?;

        Hash::from_str(blockhash)
            .map_err(|e| AppError::Network(format!("rpc returned an invalid blockhash: {e}")))
    }
}

#[async_trait]
impl ChainAdapter for SolanaAdapter {
    fn chain(&self) -> &'static str {
        "solana"
    }

    async fn build_transfer(&self, intent: &TransferIntent) -> Result<UnsignedTx, AppError> {
        if intent.mint.is_some() {
            return Err(AppError::BadRequest(
                "SPL token transfers are not yet supported".into(),
            ));
        }

        let from = Pubkey::from_str(&intent.from)
            .map_err(|_| AppError::BadRequest("invalid sender address".into()))?;
        let to = Pubkey::from_str(&intent.to).map_err(|_| AppError::InvalidRecipient)?;
        let lamports = u64::try_from(intent.amount)
            .map_err(|_| AppError::BadRequest("amount exceeds the maximum for SOL".into()))?;

        // System Program transfer instruction: a 4-byte little-endian discriminant (2)
        // followed by the lamport amount as a little-endian u64. Accounts are the sender
        // (writable signer) and the recipient (writable).
        let system_program = Pubkey::from_str("11111111111111111111111111111111")
            .expect("valid system program id");
        let mut data = Vec::with_capacity(12);
        data.extend_from_slice(&2u32.to_le_bytes());
        data.extend_from_slice(&lamports.to_le_bytes());
        let instruction = Instruction {
            program_id: system_program,
            accounts: vec![AccountMeta::new(from, true), AccountMeta::new(to, false)],
            data,
        };

        let blockhash = self.latest_blockhash().await?;
        let message = Message::new_with_blockhash(&[instruction], Some(&from), &blockhash);

        Ok(UnsignedTx {
            message: message.serialize(),
            valid_until: SystemTime::now() + Duration::from_secs(90),
        })
    }

    async fn validate_signed(&self, _signed: &[u8]) -> Result<(), AppError> {
        Err(AppError::Network("SolanaAdapter::validate_signed not implemented".into()))
    }

    async fn broadcast(&self, _signed: &[u8]) -> Result<String, AppError> {
        Err(AppError::Network("SolanaAdapter::broadcast not implemented".into()))
    }

    async fn status(&self, _signature: &str) -> Result<Commitment, AppError> {
        Err(AppError::Network("SolanaAdapter::status not implemented".into()))
    }
}
