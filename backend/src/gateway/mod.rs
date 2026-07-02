//! The gateway: cross-cutting request concerns applied as middleware — API-key
//! authentication, rate limiting, and request-ID propagation. These wrap the handlers
//! rather than living inside them, so a handler only ever sees a request that is already
//! authenticated and within its rate budget.

pub mod auth;
pub mod rate_limit;
pub mod request_id;

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use rate_limit::RateLimiter;

/// The maximum number of requests one caller may make per minute.
const RATE_LIMIT_PER_MINUTE: u32 = 120;

/// Gateway configuration assembled once at startup and shared with the middleware.
pub struct Gateway {
    pub api_keys: Arc<HashSet<String>>,
    pub rate_limiter: Arc<RateLimiter>,
}

impl Gateway {
    /// Builds the gateway from the environment. `XEND_API_KEYS` is a comma-separated list
    /// of accepted keys; when it is unset or empty, authentication is disabled for local
    /// development and a warning is logged.
    pub fn from_env() -> Self {
        let api_keys: HashSet<String> = std::env::var("XEND_API_KEYS")
            .unwrap_or_default()
            .split(',')
            .map(|key| key.trim().to_string())
            .filter(|key| !key.is_empty())
            .collect();

        if api_keys.is_empty() {
            tracing::warn!(
                "XEND_API_KEYS is not set — API-key authentication is DISABLED (development mode)"
            );
        } else {
            tracing::info!(keys = api_keys.len(), "API-key authentication enabled");
        }

        Self {
            api_keys: Arc::new(api_keys),
            rate_limiter: Arc::new(RateLimiter::new(
                RATE_LIMIT_PER_MINUTE,
                Duration::from_secs(60),
            )),
        }
    }
}
