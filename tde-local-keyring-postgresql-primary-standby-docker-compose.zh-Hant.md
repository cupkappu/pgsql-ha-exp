# PostgreSQL 本機 Keyring TDE 雙機主備部署手冊

本文使用 Percona Distribution for PostgreSQL 17、pg_tde、pgvector、本機 keyring file、Docker Compose、LUKS、physical streaming replication 與手動切換建立雙機主備。

架構不配置 OpenBao、Vault、KMIP 或外部 KMS。每台資料庫主機保存一份獨立 keyring；離線媒體保存第三份 keyring 與 SHA-256 manifest。

本文使用以下節點：

```text
host1  192.168.50.11  初始 primary
host2  192.168.50.12  初始 standby
```

資料庫元件：

```text
PostgreSQL 17.10.2
pg_tde 2.2.1
pgvector 0.8.3
TCP 5432
```

切換由操作人員執行。應用程式端點在 promote 後更新。本文未配置 VIP、HAProxy、Patroni、自動 fencing 或自動選主。

## 1. Keyring 模型

pg_tde 使用 principal key 加密 internal key。internal key 與 provider metadata 位於：

```text
$PGDATA/pg_tde
```

principal key 位於：

```text
/srv/postgresql-keyring/principal.keyring
```

兩台主機使用相同容器路徑：

```text
/run/pg-tde-keyring/principal.keyring
```

複製關係：

```text
目前 primary keyring
    ├── 同步副本 -> standby keyring
    └── 版本化副本 -> 離線備份媒體
```

host1 與 host2 使用各自的 keyring 檔案。兩台容器不掛載同一個可寫網路檔案系統。

Percona 文件將 keyring file 定義為開發與測試用途。該檔案以未加密形式保存 principal key。Percona 的 replication 文件指出，file provider 不用於 shared 或 concurrent multi-server access。本文只在初始化與重建階段複製靜態副本；密鑰變更後重新製作完整 standby。

## 2. 加密邊界

本方案包含兩層靜態資料加密：

```text
LUKS
└── 主機磁碟、Docker bind mount、keyring file

pg_tde
├── tde_heap table
├── tde_heap index
└── WAL
```

LUKS 處理關機狀態下的區塊裝置讀取。主機完成 LUKS 解鎖後，root 可讀取 PGDATA 與 keyring。

pg_tde 處理 database relation 與 WAL。現有 heap table 需要轉換為 `tde_heap`。系統 catalog、日誌、core dump、應用程式匯出檔案與其他未使用 `tde_heap` 的 relation 由主機磁碟加密處理。

## 3. License

本文使用的資料庫套件：

```text
percona-pg_tde17     PostgreSQL License
percona-pgvector_17  PostgreSQL License
```

OpenBao 未包含在本方案內。

## 4. LUKS 儲存配置

### 4.1 單一加密卷

每台主機使用一個 LUKS volume：

```text
/dev/sdb
└── LUKS
    └── /srv/postgresql-secure
        ├── data
        └── keyring
```

對應路徑：

```text
/srv/postgresql-secure/data
/srv/postgresql-secure/keyring/principal.keyring
```

該配置在關機時加密整個資料庫儲存。解鎖後，資料與 keyring 同時可讀。

### 4.2 分離加密卷

需要不同解鎖材料時，可使用兩個 LUKS volume：

```text
/dev/sdb
└── LUKS data
    └── /srv/postgresql/data

/dev/sdc
└── LUKS keyring
    └── /srv/postgresql-keyring
```

資料庫啟動順序：

```text
解鎖 data volume
解鎖 keyring volume
掛載兩個 filesystem
啟動 PostgreSQL container
```

keyring volume 使用人工輸入 passphrase 時，主機重啟後需要人工解鎖。

以下章節使用分離路徑：

```text
/srv/postgresql/data
/srv/postgresql-keyring
```

## 5. 建立 LUKS Volume

以下命令會清除範例裝置上的既有資料。將 `/dev/sdb` 與 `/dev/sdc` 改為實際裝置。

安裝工具：

```bash
sudo apt-get update
sudo apt-get install -y cryptsetup
```

建立 data volume：

