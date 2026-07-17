# PostgreSQL 雙機手動主備：Docker Compose 完整操作手冊

本文使用 PostgreSQL 16、Docker Engine、Docker Compose、`pg_basebackup` 與串流複寫建立雙機主備。所有設定檔與命令均包含在本文內，不引用倉庫腳本、Makefile、自訂入口程式或既有範本。

內容涵蓋以下操作：

1. 由零建立 primary 與 standby。
2. 將既有 Docker Compose 單實例擴展為雙機主備。
3. 執行計畫內切換、故障後提升、舊 primary 重建與切回。
4. 安裝及維護 PostgreSQL extension，並以 pgvector 為例。

本文使用非同步 physical streaming replication。primary 突然失效時，尚未送達 standby 的交易可能遺失。計畫內切換會先停止應用程式寫入，確認 WAL 已完成重播，再提升 standby。

## 1. 範例環境

```text
host1  192.168.50.11  初始 primary
host2  192.168.50.12  初始 standby
port   5432
```

兩台主機均需安裝 Docker Engine 與 Docker Compose plugin。主機間開放 TCP 5432。本文使用 host network，主機的 TCP 5432 需保持空閒。

每台主機使用以下路徑：

```text
/opt/postgresql/compose.yml
/opt/postgresql/.env
/opt/postgresql/.pgpass
/opt/postgresql/pg_hba.conf
/srv/postgresql/data
```

本文命令預設於 `/opt/postgresql` 執行。

## 2. 準備目錄

在 host1 與 host2 執行：

```bash
sudo install -d -m 0755 /opt/postgresql
sudo install -d -m 0700 -o 999 -g 999 /srv/postgresql/data
cd /opt/postgresql
```

確認 image 內的 PostgreSQL UID/GID：

```bash
docker run --rm postgres:16-bookworm id postgres
```

本文範例使用 `999:999`。輸出不同時，依實際 UID/GID 調整資料目錄：

```bash
sudo chown -R UID:GID /srv/postgresql/data
sudo chmod 0700 /srv/postgresql/data
```

## 3. 建立 Compose 設定

以下檔案在兩台主機使用相同內容。

### 3.1 `.env`

建立 `/opt/postgresql/.env`：

```dotenv
POSTGRES_IMAGE=postgres:16-bookworm
POSTGRES_PASSWORD=CHANGE_ME_POSTGRES_PASSWORD
REPLICATION_PASSWORD=CHANGE_ME_REPLICATION_PASSWORD
```

設定權限：

```bash
sudo chmod 0600 /opt/postgresql/.env
```

正式使用時固定 image digest。兩台主機應使用同一個 PostgreSQL 大版本、image tag 與 digest。

查看 digest：

```bash
docker pull postgres:16-bookworm
docker image inspect postgres:16-bookworm \
  --format '{{json .RepoDigests}}'
```

### 3.2 `.pgpass`

建立 `/opt/postgresql/.pgpass`：

```text
192.168.50.11:5432:replication:replicator:CHANGE_ME_REPLICATION_PASSWORD
192.168.50.12:5432:replication:replicator:CHANGE_ME_REPLICATION_PASSWORD
```

密碼需與 `.env` 的 `REPLICATION_PASSWORD` 相同。

設定權限：

```bash
sudo chown 999:999 /opt/postgresql/.pgpass
sudo chmod 0600 /opt/postgresql/.pgpass
```

### 3.3 `pg_hba.conf`

建立 `/opt/postgresql/pg_hba.conf`：

```conf
local   all             all                                     trust
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             192.168.50.0/24         scram-sha-256
host    replication     replicator      192.168.50.11/32        scram-sha-256
host    replication     replicator      192.168.50.12/32        scram-sha-256
```

將應用程式網段與兩台資料庫 IP 改成實際值。資料庫主機使用其他網卡傳輸複寫時，填入該網卡位址。

### 3.4 `compose.yml`

建立 `/opt/postgresql/compose.yml`：

