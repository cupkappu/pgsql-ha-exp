CREATE TABLE IF NOT EXISTS ha_test (
    id          bigserial PRIMARY KEY,
    phase       text NOT NULL,
    payload     text NOT NULL UNIQUE,
    server_addr inet NOT NULL DEFAULT inet_server_addr(),
    txid        bigint NOT NULL DEFAULT txid_current(),
    written_at  timestamptz NOT NULL DEFAULT clock_timestamp()
);

INSERT INTO ha_test (phase, payload)
SELECT 'seed', 'demo-row-' || to_char(n, 'FM00')
FROM generate_series(1, 10) AS n
ON CONFLICT (payload) DO NOTHING;

CREATE OR REPLACE VIEW ha_test_summary AS
SELECT
    phase,
    server_addr,
    count(*) AS row_count,
    min(id) AS first_id,
    max(id) AS last_id,
    min(written_at) AS first_write,
    max(written_at) AS last_write
FROM ha_test
GROUP BY phase, server_addr;