```bash
sudo cryptsetup luksFormat /dev/sdb
sudo cryptsetup open /dev/sdb postgresql-data
sudo mkfs.ext4 /dev/mapper/postgresql-data
sudo install -d -m 0755 /srv/postgresql
sudo mount /dev/mapper/postgresql-data /srv/postgresql
sudo install -d -m 0700 -o 26 -g 26 /srv/postgresql/data
```

建立 keyring volume：

```bash
sudo cryptsetup luksFormat /dev/sdc
sudo cryptsetup open /dev/sdc postgresql-keyring
sudo mkfs.ext4 /dev/mapper/postgresql-keyring
sudo install -d -m 0755 /srv/postgresql-keyring
sudo mount /dev/mapper/postgresql-keyring /srv/postgresql-keyring
sudo chown 26:26 /srv/postgresql-keyring
sudo chmod 0700 /srv/postgresql-keyring
```

Percona container 內的 `postgres` 使用 UID/GID `26:26`。確認 image：

```bash
docker run --rm \
  percona/percona-distribution-postgresql:17.10-2-ubi8 \
  id postgres
```

預期包含：

```text
uid=26(postgres) gid=26(postgres)
```

查看 LUKS UUID：

```bash
sudo cryptsetup luksUUID /dev/sdb
sudo cryptsetup luksUUID /dev/sdc
```

人工解鎖的 `/etc/crypttab` 範例：

```text
postgresql-data UUID=DATA_LUKS_UUID none luks,noauto
postgresql-keyring UUID=KEYRING_LUKS_UUID none luks,noauto
```

啟動時執行：

```bash
sudo cryptdisks_start postgresql-data
sudo cryptdisks_start postgresql-keyring
sudo mount /dev/mapper/postgresql-data /srv/postgresql
sudo mount /dev/mapper/postgresql-keyring /srv/postgresql-keyring
```

關閉順序：

```bash
cd /opt/postgresql
sudo docker compose down
sudo umount /srv/postgresql-keyring
sudo umount /srv/postgresql
sudo cryptsetup close postgresql-keyring
sudo cryptsetup close postgresql-data
```

## 6. 建立部署目錄

在 host1 與 host2 執行：

```bash
sudo install -d -m 0755 /opt/postgresql
sudo install -d -m 0700 -o 26 -g 26 /srv/postgresql/data
sudo install -d -m 0700 -o 26 -g 26 /srv/postgresql-keyring
cd /opt/postgresql
```

檢查目錄：

```bash
sudo stat -c '%u:%g %a %n' \
  /srv/postgresql/data \
  /srv/postgresql-keyring
```

預期 owner：

```text
26:26
```

## 7. 環境變數

在兩台主機建立 `/opt/postgresql/.env`：

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

兩台主機使用相同 PostgreSQL image digest：

```bash
docker pull percona/percona-distribution-postgresql:17.10-2-ubi8
docker image inspect \
  percona/percona-distribution-postgresql:17.10-2-ubi8 \
  --format '{{json .RepoDigests}}'
```

## 8. pg_hba.conf

在兩台主機建立 `/opt/postgresql/pg_hba.conf`：

```conf
local   all             all                                     trust
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             192.168.50.0/24         scram-sha-256
host    replication     replicator      192.168.50.11/32        scram-sha-256
host    replication     replicator      192.168.50.12/32        scram-sha-256
```

應用程式網段改為實際 CIDR。replication 規則使用兩台資料庫主機的 `/32`。

## 9. Docker Compose

在兩台主機建立 `/opt/postgresql/compose.yml`：

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
    command:
      - postgres
      - -c
      - shared_preload_libraries=pg_tde
      - -c
      - pg_tde.cipher=aes_256
      - -c
      - listen_addresses=*
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
      - wal_keep_size=512MB
    volumes:
      - /srv/postgresql/data:/data/db
      - /srv/postgresql-keyring:/run/pg-tde-keyring
      - ./pg_hba.conf:/etc/postgresql/pg_hba.conf:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 3s
      retries: 20
      start_period: 10s
```

檢查展開結果：

```bash
cd /opt/postgresql
docker compose --env-file .env config
```

## 10. 初始化 host1 Primary

只在 host1 啟動 PostgreSQL：

```bash
cd /opt/postgresql
docker compose --env-file .env up -d
```

查看狀態：

```bash
docker compose ps
docker compose logs --tail 100 postgres
```

確認 primary：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT pg_is_in_recovery();"
```

回傳：

```text
f
```

