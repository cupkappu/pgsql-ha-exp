# PostgreSQL 兩主機 HA 實驗

本倉庫包含三套 PostgreSQL 16 主備與高可用實驗、三種區域網路部署範本、兩套單機 Docker Compose 演示及一套分主機 Compose 範例。

## 狀態

| 實驗 | 元件 | 狀態 | 驗證命令 |
|---|---|---|---|
| Patroni | PostgreSQL、Patroni、三成員 etcd、HAProxy | 完成 | `make patroni-test` |
| Pacemaker | PostgreSQL、Corosync、Pacemaker、PAF、STONITH、VIP | 完成 | `make pcmk-test` |
| Manual | PostgreSQL streaming replication、手動 promote、pg_basebackup rejoin | 完成 | `make manual-test`、`make manual-demo-test` |

`make test-all` 執行三套驗證。

## 目錄

| 路徑 | 內容 |
|---|---|
| `topology.clab.yml` | Patroni 實驗拓撲 |
| `topology-pacemaker.clab.yml` | Pacemaker 實驗拓撲 |
| `topology-manual.clab.yml` | 雙機手動主備實驗拓撲 |
| `config/` | 實驗設定 |
| `images/` | 實驗映像 |
| `scripts/` | 建立、狀態、停止、清理及節點恢復 |
| `tests/` | smoke、程序故障、主機故障、witness、fencing 測試 |
| `deploy/lan/` | 三種區域網路部署範本 |
| `standalone-compose-example/` | 可分別複製到三台主機的 Patroni Compose 檔 |
| `demo/` | Patroni 單一 Docker daemon 演示環境 |
| `manual-demo/` | 雙節點手動切換 Compose 演示及繁體中文 README |
| `manual-postgresql-primary-standby.zh-Hant.md` | 兩台實機與 containerlab 手動切換指南 |

## Docker-only 演示

`demo/compose.yml` 在一個 Docker daemon 內啟動：

```text
etcd1 + etcd2 + etcd3
pg1 + pg2
HAProxy
Adminer
init
```

啟動：

```bash
make demo-up
```

入口與憑證：

| 項目 | 值 |
|---|---|
| Adminer | `http://127.0.0.1:18080` |
| PostgreSQL 寫入 | `127.0.0.1:15432` |
| PostgreSQL replica 讀取 | `127.0.0.1:15433` |
| pg1 Patroni REST | `http://127.0.0.1:18108/patroni` |
| pg2 Patroni REST | `http://127.0.0.1:18109/patroni` |
| System | `PostgreSQL` |
| Server | `haproxy:5000` |
| User | `app` |
| Password | `apppass` |
| Database | `appdb` |

`init` 建立 `app`、`appdb`、`ha_test`、`ha_test_summary`，並寫入 10 筆 `seed` 資料。

查看狀態：

```bash
make demo-status
```

故障前寫入：

```sql
INSERT INTO ha_test (phase, payload)
VALUES ('before-failover', 'before-' || gen_random_uuid())
RETURNING *;
```

停止 primary 並等待另一節點提升：

```bash
make demo-failover
```

故障後寫入與查詢：

```sql
INSERT INTO ha_test (phase, payload)
VALUES ('after-failover', 'after-' || gen_random_uuid())
RETURNING *;

SELECT * FROM ha_test ORDER BY id;
SELECT * FROM ha_test_summary ORDER BY first_write;
SELECT inet_server_addr(), pg_is_in_recovery(), now();
```

啟動兩個 PostgreSQL 節點：

```bash
make demo-rejoin
```

停止容器與刪除全部 demo volume：

```bash
make demo-down
make demo-clean
```

此環境演示容器程序故障轉移。全部容器共用同一 Docker host。

## 雙節點手動切換 Compose 演示

`manual-demo/compose.yml` 在單一 Docker daemon 內執行兩個 PostgreSQL 16 節點。首次啟動時，db1 為 primary，db2 透過 `pg_basebackup -R` 建立為 standby。

```text
db1  127.0.0.1:35432  primary
db2  127.0.0.1:45432  standby
```

啟動及驗收：

```bash
make manual-demo-up
make manual-demo-status
make manual-demo-smoke
make manual-demo-test
```

計畫內切換與舊節點重建：

```bash
make manual-demo-switch FROM=db1 TO=db2
make manual-demo-rejoin NODE=db1
```

primary 故障後提升 standby：

```bash
docker compose --env-file manual-demo/.env.example \
  -f manual-demo/compose.yml stop db1
make manual-demo-promote NODE=db2
make manual-demo-rejoin NODE=db1
```

