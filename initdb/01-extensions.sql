-- ==============================================================================
-- GBrain PostgreSQL First-Boot Extension Setup
-- Executed automatically by pgvector/pgvector:pg16 on fresh volume creation.
-- ==============================================================================
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_prewarm;

