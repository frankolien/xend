//! A single error type mapped to HTTP responses. Every failure from the chain, database,
//! or a client becomes a variant of [`AppError`], each with an HTTP status and a stable
//! `code` string the SDK's typed errors mirror, so clients branch on the code rather than
//! parse strings.
//!
//! Internal and database error detail is logged server-side, never in a response body.

use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::json;

#[derive(Debug, thiserror::Error)]
pub enum AppError {
    #[error("invalid request: {0}")]
    BadRequest(String),

    #[error("unauthorized")]
    Unauthorized,

    #[error("rate limited; retry after {retry_after_secs}s")]
    RateLimited { retry_after_secs: u64 },

    #[error("insufficient funds")]
    InsufficientFunds,

    #[error("invalid recipient address")]
    InvalidRecipient,

    #[error("blockhash expired")]
    BlockhashExpired,

    #[error("chain rejected: {0}")]
    ChainRejected(String),

    #[error("upstream/network error: {0}")]
    Network(String),

    #[error("database error: {0}")]
    Database(#[from] sqlx::Error),

    #[error("internal error: {0}")]
    Internal(String),
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, code) = match &self {
            AppError::BadRequest(_) => (StatusCode::BAD_REQUEST, "bad_request"),
            AppError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized"),
            AppError::RateLimited { .. } => (StatusCode::TOO_MANY_REQUESTS, "rate_limited"),
            AppError::InsufficientFunds => (StatusCode::UNPROCESSABLE_ENTITY, "insufficient_funds"),
            AppError::InvalidRecipient => (StatusCode::UNPROCESSABLE_ENTITY, "invalid_recipient"),
            AppError::BlockhashExpired => (StatusCode::CONFLICT, "blockhash_expired"),
            AppError::ChainRejected(_) => (StatusCode::UNPROCESSABLE_ENTITY, "chain_rejected"),
            AppError::Network(_) => (StatusCode::BAD_GATEWAY, "network"),
            AppError::Database(_) | AppError::Internal(_) => {
                (StatusCode::INTERNAL_SERVER_ERROR, "internal")
            }
        };

        let retry_after = match &self {
            AppError::RateLimited { retry_after_secs } => Some(*retry_after_secs),
            _ => None,
        };

        // Log full detail server-side; return only a safe message to the client.
        if status == StatusCode::INTERNAL_SERVER_ERROR {
            tracing::error!(error = %self, "request failed with internal error");
        }

        let body = Json(json!({
            "error": { "code": code, "message": public_message(&self), "retry_after": retry_after }
        }));

        (status, body).into_response()
    }
}

/// Hides DB and internal detail from clients; every other variant is safe to echo.
fn public_message(e: &AppError) -> String {
    match e {
        AppError::Database(_) | AppError::Internal(_) => "internal error".to_string(),
        other => other.to_string(),
    }
}
