//! Xend backend entry point. Loads configuration, builds shared state, and serves.
//! Everything else lives in a dedicated module: the route table in [`app`], the HTTP
//! handlers in [`handlers`], persistence in [`store`], the chain abstraction in [`chain`],
//! shared state in [`state`], and error mapping in [`error`].
//!
//! The service reads the chain, builds unsigned transactions, relays signed ones, and
//! records what happened. Signing stays on the device.

mod app;
mod chain;
mod db;
mod error;
mod gateway;
mod handlers;
mod state;
mod store;

use std::env;
use std::sync::Arc;

use solana_sdk::signature::{Keypair, Signer};

use crate::chain::{ChainAdapter, SolanaAdapter};
use crate::state::AppState;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Structured JSON logging, initialized up front so request traces are available
    // throughout. Request-ID propagation and richer telemetry come later.
    tracing_subscriber::fmt().json().init();

    let db_url = env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://xend:xend@localhost:5432/xend".to_string());
    let rpc_url = env::var("SOLANA_RPC_URL")
        .unwrap_or_else(|_| "https://api.devnet.solana.com".to_string());
    // `.sol` domains live on mainnet, so name resolution defaults there regardless of which
    // cluster transfers settle on. A resolved name is a pubkey, valid on any cluster.
    let sns_rpc_url = env::var("SNS_RPC_URL")
        .unwrap_or_else(|_| "https://api.mainnet-beta.solana.com".to_string());

    // A configured paymaster enables gasless transfers: it becomes the fee payer for every
    // built transaction, so users transact holding no SOL. Without one, senders pay their
    // own fee. The secret is a base58 keypair string (as produced by `solana-keygen`).
    let fee_payer = match env::var("XEND_PAYMASTER_SECRET") {
        Ok(secret) => {
            let keypair = Keypair::from_base58_string(secret.trim());
            tracing::info!(paymaster = %keypair.pubkey(), "gasless enabled: sponsoring network fees");
            Some(keypair)
        }
        Err(_) => {
            tracing::info!(
                "gasless disabled: set XEND_PAYMASTER_SECRET (a base58 keypair) and fund its \
                 pubkey with devnet SOL to sponsor fees"
            );
            None
        }
    };

    let pool = db::connect(&db_url).await?;
    let chain: Arc<dyn ChainAdapter> = Arc::new(SolanaAdapter::new(rpc_url, sns_rpc_url, fee_payer));
    let state = AppState { pool, chain };
    let gateway = gateway::Gateway::from_env();

    let addr = env::var("XEND_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".to_string());
    tracing::info!(%addr, "xend-backend listening");

    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app::router(state, gateway)).await?;
    Ok(())
}