停止與清理：

```bash
make manual-demo-down
make manual-demo-clean
```

完整操作流程、資料 volume、角色判斷、故障處理與一致性範圍位於 [`manual-demo/README.md`](manual-demo/README.md)。

## 實驗一：Patroni

### 拓撲

```text
Lima VM: fabric-clab
└── containerlab: pgsql-ha
    ├── host1 / 172.31.100.11 / 10.10.0.1
    │   ├── etcd1
    │   ├── PostgreSQL 16 + Patroni pg1
    │   └── HAProxy
    ├── host2 / 172.31.100.12 / 10.10.0.2
    │   ├── etcd2
    │   ├── PostgreSQL 16 + Patroni pg2
    │   └── HAProxy
    └── witness / 172.31.100.13
        └── etcd3
```

`host1` 與 `host2` 各自執行獨立 Docker daemon。`10.10.0.0/30` 傳輸 PostgreSQL 複寫、Patroni REST 與 HAProxy 後端流量。`172.31.100.0/24` 傳輸 etcd client 與 peer 流量。

三成員 etcd 的多數票為 2。資料庫主機失效後，存活資料庫主機與 witness 保留 2 票。witness 失效後，兩台資料庫主機保留 2 票。

### 入口

| 用途 | host1 | host2 |
|---|---:|---:|
| 寫入 | `127.0.0.1:15000` | `127.0.0.1:25000` |
| replica 讀取 | `127.0.0.1:15001` | `127.0.0.1:25001` |
| Patroni REST | `127.0.0.1:18008` | `127.0.0.1:28008` |

HAProxy 寫入端以 `/primary` 檢查後端；讀取端以 `/replica` 檢查後端。

### 命令

```bash
make patroni-up
make patroni-status
make patroni-smoke
make patroni-process-failover
make patroni-witness-failure
make patroni-host-failover
make patroni-test
make patroni-down
make patroni-clean
```

預設別名：

```text
up      -> patroni-up
status  -> patroni-status
smoke   -> patroni-smoke
test    -> patroni-test
down    -> patroni-down
clean   -> patroni-clean
```

### 驗證項目

| 命令 | 驗證項目 |
|---|---|
| `make patroni-smoke` | Docker daemon、etcd 多數票、主副角色、讀寫與複寫 |
| `make patroni-process-failover` | Patroni/PostgreSQL 程序停止、replica 提升、舊 primary 重新加入 |
| `make patroni-witness-failure` | etcd3 停止、etcd1+etcd2 多數票、持續寫入 |
| `make patroni-host-failover` | primary 主機停止、存活主機提升、舊主機重新加入 |

### 資料

```text
/var/lib/pgsql-ha-exp/lab
/var/lib/pgsql-ha-exp/host1-docker
/var/lib/pgsql-ha-exp/host2-docker
/var/lib/pgsql-ha-exp/witness-etcd
```

`make patroni-down` 保留資料。`make patroni-clean` 刪除以上目錄。

## 實驗二：Pacemaker

### 拓撲

```text
Lima VM: fabric-clab
└── containerlab: pgsql-pcmk
    ├── db1 / 172.31.110.11 / 10.20.0.1
    │   ├── PostgreSQL 16
    │   ├── Corosync
    │   ├── Pacemaker
    │   └── PAF pgsqlms
    └── db2 / 172.31.110.12 / 10.20.0.2
        ├── PostgreSQL 16
        ├── Corosync
        ├── Pacemaker
        └── PAF pgsqlms
```

| 資源 | 值 |
|---|---|
| Corosync | `two_node: 1`、`wait_for_all: 1` |
| STONITH | `fence_peer_docker` |
| PostgreSQL | promotable `pgsql-ha` resource |
| VIP | `172.31.110.100/24` |
| Client | `172.31.110.100:5432` |

`fence_peer_docker` 透過 Lima Docker daemon 停止目標節點。實體部署對應 IPMI、Redfish、PDU 或虛擬化平台 fence agent。

被 fence 的節點寫入 `rejoin-required`。`scripts/pcmk-rejoin.sh` 從 active primary 執行 `pg_basebackup`，再把節點加入為 standby。

### 命令

```bash
make pcmk-up
make pcmk-status
make pcmk-smoke
make pcmk-failover
make pcmk-test
make pcmk-down
make pcmk-clean
```

### 驗證項目

| 命令 | 驗證項目 |
|---|---|
| `make pcmk-smoke` | Corosync membership、primary/standby、VIP、雙向 fencing control、串流複寫 |
| `make pcmk-failover` | STONITH、standby 提升、VIP 轉移、故障後寫入、舊節點重新建立 |