## 11. 初始化 pg_tde、pgvector 與 Keyring

在 host1 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION pg_tde;
CREATE EXTENSION vector;

SELECT pg_tde_add_global_key_provider_file(
  'local-keyring',
  '/run/pg-tde-keyring/principal.keyring'
);

SELECT pg_tde_create_key_using_global_key_provider(
  'pgsql-data-key-v1',
  'local-keyring'
);

SELECT pg_tde_set_default_key_using_global_key_provider(
  'pgsql-data-key-v1',
  'local-keyring'
);

SELECT pg_tde_create_key_using_global_key_provider(
  'pgsql-wal-key-v1',
  'local-keyring'
);

SELECT pg_tde_set_server_key_using_global_key_provider(
  'pgsql-wal-key-v1',
  'local-keyring'
);

ALTER SYSTEM SET pg_tde.wal_encrypt = 'on';
SQL
```

重新啟動：

```bash
docker compose restart postgres
```

驗證：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SHOW pg_tde.wal_encrypt; SELECT * FROM pg_tde_default_key_info(); SELECT * FROM pg_tde_server_key_info(); SELECT * FROM pg_tde_list_all_global_key_providers();"
```

檢查 keyring：

```bash
sudo stat -c '%u:%g %a %s %n' \
  /srv/postgresql-keyring/principal.keyring
sudo sha256sum \
  /srv/postgresql-keyring/principal.keyring
```

設定檔案權限：

```bash
sudo chown 26:26 /srv/postgresql-keyring/principal.keyring
sudo chmod 0600 /srv/postgresql-keyring/principal.keyring
```

## 12. 建立 Replication Role

在 host1 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -v ON_ERROR_STOP=1 \
  -c "CREATE ROLE replicator WITH LOGIN REPLICATION PASSWORD 'CHANGE_ME_REPLICATION_PASSWORD';"
```

密碼需與 `.env` 的 `REPLICATION_PASSWORD` 相同。

重新載入 HBA：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT pg_reload_conf();"
```

## 13. 建立 Encrypted pgvector Table

在 host1 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -v ON_ERROR_STOP=1 <<'SQL'
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
```

驗證：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT pg_tde_is_encrypted('embeddings'); SELECT content FROM embeddings ORDER BY embedding <=> '[0.9,0.1,0]' LIMIT 1;"
```

預期包含：

```text
t
alpha
```

## 14. 保存離線 Keyring 備份

準備已掛載的加密備份媒體，例如：

```text
/mnt/offline-keyring-backup
```

在 host1 執行：

```bash
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
sudo install -d -m 0700 \
  "/mnt/offline-keyring-backup/${timestamp}"

sudo install -m 0600 \
  /srv/postgresql-keyring/principal.keyring \
  "/mnt/offline-keyring-backup/${timestamp}/principal.keyring"

cd "/mnt/offline-keyring-backup/${timestamp}"
sudo sha256sum principal.keyring \
  | sudo tee principal.keyring.sha256 >/dev/null
sudo chmod 0600 principal.keyring.sha256
sync
```

驗證：

```bash
cd "/mnt/offline-keyring-backup/${timestamp}"
sudo sha256sum -c principal.keyring.sha256
```

完成後卸載備份媒體：

```bash
cd /
sudo umount /mnt/offline-keyring-backup
```

每次 principal key 變更後建立新的版本目錄。舊 physical backup 可能依賴舊 principal key；保留對應版本的 keyring。

## 15. 將 Keyring 複製到 host2

停止所有 key rotation 操作。讀取 host1 checksum：

```bash
sudo sha256sum \
  /srv/postgresql-keyring/principal.keyring
```

透過管理通道將檔案複製至 host2 的暫存目錄。隨後在 host2 執行：

```bash
sudo install -m 0600 -o 26 -g 26 \
  /path/from/transfer/principal.keyring \
  /srv/postgresql-keyring/principal.keyring

sudo sha256sum \
  /srv/postgresql-keyring/principal.keyring
```

host1、host2 與離線備份的 checksum 應一致。

## 16. 建立 host2 Standby

### 16.1 建立 Replication Slot

在 host1 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -v ON_ERROR_STOP=1 \
  -c "SELECT * FROM pg_create_physical_replication_slot('host2_slot');"
