# PostgreSQL TDE、pgvector 與雙機手動主備部署手冊

本文使用 Percona Distribution for PostgreSQL 17、pg_tde、pgvector、OpenBao KV v2、Docker Compose 與 physical streaming replication 建立雙機主備。

本機 keyring、LUKS 與離線備份方案位於 [`tde-local-keyring-postgresql-primary-standby-docker-compose.zh-Hant.md`](tde-local-keyring-postgresql-primary-standby-docker-compose.zh-Hant.md)。

本文涵蓋：

1. 外部 OpenBao 準備。
2. primary 初始化。
3. TDE、WAL encryption 與 pgvector 設定。
4. 使用 `pg_tde_basebackup` 建立 standby。
5. 計畫內切換、故障提升與舊 primary 重建。
6. 現有 PostgreSQL 資料轉換為 `tde_heap`。
7. 金鑰輪換、備份與版本升級限制。

本文使用手動切換。應用程式端點由操作人員更新。沒有配置 VIP、HAProxy、Patroni 或自動 fencing。

## 1. 元件與授權

本文測試基線：

```text
Percona PostgreSQL image
  percona/percona-distribution-postgresql:17.10-2-ubi8

PostgreSQL
  17.10 - Percona Server for PostgreSQL 17.10.2

pg_tde package
  2.2.1

pgvector package
  0.8.3

OpenBao image
  openbao/openbao:2.5.4
```

容器內套件資訊：

```text
percona-pg_tde17     PostgreSQL License
percona-pgvector_17  PostgreSQL License
OpenBao              MPL-2.0
```

本文使用開源元件，沒有使用商業授權限定的 TDE 功能。重新分發 image 或套件時，保留對應授權與版權文件。

固定 image digest：

```bash
docker pull percona/percona-distribution-postgresql:17.10-2-ubi8

docker image inspect \
  percona/percona-distribution-postgresql:17.10-2-ubi8 \
  --format '{{json .RepoDigests}}'
```

兩台資料庫主機使用相同 image digest。

## 2. 範例拓撲

```text
OpenBao  kms.example.internal:8200

db1      192.168.50.11:5432
          初始 primary

db2      192.168.50.12:5432
          初始 standby
```

網路規則：

```text
db1 -> OpenBao TCP 8200
db2 -> OpenBao TCP 8200
db1 <-> db2 TCP 5432
應用程式 -> 目前 primary TCP 5432
```

OpenBao 使用 TLS。db1 與 db2 保存相同 CA 檔案路徑。兩台可以使用不同 token，token policy 需一致。

## 3. OpenBao 要求

OpenBao 需提供持久化 storage。單節點、Raft cluster 或既有 OpenBao 服務均可。本文使用以下條件：

```text
API URL       https://kms.example.internal:8200
KV v2 mount   tde
CA file       /opt/postgresql/secrets/openbao-ca.pem
Token file    /opt/postgresql/secrets/openbao-token
```

pg_tde provider 的 mount path 填寫 KV mount 名稱：

```text
tde
```

目前測試 image 對應的值為 `tde`。API 內部的 `/data/` 路徑由 KV v2 client 處理。

### 3.1 啟用 KV v2

在 OpenBao 管理端執行：

```bash
export BAO_ADDR=https://kms.example.internal:8200
export BAO_CACERT=/path/to/openbao-ca.pem
export BAO_TOKEN=ADMIN_TOKEN

bao secrets enable -path=tde -version=2 kv
```

已存在時查看：

```bash
bao secrets list -detailed
```

### 3.2 建立 pg_tde policy

建立 `pg-tde-policy.hcl`：

```hcl
path "tde/data/*" {
  capabilities = ["create", "read", "update", "delete"]
}

path "tde/metadata" {
  capabilities = ["read", "list"]
}

path "tde/metadata/*" {
  capabilities = ["read", "list", "delete"]
}
```

載入 policy：

```bash
bao policy write pg-tde pg-tde-policy.hcl
```

### 3.3 建立資料庫 token

為 db1 與 db2 分別建立 token：

```bash
bao token create \
  -policy=pg-tde \
  -orphan \
  -renewable=true \
  -ttl=720h
```

將輸出的 token 分別寫入兩台主機：

