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
use solana_sdk::signature::{Keypair, Signer};
use solana_sdk::transaction::Transaction;

use super::adapter::{ChainAdapter, Commitment, TransferIntent, UnsignedTx};
use crate::error::AppError;

/// The Solana implementation of [`ChainAdapter`]. It holds the RPC endpoint — the only
/// component with RPC credentials — and an HTTP client for JSON-RPC calls.
///
/// When a `fee_payer` keypair is present, transfers are built with that account as the
/// Solana fee payer and co-signed by it, so a user can transact holding no SOL (the
/// "gasless" path). The fee payer only authorizes paying the network fee; the sender's own
/// signature is still required to move their funds, so this never lets the backend spend on
/// a user's behalf.
pub struct SolanaAdapter {
    rpc_url: String,
    /// RPC used only for Solana Name Service lookups. `.sol` domains live on mainnet, so
    /// this defaults there even when transfers settle on another cluster: a name resolves
    /// to a real pubkey, which is a valid recipient on whichever cluster `rpc_url` targets.
    sns_rpc_url: String,
    http: reqwest::Client,
    fee_payer: Option<Keypair>,
}

impl SolanaAdapter {
    pub fn new(
        rpc_url: impl Into<String>,
        sns_rpc_url: impl Into<String>,
        fee_payer: Option<Keypair>,
    ) -> Self {
        Self {
            rpc_url: rpc_url.into(),
            sns_rpc_url: sns_rpc_url.into(),
            http: reqwest::Client::new(),
            fee_payer,
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
        let from = Pubkey::from_str(&intent.from)
            .map_err(|_| AppError::BadRequest("invalid sender address".into()))?;
        let to = Pubkey::from_str(&intent.to).map_err(|_| AppError::InvalidRecipient)?;

        // The fee payer is the paymaster when fees are sponsored, otherwise the sender. It
        // pays the network fee and funds any account rent (a new associated token account),
        // so a sponsored user needs no SOL at all.
        let payer = self
            .fee_payer
            .as_ref()
            .map(|k| k.pubkey())
            .unwrap_or(from);

        // A native transfer is one System instruction; a token transfer is an idempotent
        // "create the recipient's associated token account" followed by a checked token
        // transfer between the two owners' associated accounts.
        let instructions = match &intent.mint {
            None => vec![system_transfer(&from, &to, intent.amount)?],
            Some(mint) => {
                let mint = Pubkey::from_str(mint)
                    .map_err(|_| AppError::BadRequest("invalid mint".into()))?;
                let amount = u64::try_from(intent.amount).map_err(|_| {
                    AppError::BadRequest("amount exceeds the maximum for this token".into())
                })?;
                let decimals = self.mint_decimals(&mint).await?;
                let source_ata = associated_token_address(&from, &mint);
                let dest_ata = associated_token_address(&to, &mint);
                vec![
                    // The fee payer funds the recipient's token account so token sends are
                    // gasless too; the transfer itself is still authorized by `from`.
                    create_ata_idempotent(&payer, &to, &mint, &dest_ata),
                    token_transfer_checked(&source_ata, &mint, &dest_ata, &from, amount, decimals),
                ]
            }
        };

        let blockhash = self.latest_blockhash().await?;
        let message = Message::new_with_blockhash(&instructions, Some(&payer), &blockhash);
        let message_bytes = message.serialize();

        // Co-sign the fee-payer slot now, so the device only has to add its own signature.
        // Both sign the identical message bytes; they are placed in signer order on assembly.
        let fee_payer_signature = self
            .fee_payer
            .as_ref()
            .map(|k| k.sign_message(&message_bytes).as_ref().to_vec());

        Ok(UnsignedTx {
            message: message_bytes,
            valid_until: SystemTime::now() + Duration::from_secs(90),
            fee_payer_signature,
        })
    }

    async fn resolve_name(&self, name: &str) -> Result<String, AppError> {
        // v0.1 resolves a single-label `.sol` domain to its owner. Subdomains (`a.b.sol`)
        // and custom SOL records are recognized enhancements left for a later pass.
        let label = name
            .strip_suffix(".sol")
            .filter(|l| !l.is_empty() && !l.contains('.'))
            .ok_or(AppError::InvalidRecipient)?;

        let domain_key = sol_domain_key(label);
        let owner = self.sns_domain_owner(&domain_key).await?;
        Ok(owner.to_string())
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
        // Reject a malformed address before spending an RPC round trip on it.
        Pubkey::from_str(address).map_err(|_| AppError::BadRequest("invalid address".into()))?;

        match mint {
            None => self.native_balance(address).await,
            Some(mint) => self.token_balance(address, mint).await,
        }
    }
}

impl SolanaAdapter {
    /// The address's native SOL balance in lamports, via `getBalance`.
    async fn native_balance(&self, address: &str) -> Result<u128, AppError> {
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

    /// The address's balance of an SPL token, in the token's base units. Sums every token
    /// account the owner holds for `mint` (normally just the associated token account);
    /// an owner with no such account has a zero balance.
    async fn token_balance(&self, owner: &str, mint: &str) -> Result<u128, AppError> {
        Pubkey::from_str(mint).map_err(|_| AppError::BadRequest("invalid mint".into()))?;

        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getTokenAccountsByOwner",
            "params": [owner, { "mint": mint }, { "encoding": "jsonParsed" }],
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
            return Err(AppError::Network(format!(
                "getTokenAccountsByOwner failed: {error}"
            )));
        }

        let accounts = body["result"]["value"]
            .as_array()
            .ok_or_else(|| AppError::Network("getTokenAccountsByOwner returned no value".into()))?;

        let mut total: u128 = 0;
        for account in accounts {
            let amount = account["account"]["data"]["parsed"]["info"]["tokenAmount"]["amount"]
                .as_str()
                .ok_or_else(|| AppError::Network("token account missing amount".into()))?;
            let parsed: u128 = amount
                .parse()
                .map_err(|_| AppError::Network("token amount is not an integer".into()))?;
            total = total.saturating_add(parsed);
        }
        Ok(total)
    }

