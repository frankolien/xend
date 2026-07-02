//! Name resolution: turn a chain-native name (a Solana `.sol` domain) into an address.
//! Parses the request and delegates to the chain adapter; resolution logic and RPC live
//! in [`crate::chain`].

use axum::{
    extract::{Query, State},
    Json,
};
use serde::{Deserialize, Serialize};

use crate::error::AppError;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct ResolveQuery {
    /// Name to resolve, such as `gift.sol`.
    pub name: String,
}

#[derive(Serialize)]
pub struct ResolveResponse {
    /// The resolved name, echoed back.
    pub name: String,
    /// The resolved base58 address.
    pub address: String,
}

/// `GET /v1/resolve?name=gift.sol` resolves a name to an address.
///
/// Returns `invalid_recipient` if the name is malformed or unregistered, so a client can
/// treat an unresolvable name like a bad address.
pub async fn resolve(
    State(state): State<AppState>,
    Query(query): Query<ResolveQuery>,
) -> Result<Json<ResolveResponse>, AppError> {
    let address = state.chain.resolve_name(&query.name).await?;
    Ok(Json(ResolveResponse {
        name: query.name,
        address,
    }))
}