```text
/opt/postgresql/secrets/openbao-token
```

權限：

```bash
sudo chown root:26 /opt/postgresql/secrets/openbao-token
sudo chmod 0640 /opt/postgresql/secrets/openbao-token
```

token 到期前執行續期或替換。替換 token 時保持容器內路徑不變。

### 3.4 安裝 CA

在 db1 與 db2 建立：

```text
/opt/postgresql/secrets/openbao-ca.pem
```

權限：

```bash
sudo chown root:26 /opt/postgresql/secrets/openbao-ca.pem
sudo chmod 0640 /opt/postgresql/secrets/openbao-ca.pem
```

驗證連線：

```bash
curl \
  --cacert /opt/postgresql/secrets/openbao-ca.pem \
  https://kms.example.internal:8200/v1/sys/health
```

## 4. 準備兩台資料庫主機

在 db1 與 db2 執行：

```bash
sudo install -d -m 0755 /opt/postgresql
sudo install -d -m 0750 /opt/postgresql/secrets
sudo install -d -m 0700 -o 26 -g 26 /srv/postgresql/data
cd /opt/postgresql
```

Percona image 內的 PostgreSQL 使用者為：

```text
uid=26
gid=26
```

確認 image：

```bash
docker run --rm \
  --entrypoint id \
  percona/percona-distribution-postgresql:17.10-2-ubi8 \
  postgres
```

## 5. 建立環境檔

在 db1 與 db2 建立 `/opt/postgresql/.env`：

```dotenv
POSTGRES_IMAGE=percona/percona-distribution-postgresql:17.10-2-ubi8
POSTGRES_DB=appdb
POSTGRES_USER=postgres
POSTGRES_PASSWORD=CHANGE_ME_POSTGRES_PASSWORD
REPLICATION_PASSWORD=CHANGE_ME_REPLICATION_PASSWORD
```

設定權限：

```bash
sudo chmod 0600 /opt/postgresql/.env
```

## 6. 建立 `.pgpass`

在 db1 與 db2 建立 `/opt/postgresql/.pgpass`：

```text
192.168.50.11:5432:replication:replicator:CHANGE_ME_REPLICATION_PASSWORD
192.168.50.12:5432:replication:replicator:CHANGE_ME_REPLICATION_PASSWORD
```

設定權限：

```bash
sudo chown 26:26 /opt/postgresql/.pgpass
sudo chmod 0600 /opt/postgresql/.pgpass
```

## 7. 建立 `pg_hba.conf`

db1 的 `/opt/postgresql/pg_hba.conf`：

```conf
local   all             all                                     trust
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             192.168.50.0/24         scram-sha-256
host    replication     replicator      192.168.50.12/32        scram-sha-256
```

db2 的 `/opt/postgresql/pg_hba.conf`：

```conf
local   all             all                                     trust
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             192.168.50.0/24         scram-sha-256
host    replication     replicator      192.168.50.11/32        scram-sha-256
```

應用程式網段可改為實際 CIDR。複寫規則使用對端 `/32`。

## 8. 建立 Docker Compose

在 db1 與 db2 建立 `/opt/postgresql/compose.yml`：

```yaml
services:
  postgres:
    image: ${POSTGRES_IMAGE}
    container_name: postgres
    restart: unless-stopped
    network_mode: host
    environment:
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_INITDB_ARGS: --auth-host=scram-sha-256 --auth-local=trust
      PGDATA: /data/db
      PGPASSFILE: /run/postgresql/.pgpass
    command:
      - postgres
      - -c
      - shared_preload_libraries=pg_tde
      - -c
      - pg_tde.cipher=aes_256
      - -c
      - listen_addresses=*
      - -c
      - port=5432
      - -c
      - hba_file=/etc/postgresql/pg_hba.conf
      - -c
      - password_encryption=scram-sha-256
      - -c
      - wal_level=replica
      - -c
      - max_wal_senders=10
      - -c
      - max_replication_slots=10
      - -c
      - hot_standby=on
      - -c
      - wal_keep_size=1GB
    volumes:
      - /srv/postgresql/data:/data/db
      - ./pg_hba.conf:/etc/postgresql/pg_hba.conf:ro
      - ./.pgpass:/run/postgresql/.pgpass:ro
      - ./secrets/openbao-token:/run/pg-tde-secrets/openbao-token:ro
      - ./secrets/openbao-ca.pem:/run/pg-tde-secrets/openbao-ca.pem:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 3s
      retries: 20
      start_period: 10s
```

