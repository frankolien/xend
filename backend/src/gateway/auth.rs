//! API-key authentication middleware. Callers present `Authorization: Bearer <key>`, checked
//! against the configured set. With no keys configured, authentication is disabled
//! (development mode).

use std::collections::HashSet;
use std::sync::Arc;

use axum::extract::{Request, State};
use axum::middleware::Next;
use axum::response::Response;

use crate::error::AppError;

/// The API key a request authenticated with. Attached as a request extension once auth
/// passes, so later layers (rate limiting) key on a validated value, not a raw header.
#[derive(Clone, Debug)]
pub struct ApiKeyIdentity(pub String);

/// Whether `auth_header` is authorized against `keys`. An empty key set disables
/// authentication (development mode) and allows everything.
fn is_authorized(keys: &HashSet<String>, auth_header: Option<&str>) -> bool {
    if keys.is_empty() {
        return true;
    }
    validated_key(keys, auth_header).is_some()
}

/// The configured key matching `auth_header`, if any.
fn validated_key<'a>(keys: &'a HashSet<String>, auth_header: Option<&str>) -> Option<&'a String> {
    let presented = auth_header.and_then(|h| h.strip_prefix("Bearer "))?.trim();
    keys.get(presented)
}

/// Rejects requests without a valid API key with `401 Unauthorized`.
pub async fn require_api_key(
    State(keys): State<Arc<HashSet<String>>>,
    mut request: Request,
    next: Next,
) -> Result<Response, AppError> {
    let header = request
        .headers()
        .get("authorization")
        .and_then(|v| v.to_str().ok());

    if !is_authorized(&keys, header) {
        return Err(AppError::Unauthorized);
    }
    if let Some(key) = validated_key(&keys, header).cloned() {
        request.extensions_mut().insert(ApiKeyIdentity(key));
    }
    Ok(next.run(request).await)
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