```

### 16.2 準備 host2 PGDATA

在 host2 執行：

```bash
cd /opt/postgresql
docker compose down
sudo find /srv/postgresql/data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
sudo chown 26:26 /srv/postgresql/data
sudo chmod 0700 /srv/postgresql/data
```

### 16.3 複製 pg_tde Metadata

WAL encryption 開啟時，`pg_tde_basebackup` 執行前需要把 source `$PGDATA/pg_tde` 複製到目標 PGDATA。

在 host1 建立 transfer archive：

```bash
sudo tar -C /srv/postgresql/data \
  -cpf /path/to/transfer/pg_tde.tar \
  pg_tde
```

將 archive 傳至 host2，然後執行：

```bash
sudo tar -C /srv/postgresql/data \
  -xpf /path/from/transfer/pg_tde.tar
sudo chown -R 26:26 /srv/postgresql/data/pg_tde
```

### 16.4 執行 pg_tde_basebackup

在 host2 執行：

```bash
docker run --rm \
  --network host \
  --user 26:26 \
  -e PGPASSWORD=CHANGE_ME_REPLICATION_PASSWORD \
  -v /srv/postgresql/data:/data/db \
  -v /srv/postgresql-keyring:/run/pg-tde-keyring:ro \
  percona/percona-distribution-postgresql:17.10-2-ubi8 \
  pg_tde_basebackup \
    -h 192.168.50.11 \
    -p 5432 \
    -U replicator \
    -D /data/db \
    -F p \
    -X stream \
    --encrypt-wal=aes_256 \
    -R \
    -S host2_slot \
    -P
```

檢查：

```bash
sudo test -f /srv/postgresql/data/PG_VERSION
sudo test -f /srv/postgresql/data/standby.signal
sudo test -d /srv/postgresql/data/pg_tde
```

啟動 host2：

```bash
cd /opt/postgresql
docker compose --env-file .env up -d
```

確認 standby：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT pg_is_in_recovery(); SELECT pg_tde_is_encrypted('embeddings'); SELECT pg_tde_verify_default_key(); SELECT pg_tde_verify_server_key();"
```

預期 `pg_is_in_recovery()` 回傳 `t`。

## 17. 驗證 Streaming Replication

在 host1 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT client_addr, state, sync_state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication;"
```

`state` 應顯示：

```text
streaming
```

在 host2 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT status, sender_host, slot_name, latest_end_lsn FROM pg_stat_wal_receiver;"
```

寫入測試：

```bash
# host1
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "INSERT INTO embeddings(content, embedding) VALUES ('replication-check', '[0.8,0.2,0]');"

# host2
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT content FROM embeddings WHERE content = 'replication-check';"
```

## 18. 計畫內切換

以下流程由 host1 切換至 host2。

停止應用程式寫入並關閉 connection pool。

在 host1 記錄目標 LSN：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -Atc "CHECKPOINT; SELECT pg_current_wal_lsn();"
```

在 host2 等待 replay LSN 到達目標值：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT pg_last_wal_replay_lsn(), pg_last_wal_replay_lsn() >= 'TARGET_LSN'::pg_lsn AS caught_up;"
```

`caught_up` 回傳 `t` 後，在 host1 停止 PostgreSQL：

```bash
cd /opt/postgresql
docker compose stop postgres
```

在 host2 promote：

```bash
cd /opt/postgresql
docker compose exec -T --user postgres postgres \
  pg_ctl -D /data/db promote -w
```

確認：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT pg_is_in_recovery(); SELECT pg_tde_verify_default_key(); SELECT pg_tde_verify_server_key();"
```

將應用程式端點改為：

```text
192.168.50.12:5432
```

重新建立 connection pool 並恢復寫入。

## 19. Primary 故障後提升 host2

先隔離 host1，確保舊 primary 不再接受寫入。

在 host2 記錄最後接收與重播位置：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT now(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(), pg_last_xact_replay_timestamp();"
```

執行 promote：

```bash
docker compose exec -T --user postgres postgres \
  pg_ctl -D /data/db promote -w
```

驗證 encrypted table：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT pg_tde_is_encrypted('embeddings'); INSERT INTO embeddings(content, embedding) VALUES ('after-failover', '[0.7,0.3,0]');"
```

更新應用程式端點至 host2。

## 20. 將舊 host1 重建為 Standby

舊 primary 的 timeline 已分叉。本文使用完整 base backup 重建。

在目前 primary host2 建立 slot：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT * FROM pg_create_physical_replication_slot('host1_slot');"
```

