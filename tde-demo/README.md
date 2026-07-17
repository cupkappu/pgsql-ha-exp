# PostgreSQL TDE、pgvector 與手動主備實驗

本目錄在單一 Docker daemon 內建立以下環境：

```text
OpenBao KV v2
pg1  Percona PostgreSQL 17 + pg_tde + pgvector
pg2  Percona PostgreSQL 17 + pg_tde + pgvector
```

初始角色：

```text
pg1  primary
pg2  standby
```

實驗驗證資料表 TDE、WAL 加密、pgvector HNSW 索引、串流複寫、手動 promote，以及使用 `pg_tde_basebackup` 重建舊 primary。

OpenBao 以 dev mode 執行。金鑰只存在記憶體。初始化服務使用 dev root token 建立 `pg-tde` policy，再將受限 token 寫入共用 volume。此設定只供本機實驗。實機部署流程位於 [`../tde-postgresql-primary-standby-docker-compose.zh-Hant.md`](../tde-postgresql-primary-standby-docker-compose.zh-Hant.md)。

## 元件版本

```text
Percona PostgreSQL image
  percona/percona-distribution-postgresql:17.10-2-ubi8

PostgreSQL
  17.10 - Percona Server for PostgreSQL 17.10.2

pg_tde
  2.2

pgvector
  0.8.3

OpenBao
  openbao/openbao:2.5.4
```

兩個 image tag 可在 `.env` 覆寫。測試基線位於 `.env.example`。

## 連線資訊

| 服務 | 位址 |
|---|---|
| pg1 | `127.0.0.1:55431` |
| pg2 | `127.0.0.1:55432` |
| OpenBao | `http://127.0.0.1:18200` |

預設資料庫憑證：

```text
database  appdb
user      postgres
password  postgres
```

預設複寫帳號：

```text
user      replicator
password  replicator
```

以上值只供本機實驗。

## 完整驗證

```bash
make tde-demo-test
```

此命令會先清除舊實驗資料，再依序執行：

```text
Compose 與 shell 靜態校驗
啟動 OpenBao
建立 KV v2 mount
初始化 pg1
註冊 pg_tde OpenBao provider
建立資料 principal key
建立 WAL server key
啟用 WAL encryption
建立 pgvector extension
建立 tde_heap 表與 HNSW index
複製 PGDATA/pg_tde
使用 pg_tde_basebackup 建立 pg2
驗證加密表、WAL、KMS、向量查詢與串流複寫
停止 pg1
提升 pg2
在新 primary 寫入加密向量資料
使用 pg_tde_basebackup 將 pg1 重建為 standby
```

驗證完成後角色為：

```text
pg1  standby
pg2  primary
```

## 分步執行

清除舊環境：

```bash
make tde-demo-clean
```

啟動初始主備：

```bash
make tde-demo-up
```

查看狀態：

```bash
make tde-demo-status
```

執行 smoke test：

```bash
make tde-demo-smoke
```

停止 pg1：

```bash
docker compose \
  --env-file tde-demo/.env.example \
  -f tde-demo/compose.yml \
  stop pg1
```

提升 pg2：

```bash
make tde-demo-promote NODE=pg2
```

將 pg1 重建為 standby：

```bash
make tde-demo-rejoin NODE=pg1
```

執行完整故障切換測試：

```bash
make tde-demo-failover
```

## 查詢節點角色

pg1：

```bash
docker compose \
  --env-file tde-demo/.env.example \
  -f tde-demo/compose.yml \
  exec -T pg1 \
  psql -U postgres -d appdb \
  -c "SELECT pg_is_in_recovery();"
```

pg2：

```bash
docker compose \
  --env-file tde-demo/.env.example \
  -f tde-demo/compose.yml \
  exec -T pg2 \
  psql -U postgres -d appdb \
  -c "SELECT pg_is_in_recovery();"
```

回傳值：

```text
f  primary
t  standby
```

## 查詢 TDE 狀態

在目前 primary 執行：

```sql
SHOW shared_preload_libraries;
SHOW pg_tde.cipher;
SHOW pg_tde.wal_encrypt;

SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_tde', 'vector')
ORDER BY extname;

SELECT pg_tde_is_encrypted('embeddings');
SELECT * FROM pg_tde_default_key_info();
SELECT * FROM pg_tde_server_key_info();
SELECT pg_tde_verify_default_key();
SELECT pg_tde_verify_server_key();
```

實驗使用：

```text
pg_tde.cipher       aes_256
pg_tde.wal_encrypt  on
embeddings          tde_heap
```

## pgvector 查詢

```bash
docker compose \
  --env-file tde-demo/.env.example \
  -f tde-demo/compose.yml \
  exec -T pg1 \
  psql -U postgres -d appdb \
  -c "SELECT id, content, embedding FROM embeddings ORDER BY embedding <=> '[0.9,0.1,0]' LIMIT 3;"
```

`embeddings` 使用 `tde_heap`，HNSW index 建立於同一個加密 relation 上。

## base backup 流程

啟用 WAL encryption 後，重建 standby 需要以下順序：

1. 停止並清空目標 PGDATA。
2. 從 source 複製 `PGDATA/pg_tde` 到目標 PGDATA。
3. 保持兩個節點上的 OpenBao token 路徑相同。
4. 執行 `pg_tde_basebackup`。

實驗命令使用：

```text
-F p
-X stream
--encrypt-wal=aes_256
-R
-S <slot>
```

`scripts/tde-demo-lib.sh` 實作完整流程。

## Volume

```text
pgsql-tde-demo-pg1-data
pgsql-tde-demo-pg2-data
pgsql-tde-demo-secrets
```

OpenBao dev mode 的 key state 不會寫入 volume。OpenBao 停止後，既有 encrypted PGDATA 無法使用新啟動的 dev server 解密。

停止並刪除所有容器、網路與 volume：

```bash
make tde-demo-clean
```

`make tde-demo-clean` 會刪除兩個 PostgreSQL 資料 volume。
