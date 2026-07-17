-- Binds an idempotency key to the exact payload it was claimed with.
--
-- The UNIQUE idempotency_key stops a duplicate from broadcasting twice only when the retry
-- carries identical bytes: identical signed bytes produce the identical on-chain signature,
-- so the network collapses them into one transaction. A retry that reuses the key with
-- DIFFERENT bytes is a different transaction, and relaying it would move funds twice.
--
-- Recording the payload hash when the key is claimed lets submit reject that case instead
-- of broadcasting it. Rows written before this column exists stay null and are treated as
-- unbound, so old keys keep their previous behaviour.

alter table transactions add column if not exists signed_hash text;
