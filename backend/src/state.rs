//! Shared application state injected into every request handler.

use std::sync::Arc;

use sqlx::PgPool;

use crate::chain::ChainAdapter;

/// State shared across all routes: the database pool and the active chain adapter.
#[derive(Clone)]
pub struct AppState {
    pub pool: PgPool,
    pub chain: Arc<dyn ChainAdapter>,
}
