//! Dev utility: exercise the gasless (fee-sponsored) send path against a running backend,
//! end to end, exactly as the mobile SDK does — build, sign with the user key, assemble the
//! two-signature wire transaction, and submit.
//!
//! Usage:
//!   cargo run --bin gasless_client -- <base_url> <from_secret_base58> <to_pubkey> <lamports>
//!
//! It prints whether the fee was sponsored and the resulting on-chain signature. Fund the
//! sender with only the transfer `amount` (no fee buffer) to prove the paymaster, not the
//! sender, paid the network fee. Devnet only.

use std::env;

use base64::Engine;
use solana_sdk::signature::{Keypair, Signer};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = env::args().collect();
    let base_url = args
        .get(1)
        .cloned()
        .unwrap_or_else(|| "http://localhost:8081".to_string());
    let from = Keypair::from_base58_string(args.get(2).expect("from_secret_base58"));
    let to_arg = args.get(3).expect("to (address or .sol name)").clone();
    let lamports: u64 = args.get(4).expect("lamports").parse()?;

    let http = reqwest::Client::new();
    let b64 = base64::engine::general_purpose::STANDARD;

    // Resolve a `.sol` name to an address first, exactly as the SDK's send() does.
    let to = if to_arg.to_lowercase().ends_with(".sol") {
        let resolved: serde_json::Value = http
            .get(format!("{base_url}/v1/resolve"))
            .query(&[("name", &to_arg)])
            .send()
            .await?
            .json()
            .await?;
        let address = resolved["address"]
            .as_str()
            .ok_or("name did not resolve")?
            .to_string();
        println!("resolved {to_arg} -> {address}");
        address
    } else {
        to_arg
    };

    // 1. Build the unsigned transfer. The backend chooses the fee payer and, when it
    //    sponsors, returns the fee payer's signature over the message.
    let build: serde_json::Value = http
        .post(format!("{base_url}/v1/tx/build"))
        .json(&serde_json::json!({
            "from": from.pubkey().to_string(),
            "to": to,
            "amount": lamports.to_string(),
        }))
        .send()
        .await?
        .json()
        .await?;
    let message = b64.decode(build["message"].as_str().ok_or("build returned no message")?)?;
    let fee_payer_sig = build["fee_payer_signature"].as_str();
    println!("fee sponsored by backend: {}", fee_payer_sig.is_some());

    // 2. Sign the message with the sender's key (the device's role in the SDK).
    let user_sig = from.sign_message(&message);

    // 3. Assemble the wire transaction: compact-u16 signature count, each signature in signer
    //    order (fee payer first when sponsored, then sender), then the message.
    let mut signatures: Vec<Vec<u8>> = Vec::new();
    if let Some(sig) = fee_payer_sig {
        signatures.push(b64.decode(sig)?);
    }
    signatures.push(user_sig.as_ref().to_vec());

    let mut wire = Vec::new();
    wire.push(signatures.len() as u8); // compact-u16 for a tiny count is a single byte
    for signature in &signatures {
        wire.extend_from_slice(signature);
    }
    wire.extend_from_slice(&message);
    println!("assembled {} signature(s)", signatures.len());

    // 4. Submit for broadcast.
    let submit: serde_json::Value = http
        .post(format!("{base_url}/v1/tx/submit"))
        .json(&serde_json::json!({
            "signed": b64.encode(&wire),
            "idempotency_key": format!("gasless-{user_sig}"),
            "pubkey": from.pubkey().to_string(),
            "to": to,
            "amount": lamports.to_string(),
        }))
        .send()
        .await?
        .json()
        .await?;
    println!("submit response: {submit}");
    Ok(())
}