    /// Reads a token mint's decimal precision via `getTokenSupply`. `transferChecked`
    /// requires the caller to pass the mint's decimals, which the client does not send, so
    /// the backend resolves it here.
    async fn mint_decimals(&self, mint: &Pubkey) -> Result<u8, AppError> {
        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getTokenSupply",
            "params": [mint.to_string()],
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

        let decimals = body["result"]["value"]["decimals"].as_u64().ok_or_else(|| {
            AppError::BadRequest("mint not found or is not a token mint".into())
        })?;
        u8::try_from(decimals).map_err(|_| AppError::Network("invalid mint decimals".into()))
    }

    /// Reads the owner of a Name Service domain account (its registered address) from the
    /// SNS RPC. The account's data begins with a fixed header — parent (32), owner (32),
    /// class (32) — so the owner is the second 32-byte field. A missing account means the
    /// name is not registered.
    async fn sns_domain_owner(&self, domain: &Pubkey) -> Result<Pubkey, AppError> {
        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getAccountInfo",
            "params": [domain.to_string(), { "encoding": "base64", "commitment": "confirmed" }],
        });

        let response = self
            .http
            .post(&self.sns_rpc_url)
            .json(&request)
            .send()
            .await
            .map_err(|e| AppError::Network(format!("sns rpc request failed: {e}")))?;

        let body: serde_json::Value = response
            .json()
            .await
            .map_err(|e| AppError::Network(format!("sns rpc decode failed: {e}")))?;

        let value = &body["result"]["value"];
        if value.is_null() {
            // No such account: the name has not been registered.
            return Err(AppError::InvalidRecipient);
        }

        let encoded = value["data"][0]
            .as_str()
            .ok_or_else(|| AppError::Network("sns account has no data".into()))?;
        let data = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(|_| AppError::Network("sns account data is not base64".into()))?;

        // parent (32) + owner (32) + class (32) header must be present.
        let owner: [u8; 32] = data
            .get(32..64)
            .and_then(|s| s.try_into().ok())
            .ok_or_else(|| AppError::Network("sns account data is too short".into()))?;
        Ok(Pubkey::new_from_array(owner))
    }
}

/// SPL Token program.
const TOKEN_PROGRAM_ID: &str = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA";
/// Associated Token Account program, which derives and creates a wallet's canonical token
/// account for a given mint.
const ASSOCIATED_TOKEN_PROGRAM_ID: &str = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL";
/// System program.
const SYSTEM_PROGRAM_ID: &str = "11111111111111111111111111111111";

