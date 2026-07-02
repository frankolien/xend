//! Dev utility: mint a fresh paymaster keypair for gasless (fee-sponsored) transfers.
//!
//! Run `cargo run --bin paymaster_keygen`, then:
//!   1. set `XEND_PAYMASTER_SECRET` to the printed secret and restart the backend, and
//!   2. fund the printed pubkey with devnet SOL (`solana airdrop 2 <pubkey> --url devnet`).
//!
//! The secret is the base58 keypair string that [`solana_sdk::signature::Keypair`] reads
//! back with `from_base58_string`, matching how the backend loads it. Devnet only — never
//! print or reuse a mainnet paymaster secret this way.

use solana_sdk::signature::{Keypair, Signer};

fn main() {
    let keypair = Keypair::new();
    println!("pubkey (fund this on devnet): {}", keypair.pubkey());
    println!("XEND_PAYMASTER_SECRET={}", keypair.to_base58_string());
}
