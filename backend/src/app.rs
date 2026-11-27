//! HTTP wiring: the route table plus gateway middleware. Public `health` stays open; the
//! versioned API sits behind API-key auth and rate limiting; request-ID propagation wraps
//! everything. Separate from `main` so the route table lives in one place.

use axum::{
    routing::{get, post},
    Router,
};

use crate::gateway::{self, auth, rate_limit, request_id};
use crate::handlers::{health, resolve, tx, wallet};
use crate::state::AppState;

/// Builds the application router with all routes, shared state, and gateway middleware.
pub fn router(state: AppState, gw: gateway::Gateway) -> Router {
    // Versioned API, guarded by auth and rate limiting.
    let api = Router::new()
        .route("/wallets", post(wallet::register))
        .route("/wallets/:pubkey/balance", get(wallet::balance))
        .route("/wallets/:pubkey/transactions", get(wallet::history))
        .route("/tx/build", post(tx::build))
        .route("/tx/submit", post(tx::submit))
        .route("/tx/:signature", get(tx::status))
        .route("/resolve", get(resolve::resolve))
        // Layers run outermost-last, so auth runs before the rate limiter. The limiter
        // then keys on the validated key (or peer IP), never on a raw header.
        .layer(axum::middleware::from_fn_with_state(
            gw.rate_limiter.clone(),
            rate_limit::enforce,
        ))
        .layer(axum::middleware::from_fn_with_state(
            gw.api_keys.clone(),
            auth::require_api_key,
        ))
        .with_state(state);

    Router::new()
        .route("/health", get(health::health))
        .nest("/v1", api)
        .layer(axum::middleware::from_fn(request_id::propagate))
}

#[cfg(test)]
mod tests {
    use std::collections::HashSet;
    use std::sync::Arc;
    use std::time::Duration;

    use axum::body::Body;
    use axum::http::{Request, StatusCode};
    use tower::ServiceExt;

    use super::*;
    use crate::chain::SolanaAdapter;
    use crate::gateway::rate_limit::RateLimiter;

    /// Unauthenticated requests are turned away by auth before the limiter sees them, so
    /// random bearer values cannot fill the limiter's table. A valid key is tracked once.
    #[tokio::test]
    async fn auth_runs_before_rate_limiting() {
        let pool = sqlx::PgPool::connect_lazy("postgres://unused@127.0.0.1:1/unused").unwrap();
        let chain = Arc::new(SolanaAdapter::new("http://127.0.0.1:9", "http://127.0.0.1:9", None));
        let limiter = Arc::new(RateLimiter::new(100, Duration::from_secs(60)));
        let gw = gateway::Gateway {
            api_keys: Arc::new(HashSet::from(["good".to_string()])),
            rate_limiter: limiter.clone(),
        };
        let app = router(AppState { pool, chain }, gw);

        let call = |bearer: String| {
            Request::post("/v1/tx/build")
                .header("authorization", format!("Bearer {bearer}"))
                .header("content-type", "application/json")
                .body(Body::from("{}"))
                .unwrap()
        };

        for i in 0..50 {
            let response = app.clone().oneshot(call(format!("random-{i}"))).await.unwrap();
            assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        }
        assert_eq!(limiter.tracked(), 0, "rejected callers are not tracked");

        let response = app.clone().oneshot(call("good".to_string())).await.unwrap();
        assert_ne!(response.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(limiter.tracked(), 1);
    }
}