```yaml
services:
  postgres:
    image: ${POSTGRES_IMAGE}
    container_name: postgres
    restart: unless-stopped
    network_mode: host
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: postgres
      POSTGRES_INITDB_ARGS: --auth-host=scram-sha-256 --auth-local=trust
      PGDATA: /var/lib/postgresql/data
    command:
      - postgres
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
      - wal_keep_size=512MB
    volumes:
      - /srv/postgresql/data:/var/lib/postgresql/data
      - ./pg_hba.conf:/etc/postgresql/pg_hba.conf:ro
      - ./.pgpass:/var/lib/postgresql/.pgpass:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres -d postgres"]
      interval: 5s
      timeout: 3s
      retries: 12
      start_period: 10s
```

檢查展開後的設定：

```bash
cd /opt/postgresql
docker compose --env-file .env config
```

## 4. 由零建立雙機主備

### 4.1 初始化 host1 primary

只在 host1 執行：

```bash
cd /opt/postgresql
docker compose --env-file .env up -d
```

查看容器與日誌：

```bash
docker compose ps
docker compose logs --tail 100 postgres
```

確認 host1 角色：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT pg_is_in_recovery();"
```

primary 回傳：

```text
f
```

### 4.2 建立複寫帳號

在 host1 執行。SQL 內的密碼需與 `.env` 和 `.pgpass` 相同。

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -v ON_ERROR_STOP=1 \
  -c "CREATE ROLE replicator WITH LOGIN REPLICATION PASSWORD 'CHANGE_ME_REPLICATION_PASSWORD';"
```

確認帳號：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT rolname, rolreplication FROM pg_roles WHERE rolname = 'replicator';"
```

### 4.3 建立 host2 replication slot

在 host1 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -v ON_ERROR_STOP=1 \
  -c "SELECT * FROM pg_create_physical_replication_slot('host2_slot');"
```

查看 slot：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT slot_name, slot_type, active, restart_lsn FROM pg_replication_slots;"
```

physical replication slot 會保留 standby 尚未接收的 WAL。standby 長期離線時，primary 的 `pg_wal` 會持續增長。運維期間需監看 slot 狀態與磁碟空間。

### 4.4 測試 host2 到 host1 的連線

在 host2 執行：

```bash
docker run --rm \
  --network host \
  --user postgres \
  -e PGPASSFILE=/var/lib/postgresql/.pgpass \
  -v /opt/postgresql/.pgpass:/var/lib/postgresql/.pgpass:ro \
  postgres:16-bookworm \
  pg_isready -h 192.168.50.11 -p 5432 -U replicator
```

測試認證：

```bash
docker run --rm \
  --network host \
  --user postgres \
  -e PGPASSFILE=/var/lib/postgresql/.pgpass \
  -v /opt/postgresql/.pgpass:/var/lib/postgresql/.pgpass:ro \
  postgres:16-bookworm \
  psql "host=192.168.50.11 port=5432 user=replicator dbname=postgres" \
  -c "SELECT pg_is_in_recovery();"
```

### 4.5 由 host1 建立 host2 standby

先在 host2 停止 Compose：

```bash
cd /opt/postgresql
docker compose --env-file .env down
```

確認資料目錄沒有正式資料。由零建立時可清空：

```bash
sudo find /srv/postgresql/data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
sudo chown 999:999 /srv/postgresql/data
sudo chmod 0700 /srv/postgresql/data
```

執行 base backup：

```bash
docker run --rm \
  --network host \
  --user postgres \
  -e PGPASSFILE=/var/lib/postgresql/.pgpass \
  -v /srv/postgresql/data:/var/lib/postgresql/data \
  -v /opt/postgresql/.pgpass:/var/lib/postgresql/.pgpass:ro \
  postgres:16-bookworm \
  pg_basebackup \
    -h 192.168.50.11 \
    -p 5432 \
    -U replicator \
    -D /var/lib/postgresql/data \
    -Fp \
    -Xs \
    -P \
    -R \
    -S host2_slot
```

`-R` 會建立 `standby.signal`，並將 primary 連線資料與 slot 名稱寫入 `postgresql.auto.conf`。

檢查結果：

```bash
sudo test -f /srv/postgresql/data/PG_VERSION
sudo test -f /srv/postgresql/data/standby.signal
sudo grep -E 'primary_conninfo|primary_slot_name' \
  /srv/postgresql/data/postgresql.auto.conf
