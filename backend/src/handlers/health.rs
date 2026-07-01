//! Liveness endpoint.

/// `GET /health` — liveness probe. Returns as soon as the process can serve requests.
pub async fn health() -> &'static str {
    "ok"
}
