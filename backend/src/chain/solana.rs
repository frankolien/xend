//! Solana implementation of [`ChainAdapter`]. The only component that holds RPC
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

use super::{ChainAdapter, Commitment, SignedTransfer, TransferIntent, UnsignedTx};
use crate::error::AppError;
use crate::gateway::rate_limit::RateLimiter;

/// Sponsored builds allowed per sender wallet per hour.
const SPONSORED_BUILDS_PER_SENDER_PER_HOUR: u32 = 60;
/// Recipient token accounts the paymaster will fund per sender wallet per day.
const SPONSORED_ATAS_PER_SENDER_PER_DAY: u32 = 10;
/// Recipient token accounts the paymaster will fund across all senders per hour. At about
/// 0.002 SOL rent each this bounds the worst case to roughly 0.4 SOL an hour.
const SPONSORED_ATAS_GLOBAL_PER_HOUR: u32 = 200;

/// In-memory caps on what the paymaster pays for. Per-sender caps stop one wallet from
/// looping builds; the global cap on account creation covers senders rotating through
/// fresh wallets, which per-sender limits cannot see.
///
/// Residual risk: rent funded for a new recipient token account can be reclaimed by its
/// owner by closing the account, so up to the global cap per hour can still be extracted.
/// The counters are per process and reset on restart. A production deployment should tie
/// sponsorship to an authenticated user or API key budget and keep counters in a shared
/// store.
struct SponsorLimits {
    builds_per_sender: RateLimiter,
    atas_per_sender: RateLimiter,
    atas_global: RateLimiter,
}

impl SponsorLimits {
    fn new() -> Self {
        const HOUR: Duration = Duration::from_secs(3600);
        Self {
            builds_per_sender: RateLimiter::new(SPONSORED_BUILDS_PER_SENDER_PER_HOUR, HOUR),
            atas_per_sender: RateLimiter::new(SPONSORED_ATAS_PER_SENDER_PER_DAY, HOUR * 24),
            atas_global: RateLimiter::new(SPONSORED_ATAS_GLOBAL_PER_HOUR, HOUR),
        }
    }

    fn allow_build(&self, sender: &Pubkey) -> Result<(), AppError> {
        self.builds_per_sender
            .record(&sender.to_string())
            .map_err(|retry_after_secs| AppError::RateLimited { retry_after_secs })
    }

    fn allow_ata_creation(&self, sender: &Pubkey) -> Result<(), AppError> {
        self.atas_per_sender
            .record(&sender.to_string())
            .and_then(|()| self.atas_global.record("global"))
            .map_err(|retry_after_secs| AppError::RateLimited { retry_after_secs })
    }
}