### 資料

```text
/var/lib/pgsql-ha-exp-pcmk/lab
/var/lib/pgsql-ha-exp-pcmk/db1-postgresql
/var/lib/pgsql-ha-exp-pcmk/db2-postgresql
/var/lib/pgsql-ha-exp-pcmk/db1-pacemaker
/var/lib/pgsql-ha-exp-pcmk/db2-pacemaker
/var/lib/pgsql-ha-exp-pcmk/db1-corosync
/var/lib/pgsql-ha-exp-pcmk/db2-corosync
```

`make pcmk-down` 保留資料。`make pcmk-clean` 刪除以上目錄。

## 實驗三：雙機主備與手動切換

此方案只執行 PostgreSQL streaming replication。角色提升、應用程式端點切換及舊節點重建均由操作人員執行。

### containerlab 雙主機實驗

```text
Lima VM: fabric-clab
└── containerlab: pgsql-manual
    ├── db1 / 172.31.120.11 / client 127.0.0.1:35432
    └── db2 / 172.31.120.12 / client 127.0.0.1:45432
```

兩個節點各自執行獨立 Docker daemon。首次啟動建立 db1 primary 與 db2 standby。

```bash
make manual-up
make manual-status
make manual-smoke
make manual-switch FROM=db1 TO=db2
make manual-rejoin NODE=db1
make manual-failover
make manual-test
make manual-down
make manual-clean
```

`manual-switch` 先停止原 primary，再提升 standby。`manual-promote` 用於原 primary 主機已停止的故障情境。`manual-rejoin` 會清除指定節點的舊資料，並從目前 primary 執行 `pg_basebackup -R`。

### 單機 Docker Compose 演示

`manual-demo/compose.yml` 使用同一 Docker daemon 啟動 db1 與 db2，操作語義與雙主機實驗一致。

```bash
make manual-demo-lint
make manual-demo-up
make manual-demo-status
make manual-demo-smoke
make manual-demo-switch FROM=db1 TO=db2
make manual-demo-rejoin NODE=db1
make manual-demo-failover
make manual-demo-test
make manual-demo-down
make manual-demo-clean
```

Compose 演示使用以下 named volumes：

```text
pgsql-manual-demo-db1-data
pgsql-manual-demo-db2-data
```

完整流程位於 [`manual-demo/README.md`](manual-demo/README.md)。兩台獨立 Docker 主機的操作位於 [`manual-postgresql-primary-standby.zh-Hant.md`](manual-postgresql-primary-standby.zh-Hant.md)。

### 將現有 Docker Compose 單節點擴展為雙機手動主備

以下流程適用於這種現況：

```text
host1  192.168.50.11  已由 Docker Compose 執行 PostgreSQL 16，保存現有資料
host2  192.168.50.12  已安裝 Docker Compose，準備建立 standby
```

完成後的角色：

```text
正常狀態    host1 primary  running    host2 standby  running    app -> host1
故障切換後  host1 stopped  or fenced  host2 primary  running    app -> host2
重新加入後  host1 standby  running    host2 primary  running    app -> host2
```

範例假設 Compose service 名稱為 `postgres`，PostgreSQL superuser 為 `postgres`，兩台主機使用相同的 PostgreSQL major version、extension 套件及 Compose volume 掛載方式。請將 IP、service 名稱、資料庫名稱與密碼替換為實際值。

#### 1. 記錄現有節點

在 host1：

```bash
cd /opt/your-postgres-stack

docker compose ps
docker compose config
docker compose exec -T postgres \
  psql -U postgres -d postgres -c 'SELECT version();'
docker compose exec -T postgres \
  psql -U postgres -d postgres -c 'SHOW data_directory;'
docker compose exec -T postgres \
  psql -U postgres -d postgres -c 'SHOW config_file;'
docker compose exec -T postgres \
  psql -U postgres -d postgres -c 'SHOW hba_file;'

docker inspect "$(docker compose ps -q postgres)" \
  --format '{{range .Mounts}}{{println .Type .Source "->" .Destination}}{{end}}'
```

執行一次可恢復的 PostgreSQL 備份，並記錄目前 image tag、Compose 檔、環境檔及 volume 位置。物理複寫不取代備份。

#### 2. 讓 host1 接受複寫連線

現有 Compose service 需要把 PostgreSQL port 發布到區域網路。保留原有 image、environment 與 volume，只加入或確認以下設定：

