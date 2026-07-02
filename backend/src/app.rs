//! HTTP application wiring: the route table plus the gateway middleware. Public `health`
//! stays open; the versioned API sits behind API-key auth and rate limiting; request-ID
//! propagation wraps everything. Kept separate from `main` so the bootstrap stays thin and
//! the route table is visible in one place.

use axum::{
    routing::{get, post},
    Router,
};

use crate::gateway::{self, auth, rate_limit, request_id};
use crate::handlers::{health, resolve, tx, wallet};
use crate::state::AppState;

/// Builds the application router with all routes, shared state, and gateway middleware.
pub fn router(state: AppState, gw: gateway::Gateway) -> Router {
    // The versioned API, guarded by auth and rate limiting.
    let api = Router::new()
        .route("/wallets", post(wallet::register))
        .route("/wallets/:pubkey/balance", get(wallet::balance))
        .route("/wallets/:pubkey/transactions", get(wallet::history))
        .route("/tx/build", post(tx::build))
        .route("/tx/submit", post(tx::submit))
        .route("/tx/:signature", get(tx::status))
        .route("/resolve", get(resolve::resolve))
        .layer(axum::middleware::from_fn_with_state(
            gw.api_keys.clone(),
            auth::require_api_key,
        ))
        .layer(axum::middleware::from_fn_with_state(
            gw.rate_limiter.clone(),
            rate_limit::enforce,
        ))
        .with_state(state);

    Router::new()
        .route("/health", get(health::health))
        .nest("/v1", api)
        .layer(axum::middleware::from_fn(request_id::propagate))
}
