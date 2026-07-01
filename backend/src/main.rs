//! The Xend backend: a single binary organized as several independent modules whose
//! boundaries match the service boundaries it would be split into at scale, so that
//! extracting a service later is a matter of moving a module rather than restructuring.
//!
//! Its capabilities are bounded by the signing boundary: it reads the chain, builds
//! unsigned transactions, relays signed ones, and records what happened. It never signs.

mod chain; // chain adapters (multi-chain abstraction)
mod db; // connection pool and migrations
mod error; // error type and HTTP mapping
mod tx; // build, validate, submit, and confirm transactions
mod wallet; // public-key registration and balances
            // Planned modules: gateway (auth, rate limiting, request IDs),
            // auth (challenge/verify, sessions), notify (WebSocket fan-out).

use axum::{
    routing::{get, post},
    Router,
};
use std::env;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // Structured JSON logging is initialized up front so request traces are available
    // throughout. Request-ID propagation and richer telemetry are added later.
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

/// Liveness probe.
async fn health() -> &'static str {
    "ok"
}