兩台的容器內 token 與 CA 路徑一致：

```text
/run/pg-tde-secrets/openbao-token
/run/pg-tde-secrets/openbao-ca.pem
```

檢查設定：

```bash
cd /opt/postgresql
docker compose --env-file .env config
```

## 9. 初始化 db1 primary

只在 db1 執行：

```bash
cd /opt/postgresql
docker compose --env-file .env up -d
```

查看日誌：

```bash
docker compose logs --tail 100 postgres
```

確認角色：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT pg_is_in_recovery();"
```

回傳 `f`。

## 10. 建立複寫帳號

在 db1 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -v ON_ERROR_STOP=1 \
  -c "CREATE ROLE replicator WITH LOGIN REPLICATION PASSWORD 'CHANGE_ME_REPLICATION_PASSWORD';"
```

## 11. 初始化 pg_tde 與 pgvector

以下 SQL 在 db1 的 `appdb` 執行：

```sql
CREATE EXTENSION pg_tde;
CREATE EXTENSION vector;
```

註冊 OpenBao global provider：

```sql
SELECT pg_tde_add_global_key_provider_vault_v2(
  'openbao',
  'https://kms.example.internal:8200',
  'tde',
  '/run/pg-tde-secrets/openbao-token',
  '/run/pg-tde-secrets/openbao-ca.pem'
);
```

確認 provider：

```sql
SELECT *
FROM pg_tde_list_all_global_key_providers();
```

建立資料 principal key：

```sql
SELECT pg_tde_create_key_using_global_key_provider(
  'appdb-data-key-v1',
  'openbao'
);

SELECT pg_tde_set_default_key_using_global_key_provider(
  'appdb-data-key-v1',
  'openbao'
);
```

建立 WAL server key：

```sql
SELECT pg_tde_create_key_using_global_key_provider(
  'cluster-wal-key-v1',
  'openbao'
);

SELECT pg_tde_set_server_key_using_global_key_provider(
  'cluster-wal-key-v1',
  'openbao'
);
```

啟用 WAL encryption：

```sql
ALTER SYSTEM SET pg_tde.wal_encrypt = 'on';
```

重新啟動 db1：

```bash
docker compose restart postgres
```

確認設定與金鑰：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SHOW pg_tde.cipher; SHOW pg_tde.wal_encrypt; SELECT * FROM pg_tde_default_key_info(); SELECT * FROM pg_tde_server_key_info(); SELECT pg_tde_verify_default_key(); SELECT pg_tde_verify_server_key();"
```

預期值：

```text
pg_tde.cipher       aes_256
pg_tde.wal_encrypt  on
```

## 12. 建立加密 pgvector 表

在 db1 的 `appdb` 執行：

```sql
CREATE TABLE embeddings (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  content text NOT NULL,
  embedding vector(3) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
) USING tde_heap;

CREATE INDEX embeddings_hnsw_idx
  ON embeddings
  USING hnsw (embedding vector_cosine_ops);
```

確認 relation 使用 TDE：

```sql
SELECT pg_tde_is_encrypted('embeddings');
```

回傳 `t`。

## 13. 建立 db2 replication slot

在 db1 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -v ON_ERROR_STOP=1 \
  -c "SELECT * FROM pg_create_physical_replication_slot('db2_slot');"
```

## 14. 準備 db2 PGDATA

在 db2 執行：

```bash
cd /opt/postgresql
docker compose --env-file .env down

sudo find /srv/postgresql/data \
  -mindepth 1 \
  -maxdepth 1 \
  -exec rm -rf -- {} +

sudo chown 26:26 /srv/postgresql/data
sudo chmod 0700 /srv/postgresql/data
```

## 15. 複製 db1 的 `PGDATA/pg_tde`

WAL encryption 啟用後，`pg_tde_basebackup` 前需先複製 source 的 `PGDATA/pg_tde`。

在 db1 建立 archive：

