//! Request-ID propagation. Each request is given a stable id — reused from an inbound
//! `x-request-id` header or freshly generated — that is attached to the tracing span and
//! echoed on the response, so one request can be followed across the logs.

use axum::extract::Request;
use axum::http::{HeaderName, HeaderValue};
use axum::middleware::Next;
use axum::response::Response;
use tracing::Instrument;
use uuid::Uuid;

pub async fn propagate(request: Request, next: Next) -> Response {
    let header = HeaderName::from_static("x-request-id");
    let id = request
        .headers()
        .get(&header)
        .and_then(|v| v.to_str().ok())
        .map(str::to_owned)
        .unwrap_or_else(|| Uuid::new_v4().to_string());

    // Run the rest of the request inside a span carrying the id, so every log line emitted
    // while handling it is tagged with the same request_id.
    let span = tracing::info_span!("request", request_id = %id);
    let mut response = async move { next.run(request).await }.instrument(span).await;

    if let Ok(value) = HeaderValue::from_str(&id) {
        response.headers_mut().insert(header, value);
    }
    response
}