將 host2 目前 keyring 複製到 host1：

```text
host2 /srv/postgresql-keyring/principal.keyring
    -> host1 /srv/postgresql-keyring/principal.keyring
```

在 host1 檢查 checksum 與權限：

```bash
sudo chown 26:26 /srv/postgresql-keyring/principal.keyring
sudo chmod 0600 /srv/postgresql-keyring/principal.keyring
sudo sha256sum /srv/postgresql-keyring/principal.keyring
```

停止並保存舊 PGDATA：

```bash
cd /opt/postgresql
docker compose down
sudo mv /srv/postgresql/data \
  "/srv/postgresql/data.before-rejoin-$(date +%Y%m%d%H%M%S)"
sudo install -d -m 0700 -o 26 -g 26 /srv/postgresql/data
```

從 host2 複製 `PGDATA/pg_tde` metadata 至新目錄，再執行：

```bash
docker run --rm \
  --network host \
  --user 26:26 \
  -e PGPASSWORD=CHANGE_ME_REPLICATION_PASSWORD \
  -v /srv/postgresql/data:/data/db \
  -v /srv/postgresql-keyring:/run/pg-tde-keyring:ro \
  percona/percona-distribution-postgresql:17.10-2-ubi8 \
  pg_tde_basebackup \
    -h 192.168.50.12 \
    -p 5432 \
    -U replicator \
    -D /data/db \
    -F p \
    -X stream \
    --encrypt-wal=aes_256 \
    -R \
    -S host1_slot \
    -P
```

啟動 host1 並確認 standby：

```bash
docker compose --env-file .env up -d
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT pg_is_in_recovery(); SELECT pg_tde_is_encrypted('embeddings');"
```

驗收完成後，依資料保留規則刪除 `data.before-rejoin-*`。

## 21. Keyring 輪換

輪換期間停止 base backup 與其他備份工作。Percona 文件指出，key rotation 與 backup 並行可能產生無法恢復的備份。

本機 keyring 與雙機主備使用以下順序：

```text
停止應用程式寫入
停止 standby
確認沒有 backup 工作
在 primary 建立新 data principal key
在 primary 建立新 WAL principal key
保存新版離線 keyring
清除並重建 standby
完成複寫驗證
恢復應用程式寫入
```

在 primary 執行：

```sql
SELECT pg_tde_create_key_using_global_key_provider(
  'pgsql-data-key-v2',
  'local-keyring'
);

SELECT pg_tde_set_default_key_using_global_key_provider(
  'pgsql-data-key-v2',
  'local-keyring'
);

SELECT pg_tde_create_key_using_global_key_provider(
  'pgsql-wal-key-v2',
  'local-keyring'
);

SELECT pg_tde_set_server_key_using_global_key_provider(
  'pgsql-wal-key-v2',
  'local-keyring'
);
```

驗證：

```sql
SELECT * FROM pg_tde_default_key_info();
SELECT * FROM pg_tde_server_key_info();
SELECT pg_tde_verify_default_key();
SELECT pg_tde_verify_server_key();
```

建立新的離線 keyring 版本。將新版 keyring 複製到 standby 後，依第 20 節執行完整重建。輪換完成後建立新的完整資料庫備份。

舊 key 保留在 keyring provider 中，用於讀取舊 backup。刪除舊 key 後，依賴該 key 的 backup 無法恢復。

## 22. Keyring 遺失恢復

PostgreSQL 缺少 keyring 時，啟動會出現類似錯誤：

```text
FATAL: key "..." not found in key provider "local-keyring"
```

停止容器：

```bash
cd /opt/postgresql
docker compose down
```

掛載離線備份媒體並驗證：

```bash
cd /mnt/offline-keyring-backup/BACKUP_VERSION
sudo sha256sum -c principal.keyring.sha256
```

恢復：

```bash
sudo install -m 0600 -o 26 -g 26 \
  principal.keyring \
  /srv/postgresql-keyring/principal.keyring
```

啟動並驗證：

```bash
cd /opt/postgresql
docker compose --env-file .env up -d

docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT pg_tde_verify_default_key(); SELECT pg_tde_verify_server_key();"
```

