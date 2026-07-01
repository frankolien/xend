//! The Solana implementation of [`ChainAdapter`]. It is the only component that holds RPC
//! credentials and speaks Solana's JSON-RPC; all Solana-specific encoding lives here.

use std::str::FromStr;
use std::time::{Duration, SystemTime};

use async_trait::async_trait;
use base64::Engine;
use solana_sdk::hash::Hash;
use solana_sdk::instruction::{AccountMeta, Instruction};
use solana_sdk::message::Message;
use solana_sdk::pubkey::Pubkey;
use solana_sdk::transaction::Transaction;

use super::adapter::{ChainAdapter, Commitment, TransferIntent, UnsignedTx};
use crate::error::AppError;

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

    async fn validate_signed(&self, signed: &[u8]) -> Result<(), AppError> {
        // Parse the wire-format transaction and verify every signature against the
        // message it signs. This rejects a malformed payload or a tampered message
        // before it is ever broadcast, so a bad transaction fails locally rather than
        // being relayed to the network.
        let tx: Transaction = bincode::deserialize(signed)
            .map_err(|e| AppError::BadRequest(format!("malformed signed transaction: {e}")))?;
        tx.verify()
            .map_err(|_| AppError::BadRequest("transaction signature verification failed".into()))?;
        Ok(())
    }

    async fn broadcast(&self, signed: &[u8]) -> Result<String, AppError> {
        let encoded = base64::engine::general_purpose::STANDARD.encode(signed);
        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "sendTransaction",
            "params": [encoded, { "encoding": "base64", "preflightCommitment": "confirmed" }],
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

        if let Some(error) = body.get("error") {
            return Err(map_send_error(error));
        }

        let signature = body["result"]
            .as_str()
            .ok_or_else(|| AppError::Network("sendTransaction returned no signature".into()))?;
        Ok(signature.to_string())
    }

    async fn status(&self, signature: &str) -> Result<Commitment, AppError> {
        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getSignatureStatuses",
            "params": [[signature], { "searchTransactionHistory": true }],
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

        let value = &body["result"]["value"][0];
        if value.is_null() {
            // The network has no record for this signature yet: it is still propagating
            // or has been dropped. Report the least-final level; the client keeps checking
            // (and, from Phase 5, subscribes) until the status advances.
            return Ok(Commitment::Processed);
        }
        if !value["err"].is_null() {
            return Ok(Commitment::Failed);
        }

        let commitment = match value["confirmationStatus"].as_str() {
            Some("finalized") => Commitment::Finalized,
            Some("confirmed") => Commitment::Confirmed,
            _ => Commitment::Processed,
        };
        Ok(commitment)
    }

    async fn balance(&self, address: &str, mint: Option<&str>) -> Result<u128, AppError> {
        if mint.is_some() {
            return Err(AppError::BadRequest(
                "SPL token balances are not yet supported".into(),
            ));
        }

        // Reject a malformed address before spending an RPC round trip on it.
        Pubkey::from_str(address).map_err(|_| AppError::BadRequest("invalid address".into()))?;

        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getBalance",
            "params": [address, { "commitment": "confirmed" }],
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

        if let Some(error) = body.get("error") {
            return Err(AppError::Network(format!("getBalance failed: {error}")));
        }

        let lamports = body["result"]["value"]
            .as_u64()
            .ok_or_else(|| AppError::Network("getBalance returned no value".into()))?;
        Ok(u128::from(lamports))
    }
}

/// Maps a Solana `sendTransaction` JSON-RPC error into a typed [`AppError`] so the SDK
/// can branch on the cause: an expired blockhash is retryable by rebuilding, while a
/// rejected instruction is terminal for the submitted transaction.
fn map_send_error(error: &serde_json::Value) -> AppError {
    let message = error["message"].as_str().unwrap_or("transaction rejected");
    let lower = message.to_ascii_lowercase();
    if lower.contains("blockhash not found") || lower.contains("block height exceeded") {
        AppError::BlockhashExpired
    } else if lower.contains("insufficient") {
        AppError::InsufficientFunds
    } else {
        AppError::ChainRejected(message.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The signed-transaction wire format is the contract between the device and the
    /// backend: the SDK assembles `compact-u16(1) | signature | message`, and
    /// [`SolanaAdapter::validate_signed`] parses it back with `bincode`. This test pins
    /// that contract offline — no network, no real key — by round-tripping a
    /// representative transfer message and asserting the message survives byte-for-byte.
    #[test]
    fn signed_wire_format_round_trips() {
        let from = Pubkey::new_unique();
        let to = Pubkey::new_unique();
        let system_program =
            Pubkey::from_str("11111111111111111111111111111111").expect("valid system program id");

        let mut data = Vec::with_capacity(12);
        data.extend_from_slice(&2u32.to_le_bytes());
        data.extend_from_slice(&1_000_000u64.to_le_bytes());
        let instruction = Instruction {
            program_id: system_program,
            accounts: vec![AccountMeta::new(from, true), AccountMeta::new(to, false)],
            data,
        };
        let message = Message::new_with_blockhash(&[instruction], Some(&from), &Hash::default());
        let message_bytes = message.serialize();

        // Assemble the wire transaction exactly as the SDK does: one signature, encoded
        // as the compact-u16 byte 0x01, followed by a placeholder signature and the
        // message. (Signature validity is exercised end-to-end on devnet, not here.)
        let mut wire = Vec::with_capacity(1 + 64 + message_bytes.len());
        wire.push(1u8);
        wire.extend_from_slice(&[0u8; 64]);
        wire.extend_from_slice(&message_bytes);

        let tx: Transaction = bincode::deserialize(&wire).expect("wire transaction parses");
        assert_eq!(tx.signatures.len(), 1, "single-signer transfer has one signature");
        assert_eq!(
            tx.message.serialize(),
            message_bytes,
            "message survives the wire round trip byte-for-byte"
        );
    }
}
