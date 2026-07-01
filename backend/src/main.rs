//! Xend backend — a single binary structured as if it were already five services.
//! The module boundaries below are drawn exactly where the service boundaries will
//! later fall, so "extract the tx service" is moving a folder, not untangling yarn.
//!
//! Powers are strictly bounded by the signing boundary: read the chain, build
//! unsigned tx, relay signed tx, remember what happened. It CANNOT sign.

mod chain; // ChainAdapter trait + SolanaAdapter  (the multi-chain seam)
mod db; // pool + migrations
mod error; // AppError → HTTP status mapping
mod tx; // build · validate · submit · confirm · idempotency  (the heart)
mod wallet; // register pubkey, balances
            // mod gateway;  // middleware: auth, rate-limit, request-id  (Phase 1/6)
            // mod auth;     // challenge/verify, session tokens           (Phase 1)
            // mod notify;   // ws hub, event fan-out                      (Phase 5)

use axum::{
    routing::{get, post},
    Router,
};
use std::env;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Structured JSON logging with request IDs is a Phase 6 hardening item; the
    // subscriber is initialized here from day one so traces exist while we build.
    tracing_subscriber::fmt().json().init();

    let db_url = env::var("DATABASE_URL")
        .unwrap_or_else(|_| "postgres://xend:xend@localhost:5432/xend".to_string());

    let pool = db::connect(&db_url).await?;

    let app = Router::new()
        .route("/health", get(health))
        .route("/v1/wallets", post(wallet::register))
        .with_state(pool);

    let addr = "0.0.0.0:8080";
    tracing::info!(%addr, "xend-backend listening");

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app).await?;
    Ok(())
}

/// Liveness. The first thing Phase 1 proves: the binary is up and routes.
async fn health() -> &'static str {
    "ok"
}