恢復檔案需包含目前 PGDATA 所引用的 principal key。checksum 一致只證明檔案內容與備份副本一致。

## 23. Encrypted Table 轉換

現有 heap table 轉換為 `tde_heap`：

```sql
ALTER TABLE existing_table
SET ACCESS METHOD tde_heap;
```

該操作重寫 table。執行後驗證：

```sql
SELECT pg_tde_is_encrypted('existing_table');
```

pgvector table 使用相同轉換方式：

```sql
ALTER TABLE embeddings
SET ACCESS METHOD tde_heap;
```

轉換期間會取得 table lock。操作窗口由 table size、磁碟吞吐與 index rebuild 時間決定。

## 24. 資料庫備份

啟用 encrypted WAL 時，physical backup 使用 `pg_tde_basebackup`。

備份目標目錄需預先包含 source `PGDATA/pg_tde`，並能透過相同路徑讀取 keyring file。命令：

```bash
pg_tde_basebackup \
  -h PRIMARY_IP \
  -U replicator \
  -D /path/to/backup \
  -F p \
  -X stream \
  --encrypt-wal=aes_256 \
  -P
```

備份集合保存：

```text
physical backup
對應版本 keyring
keyring SHA-256 manifest
PostgreSQL image digest
pg_tde 與 pgvector 版本
備份時間與 source LSN
```

keyring 與資料庫 backup 使用不同儲存位置。

## 25. 狀態檢查

Primary：

```sql
SELECT pg_is_in_recovery();
SHOW pg_tde.wal_encrypt;
SELECT * FROM pg_tde_default_key_info();
SELECT * FROM pg_tde_server_key_info();
SELECT * FROM pg_tde_list_all_global_key_providers();
SELECT client_addr, state, sync_state, replay_lsn
FROM pg_stat_replication;
```

Standby：

```sql
SELECT pg_is_in_recovery();
SHOW pg_tde.wal_encrypt;
SELECT pg_tde_verify_default_key();
SELECT pg_tde_verify_server_key();
SELECT status, sender_host, slot_name, latest_end_lsn
FROM pg_stat_wal_receiver;
```

Encrypted relation：

```sql
SELECT pg_tde_is_encrypted('embeddings');
```

Keyring 檔案：

```bash
sudo stat -c '%u:%g %a %s %n' \
  /srv/postgresql-keyring/principal.keyring
sudo sha256sum \
  /srv/postgresql-keyring/principal.keyring
```

## 26. 操作限制

本方案的執行條件：

```text
兩台節點使用相同 PostgreSQL major version
兩台節點使用相同 Percona image digest
兩台節點使用相同 pg_tde 與 pgvector 版本
keyring container path 完全相同
keyring 變更期間停止 backup
keyring 變更後重新製作 standby
每個 keyring 版本保存離線副本
promote 前隔離舊 primary
```

本機 keyring 沒有 KMS ACL、遠端撤銷、集中稽核或獨立服務故障域。執行中主機的 root 可讀取未加密 keyring file。

Percona 將 file provider 標示為開發與測試功能，並在 replication 文件中標示其不適用於 shared 或 concurrent multi-server access。本文實驗與部署流程驗證獨立副本、手動同步、完整重建與離線恢復。

## 27. 倉庫實驗

倉庫內實驗在單一 Docker host 模擬兩台資料庫主機：

```bash
make tde-local-demo-test
```

單獨命令：

```bash
make tde-local-demo-up
make tde-local-demo-status
make tde-local-demo-smoke
make tde-local-demo-promote NODE=pg2
make tde-local-demo-rejoin NODE=pg1
make tde-local-demo-keyring-restore
make tde-local-demo-down
make tde-local-demo-clean
```

自動驗收包含：

```text
local file provider
三份獨立 keyring checksum
AES-256 WAL encryption
tde_heap table
pgvector HNSW query
streaming replication
manual promote
old primary full rejoin
missing keyring startup failure
offline backup keyring restore
```

## 28. 參考文件

```text
https://docs.percona.com/pg-tde/global-key-provider-configuration/keyring.html
https://docs.percona.com/pg-tde/replication.html
https://docs.percona.com/pg-tde/how-to/backup-wal-enabled.html
https://docs.percona.com/pg-tde/architecture/key-provider-management.html
https://docs.percona.com/pg-tde/how-to/restore-backups.html
```