```yaml
services:
  postgres:
    ports:
      - "192.168.50.11:5432:5432"
```

在 host1 設定 PostgreSQL：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres <<'SQL'
ALTER SYSTEM SET listen_addresses = '*';
ALTER SYSTEM SET wal_level = 'replica';
ALTER SYSTEM SET max_wal_senders = '10';
ALTER SYSTEM SET max_replication_slots = '10';
ALTER SYSTEM SET wal_keep_size = '512MB';
ALTER SYSTEM SET hot_standby = 'on';
SQL
```

建立複寫帳戶：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres <<'SQL'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
    CREATE ROLE replicator LOGIN REPLICATION;
  END IF;
END
$$;
ALTER ROLE replicator PASSWORD 'CHANGE_ME_REPLICATION_PASSWORD';
SQL
```

將 host2 加入 host1 的 `pg_hba.conf`：

```bash
docker compose exec -T postgres bash -ceu '
  superuser="${POSTGRES_USER:-postgres}"
  hba="$(psql -U "$superuser" -d postgres -Atc "SHOW hba_file")"
  grep -q "manual standby host2" "$hba" || cat >> "$hba" <<"HBA"
# manual standby host2
host replication replicator 192.168.50.12/32 scram-sha-256
HBA
'
```

重新啟動 PostgreSQL，使 `listen_addresses`、WAL 與 slot 設定生效：

```bash
docker compose up -d postgres
docker compose restart postgres

docker compose exec -T postgres \
  psql -U postgres -d postgres -c \
  "SELECT name, setting, source, sourcefile
     FROM pg_settings
    WHERE name IN
   ('listen_addresses','wal_level','max_wal_senders','max_replication_slots','wal_keep_size','hot_standby');"
```

若 `source` 顯示 `command line`，Compose 的 `command:` 或 entrypoint 參數正在覆蓋 `ALTER SYSTEM`。請在兩台主機的 Compose 檔同步修改該參數，再執行 `docker compose up -d postgres`。

將 host1 的 5432/TCP 來源限制為 host2。Docker published port 可能繞過一般 UFW INPUT 規則；來源限制應配置在上游防火牆、Docker `DOCKER-USER` chain 或等效 nftables forwarding chain。`pg_hba.conf` 同時限制 replication user 的來源位址。

從 host2 確認網路可達：

```bash
nc -vz 192.168.50.11 5432
```

#### 3. 準備 host2 Compose

將 host1 的 PostgreSQL service 定義複製到 host2。兩邊使用相同 image major version、`PGDATA`、volume destination、啟動參數及 extension 套件。host2 可以使用不同的 host bind-mount source。

範例：

```yaml
services:
  postgres:
    image: postgres:16-bookworm
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      PGDATA: /var/lib/postgresql/data/pgdata
    ports:
      - "192.168.50.12:5432:5432"
    volumes:
      - /srv/postgresql/data:/var/lib/postgresql/data
```

`POSTGRES_DB`、`POSTGRES_PASSWORD` 與 `/docker-entrypoint-initdb.d` 只在空資料目錄初始化時執行。host2 將接收 host1 的完整物理副本，現有資料庫、角色與 schema 會一併複製。

在 host2 停止 PostgreSQL：

```bash
cd /opt/your-postgres-stack
docker compose stop postgres
```

host2 的目標 volume 若包含其他 PostgreSQL 資料，先備份或改用新的 volume。下一步會清除目標 `PGDATA`。

#### 4. 從 host1 建立 host2 standby

若先前執行過同名 slot 的失敗操作，在 host1 檢查 slot：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres -c \
  "SELECT slot_name, slot_type, active, restart_lsn FROM pg_replication_slots;"
```

確認 `host2_slot` 沒有被任何 standby 使用後，清除該 inactive slot：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres -c \
  "SELECT pg_drop_replication_slot(slot_name)
     FROM pg_replication_slots
    WHERE slot_name = 'host2_slot' AND active = false;"
```

在 host2 執行：

```bash
export REPLICATION_PASSWORD='CHANGE_ME_REPLICATION_PASSWORD'

docker compose run --rm --no-deps \
  -e PGPASSWORD="$REPLICATION_PASSWORD" \
  --entrypoint bash postgres -ceu '
    data="${PGDATA:-/var/lib/postgresql/data}"
    install -d -o postgres -g postgres -m 0700 "$data"
    find "$data" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    chown postgres:postgres "$data"
    chmod 0700 "$data"

    exec gosu postgres pg_basebackup \
      -d "host=192.168.50.11 port=5432 user=replicator password=$PGPASSWORD application_name=host2" \
      -D "$data" \
      -Fp -Xs -P -R \
      -C -S host2_slot
  '
```

