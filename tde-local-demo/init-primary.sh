#!/usr/bin/env bash
set -euo pipefail

psql \
  --username "$POSTGRES_USER" \
  --dbname "$POSTGRES_DB" \
  --set=ON_ERROR_STOP=1 \
  --set=replication_password="$REPLICATION_PASSWORD" <<'SQL'
CREATE EXTENSION pg_tde;
CREATE EXTENSION vector;

CREATE ROLE replicator
  WITH LOGIN REPLICATION
  PASSWORD :'replication_password';

SELECT pg_tde_add_global_key_provider_file(
  'local-keyring',
  '/run/pg-tde-keyring/principal.keyring'
);

SELECT pg_tde_create_key_using_global_key_provider(
  'pgsql-tde-local-data-key-v1',
  'local-keyring'
);

SELECT pg_tde_set_default_key_using_global_key_provider(
  'pgsql-tde-local-data-key-v1',
  'local-keyring'
);

SELECT pg_tde_create_key_using_global_key_provider(
  'pgsql-tde-local-wal-key-v1',
  'local-keyring'
);

SELECT pg_tde_set_server_key_using_global_key_provider(
  'pgsql-tde-local-wal-key-v1',
  'local-keyring'
);

ALTER SYSTEM SET pg_tde.wal_encrypt = 'on';

CREATE TABLE embeddings (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  content text NOT NULL,
  embedding vector(3) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
) USING tde_heap;

CREATE INDEX embeddings_hnsw_idx
  ON embeddings
  USING hnsw (embedding vector_cosine_ops);

INSERT INTO embeddings (content, embedding) VALUES
  ('alpha', '[1,0,0]'),
  ('beta', '[0,1,0]'),
  ('gamma', '[0,0,1]');
SQL
