-- Xend Phase 2: the transactions ledger, added with the send path.
--
-- Like the rest of the schema it stores only public facts: the recipient, the amount,
-- and the on-chain signature. There is no private key, no signed-transaction blob, and
-- no seed here. The signed transaction is the source of truth for what moved on-chain;
-- this table's job is idempotency and history, not custody.
--
-- Idempotency is enforced structurally: idempotency_key is UNIQUE, so two concurrent
-- submissions of the same logical send race to a single winning row instead of
-- broadcasting twice. signature is UNIQUE for the same reason once broadcast.

create table if not exists transactions (
    id              uuid        primary key,
    wallet_id       uuid        references wallets (id),      -- sender, resolved from pubkey; null if unregistered
    idempotency_key text        not null unique,              -- guards double-submit (D5)
    signature       text        unique,                       -- on-chain signature; null until broadcast
    status          text        not null default 'pending',   -- pending | submitted | confirmed | finalized | failed
    to_address      text,                                     -- recipient, recorded for history
    amount          text,                                     -- base units as a decimal string (source of truth is the signed tx)
    mint            text,                                      -- token mint, or null for the native asset
    created_at      timestamptz not null default now(),
    updated_at      timestamptz not null default now()
);

-- History hot path: a wallet's transactions, most recent first (D5).
create index if not exists idx_tx_wallet_created on transactions (wallet_id, created_at desc);
