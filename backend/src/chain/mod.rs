//! Chain abstraction: a chain-agnostic port ([`ChainAdapter`]) and its implementations.
//! The rest of the backend depends only on the trait, so adding a chain means adding an
//! adapter. This release ships one implementation, [`SolanaAdapter`].

mod adapter;
mod solana;

pub use adapter::{ChainAdapter, Commitment, TransferIntent};
pub use solana::SolanaAdapter;
