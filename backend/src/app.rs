//! HTTP application wiring: the route table, mapping paths to handlers. Kept separate
//! from `main` so the bootstrap stays a thin shell and every route is visible in one
//! place.

use axum::{
    routing::{get, post},
    Router,
};

use crate::handlers::{health, tx, wallet};
use crate::state::AppState;

/// Builds the application router with all routes and shared state.
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(health::health))
        .route("/v1/wallets", post(wallet::register))
        .route("/v1/wallets/:pubkey/balance", get(wallet::balance))
        .route("/v1/tx/build", post(tx::build))
        .route("/v1/tx/submit", post(tx::submit))
        .route("/v1/tx/:signature", get(tx::status))
        .with_state(state)
}