`-R` 建立 `standby.signal` 並寫入 `primary_conninfo`。`-C -S host2_slot` 在 host1 建立 physical replication slot。範例會把複寫密碼寫入 host2 的 `postgresql.auto.conf`；實際部署可改用受限權限的 passfile 或 secret 掛載。

啟動 host2：

```bash
docker compose up -d postgres

docker compose exec -T postgres \
  psql -U postgres -d postgres -c \
  'SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();'
```

預期 `pg_is_in_recovery()` 為 `true`。

在 host1 檢查複寫：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres -c \
  "SELECT application_name, client_addr, state, sync_state,
          pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::bigint AS lag_bytes
     FROM pg_stat_replication;"
```

預期看到 `application_name=host2`、`state=streaming`。

#### 5. 驗證現有資料會到達 host2

在 host1 的 `postgres` database 建立測試資料：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres <<'SQL'
CREATE TABLE IF NOT EXISTS manual_ha_probe (
  id bigserial PRIMARY KEY,
  payload text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO manual_ha_probe (payload)
VALUES ('before-first-switch-' || clock_timestamp());
SQL
```

在 host2 查詢：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres -c \
  'SELECT * FROM manual_ha_probe ORDER BY id DESC LIMIT 5;'
```

#### 6. 計畫內從 host1 切到 host2

先停止應用程式寫入。若應用程式也由 Compose 管理：

```bash
docker compose stop app
```

在 host1 取得切換 LSN：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres -c 'CHECKPOINT;'

TARGET_LSN="$(docker compose exec -T postgres \
  psql -U postgres -d postgres -Atc 'SELECT pg_switch_wal()')"

printf 'target LSN: %s\n' "$TARGET_LSN"
```

在 host2 等待 replay 到該 LSN：

```bash
until [[ "$(docker compose exec -T postgres \
  psql -U postgres -d postgres -Atc \
  "SELECT COALESCE(pg_last_wal_replay_lsn() >= '${TARGET_LSN}'::pg_lsn, false)")" == t ]]; do
  sleep 1
done
```

在 host1 停止 PostgreSQL：

```bash
docker compose stop postgres
```

在 host2 提升：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres -c \
  'SELECT pg_promote(true, 60);'

docker compose exec -T postgres \
  psql -U postgres -d postgres -c \
  'SELECT pg_is_in_recovery();'
```

預期 `pg_is_in_recovery()` 為 `false`。將應用程式的 `DB_HOST`、DNS 或連線設定改為 `192.168.50.12`，再啟動應用程式。

#### 7. host1 故障時手動提升 host2

先確認 host1 已關機、PostgreSQL container 已停止，或 host1 已被網路與電源隔離。確認完成後，在 host2 執行：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres -c \
  'SELECT pg_promote(true, 60);'
```

將應用程式端點改為 `192.168.50.12`。非同步複寫下，host1 突然失效前尚未送達 host2 的交易可能缺失。

舊 host1 恢復時，先保持資料庫服務對應用程式網路不可達。不要直接使用舊資料啟動 PostgreSQL。

#### 8. 將舊 host1 重建為 host2 的 standby

在 host2 的 `pg_hba.conf` 允許 host1 連入。host2 的資料來自 host1 的 physical backup，通常已包含原有規則；仍需檢查：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres -c 'SHOW hba_file;'

docker compose exec -T postgres bash -ceu '
  superuser="${POSTGRES_USER:-postgres}"
  hba="$(psql -U "$superuser" -d postgres -Atc "SHOW hba_file")"
  grep -q "manual standby host1" "$hba" || cat >> "$hba" <<"HBA"
# manual standby host1
host replication replicator 192.168.50.11/32 scram-sha-256
HBA
  psql -U "$superuser" -d postgres -c "SELECT pg_reload_conf()"
'
```

將 host2 的 5432/TCP 來源限制為 host1，使用與 host1 相同的 forwarding firewall 管理方式。

若 `host1_slot` 已存在，先在 host2 檢查其 `active` 狀態。確認 slot 為 inactive 且沒有 standby 使用後，再執行刪除：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres -c \
  "SELECT pg_drop_replication_slot(slot_name)
     FROM pg_replication_slots
    WHERE slot_name = 'host1_slot' AND active = false;"
```

在 host1 停止舊 container，並從 host2 重新建立資料：

