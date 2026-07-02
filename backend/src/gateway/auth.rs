//! API-key authentication middleware. Callers present `Authorization: Bearer <key>`, checked
//! against the configured set. With no keys configured, authentication is disabled
//! (development mode).

use std::collections::HashSet;
use std::sync::Arc;

use axum::extract::{Request, State};
use axum::middleware::Next;
use axum::response::Response;

use crate::error::AppError;

/// Whether `auth_header` is authorized against `keys`. An empty key set disables
/// authentication (development mode) and allows everything.
fn is_authorized(keys: &HashSet<String>, auth_header: Option<&str>) -> bool {
    if keys.is_empty() {
        return true;
    }
    match auth_header.and_then(|h| h.strip_prefix("Bearer ")) {
        Some(key) => keys.contains(key.trim()),
        None => false,
    }
}

/// Rejects requests without a valid API key with `401 Unauthorized`.
pub async fn require_api_key(
    State(keys): State<Arc<HashSet<String>>>,
    request: Request,
    next: Next,
) -> Result<Response, AppError> {
    let header = request
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok());

    if is_authorized(&keys, header) {
        Ok(next.run(request).await)
    } else {
        Err(AppError::Unauthorized)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn keys(items: &[&str]) -> HashSet<String> {
        items.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn disabled_when_no_keys_configured() {
        assert!(is_authorized(&HashSet::new(), None));
        assert!(is_authorized(&HashSet::new(), Some("Bearer anything")));
    }

    #[test]
    fn accepts_a_valid_bearer_key_and_rejects_others() {
        let configured = keys(&["secret"]);
        assert!(is_authorized(&configured, Some("Bearer secret")));
        assert!(!is_authorized(&configured, Some("Bearer wrong")));
        assert!(!is_authorized(&configured, Some("secret"))); // missing the Bearer scheme
        assert!(!is_authorized(&configured, None));
    }
}