```bash
cd /opt/postgresql

docker compose exec -T postgres \
  tar -C /data/db -cf - pg_tde \
  > pg_tde-bootstrap.tar

chmod 0600 pg_tde-bootstrap.tar
```

透過現有受控管理通道將 `pg_tde-bootstrap.tar` 傳送至 db2 的：

```text
/opt/postgresql/pg_tde-bootstrap.tar
```

在 db2 解壓：

```bash
docker run --rm \
  --user root \
  -v /srv/postgresql/data:/target \
  -v /opt/postgresql/pg_tde-bootstrap.tar:/tmp/pg_tde-bootstrap.tar:ro \
  --entrypoint bash \
  percona/percona-distribution-postgresql:17.10-2-ubi8 \
  -lc 'tar -C /target -xf /tmp/pg_tde-bootstrap.tar && chown -R 26:26 /target/pg_tde'
```

確認：

```bash
sudo find /srv/postgresql/data/pg_tde \
  -maxdepth 1 \
  -type f \
  -ls
```

archive 包含 pg_tde provider 與 wrapped-key metadata。使用與 PGDATA 相同的存取控制。

## 16. 使用 `pg_tde_basebackup` 建立 db2

在 db2 執行：

```bash
cd /opt/postgresql

docker compose \
  --env-file .env \
  run --rm --no-deps \
  --entrypoint pg_tde_basebackup \
  -e PGPASSWORD=CHANGE_ME_REPLICATION_PASSWORD \
  postgres \
    -h 192.168.50.11 \
    -p 5432 \
    -U replicator \
    -D /data/db \
    -F p \
    -X stream \
    --encrypt-wal=aes_256 \
    -R \
    -S db2_slot \
    -P
```

啟動 db2：

```bash
docker compose --env-file .env up -d
```

確認角色：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT pg_is_in_recovery();"
```

回傳 `t`。

確認 standby 能取得金鑰：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT pg_tde_verify_default_key(); SELECT pg_tde_verify_server_key(); SELECT pg_tde_is_encrypted('embeddings');"
```

## 17. 驗證串流複寫

在 db1 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -x \
  -c "SELECT application_name, client_addr, state, sync_state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication;"
```

`state` 顯示 `streaming`。

在 db1 寫入：

```sql
INSERT INTO embeddings (content, embedding)
VALUES ('primary-write', '[1,0,0]');
```

在 db2 查詢：

```sql
SELECT id, content
FROM embeddings
WHERE content = 'primary-write';
```

## 18. 日常狀態檢查

角色：

```sql
SELECT pg_is_in_recovery();
```

WAL encryption：

```sql
SHOW pg_tde.wal_encrypt;
```

資料 key：

```sql
SELECT * FROM pg_tde_default_key_info();
SELECT pg_tde_verify_default_key();
```

WAL key：

```sql
SELECT * FROM pg_tde_server_key_info();
SELECT pg_tde_verify_server_key();
```

加密 relation：

```sql
SELECT pg_tde_is_encrypted('embeddings');
```

primary sender：

```sql
SELECT client_addr, state, sync_state, replay_lsn
FROM pg_stat_replication;
```

standby receiver：

```sql
SELECT status, sender_host, slot_name, latest_end_lsn
FROM pg_stat_wal_receiver;
```

## 19. 計畫內切換 db1 到 db2

本節假設 db1 為 primary，db2 為 standby。

停止應用程式寫入並關閉資料庫連線池。

在 db1 執行：

```sql
CHECKPOINT;
SELECT pg_current_wal_lsn();
```

記錄 LSN，例如：

```text
0/60001F8
```

在 db2 等待 replay：

```sql
SELECT
  pg_last_wal_replay_lsn(),
  pg_last_wal_replay_lsn() >= '0/60001F8'::pg_lsn AS caught_up;
```

`caught_up` 回傳 `t` 後，在 db1 停止 PostgreSQL：

```bash
cd /opt/postgresql
docker compose stop postgres
```

在 db2 promote：

```bash
cd /opt/postgresql

docker compose exec -T --user postgres postgres \
  pg_ctl -D /data/db promote -w
