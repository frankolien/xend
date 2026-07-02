//! HTTP layer: one module per resource. A handler parses and validates the request,
//! orchestrates the chain adapter ([`crate::chain`]) and persistence ([`crate::store`]),
//! and shapes the response. Handlers hold no SQL and no chain-specific logic.

pub mod health;
pub mod resolve;
pub mod tx;
pub mod wallet;