/// Solana implementation of [`ChainAdapter`]. Holds the RPC endpoint and an HTTP client
/// for JSON-RPC calls.
///
/// When a `fee_payer` keypair is present, transfers use that account as the Solana fee
/// payer and co-sign with it, letting a user transact holding no SOL (the "gasless" path).
/// The fee payer only authorizes paying the network fee; the sender's signature is still
/// required to move their funds, so the backend cannot spend on a user's behalf.
pub struct SolanaAdapter {
    rpc_url: String,
    /// RPC used only for Solana Name Service lookups. `.sol` domains live on mainnet, so
    /// this defaults there even when transfers settle on another cluster. A name resolves
    /// to a real pubkey, which is a valid recipient on whichever cluster `rpc_url` targets.
    sns_rpc_url: String,
    http: reqwest::Client,
    fee_payer: Option<Keypair>,
    sponsor_limits: SponsorLimits,
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
            sponsor_limits: SponsorLimits::new(),
        }
    }

    /// Fetches a recent blockhash to anchor a new transaction.
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

        // Fee payer is the paymaster when fees are sponsored, otherwise the sender. It pays
        // the network fee and funds any account rent (a new associated token account), so a
        // sponsored user needs no SOL.
        let sponsor = self.fee_payer.as_ref().map(|k| k.pubkey());
        let payer = sponsor.unwrap_or(from);

        if let Some(sponsor) = sponsor {
            // With the paymaster as sender, its co-signature would be the only one the
            // transfer needs, so anyone could move its funds. Sending to it is refused too:
            // it keeps the paymaster out of every role except fee payer.
            if from == sponsor {
                return Err(AppError::BadRequest(
                    "sender cannot be the fee payer account".into(),
                ));
            }
            if to == sponsor {
                return Err(AppError::InvalidRecipient);
            }
            self.sponsor_limits.allow_build(&from)?;
        }

        // Native transfer is one System instruction. Token transfer is an idempotent
        // "create recipient's associated token account" followed by a checked transfer
        // between the two owners' associated accounts.
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
                let transfer =
                    token_transfer_checked(&source_ata, &mint, &dest_ata, &from, amount, decimals);

                // Fee payer funds the recipient's token account so token sends are gasless
                // too; the transfer is still authorized by `from`. When sponsored, the
                // create is only included if the account is missing, and each one counts
                // against the rent caps.
                let needs_create = match sponsor {
                    Some(_) => !self.account_exists(&dest_ata).await?,
                    None => true,
                };
                if needs_create {
                    if sponsor.is_some() {
                        self.sponsor_limits.allow_ata_creation(&from)?;
                    }
                    vec![create_ata_idempotent(&payer, &to, &mint, &dest_ata), transfer]
                } else {
                    vec![transfer]
                }
            }
        };

        let blockhash = self.latest_blockhash().await?;
        let message = Message::new_with_blockhash(&instructions, Some(&payer), &blockhash);

        // Last line of defence before the paymaster signs anything: the message must use it
        // only as fee payer and ATA rent funder.
        if let Some(sponsor) = &sponsor {
            check_sponsored_message(&message, sponsor).inspect_err(|e| {
                tracing::warn!(error = %e, from = %from, "refused to co-sign a sponsored message");
            })?;
        }
        let message_bytes = message.serialize();

        // Co-sign the fee-payer slot now so the device only adds its own signature. Both
        // sign the identical message bytes and are placed in signer order on assembly.
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
        // and custom SOL records are left for a later pass.
        let label = name
            .strip_suffix(".sol")
            .filter(|l| !l.is_empty() && !l.contains('.'))
            .ok_or(AppError::InvalidRecipient)?;

        let domain_key = sol_domain_key(label);
        let owner = self.sns_domain_owner(&domain_key).await?;
        Ok(owner.to_string())
    }

    async fn validate_signed(
        &self,
        signed: &[u8],
        claimed_to: Option<&str>,
    ) -> Result<Option<SignedTransfer>, AppError> {
        // Parse the wire-format transaction and verify every signature against the message
        // it signs. Rejects a malformed payload or tampered message locally, before it is
        // relayed to the network.
        let tx: Transaction = bincode::deserialize(signed)
            .map_err(|e| AppError::BadRequest(format!("malformed signed transaction: {e}")))?;
        tx.verify()
            .map_err(|_| AppError::BadRequest("transaction signature verification failed".into()))?;
        Ok(summarize_transfer(&tx.message, claimed_to))
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
            // No record for this signature yet: still propagating or dropped. Report the
            // least-final level; the client keeps checking (and, from Phase 5, subscribes)
            // until the status advances.
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
        // Reject a malformed address before an RPC round trip.
        Pubkey::from_str(address).map_err(|_| AppError::BadRequest("invalid address".into()))?;

        match mint {
            None => self.native_balance(address).await,
            Some(mint) => self.token_balance(address, mint).await,
        }
    }
}

