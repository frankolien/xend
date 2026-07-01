//! Persistence layer: every SQL query in the backend lives here, behind small functions
//! that the handlers call. Keeping SQL out of the HTTP layer keeps handlers readable and
//! confines schema knowledge to one place, so evolving the storage model touches only
//! this module.

pub mod transactions;
pub mod wallets;
