# PostgreSQL 本機 Keyring TDE 雙節點實驗

本目錄在單一 Docker daemon 內建立兩個 PostgreSQL 節點，驗證本機 keyring file、pg_tde、pgvector、WAL 加密、串流複寫、手動提升、舊節點重建及 keyring 備份恢復。

實驗不啟動 OpenBao、Vault、KMIP 或其他外部 KMS。

## 元件

```text
Percona Distribution for PostgreSQL 17.10.2
pg_tde 2.2.1
pgvector 0.8.3
PostgreSQL physical streaming replication
local keyring file provider
```

節點與入口：

```text
pg1  172.31.124.11  127.0.0.1:56431
pg2  172.31.124.12  127.0.0.1:56432
```

初始角色：

```text
pg1  primary
pg2  standby
```

## Keyring 配置

三個 Docker volume 保存三份獨立副本：

```text
pgsql-tde-local-demo-pg1-keyring
pgsql-tde-local-demo-pg2-keyring
pgsql-tde-local-demo-keyring-backup
```

容器內路徑固定為：

```text
/run/pg-tde-keyring/principal.keyring
```

pg1 和 pg2 沒有共用可寫 keyring volume。初始化、base backup 及 rejoin 期間，腳本會從目前 primary 複製 keyring 至目標節點，再更新備份 volume。

Percona 文件將本機 keyring file 定義為開發及測試用途。該檔案以未加密形式保存 principal key。Percona 的 replication 文件同時指出，keyring file 不用於多節點共享及並行寫入。本實驗使用獨立副本，密鑰變更後以完整 base backup 重建 standby。

## 加密物件

初始化建立：

```sql
CREATE EXTENSION pg_tde;
CREATE EXTENSION vector;
```

Key provider：

```sql
SELECT pg_tde_add_global_key_provider_file(
  'local-keyring',
  '/run/pg-tde-keyring/principal.keyring'
);
```

資料表：

```sql
CREATE TABLE embeddings (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  content text NOT NULL,
  embedding vector(3) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
) USING tde_heap;
```

向量索引：

```sql
CREATE INDEX embeddings_hnsw_idx
  ON embeddings
  USING hnsw (embedding vector_cosine_ops);
```

WAL 使用 AES-256：

```text
pg_tde.wal_encrypt = on
pg_tde.cipher = aes_256
```

## 啟動

```bash
make tde-local-demo-up
```

首次啟動流程：

```text
建立 pg1 與 pg2 的資料及 keyring volume
設定 keyring volume owner 為 26:26
初始化 pg1 primary
建立 pg_tde、pgvector、principal key 及 encrypted table
複製 pg1 keyring 至 pg2
保存獨立 keyring 備份副本與 SHA-256
複製 PGDATA/pg_tde metadata 至 pg2
執行 pg_tde_basebackup --encrypt-wal=aes_256
啟動 pg2 standby
驗證 streaming replication
```

## 狀態

```bash
make tde-local-demo-status
```

輸出包含：

```text
節點角色
WAL encryption
pg_tde 與 pgvector 版本
key provider 類型
embeddings 加密狀態
資料列數
三份 keyring SHA-256
```

## Smoke test

```bash
make tde-local-demo-smoke
```

驗證內容：

```text
pg1 primary 與 pg2 standby
file key provider
相同 keyring checksum
default key 與 server key 可讀取
tde_heap table 已加密
pgvector cosine query
primary 寫入與 standby 重播
```

## 故障提升與重建

完整測試：

```bash
make tde-local-demo-failover
```

執行順序：

```text
停止 pg1
提升 pg2
在 pg2 寫入 encrypted vector row
刪除 pg1 舊 PGDATA 與 keyring volume
由 pg2 複製 keyring 至 pg1
由 pg2 執行 pg_tde_basebackup
啟動 pg1 standby
驗證故障後資料與 keyring checksum
```

單獨操作：

```bash
make tde-local-demo-promote NODE=pg2
make tde-local-demo-rejoin NODE=pg1
```

## Keyring 遺失與備份恢復

```bash
make tde-local-demo-keyring-restore
```

測試會執行：

```text
校驗備份 volume 內的 SHA-256 manifest
停止目前 standby
刪除 standby keyring volume
確認 PostgreSQL 因找不到 server principal key 而無法啟動
由備份 volume 恢復 keyring
重新啟動 standby
驗證 default key、server key 與複寫角色
```

實驗中的備份 volume 仍位於同一 Docker host。實機部署需將 keyring 與 checksum 複製到離線媒體或獨立加密儲存。完整操作位於根目錄的 `tde-local-keyring-postgresql-primary-standby-docker-compose.zh-Hant.md`。

## 完整驗收

```bash
make tde-local-demo-test
```

該目標依序執行：

```text
static validation
clean
up
smoke
failover and rejoin
keyring loss and restore
```

## 停止與清理

停止並保留 volume：

```bash
make tde-local-demo-down
```

刪除容器、網路、PGDATA、兩份節點 keyring 及備份 keyring：

```bash
make tde-local-demo-clean
```

`clean` 會永久刪除實驗密鑰與 encrypted data。

## 檔案

| 路徑 | 內容 |
|---|---|
| `.env.example` | image、資料庫憑證及 host port |
| `compose.yml` | pg1、pg2、資料 volume、keyring volume、備份 volume |
| `init-primary.sh` | pg_tde、pgvector、principal key、encrypted table 初始化 |
| `pg_hba.conf` | client 與 replication CIDR |
| `../scripts/tde-local-demo-lib.sh` | 角色、keyring 同步、base backup 及共用操作 |
| `../tests/tde-local-demo-smoke.sh` | 加密、向量、keyring 與複寫測試 |
| `../tests/tde-local-demo-failover.sh` | promote、故障後寫入及 rejoin 測試 |
| `../tests/tde-local-demo-keyring-restore.sh` | keyring 遺失及備份恢復測試 |

## 文件

Percona pg_tde 文件：

- `https://docs.percona.com/pg-tde/global-key-provider-configuration/keyring.html`
- `https://docs.percona.com/pg-tde/replication.html`
- `https://docs.percona.com/pg-tde/how-to/backup-wal-enabled.html`
