//! Persistence layer. All SQL queries live here behind small functions the handlers call,
//! keeping SQL out of the HTTP layer and schema knowledge in one place.

pub mod transactions;
pub mod wallets;