```

啟動 host2：

```bash
cd /opt/postgresql
docker compose --env-file .env up -d
```

查看日誌與角色：

```bash
docker compose logs --tail 100 postgres

docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT pg_is_in_recovery();"
```

standby 回傳：

```text
t
```

### 4.6 驗證串流複寫

在 host1 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -x \
  -c "SELECT application_name, client_addr, state, sync_state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication;"
```

`state` 應顯示 `streaming`。非同步複寫的 `sync_state` 顯示 `async`。

在 host1 建立測試資料：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -v ON_ERROR_STOP=1 \
  -c "CREATE DATABASE appdb;"

docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -v ON_ERROR_STOP=1 \
  -c "CREATE TABLE ha_check (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, note text NOT NULL, created_at timestamptz NOT NULL DEFAULT now()); INSERT INTO ha_check(note) VALUES ('written-on-host1');"
```

在 host2 查詢：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "TABLE ha_check;"
```

standby 接受唯讀查詢。寫入會回傳 read-only transaction 錯誤。

## 5. 將既有單實例擴展為雙機主備

本節假設 host1 已透過 Docker Compose 執行 PostgreSQL，host2 尚未保存正式資料。

### 5.1 記錄既有實例

在 host1 執行：

```bash
docker compose config
docker inspect postgres
```

查詢 PostgreSQL 狀態：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT version(); SHOW data_directory; SHOW hba_file; SHOW config_file; SHOW port; SHOW listen_addresses; SHOW wal_level; SHOW max_wal_senders; SHOW max_replication_slots; SHOW wal_keep_size;"
```

記錄以下資料：

```text
PostgreSQL 大版本
container image 與 digest
資料 volume 或 bind mount
PGDATA
外部設定檔掛載
應用程式帳號與資料庫
啟動參數
```

host2 使用相同 PostgreSQL 大版本。若 host1 已安裝 extension，先完成第 10 節的 image 檢查，再啟動 host2。

### 5.2 加入複寫參數

將既有 PostgreSQL service 的啟動參數補成以下內容：

```yaml
command:
  - postgres
  - -c
  - listen_addresses=*
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
```

`wal_level`、`max_wal_senders` 與 `max_replication_slots` 的變更需要重新啟動 PostgreSQL。重新建立容器：

```bash
docker compose up -d --force-recreate postgres
```

確認參數：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SHOW wal_level; SHOW max_wal_senders; SHOW max_replication_slots; SHOW hot_standby; SHOW wal_keep_size;"
```

### 5.3 加入 HBA 規則

在 host1 使用中的 `pg_hba.conf` 加入：

```conf
host    replication     replicator      192.168.50.12/32        scram-sha-256
```

重新載入：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT pg_reload_conf();"
```

確認實際 HBA 檔案與規則：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SHOW hba_file;"

docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT line_number, type, database, user_name, address, auth_method, error FROM pg_hba_file_rules ORDER BY line_number;"
```

### 5.4 建立或更新複寫帳號

確認帳號：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT rolname, rolreplication FROM pg_roles WHERE rolname = 'replicator';"
```

帳號不存在時執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -v ON_ERROR_STOP=1 \
  -c "CREATE ROLE replicator WITH LOGIN REPLICATION PASSWORD 'CHANGE_ME_REPLICATION_PASSWORD';"
```

帳號已存在時執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -v ON_ERROR_STOP=1 \
  -c "ALTER ROLE replicator WITH LOGIN REPLICATION PASSWORD 'CHANGE_ME_REPLICATION_PASSWORD';"
```

### 5.5 建立 slot 與 host2

在 host1 建立 slot：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -v ON_ERROR_STOP=1 \
  -c "SELECT * FROM pg_create_physical_replication_slot('host2_slot');"
```

在 host2 建立第 3 節的 `.env`、`.pgpass`、`pg_hba.conf` 與 `compose.yml`。`POSTGRES_IMAGE` 使用 host1 的 image。資料目錄保持空白。

執行第 4.4 至 4.6 節，從 host1 建立 host2 standby 並驗證複寫。`pg_basebackup` 會複製現有資料庫、角色、schema、資料與 extension catalog。

### 5.6 切換應用程式端點

此架構未配置 VIP、HAProxy 或自動服務發現。應用程式需保存單一可修改的資料庫端點，例如：