/// SPL Name Service program, which owns every `.sol` domain account.
const NAME_PROGRAM_ID: &str = "namesLPneVptA9Z5rqUDD9tMTWEJwofgaYwp8cawRkX";
/// The `.sol` top-level-domain account; every `.sol` domain is derived under it.
const SOL_TLD_AUTHORITY: &str = "58PwtjSDuFHuUkYjH9BYnnQKHfwo9reZhC2zMJv9JPkx";
/// Domain hashing prefix, prepended to a label before SHA-256 to form the seed.
const SNS_HASH_PREFIX: &str = "SPL Name Service";

fn program(id: &str) -> Pubkey {
    Pubkey::from_str(id).expect("valid built-in program id")
}

/// Derives the Name Service account for a single `.sol` label — the program address of
/// `[sha256("SPL Name Service" + label), default_class, sol_tld]` under the Name Service
/// program. The hashing and derivation are the same ones every SNS client uses, so this
/// yields the exact account a domain resolves to.
fn sol_domain_key(label: &str) -> Pubkey {
    let hashed = solana_sdk::hash::hashv(&[SNS_HASH_PREFIX.as_bytes(), label.as_bytes()]);
    let (key, _bump) = Pubkey::find_program_address(
        &[
            hashed.as_ref(),
            Pubkey::default().as_ref(),
            program(SOL_TLD_AUTHORITY).as_ref(),
        ],
        &program(NAME_PROGRAM_ID),
    );
    key
}

/// A System Program transfer of `amount` lamports from `from` (writable signer) to `to`
/// (writable). The instruction data is the discriminant `2` (u32 LE) then the amount
/// (u64 LE).
fn system_transfer(from: &Pubkey, to: &Pubkey, amount: u128) -> Result<Instruction, AppError> {
    let lamports = u64::try_from(amount)
        .map_err(|_| AppError::BadRequest("amount exceeds the maximum for SOL".into()))?;
    let mut data = Vec::with_capacity(12);
    data.extend_from_slice(&2u32.to_le_bytes());
    data.extend_from_slice(&lamports.to_le_bytes());
    Ok(Instruction {
        program_id: program(SYSTEM_PROGRAM_ID),
        accounts: vec![AccountMeta::new(*from, true), AccountMeta::new(*to, false)],
        data,
    })
}

/// Derives the canonical associated token account for `owner` and `mint`: the program
/// address of `[owner, token_program, mint]` under the Associated Token Account program.
fn associated_token_address(owner: &Pubkey, mint: &Pubkey) -> Pubkey {
    let token_program = program(TOKEN_PROGRAM_ID);
    let (address, _bump) = Pubkey::find_program_address(
        &[owner.as_ref(), token_program.as_ref(), mint.as_ref()],
        &program(ASSOCIATED_TOKEN_PROGRAM_ID),
    );
    address
}

/// An idempotent "create associated token account" instruction: it creates `ata` for
/// `owner`/`mint`, funded by `funder`, and is a no-op if the account already exists. The
/// single data byte `1` selects the idempotent variant.
fn create_ata_idempotent(
    funder: &Pubkey,
    owner: &Pubkey,
    mint: &Pubkey,
    ata: &Pubkey,
) -> Instruction {
    Instruction {
        program_id: program(ASSOCIATED_TOKEN_PROGRAM_ID),
        accounts: vec![
            AccountMeta::new(*funder, true),
            AccountMeta::new(*ata, false),
            AccountMeta::new_readonly(*owner, false),
            AccountMeta::new_readonly(*mint, false),
            AccountMeta::new_readonly(program(SYSTEM_PROGRAM_ID), false),
            AccountMeta::new_readonly(program(TOKEN_PROGRAM_ID), false),
        ],
        data: vec![1],
    }
}

