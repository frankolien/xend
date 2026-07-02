//! The Xend backend entry point. It loads configuration, builds shared state, and serves.
//! Everything else lives in a dedicated module: the route table in [`app`], the HTTP
//! handlers in [`handlers`], persistence in [`store`], the chain abstraction in [`chain`],
//! shared state in [`state`], and error mapping in [`error`].
//!
//! The service's capability is bounded by the signing boundary: it reads the chain, builds
//! unsigned transactions, relays signed ones, and records what happened. It never signs.

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

use crate::chain::{ChainAdapter, SolanaAdapter};
use crate::state::AppState;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Structured JSON logging is initialized up front so request traces are available
    // throughout. Request-ID propagation and richer telemetry are added later.
    tracing_subscriber::fmt().json().init();

    let db_url = env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://xend:xend@localhost:5432/xend".to_string());
    let rpc_url = env::var("SOLANA_RPC_URL")
        .unwrap_or_else(|_| "https://api.devnet.solana.com".to_string());

    let pool = db::connect(&db_url).await?;
    let chain: Arc<dyn ChainAdapter> = Arc::new(SolanaAdapter::new(rpc_url));
    let state = AppState { pool, chain };
    let gateway = gateway::Gateway::from_env();

    let addr = env::var("XEND_ADDR").unwrap_or_else(|_| "0.0.0.0:8080".to_string());
    tracing::info!(%addr, "xend-backend listening");

    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app::router(state, gateway)).await?;
    Ok(())
}
