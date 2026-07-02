//! Liveness endpoint.

/// `GET /health` liveness probe. Returns once the process can serve requests.
pub async fn health() -> &'static str {
    "ok"
}
