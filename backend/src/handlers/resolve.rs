//! Name resolution: turn a chain-native name (a Solana `.sol` domain) into an address.
//! This layer only parses the request and delegates to the chain adapter; the resolution
//! logic and RPC live in [`crate::chain`].

use axum::{
    extract::{Query, State},
    Json,
};
use serde::{Deserialize, Serialize};

use crate::error::AppError;
use crate::state::AppState;

#[derive(Deserialize)]
pub struct ResolveQuery {
    /// The name to resolve, such as `gift.sol`.
    pub name: String,
}

#[derive(Serialize)]
pub struct ResolveResponse {
    /// The name that was resolved, echoed back for the caller's convenience.
    pub name: String,
    /// The resolved base58 address.
    pub address: String,
}

/// `GET /v1/resolve?name=gift.sol` — resolve a name to an address.
///
/// Returns `invalid_recipient` if the name is malformed or not registered, so a client can
/// treat an unresolvable name the same as a bad address.
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