```

確認 db2：

```sql
SELECT pg_is_in_recovery();
SHOW pg_tde.wal_encrypt;
SELECT pg_tde_verify_default_key();
SELECT pg_tde_verify_server_key();
```

將應用程式端點改為：

```text
192.168.50.12:5432
```

重新建立應用程式連線池。

## 20. primary 故障後提升 db2

確認 db1 已停止或完成網路隔離。db1 不再接受寫入後，在 db2 執行：

```bash
cd /opt/postgresql

docker compose exec -T --user postgres postgres \
  pg_ctl -D /data/db promote -w
```

確認角色與金鑰：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT pg_is_in_recovery(); SHOW pg_tde.wal_encrypt; SELECT pg_tde_verify_default_key(); SELECT pg_tde_verify_server_key();"
```

更新應用程式端點至 db2。

非同步複寫可能遺失尚未送達 db2 的交易。故障時記錄：

```sql
SELECT
  pg_last_wal_receive_lsn(),
  pg_last_wal_replay_lsn(),
  pg_last_xact_replay_timestamp();
```

## 21. 將舊 db1 重建為 standby

目前 primary 為 db2。

在 db2 建立 slot：

```sql
SELECT pg_create_physical_replication_slot('db1_slot')
WHERE NOT EXISTS (
  SELECT 1
  FROM pg_replication_slots
  WHERE slot_name = 'db1_slot'
);
```

在 db1 停止並保存舊資料：

```bash
cd /opt/postgresql
docker compose down

sudo mv /srv/postgresql/data \
  /srv/postgresql/data.before-rejoin-$(date +%Y%m%d%H%M%S)

sudo install -d -m 0700 -o 26 -g 26 /srv/postgresql/data
```

從 db2 匯出新的 `PGDATA/pg_tde`：

```bash
docker compose exec -T postgres \
  tar -C /data/db -cf - pg_tde \
  > pg_tde-bootstrap.tar

chmod 0600 pg_tde-bootstrap.tar
```

將 archive 傳送到 db1，依第 15 節解壓，再執行：

```bash
docker compose \
  --env-file .env \
  run --rm --no-deps \
  --entrypoint pg_tde_basebackup \
  -e PGPASSWORD=CHANGE_ME_REPLICATION_PASSWORD \
  postgres \
    -h 192.168.50.12 \
    -p 5432 \
    -U replicator \
    -D /data/db \
    -F p \
    -X stream \
    --encrypt-wal=aes_256 \
    -R \
    -S db1_slot \
    -P
```

啟動 db1：

```bash
docker compose --env-file .env up -d
```

確認 db1 為 standby，db2 的 `pg_stat_replication` 顯示 `streaming`。

本文對 diverged 舊 primary 使用完整 base backup。現行 pg_tde 限制文件指出 `pg_rewind` 與 `pg_tde_rewind` 對 encrypted relations 存在資料損壞風險。

## 22. 將現有表轉換為 TDE

先建立 pg_tde provider 與 default key。接著在 primary 執行：

```sql
ALTER TABLE embeddings
SET ACCESS METHOD tde_heap;
```

此操作會重寫 relation。資料量、可用磁碟空間、WAL 產生量與 standby replay 時間需納入變更窗口。

確認：

```sql
SELECT pg_tde_is_encrypted('embeddings');
```

pgvector 欄位與 HNSW、IVFFlat index 可以位於 `tde_heap` 表。index 會隨 encrypted table 使用 pg_tde 加密。

多個資料庫需要分別執行：

```sql
CREATE EXTENSION pg_tde;
CREATE EXTENSION vector;
```

每個需要 encrypted table 的資料庫都需設定 default principal key。WAL server key 為 cluster 層級設定。

## 23. 金鑰輪換

輪換期間停止新的 physical base backup。輪換完成後建立新的完整備份。

建立新資料 key：

```sql
SELECT pg_tde_create_key_using_global_key_provider(
  'appdb-data-key-v2',
  'openbao'
);

SELECT pg_tde_set_default_key_using_global_key_provider(
  'appdb-data-key-v2',
  'openbao'
);
```

建立新 WAL key：

```sql
SELECT pg_tde_create_key_using_global_key_provider(
  'cluster-wal-key-v2',
  'openbao'
);

SELECT pg_tde_set_server_key_using_global_key_provider(
  'cluster-wal-key-v2',
  'openbao'
);
```