```bash
docker compose stop postgres
export REPLICATION_PASSWORD='CHANGE_ME_REPLICATION_PASSWORD'

docker compose run --rm --no-deps \
  -e PGPASSWORD="$REPLICATION_PASSWORD" \
  --entrypoint bash postgres -ceu '
    data="${PGDATA:-/var/lib/postgresql/data}"
    install -d -o postgres -g postgres -m 0700 "$data"
    find "$data" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
    chown postgres:postgres "$data"
    chmod 0700 "$data"

    exec gosu postgres pg_basebackup \
      -d "host=192.168.50.12 port=5432 user=replicator password=$PGPASSWORD application_name=host1" \
      -D "$data" \
      -Fp -Xs -P -R \
      -C -S host1_slot
  '

docker compose up -d postgres
```

在 host1 確認 standby：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres -c \
  'SELECT pg_is_in_recovery(), pg_last_wal_replay_lsn();'
```

在 host2 確認 streaming：

```bash
docker compose exec -T postgres \
  psql -U postgres -d postgres -c \
  'SELECT application_name, client_addr, state, sync_state FROM pg_stat_replication;'
```

此時角色為 host2 primary、host1 standby。之後可以用相同的 LSN 等待、停止、promote 與 `pg_basebackup` 流程切回 host1。

#### 9. 操作限制

- 兩台主機不執行 leader election。應用程式端點由操作人員切換。
- 舊 primary 的停止或隔離狀態需要人工確認。舊 primary 重新上線前需要先重建為 standby。
- `restart: unless-stopped` 可能在主機重啟後啟動舊 primary。故障切換後，舊主機應在隔離狀態下完成 rejoin。
- physical replication 要求兩台 PostgreSQL major version 相同，host2 image 具備資料庫使用的 extension shared libraries。
- `config_file`、`hba_file` 或 tablespace 若位於 `PGDATA` 之外，需要在 host2 建立相同掛載與路徑。tablespace 需要配合 `pg_basebackup --tablespace-mapping`。
- replication slot 會保留 standby 尚未接收的 WAL。standby 長期離線時，需要檢查 `pg_replication_slots` 與磁碟使用量。
- Compose 環境變數不會修改既有資料目錄中的角色、密碼或資料庫。既有叢集的變更需要使用 SQL 或設定檔完成。

### 切換條件

計畫內切換會等待 standby replay 到指定 WAL LSN，再停止 primary 並提升 standby。故障提升要求原 primary 已停止。舊 primary 恢復後直接執行 rejoin，由新 primary 重建資料。

此方案使用非同步複寫。primary 突然失效時，尚未送達或尚未 replay 的交易可能遺失。雙節點環境沒有 quorum 與自動 fencing，操作人員需要確認舊 primary 已停止。

## 共用操作

```bash
make status-all
make test-all
make clean-all
make deploy-lint
```

## 區域網路部署

### 拓撲類型

範例資料庫位址：`db1=192.168.50.11`、`db2=192.168.50.12`。

| 類型 | etcd 位置 | 多數票結果 | 範本 |
|---|---|---|---|
| A | db1=etcd1、db2=etcd2、192.168.50.13=etcd3 | 任一資料庫主機失效後保留 2/3 | `deploy/lan/db1/`、`db2/`、`witness/` |
| B | db1=etcd1+etcd3、db2=etcd2 | db1 失效後剩 1/3；db2 失效後剩 2/3 | `deploy/lan/colocated-witness/` |
| C | db1/db2 無 etcd；外部 etcd1/2/3 | 結果由外部叢集成員與網路路徑決定 | `deploy/lan/external-etcd/` |

獨立檔案版本位於 `standalone-compose-example/`。

### 主機條件

- Ubuntu 24.04 LTS
- 固定 IP 與唯一 hostname
- NTP 同步
- Docker Engine 與 Compose plugin
- PostgreSQL 資料目錄使用持久化磁碟
- db1、db2 使用相同 PostgreSQL、Patroni 與設定版本

檢查主機：

```bash
hostnamectl
ip -brief address
timedatectl status
```

安裝 chrony：

```bash
sudo apt-get update
sudo apt-get install -y chrony curl ca-certificates
sudo systemctl enable --now chrony
chronyc tracking
```

安裝 Docker：

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
printf '%s\n' \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
```

### 連接埠

| Port | 來源 | 用途 |
|---:|---|---|
| 2379/TCP | Patroni、管理端 | etcd client |
| 2380/TCP | etcd 成員 | etcd peer |
| 2479/TCP | Patroni、管理端 | 類型 B etcd3 client |
| 2480/TCP | etcd 成員 | 類型 B etcd3 peer |
| 5432/TCP | db1、db2、管理端 | PostgreSQL 複寫與管理 |
| 8008/TCP | db1、db2 | Patroni REST 與 HAProxy check |
| 5000/TCP | 應用程式 | primary 寫入 |
| 5001/TCP | 應用程式 | replica 讀取 |

