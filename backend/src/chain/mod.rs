//! The chain abstraction: a chain-agnostic port ([`ChainAdapter`]) and its
//! implementations. The rest of the backend depends only on the trait, never on a
//! chain-specific client, so adding a chain is a matter of adding an adapter. This
//! release ships a single implementation, [`SolanaAdapter`].

mod adapter;
mod solana;

pub use adapter::{ChainAdapter, Commitment, TransferIntent};
pub use solana::SolanaAdapter;