在 primary 與 standby 驗證：

```sql
SELECT pg_tde_verify_default_key();
SELECT pg_tde_verify_server_key();
```

輪換完成後，依第 15 至 16 節建立新的完整 standby backup 或獨立備份。

## 24. 備份

TDE cluster 的 physical backup 使用 `pg_tde_basebackup`。WAL encryption 使用 streaming 模式時加入：

```text
-X stream
--encrypt-wal=aes_256
```

執行前先複製 source 的 `PGDATA/pg_tde`。

logical backup 使用 `pg_dump` 或 `pg_dumpall`。logical dump 內容為資料庫邏輯資料，需要在受控位置保存或另行加密。

範例：

```bash
docker compose exec -T postgres \
  pg_dump -U postgres -d appdb -Fc \
  > appdb-$(date +%Y%m%d%H%M%S).dump
```

還原目標 image 需包含 pg_tde 與 pgvector。還原前建立 provider、principal key 和 extension。

## 25. OpenBao 可用性

PostgreSQL 啟動、金鑰驗證、部分 key 操作與節點重建需要存取 OpenBao。OpenBao endpoint、CA、token 路徑和 policy 屬於資料庫運行設定。

部署時保存：

```text
OpenBao storage backup
OpenBao unseal 或 auto-unseal 設定
KV v2 mount
pg_tde policy
資料庫 token 發行與續期流程
CA 與 TLS 憑證更新流程
PGDATA/pg_tde 備份
```

刪除 OpenBao 內的 principal key 會使對應 encrypted data 無法解密。

## 26. TDE 覆蓋範圍

`pg_tde` 加密使用 `tde_heap` 的資料表及其 index。WAL encryption 由 `pg_tde.wal_encrypt` 控制。

以下內容需另行處理：

```text
PostgreSQL system catalog 的部分 metadata
臨時檔案
資料庫與容器日誌
Docker metadata
host swap
備份檔
OpenBao token 與 CA 私密材料
```

host block storage 可使用 LUKS 或同類磁碟加密，覆蓋 PGDATA、temp、log 與 Docker storage。

## 27. 大版本升級

PostgreSQL 大版本升級使用 pg_tde 對應的 `pg_tde_upgrade` 流程。一般 `pg_upgrade` 不處理此 encrypted cluster 的 pg_tde metadata。

升級前保存：

```text
OpenBao storage backup
所有 principal key
PGDATA/pg_tde
完整 physical backup
logical backup
目前 image digest
pg_tde 與 pgvector 版本
```

先在獨立副本驗證升級，再更新主備節點。

## 28. 最終驗收

在 primary 執行：

```sql
SELECT pg_is_in_recovery();
SHOW pg_tde.cipher;
SHOW pg_tde.wal_encrypt;
SELECT pg_tde_verify_default_key();
SELECT pg_tde_verify_server_key();
SELECT pg_tde_is_encrypted('embeddings');
SELECT extname, extversion
FROM pg_extension
WHERE extname IN ('pg_tde', 'vector')
ORDER BY extname;
SELECT client_addr, state, sync_state
FROM pg_stat_replication;
```

在 standby 執行：

```sql
SELECT pg_is_in_recovery();
SHOW pg_tde.cipher;
SHOW pg_tde.wal_encrypt;
SELECT pg_tde_verify_default_key();
SELECT pg_tde_verify_server_key();
SELECT pg_tde_is_encrypted('embeddings');
SELECT status, sender_host, slot_name
FROM pg_stat_wal_receiver;
```

驗收值：

```text
一個 primary
一個 standby
streaming replication
pg_tde.cipher = aes_256
pg_tde.wal_encrypt = on
pg_tde_is_encrypted = true
pg_tde key verification 成功
pgvector extension 存在
primary 寫入可於 standby 查詢
```

## 29. 官方文件

- Percona Distribution for PostgreSQL Docker image
- pg_tde OpenBao key provider
- pg_tde streaming replication
- pg_tde encrypted WAL backup
- pg_tde limitations
- pgvector
- OpenBao

實際部署前，依選定 image digest 對照該版本文件與 release notes。