### 共用準備

每台主機使用相同倉庫路徑：

```bash
sudo mkdir -p /opt/pgsql-ha-exp
cd /opt/pgsql-ha-exp
```

`db1`：

```bash
cp deploy/lan/db1/.env.example deploy/lan/db1/.env
chmod 0600 deploy/lan/db1/.env
sudo install -d -m 0700 /srv/pgsql-ha/etcd1 /srv/pgsql-ha/postgresql
```

`db2`：

```bash
cp deploy/lan/db2/.env.example deploy/lan/db2/.env
chmod 0600 deploy/lan/db2/.env
sudo install -d -m 0700 /srv/pgsql-ha/etcd2 /srv/pgsql-ha/postgresql
```

兩份 `.env` 設定相同的 cluster token、initial cluster、PostgreSQL superuser 密碼與 replication 密碼。

實機 Patroni 時間參數：

```yaml
ttl: 30
loop_wait: 10
retry_timeout: 10
```

### 類型 A

`witness`：

```bash
cp deploy/lan/witness/.env.example deploy/lan/witness/.env
chmod 0600 deploy/lan/witness/.env
sudo install -d -m 0700 /srv/pgsql-ha/etcd3
```

三個節點使用同一 initial cluster：

```text
etcd1=http://192.168.50.11:2380,etcd2=http://192.168.50.12:2380,etcd3=http://192.168.50.13:2380
```

啟動 etcd：

```bash
# db1
sudo docker compose --env-file deploy/lan/db1/.env \
  -f deploy/lan/db1/compose.yml up -d etcd

# db2
sudo docker compose --env-file deploy/lan/db2/.env \
  -f deploy/lan/db2/compose.yml up -d etcd

# witness
sudo docker compose --env-file deploy/lan/witness/.env \
  -f deploy/lan/witness/compose.yml up -d etcd
```

檢查 etcd：

```bash
export ETCDCTL_ENDPOINTS='http://192.168.50.11:2379,http://192.168.50.12:2379,http://192.168.50.13:2379'
sudo docker run --rm --network host \
  gcr.io/etcd-development/etcd:v3.5.21 \
  etcdctl --endpoints="$ETCDCTL_ENDPOINTS" endpoint health --cluster
```

啟動 Patroni：

```bash
# db1
sudo docker compose --env-file deploy/lan/db1/.env \
  -f deploy/lan/db1/compose.yml build patroni
sudo docker compose --env-file deploy/lan/db1/.env \
  -f deploy/lan/db1/compose.yml up -d patroni

# db2
sudo docker compose --env-file deploy/lan/db2/.env \
  -f deploy/lan/db2/compose.yml build patroni
sudo docker compose --env-file deploy/lan/db2/.env \
  -f deploy/lan/db2/compose.yml up -d patroni
```

啟動 HAProxy：

```bash
sudo docker compose --env-file deploy/lan/db1/.env \
  -f deploy/lan/db1/compose.yml up -d haproxy
sudo docker compose --env-file deploy/lan/db2/.env \
  -f deploy/lan/db2/compose.yml up -d haproxy
```

### 類型 B

設定三個 etcd peer：

```text
etcd1=http://192.168.50.11:2380,etcd2=http://192.168.50.12:2380,etcd3=http://192.168.50.11:2480
```

兩份 Patroni 設定的第三個 client endpoint：

```text
192.168.50.11:2479
```

在 db1 啟動 etcd3：

```bash
cp deploy/lan/colocated-witness/.env.example \
  deploy/lan/colocated-witness/.env
sudo install -d -m 0700 /srv/pgsql-ha/etcd3
sudo docker compose --env-file deploy/lan/colocated-witness/.env \
  -f deploy/lan/colocated-witness/compose.yml up -d etcd3
```

首次建立時寫入以上 peer 清單。既有叢集透過 `etcdctl member add` 與 `member remove` 修改成員。

### 類型 C

外部 etcd 範例：

```text
192.168.50.21:2379
192.168.50.22:2379
192.168.50.23:2379
```

環境檔：

```bash
cp deploy/lan/external-etcd/.env.db1.example \
  deploy/lan/external-etcd/.env.db1
cp deploy/lan/external-etcd/.env.db2.example \
  deploy/lan/external-etcd/.env.db2
chmod 0600 deploy/lan/external-etcd/.env.db1 \
  deploy/lan/external-etcd/.env.db2
```