/// A Token Program `transferChecked` (instruction `12`) moving `amount` base units from
/// `source` to `destination`, authorized by `owner` and validated against the mint's
/// `decimals`. Data is `[12, amount(u64 LE), decimals]`.
fn token_transfer_checked(
    source: &Pubkey,
    mint: &Pubkey,
    destination: &Pubkey,
    owner: &Pubkey,
    amount: u64,
    decimals: u8,
) -> Instruction {
    let mut data = Vec::with_capacity(10);
    data.push(12);
    data.extend_from_slice(&amount.to_le_bytes());
    data.push(decimals);
    Instruction {
        program_id: program(TOKEN_PROGRAM_ID),
        accounts: vec![
            AccountMeta::new(*source, false),
            AccountMeta::new_readonly(*mint, false),
            AccountMeta::new(*destination, false),
            AccountMeta::new_readonly(*owner, true),
        ],
        data,
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

    /// Pins the sponsored (gasless) wire contract: a fee payer at signer index 0 and the
    /// sender at index 1, with the wire transaction `compact-u16(2) | fee_payer_sig |
    /// sender_sig | message`. Both keys sign the identical message bytes; `Transaction::verify`
    /// then checks each signature against its account, which passes only if the two
    /// signatures are present, valid, and in signer order — exactly what the SDK must
    /// assemble. Offline: real keys, no network.
    #[test]
    fn sponsored_wire_format_verifies_two_signatures() {
        let fee_payer = Keypair::new();
        let sender = Keypair::new();
        let to = Pubkey::new_unique();

        let instruction = system_transfer(&sender.pubkey(), &to, 1_000_000).unwrap();
        // Fee payer is the message payer, so it occupies signer index 0 and the sender index 1.
        let message =
            Message::new_with_blockhash(&[instruction], Some(&fee_payer.pubkey()), &Hash::default());
        let message_bytes = message.serialize();
        assert_eq!(
            message.header.num_required_signatures, 2,
            "a sponsored transfer requires the fee payer and the sender to sign"
        );

        let fee_payer_sig = fee_payer.sign_message(&message_bytes);
        let sender_sig = sender.sign_message(&message_bytes);

        let mut wire = Vec::with_capacity(1 + 64 * 2 + message_bytes.len());
        wire.push(2u8); // compact-u16 signature count
        wire.extend_from_slice(fee_payer_sig.as_ref());
        wire.extend_from_slice(sender_sig.as_ref());
        wire.extend_from_slice(&message_bytes);

        let tx: Transaction = bincode::deserialize(&wire).expect("wire transaction parses");
        assert_eq!(tx.signatures.len(), 2);
        tx.verify().expect("both signatures verify in signer order");
    }

    /// Pins [`sol_domain_key`] against the published on-chain account for `bonfida.sol`.
    /// The derivation must reproduce the exact Name Service account a domain lives at, or
    /// resolution would read the wrong account (or none). This is the same account every
    /// SNS client derives, so a match confirms the hashing, seeds, and program id are right.
    #[test]
    fn sol_domain_key_matches_published_account() {
        let expected =
            Pubkey::from_str("Crf8hzfthWGbGbLTVCiqRqV5MVnbpHB1L9KQMd6gsinb").unwrap();
        assert_eq!(sol_domain_key("bonfida"), expected);
    }

    /// Pins [`associated_token_address`] against a real devnet vector: the associated
    /// account observed on-chain for this owner and the devnet USDC mint. A wrong
    /// derivation would send tokens to a non-existent account, so this must not drift.
    #[test]
    fn associated_token_address_matches_onchain() {
        let owner = Pubkey::from_str("Hczgu2xfpJ9FsMzPCPWKgjKPt872r7mrVHNLctPWHAXU").unwrap();
        let mint = Pubkey::from_str("4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU").unwrap();
        let expected = Pubkey::from_str("4AwPrm7a8cqW8N21Jf66pgjeNgFUoJ7BAXuAw1tSxy76").unwrap();
        assert_eq!(associated_token_address(&owner, &mint), expected);
    }

    /// Pins the byte layout of the two token instructions, which the on-chain programs
    /// parse positionally: a mistake in a discriminant, an amount, or an account order
    /// would be rejected by the runtime.
    #[test]
    fn token_instructions_are_well_formed() {
        let owner = Pubkey::new_unique();
        let mint = Pubkey::new_unique();
        let source = Pubkey::new_unique();
        let dest = Pubkey::new_unique();

        let create = create_ata_idempotent(&owner, &owner, &mint, &dest);
        assert_eq!(create.program_id, program(ASSOCIATED_TOKEN_PROGRAM_ID));
        assert_eq!(create.data, vec![1], "idempotent create variant");
        assert_eq!(create.accounts.len(), 6);
        assert!(create.accounts[0].is_signer && create.accounts[0].is_writable);

        let transfer = token_transfer_checked(&source, &mint, &dest, &owner, 1_500_000, 6);
        assert_eq!(transfer.program_id, program(TOKEN_PROGRAM_ID));
        // [12, amount(u64 LE), decimals]
        let mut expected = vec![12u8];
        expected.extend_from_slice(&1_500_000u64.to_le_bytes());
        expected.push(6);
        assert_eq!(transfer.data, expected);
        assert_eq!(transfer.accounts.len(), 4);
        assert!(transfer.accounts[3].is_signer, "owner authorizes the transfer");
    }
}
