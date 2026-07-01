-- Xend v0.1 schema. The schema's one job is to remember PUBLIC facts. Note what is
-- absent: no column anywhere for a private key, seed, or mnemonic. That absence is
-- the design (docs/04-SECURITY.md T15). UUIDs are generated server-side (in Rust).

create table if not exists users (
    id         uuid        primary key,
    created_at timestamptz not null default now(),
    auth_ref   text -- email / device id / null, depends on the §5 auth decision (D4)
);

create table if not exists wallets (
    id         uuid        primary key,
    user_id    uuid        references users (id),
    pubkey     text        not null unique, -- base58 Solana address. The only key material here, and it is public.
    label      text,
    created_at timestamptz not null default now()
);

-- transactions table lands in Phase 2 (needs the send path). Indexes per D5:
-- UNIQUE(idempotency_key), UNIQUE(signature) come free as constraints; a btree on
-- (wallet_id, created_at desc) is added then for the history hot path.