impl SolanaAdapter {
    /// Whether an account exists, via `getAccountInfo` with an empty data slice.
    async fn account_exists(&self, address: &Pubkey) -> Result<bool, AppError> {
        let request = serde_json::json!({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getAccountInfo",
            "params": [
                address.to_string(),
                { "encoding": "base64", "commitment": "confirmed", "dataSlice": { "offset": 0, "length": 0 } }
            ],
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
            return Err(AppError::Network(format!("getAccountInfo failed: {error}")));
        }
        Ok(!body["result"]["value"].is_null())
    }

    /// Native SOL balance in lamports, via `getBalance`.
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

    /// Balance of an SPL token in base units. Sums every token account the owner holds for
    /// `mint` (normally just the associated token account); no account means zero balance.
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

    /// Reads a token mint's decimals via `getTokenSupply`. `transferChecked` requires the
    /// mint's decimals, which the client does not send, so the backend resolves it here.
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

    /// Reads the owner (registered address) of a Name Service domain account from the SNS
    /// RPC. The account data begins with a fixed header: parent (32), owner (32), class
    /// (32), so the owner is the second 32-byte field. A missing account means the name is
    /// not registered.
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
/// Associated Token Account program: derives and creates a wallet's canonical token
/// account for a given mint.
const ASSOCIATED_TOKEN_PROGRAM_ID: &str = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL";
/// System program.
const SYSTEM_PROGRAM_ID: &str = "11111111111111111111111111111111";

/// SPL Name Service program; owns every `.sol` domain account.
const NAME_PROGRAM_ID: &str = "namesLPneVptA9Z5rqUDD9tMTWEJwofgaYwp8cawRkX";
/// The `.sol` top-level-domain account; every `.sol` domain is derived under it.
const SOL_TLD_AUTHORITY: &str = "58PwtjSDuFHuUkYjH9BYnnQKHfwo9reZhC2zMJv9JPkx";
/// Domain hashing prefix, prepended to a label before SHA-256 to form the seed.
const SNS_HASH_PREFIX: &str = "SPL Name Service";

fn program(id: &str) -> Pubkey {
    Pubkey::from_str(id).expect("valid built-in program id")
}

/// Derives the Name Service account for a single `.sol` label: the program address of
/// `[sha256("SPL Name Service" + label), default_class, sol_tld]` under the Name Service
/// program. Same hashing and derivation every SNS client uses, so it yields the account a
/// domain resolves to.
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

/// An idempotent "create associated token account" instruction: creates `ata` for
/// `owner`/`mint` funded by `funder`, and is a no-op if the account already exists. Data
/// byte `1` selects the idempotent variant.
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

/// Checks a message before the paymaster co-signs it. The fee payer may appear only at
/// account index 0 and, inside instructions, only as the funding account (position 0) of a
/// single create-idempotent associated token account instruction. It may never be a
/// transfer source, token authority, or hold any other role. Programs are limited to
/// System, SPL Token and Associated Token, and exactly two signatures are required (fee
/// payer and sender).
fn check_sponsored_message(message: &Message, fee_payer: &Pubkey) -> Result<(), AppError> {
    let refuse = |why: &str| {
        Err(AppError::BadRequest(format!(
            "transaction is not eligible for fee sponsorship: {why}"
        )))
    };

    let keys = &message.account_keys;
    if keys.first() != Some(fee_payer) {
        return refuse("fee payer is not the first account");
    }
    if keys.iter().skip(1).any(|k| k == fee_payer) {
        return refuse("fee payer appears more than once");
    }
    if message.header.num_required_signatures != 2 {
        return refuse("expected exactly the fee payer and the sender to sign");
    }

    let system = program(SYSTEM_PROGRAM_ID);
    let token = program(TOKEN_PROGRAM_ID);
    let ata = program(ASSOCIATED_TOKEN_PROGRAM_ID);
    let mut funded_creates = 0;

    for ix in &message.instructions {
        let Some(program_id) = keys.get(usize::from(ix.program_id_index)) else {
            return refuse("instruction references a missing program");
        };
        if ![system, token, ata].contains(program_id) {
            return refuse("instruction calls a program outside the allowlist");
        }
        for (position, &index) in ix.accounts.iter().enumerate() {
            if index != 0 {
                continue;
            }
            let is_ata_funder = *program_id == ata && position == 0 && ix.data == [1];
            if !is_ata_funder {
                return refuse("fee payer is used outside the fee payer role");
            }
            funded_creates += 1;
        }
    }
    if funded_creates > 1 {
        return refuse("fee payer funds more than one account");
    }
    Ok(())
}

/// Reads the transfer a signed message performs. Recognises the shapes `build_transfer`
/// produces: one System transfer, or one SPL `transferChecked` optionally preceded by an
/// associated token account create. Anything else returns `None`.
///
/// For a token transfer the recipient wallet is the owner named in the create
/// instruction. Without one, `claimed_to` is accepted only if its associated token account
/// is the transfer's destination.
fn summarize_transfer(message: &Message, claimed_to: Option<&str>) -> Option<SignedTransfer> {
    let keys = &message.account_keys;
    let is_signer = |index: u8| index < message.header.num_required_signatures;
    let key = |index: u8| keys.get(usize::from(index)).copied();

    let system = program(SYSTEM_PROGRAM_ID);
    let token = program(TOKEN_PROGRAM_ID);
    let ata = program(ASSOCIATED_TOKEN_PROGRAM_ID);

    // (ata, owner, mint) of a create instruction, if any.
    let mut created: Option<(Pubkey, Pubkey, Pubkey)> = None;
    let mut transfer: Option<SignedTransfer> = None;
    let mut token_dest: Option<Pubkey> = None;

    for ix in &message.instructions {
        let program_id = key(ix.program_id_index)?;
        let accounts = &ix.accounts;

        if program_id == system && ix.data.len() == 12 && ix.data[..4] == 2u32.to_le_bytes() {
            if transfer.is_some() || accounts.len() < 2 || !is_signer(accounts[0]) {
                return None;
            }
            let lamports = u64::from_le_bytes(ix.data[4..12].try_into().ok()?);
            transfer = Some(SignedTransfer {
                from: key(accounts[0])?.to_string(),
                to: Some(key(accounts[1])?.to_string()),
                amount: u128::from(lamports),
                mint: None,
            });
        } else if program_id == token && ix.data.len() == 10 && ix.data[0] == 12 {
            if transfer.is_some() || accounts.len() < 4 || !is_signer(accounts[3]) {
                return None;
            }
            let amount = u64::from_le_bytes(ix.data[1..9].try_into().ok()?);
            token_dest = Some(key(accounts[2])?);
            transfer = Some(SignedTransfer {
                from: key(accounts[3])?.to_string(),
                to: None,
                amount: u128::from(amount),
                mint: Some(key(accounts[1])?.to_string()),
            });
        } else if program_id == ata && matches!(ix.data.as_slice(), [] | [0] | [1]) {
            if created.is_some() || accounts.len() < 4 {
                return None;
            }
            created = Some((key(accounts[1])?, key(accounts[2])?, key(accounts[3])?));
        } else {
            return None;
        }
    }

    let mut transfer = transfer?;
    if let (Some(dest), Some(mint)) = (token_dest, transfer.mint.as_deref()) {
        let mint = Pubkey::from_str(mint).ok()?;
        transfer.to = match created {
            Some((ata, owner, created_mint)) if ata == dest && created_mint == mint => {
                Some(owner.to_string())
            }
            _ => claimed_to
                .and_then(|c| Pubkey::from_str(c).ok())
                .filter(|owner| associated_token_address(owner, &mint) == dest)
                .map(|owner| owner.to_string()),
        };
    }
    Some(transfer)
}

/// Maps a `sendTransaction` RPC error to an [`AppError`]. Expired blockhash is retryable
/// by rebuilding; a rejected instruction is terminal.
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

    /// Pins the signed-transaction wire format, the contract between device and backend:
    /// the SDK assembles `compact-u16(1) | signature | message` and
    /// [`SolanaAdapter::validate_signed`] parses it back with `bincode`. Offline (no
    /// network, no real key): round-trips a transfer message and asserts it survives
    /// byte-for-byte.
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

        // Assemble the wire transaction as the SDK does: one signature, encoded as the
        // compact-u16 byte 0x01, then a placeholder signature and the message. (Signature
        // validity is exercised end-to-end on devnet, not here.)
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

    /// Pins the sponsored (gasless) wire contract: fee payer at signer index 0, sender at
    /// index 1, wire transaction `compact-u16(2) | fee_payer_sig | sender_sig | message`.
    /// Both keys sign the identical message bytes; `Transaction::verify` checks each
    /// signature against its account, passing only if both are present, valid, and in
    /// signer order. Offline: real keys, no network.
    #[test]
    fn sponsored_wire_format_verifies_two_signatures() {
        let fee_payer = Keypair::new();
        let sender = Keypair::new();
        let to = Pubkey::new_unique();

        let instruction = system_transfer(&sender.pubkey(), &to, 1_000_000).unwrap();
        // Fee payer is the message payer, so it takes signer index 0 and the sender index 1.
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
    /// The derivation must reproduce the Name Service account a domain lives at, or
    /// resolution reads the wrong account (or none). A match confirms the hashing, seeds,
    /// and program id.
    #[test]
    fn sol_domain_key_matches_published_account() {
        let expected =
            Pubkey::from_str("Crf8hzfthWGbGbLTVCiqRqV5MVnbpHB1L9KQMd6gsinb").unwrap();
        assert_eq!(sol_domain_key("bonfida"), expected);
    }

    /// Pins [`associated_token_address`] against a real devnet vector: the associated
    /// account observed on-chain for this owner and the devnet USDC mint. A wrong
    /// derivation sends tokens to a non-existent account, so this must not drift.
    #[test]
    fn associated_token_address_matches_onchain() {
        let owner = Pubkey::from_str("Hczgu2xfpJ9FsMzPCPWKgjKPt872r7mrVHNLctPWHAXU").unwrap();
        let mint = Pubkey::from_str("4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU").unwrap();
        let expected = Pubkey::from_str("4AwPrm7a8cqW8N21Jf66pgjeNgFUoJ7BAXuAw1tSxy76").unwrap();
        assert_eq!(associated_token_address(&owner, &mint), expected);
    }

    /// Pins the byte layout of the two token instructions, which the on-chain programs
    /// parse positionally: a mistake in a discriminant, amount, or account order is
    /// rejected by the runtime.
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

    /// `map_send_error` classifies RPC send errors so the SDK can react. Misclassifying an
    /// expired blockhash as terminal would stop the client from rebuilding and retrying.
    #[test]
    fn send_errors_are_classified() {
        let expired = serde_json::json!({ "message": "Blockhash not found" });
        assert!(matches!(map_send_error(&expired), AppError::BlockhashExpired));

        let height = serde_json::json!({ "message": "block height exceeded" });
        assert!(matches!(map_send_error(&height), AppError::BlockhashExpired));

        let broke = serde_json::json!({ "message": "Attempt to debit an account but found no record of a prior credit. insufficient funds" });
        assert!(matches!(map_send_error(&broke), AppError::InsufficientFunds));

        let other = serde_json::json!({ "message": "custom program error: 0x1" });
        match map_send_error(&other) {
            AppError::ChainRejected(msg) => assert_eq!(msg, "custom program error: 0x1"),
            e => panic!("expected ChainRejected, got {e:?}"),
        }
    }

    /// An adapter that sponsors fees but whose RPC is unreachable. Anything rejected before
    /// the first RPC call is rejected without the network; anything that gets further fails
    /// with a network error.
    fn sponsored_adapter() -> (SolanaAdapter, Pubkey) {
        let paymaster = Keypair::new();
        let pubkey = paymaster.pubkey();
        let adapter = SolanaAdapter::new("http://127.0.0.1:9", "http://127.0.0.1:9", Some(paymaster));
        (adapter, pubkey)
    }

    fn intent(from: &Pubkey, to: &Pubkey, mint: Option<&Pubkey>) -> TransferIntent {
        TransferIntent {
            from: from.to_string(),
            to: to.to_string(),
            amount: 1_000_000,
            mint: mint.map(|m| m.to_string()),
        }
    }

    /// The drain: `from` set to the paymaster would yield a message whose only required
    /// signature is the paymaster's, which the backend itself supplies.
    #[tokio::test]
    async fn build_refuses_the_paymaster_as_sender() {
        let (adapter, paymaster) = sponsored_adapter();
        let attacker = Pubkey::new_unique();
        let mint = Pubkey::new_unique();

        for mint in [None, Some(&mint)] {
            let result = adapter.build_transfer(&intent(&paymaster, &attacker, mint)).await;
            assert!(
                matches!(result, Err(AppError::BadRequest(_))),
                "paymaster as sender must be refused before signing"
            );
        }
    }

    #[tokio::test]
    async fn build_refuses_the_paymaster_as_recipient() {
        let (adapter, paymaster) = sponsored_adapter();
        let sender = Pubkey::new_unique();
        let result = adapter.build_transfer(&intent(&sender, &paymaster, None)).await;
        assert!(matches!(result, Err(AppError::InvalidRecipient)));
    }

    /// One sender cannot loop sponsored builds without limit.
    #[tokio::test]
    async fn sponsored_builds_are_capped_per_sender() {
        let (adapter, _) = sponsored_adapter();
        let sender = Pubkey::new_unique();
        let to = Pubkey::new_unique();
        for _ in 0..SPONSORED_BUILDS_PER_SENDER_PER_HOUR {
            // Passes the cap, then fails reaching the (absent) RPC.
            let result = adapter.build_transfer(&intent(&sender, &to, None)).await;
            assert!(matches!(result, Err(AppError::Network(_))));
        }
        let over = adapter.build_transfer(&intent(&sender, &to, None)).await;
        assert!(matches!(over, Err(AppError::RateLimited { .. })));

        // Another sender still has its own budget.
        let other = adapter
            .build_transfer(&intent(&Pubkey::new_unique(), &to, None))
            .await;
        assert!(matches!(other, Err(AppError::Network(_))));
    }

    #[test]
    fn sponsored_ata_creations_are_capped() {
        let limits = SponsorLimits::new();
        let sender = Pubkey::new_unique();
        for _ in 0..SPONSORED_ATAS_PER_SENDER_PER_DAY {
            limits.allow_ata_creation(&sender).unwrap();
        }
        assert!(limits.allow_ata_creation(&sender).is_err(), "per-sender cap");

        // Fresh wallets each time still run into the global cap.
        let remaining = SPONSORED_ATAS_GLOBAL_PER_HOUR - SPONSORED_ATAS_PER_SENDER_PER_DAY;
        for _ in 0..remaining {
            limits.allow_ata_creation(&Pubkey::new_unique()).unwrap();
        }
        assert!(limits.allow_ata_creation(&Pubkey::new_unique()).is_err(), "global cap");
    }

    fn sponsored_token_message(fee_payer: &Pubkey, sender: &Pubkey, to: &Pubkey) -> Message {
        let mint = Pubkey::new_unique();
        let dest = associated_token_address(to, &mint);
        let source = associated_token_address(sender, &mint);
        Message::new(
            &[
                create_ata_idempotent(fee_payer, to, &mint, &dest),
                token_transfer_checked(&source, &mint, &dest, sender, 5, 6),
            ],
            Some(fee_payer),
        )
    }

    #[test]
    fn policy_accepts_the_messages_build_produces() {
        let fee_payer = Pubkey::new_unique();
        let sender = Pubkey::new_unique();
        let to = Pubkey::new_unique();

        let sol = Message::new(&[system_transfer(&sender, &to, 5).unwrap()], Some(&fee_payer));
        check_sponsored_message(&sol, &fee_payer).expect("sponsored SOL send");

        let token = sponsored_token_message(&fee_payer, &sender, &to);
        check_sponsored_message(&token, &fee_payer).expect("sponsored token send");
    }

    /// The attack message itself, in case an input check is ever bypassed: the fee payer is
    /// the transfer source and the only signer.
    #[test]
    fn policy_rejects_fee_payer_as_transfer_source() {
        let fee_payer = Pubkey::new_unique();
        let attacker = Pubkey::new_unique();

        let drain = Message::new(
            &[system_transfer(&fee_payer, &attacker, 5).unwrap()],
            Some(&fee_payer),
        );
        assert!(check_sponsored_message(&drain, &fee_payer).is_err());

        // Same drain with a second signer to satisfy the signature count.
        let padded = Message::new(
            &[
                system_transfer(&attacker, &attacker, 0).unwrap(),
                system_transfer(&fee_payer, &attacker, 5).unwrap(),
            ],
            Some(&fee_payer),
        );
        assert_eq!(padded.header.num_required_signatures, 2);
        assert!(check_sponsored_message(&padded, &fee_payer).is_err());
    }

    #[test]
    fn policy_rejects_fee_payer_in_any_other_role() {
        let fee_payer = Pubkey::new_unique();
        let sender = Pubkey::new_unique();
        let mint = Pubkey::new_unique();

        // Fee payer as token authority over its own token account.
        let source = associated_token_address(&fee_payer, &mint);
        let dest = associated_token_address(&sender, &mint);
        let authority = Message::new(
            &[
                system_transfer(&sender, &sender, 0).unwrap(),
                token_transfer_checked(&source, &mint, &dest, &fee_payer, 5, 6),
            ],
            Some(&fee_payer),
        );
        assert!(check_sponsored_message(&authority, &fee_payer).is_err());

        // Fee payer as the owner of a created account rather than its funder.
        let own_ata = associated_token_address(&fee_payer, &mint);
        let as_owner = Message::new(
            &[
                create_ata_idempotent(&sender, &fee_payer, &mint, &own_ata),
                system_transfer(&sender, &sender, 0).unwrap(),
            ],
            Some(&fee_payer),
        );
        assert!(check_sponsored_message(&as_owner, &fee_payer).is_err());

        // Fee payer funding two accounts.
        let to = Pubkey::new_unique();
        let other = Pubkey::new_unique();
        let mut two = vec![
            create_ata_idempotent(&fee_payer, &to, &mint, &associated_token_address(&to, &mint)),
            create_ata_idempotent(&fee_payer, &other, &mint, &associated_token_address(&other, &mint)),
        ];
        two.push(token_transfer_checked(&dest, &mint, &dest, &sender, 1, 6));
        let two = Message::new(&two, Some(&fee_payer));
        assert!(check_sponsored_message(&two, &fee_payer).is_err());
    }

    #[test]
    fn policy_rejects_programs_outside_the_allowlist() {
        let fee_payer = Pubkey::new_unique();
        let sender = Pubkey::new_unique();
        let foreign = Instruction {
            program_id: Pubkey::new_unique(),
            accounts: vec![AccountMeta::new(sender, true)],
            data: vec![],
        };
        let message = Message::new(&[foreign], Some(&fee_payer));
        assert!(check_sponsored_message(&message, &fee_payer).is_err());
    }

    #[test]
    fn summary_reads_a_sol_transfer() {
        let fee_payer = Pubkey::new_unique();
        let sender = Pubkey::new_unique();
        let to = Pubkey::new_unique();
        let message = Message::new(&[system_transfer(&sender, &to, 42).unwrap()], Some(&fee_payer));

        let summary = summarize_transfer(&message, None).expect("recognised");
        assert_eq!(summary.from, sender.to_string());
        assert_eq!(summary.to, Some(to.to_string()));
        assert_eq!(summary.amount, 42);
        assert_eq!(summary.mint, None);
    }

    #[test]
    fn summary_reads_a_token_transfer_recipient() {
        let fee_payer = Pubkey::new_unique();
        let sender = Pubkey::new_unique();
        let to = Pubkey::new_unique();

        // With a create instruction the owner comes from the bytes.
        let message = sponsored_token_message(&fee_payer, &sender, &to);
        let summary = summarize_transfer(&message, Some("ignored")).expect("recognised");
        assert_eq!(summary.from, sender.to_string());
        assert_eq!(summary.to, Some(to.to_string()));
        assert_eq!(summary.amount, 5);

        // Without one, a claim is accepted only if it derives the destination account.
        let mint = Pubkey::new_unique();
        let dest = associated_token_address(&to, &mint);
        let source = associated_token_address(&sender, &mint);
        let bare = Message::new(
            &[token_transfer_checked(&source, &mint, &dest, &sender, 5, 6)],
            Some(&fee_payer),
        );
        let honest = summarize_transfer(&bare, Some(&to.to_string())).unwrap();
        assert_eq!(honest.to, Some(to.to_string()));
        assert_eq!(honest.mint, Some(mint.to_string()));
        let liar = Pubkey::new_unique().to_string();
        assert_eq!(summarize_transfer(&bare, Some(&liar)).unwrap().to, None);
    }

    #[test]
    fn summary_ignores_unrecognised_transactions() {
        let sender = Pubkey::new_unique();
        let to = Pubkey::new_unique();
        let foreign = Instruction {
            program_id: Pubkey::new_unique(),
            accounts: vec![AccountMeta::new(sender, true)],
            data: vec![],
        };
        let mixed = Message::new(
            &[system_transfer(&sender, &to, 1).unwrap(), foreign],
            Some(&sender),
        );
        assert!(summarize_transfer(&mixed, None).is_none());

        let double = Message::new(
            &[
                system_transfer(&sender, &to, 1).unwrap(),
                system_transfer(&sender, &to, 1).unwrap(),
            ],
            Some(&sender),
        );
        assert!(summarize_transfer(&double, None).is_none());
    }
}