TLS 設定：

```yaml
etcd3:
  hosts:
    - etcd-ext-1.internal.example:2379
    - etcd-ext-2.internal.example:2379
    - etcd-ext-3.internal.example:2379
  protocol: https
  cacert: /etc/etcd/pki/ca.crt
  cert: /etc/etcd/pki/patroni.crt
  key: /etc/etcd/pki/patroni.key
```

啟動：

```bash
# db1
sudo docker compose --env-file deploy/lan/external-etcd/.env.db1 \
  -f deploy/lan/external-etcd/db1.compose.yml up -d --build patroni haproxy

# db2
sudo docker compose --env-file deploy/lan/external-etcd/.env.db2 \
  -f deploy/lan/external-etcd/db2.compose.yml up -d --build patroni haproxy
```

外部 etcd 管理項目：成員、quorum、延遲、容量、憑證、帳號、升級、備份、恢復。

### 驗證

Patroni：

```bash
curl -fsS http://192.168.50.11:8008/patroni
curl -fsS http://192.168.50.12:8008/patroni
```

寫入入口：

```bash
export PGPASSWORD='APP_PASSWORD'
psql -h 192.168.50.11 -p 5000 -U app -d appdb \
  -Atc 'SELECT NOT pg_is_in_recovery();'
psql -h 192.168.50.12 -p 5000 -U app -d appdb \
  -Atc 'SELECT NOT pg_is_in_recovery();'
```

兩個查詢回傳 `t`。

複寫：

```bash
psql -h 192.168.50.11 -p 5000 -U app -d appdb -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS ha_probe (
  id bigserial PRIMARY KEY,
  marker text UNIQUE NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO ha_probe(marker) VALUES ('lan-deployment-probe');
SQL

psql -h 192.168.50.12 -p 5001 -U app -d appdb \
  -Atc "SELECT marker FROM ha_probe WHERE marker='lan-deployment-probe';"
unset PGPASSWORD
```

### 應用程式連線

支援 libpq 多主機語法的寫入 DSN：

```text
host=192.168.50.11,192.168.50.12 port=5000,5000 dbname=appdb user=app target_session_attrs=read-write connect_timeout=3
```

`:5000` 路由 primary。`:5001` 路由 replica。範本未配置 VIP。

### 故障結果

| 事件 | 類型 A | 類型 B | 類型 C |
|---|---|---|---|
| db1 停止 | db2+witness 保留 2/3 | db2 保留 1/3，停止新選舉 | 由外部 etcd 決定 |
| db2 停止 | db1+witness 保留 2/3 | db1 保留 2/3 | 由外部 etcd 決定 |
| witness 停止 | db1+db2 保留 2/3 | 與 db1 同一故障域 | 由外部 etcd 管理 |
| etcd 失去 quorum | Patroni 停止新選舉；primary 依 TTL 狀態處理 | 相同 | 相同 |
| HAProxy 主機停止 | 該入口停止；另一入口持續服務 | 相同 | 相同 |

### 已配置與未配置項目

| 項目 | 狀態 |
|---|---|
| PostgreSQL 串流複寫 | 已配置 |
| Patroni DCS | 已配置 |
| HAProxy 讀寫路由 | 已配置 |
| etcd TLS | 外部 etcd 範例已列參數；自建範本未配置 |
| PostgreSQL TLS | 未配置 |
| Patroni REST TLS | 未配置 |
| WAL archive / PITR | 未配置 |
| 監控與告警 | 未配置 |
| VIP / Keepalived | 未配置 |
| 跨站點複寫 | 未配置 |
| 帶外 fencing | Patroni 範本未配置；Pacemaker 實驗使用 Docker fencing |

RPO 由同步副本狀態、交易確認時點、WAL 傳輸與故障事件決定。RTO 由 TTL、故障偵測、複寫延遲與節點重建時間決定。

### 資料刪除

```bash
sudo rm -rf /srv/pgsql-ha/postgresql
sudo rm -rf /srv/pgsql-ha/etcd1
sudo rm -rf /srv/pgsql-ha/etcd2
sudo rm -rf /srv/pgsql-ha/etcd3
```

以上命令永久刪除對應資料目錄。

## 實驗憑證

```text
PostgreSQL superuser: postgres / postgres
Application user: app / apppass
Replication user: replicator / replicator
Database: appdb
```

`deploy/lan/` 與 `standalone-compose-example/` 使用 `CHANGE_ME_...`。