```dotenv
DATABASE_HOST=192.168.50.11
DATABASE_PORT=5432
```

完成 promote 後，將 `DATABASE_HOST` 改成新的 primary，重新建立連線池。舊連線需關閉並重新連線。

## 6. 日常狀態檢查

### 6.1 判斷節點角色

在任一節點執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT inet_server_addr(), pg_is_in_recovery(), pg_current_wal_lsn(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"
```

primary：

```text
pg_is_in_recovery = f
```

standby：

```text
pg_is_in_recovery = t
```

### 6.2 查看 primary 的 sender

在 primary 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -x \
  -c "SELECT pid, application_name, client_addr, state, sync_state, sent_lsn, write_lsn, flush_lsn, replay_lsn, write_lag, flush_lag, replay_lag FROM pg_stat_replication;"
```

### 6.3 查看 standby 接收狀態

在 standby 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -x \
  -c "SELECT status, sender_host, sender_port, slot_name, written_lsn, flushed_lsn, latest_end_lsn, latest_end_time FROM pg_stat_wal_receiver;"
```

### 6.4 計算 replay lag bytes

在 standby 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) AS receive_replay_lag_bytes;"
```

在 primary 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT application_name, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS primary_replay_lag_bytes FROM pg_stat_replication;"
```

### 6.5 查看 slot 與 WAL 保留量

在 primary 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT slot_name, active, restart_lsn, wal_status, safe_wal_size FROM pg_replication_slots;"
```

查看 `pg_wal` 大小：

```bash
docker compose exec -T postgres \
  du -sh /var/lib/postgresql/data/pg_wal
```

## 7. 計畫內切換：host1 切到 host2

以下流程假設 host1 為 primary，host2 為 standby。

### 7.1 停止應用程式寫入

停止會寫入資料庫的服務，或將服務切入維護狀態。關閉現有連線池。

確認 primary 上沒有應用程式交易：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT pid, usename, application_name, client_addr, state, xact_start, query FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid() ORDER BY xact_start NULLS LAST;"
```

### 7.2 記錄 primary 的目標 LSN

在 host1 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -Atc "CHECKPOINT; SELECT pg_current_wal_lsn();"
```

記錄輸出的 LSN，例如：

```text
0/50001D0
```

### 7.3 等待 standby 重播完成

在 host2 執行，將 LSN 換成上一步的值：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT pg_last_wal_replay_lsn(), pg_last_wal_replay_lsn() >= '0/50001D0'::pg_lsn AS caught_up;"
```

`caught_up` 顯示 `t` 後繼續。

### 7.4 停止舊 primary

在 host1 執行：

```bash
cd /opt/postgresql
docker compose stop postgres
```

確認容器已停止：

```bash
docker compose ps
```

### 7.5 提升 host2

在 host2 執行：

```bash
cd /opt/postgresql
docker compose exec -T --user postgres postgres \
  pg_ctl -D /var/lib/postgresql/data promote -w
```

確認 host2 已成為 primary：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT pg_is_in_recovery(), pg_current_wal_lsn();"
```

`pg_is_in_recovery()` 應回傳 `f`。

### 7.6 切換應用程式

將應用程式端點改成：

```text
192.168.50.12:5432
```

重新啟動連線池與寫入服務。執行一筆可識別的驗證交易：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -v ON_ERROR_STOP=1 \
  -c "INSERT INTO ha_check(note) VALUES ('written-after-host2-promotion') RETURNING *;"
```

## 8. 將舊 host1 重建為 standby

promote 會建立新的 timeline。舊 primary 的資料目錄不應直接以 primary 模式重新啟動。本文使用新的 base backup 重建 host1。

### 8.1 在 host2 建立 host1 slot

在目前 primary host2 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -v ON_ERROR_STOP=1 \
  -c "SELECT * FROM pg_create_physical_replication_slot('host1_slot');"
```

slot 已存在時先檢查：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT slot_name, active, restart_lsn FROM pg_replication_slots WHERE slot_name = 'host1_slot';"
```

### 8.2 保存 host1 舊資料目錄

在 host1 執行：

```bash
cd /opt/postgresql
docker compose down

sudo mv /srv/postgresql/data \
  /srv/postgresql/data.before-rejoin-$(date +%Y%m%d%H%M%S)

sudo install -d -m 0700 -o 999 -g 999 /srv/postgresql/data
```

### 8.3 從 host2 建立 host1 standby

在 host1 執行：

```bash
docker run --rm \
  --network host \
  --user postgres \
  -e PGPASSFILE=/var/lib/postgresql/.pgpass \
  -v /srv/postgresql/data:/var/lib/postgresql/data \
  -v /opt/postgresql/.pgpass:/var/lib/postgresql/.pgpass:ro \
  postgres:16-bookworm \
  pg_basebackup \
    -h 192.168.50.12 \
    -p 5432 \
    -U replicator \
    -D /var/lib/postgresql/data \
    -Fp \
    -Xs \
    -P \
    -R \
    -S host1_slot
```

啟動 host1：

```bash
cd /opt/postgresql
docker compose --env-file .env up -d
```

確認 host1 為 standby：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"
```

在 host2 確認 sender：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT client_addr, state, sync_state, replay_lsn FROM pg_stat_replication;"
```

確認新 primary 上的測試資料已出現在 host1：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "TABLE ha_check;"
```

驗收完成後，依備份保留政策刪除 `data.before-rejoin-*`。

## 9. primary 故障後手動提升 standby

以下流程假設 host1 primary 已失效，host2 standby 仍可使用。

### 9.1 隔離舊 primary

確認 host1 的 PostgreSQL 容器已停止，或主機已關機。若 host1 仍可啟動，先執行：

```bash
cd /opt/postgresql
docker compose stop postgres
```

無法登入 host1 時，於交換器、防火牆、虛擬化平台或電源管理介面隔離該主機。提升 host2 前，舊 primary 不應繼續接受應用程式寫入。兩台節點同時寫入會形成兩條獨立 timeline。

### 9.2 記錄 standby 最後接收與重播位置

在 host2 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT now(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn(), pg_last_xact_replay_timestamp();"
```

此輸出用於記錄故障時的資料位置。非同步複寫的資料遺失範圍由 primary 最後提交位置與 standby 最後接收位置之差決定。primary 無法存取時，該差值無法直接取得。

### 9.3 提升 host2

```bash
cd /opt/postgresql
docker compose exec -T --user postgres postgres \
  pg_ctl -D /var/lib/postgresql/data promote -w
```

確認角色：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT pg_is_in_recovery(), pg_current_wal_lsn();"
```

更新應用程式端點至 `192.168.50.12:5432`，重新建立連線並執行驗證交易。

### 9.4 恢復舊 host1

host1 恢復連線後，先保持 PostgreSQL 容器停止。依第 8 節從 host2 重新建立 host1 standby。

## 10. PostgreSQL extension 與 pgvector

physical replication 會複製 PGDATA 與 WAL。extension 的 control file、SQL 安裝檔與 shared library 位於 container image 內，這些檔案不會由串流複寫傳送。兩台節點需安裝相同 extension，並使用相同版本。

### 10.1 通用規則

使用 extension 時執行以下檢查：

- primary 與 standby 使用相同 PostgreSQL 大版本。
- 兩台 image 均包含 extension 的 control file、SQL 檔與 shared library。
- extension 版本保持一致。
- `CREATE EXTENSION`、`ALTER EXTENSION UPDATE` 與 `DROP EXTENSION` 只在 primary 執行。
- extension 需要 `shared_preload_libraries` 時，兩台節點使用相同設定並重新啟動 PostgreSQL。
- extension 依賴作業系統套件、字典、模型或外部檔案時，兩台 image 與掛載路徑保持一致。

`CREATE EXTENSION` 會修改資料庫 catalog。physical replication 會將該變更重播至 standby。standby 啟動與查詢 extension 物件時，仍會從本機 image 載入 extension 檔案。

查看已安裝 extension：

```sql
SELECT extname, extversion
FROM pg_extension
ORDER BY extname;
```

查看 image 提供的 extension：

```sql
SELECT name, default_version, installed_version
FROM pg_available_extensions
ORDER BY name;
```

### 10.2 使用 pgvector image

兩台主機將 `.env` 的 image 改為同一個 pgvector 版本：

```dotenv
POSTGRES_IMAGE=pgvector/pgvector:0.8.2-pg16-bookworm
POSTGRES_PASSWORD=CHANGE_ME_POSTGRES_PASSWORD
REPLICATION_PASSWORD=CHANGE_ME_REPLICATION_PASSWORD
```

拉取 image 並查看 digest：

```bash
docker pull pgvector/pgvector:0.8.2-pg16-bookworm
docker image inspect pgvector/pgvector:0.8.2-pg16-bookworm \
  --format '{{json .RepoDigests}}'
```

`pgvector/pgvector` image 沿用官方 PostgreSQL image 的環境變數、資料目錄與入口方式。第 3 節的 Compose 設定可直接使用。

### 10.3 既有單實例已使用 pgvector

在 host1 檢查版本：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'vector';"
```

在 host2 執行 base backup 前，先使用包含相同 pgvector 版本的 image。base backup 完成後啟動 standby，再檢查：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'vector';"
```

兩台應回傳相同 `extversion`。

### 10.4 新建 pgvector extension

只在目前 primary 執行，每個需要 vector type 的資料庫各執行一次：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -v ON_ERROR_STOP=1 \
  -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

驗證：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'vector';"
```

建立測試表：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -v ON_ERROR_STOP=1 \
  -c "CREATE TABLE vector_items (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, embedding vector(3)); INSERT INTO vector_items(embedding) VALUES ('[1,2,3]'), ('[4,5,6]');"
```

在 standby 查詢：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT id, embedding FROM vector_items ORDER BY embedding <-> '[3,1,2]' LIMIT 2;"
```

### 10.5 升級 extension

先確認 extension 提供從目前版本到目標版本的升級路徑。以下流程讓兩台執行中的 container 都載入目標 image，再修改 extension catalog。

查看目前版本：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT extversion FROM pg_extension WHERE extname = 'vector';"
```

先在 standby 修改 `.env` 的 `POSTGRES_IMAGE`，拉取目標 image 並重新建立 container：

```bash
docker compose --env-file .env pull postgres
docker compose --env-file .env up -d --force-recreate postgres
```

確認該節點仍為 standby，且 image 提供目標版本：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT pg_is_in_recovery(); SELECT name, default_version, installed_version FROM pg_available_extensions WHERE name = 'vector';"
```

依第 7 節執行計畫內切換，將已更新 image 的 standby 提升為 primary。接著在舊 primary 修改 `.env`，使用相同目標 image，並依第 8 節將它重建為 standby。

確認兩台執行中的 container 均提供目標版本後，只在目前 primary 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -v ON_ERROR_STOP=1 \
  -c "ALTER EXTENSION vector UPDATE;"
```

在 primary 與 standby 分別確認 `extversion`。應用程式使用多個資料庫時，每個已啟用 extension 的資料庫都需在 primary 執行 `ALTER EXTENSION ... UPDATE`。

### 10.6 extension 故障檢查

看到以下錯誤時，檢查兩台 image 與版本：

```text
extension "vector" is not available
could not access file "$libdir/vector"
undefined symbol
incompatible library
```

檢查命令：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT name, default_version, installed_version FROM pg_available_extensions WHERE name = 'vector';"

docker compose exec -T postgres \
  sh -lc 'ls -l /usr/share/postgresql/16/extension/vector* /usr/lib/postgresql/16/lib/vector*'
```

### 10.7 HNSW 建索引的 shared memory

大型 HNSW index build 可能使用較高的 `maintenance_work_mem`。Docker container 的 `/dev/shm` 需配合調整。在 Compose service 加入：

```yaml
shm_size: 1g
```

調整後重新建立容器：

```bash
docker compose up -d --force-recreate postgres
```

兩台節點使用相同 `shm_size` 與 PostgreSQL 設定。

## 11. 切回 host1

host1 已依第 8 節成為 standby 後，可執行一次計畫內切換：

1. 停止應用程式寫入。
2. 在 host2 記錄目標 LSN。
3. 等待 host1 重播至該 LSN。
4. 停止 host2 PostgreSQL。
5. promote host1。
6. 將應用程式端點改回 `192.168.50.11:5432`。
7. 在 host1 建立 `host2_slot`，再由 host1 重建 host2 standby。

promote host1：

```bash
cd /opt/postgresql
docker compose exec -T --user postgres postgres \
  pg_ctl -D /var/lib/postgresql/data promote -w
```

每次 promote 後，舊 primary 依第 8 節重建。slot 建立於當前 primary，slot 名稱對應接收 WAL 的 standby。

## 12. 使用 named volume 的替換方式

本文主流程使用 bind mount：

```yaml
- /srv/postgresql/data:/var/lib/postgresql/data
```

既有 Compose 使用 named volume 時，例如：

```yaml
volumes:
  - pgdata:/var/lib/postgresql/data

volumes:
  pgdata:
```

查看實際 volume 名稱：

```bash
docker compose config --volumes
docker volume ls
docker volume inspect PROJECT_pgdata
```

執行 `pg_basebackup` 時將 bind mount 改成 named volume：

```bash
docker run --rm \
  --network host \
  --user postgres \
  -e PGPASSFILE=/var/lib/postgresql/.pgpass \
  -v PROJECT_pgdata:/var/lib/postgresql/data \
  -v /opt/postgresql/.pgpass:/var/lib/postgresql/.pgpass:ro \
  postgres:16-bookworm \
  pg_basebackup \
    -h 192.168.50.11 \
    -p 5432 \
    -U replicator \
    -D /var/lib/postgresql/data \
    -Fp -Xs -P -R \
    -S host2_slot
```

重建 named volume 前先停止容器並保存舊 volume 名稱：

```bash
docker compose down
docker volume inspect PROJECT_pgdata
```

建立新的空 volume：

```bash
docker volume create PROJECT_pgdata_new
```

更新 Compose 使用新 volume，再執行 base backup。舊 volume 保留至重建驗收完成。

## 13. 備份與資料保留

串流複寫會同步 `DROP TABLE`、誤刪資料與錯誤更新。另行建立備份與 WAL 保存流程。

基本 logical backup：

```bash
docker compose exec -T postgres \
  pg_dumpall -U postgres \
  > pg_dumpall-$(date +%Y%m%d%H%M%S).sql
```

單一資料庫 custom-format backup：

```bash
docker compose exec -T postgres \
  pg_dump -U postgres -d appdb -Fc \
  > appdb-$(date +%Y%m%d%H%M%S).dump
```

extension 資料庫還原前，目標 PostgreSQL image 需包含相同 extension。`pg_restore` 執行 `CREATE EXTENSION` 時會讀取目標 image 內的 extension 檔案。

## 14. 停止、啟動與清理

停止容器並保留資料：

```bash
cd /opt/postgresql
docker compose down
```

重新啟動：

```bash
cd /opt/postgresql
docker compose --env-file .env up -d
```

查看日誌：

```bash
docker compose logs -f postgres
```

清除測試資料前先確認節點角色與資料路徑：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT pg_is_in_recovery();"

docker compose config
```

清除 bind mount 資料：

```bash
docker compose down
sudo find /srv/postgresql/data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
```

## 15. 最終驗收

在目前 primary 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT pg_is_in_recovery(); SELECT client_addr, state, sync_state, replay_lsn FROM pg_stat_replication; SELECT slot_name, active, restart_lsn FROM pg_replication_slots;"
```

在目前 standby 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres \
  -c "SELECT pg_is_in_recovery(); SELECT status, sender_host, slot_name, latest_end_lsn FROM pg_stat_wal_receiver;"
```

寫入驗收：

```bash
# 在 primary
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -v ON_ERROR_STOP=1 \
  -c "INSERT INTO ha_check(note) VALUES ('final-validation') RETURNING *;"

# 在 standby
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT * FROM ha_check ORDER BY id DESC LIMIT 5;"
```

若使用 pgvector，再執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d appdb \
  -c "SELECT extname, extversion FROM pg_extension WHERE extname = 'vector'; SELECT id, embedding FROM vector_items ORDER BY embedding <-> '[3,1,2]' LIMIT 2;"
```

驗收結果應包含一個 primary、一個 standby、`streaming` 狀態、active replication slot、primary 寫入可於 standby 查詢，以及兩台相同的 extension catalog 版本。
