# 將現有單實例 PostgreSQL 轉換為 Patroni HA 叢集

本文使用以下節點：

```text
db1      192.168.50.11  現有 PostgreSQL 資料
db2      192.168.50.12  新增 PostgreSQL replica
witness  192.168.50.13  第三個 etcd 成員
```

轉換後服務：

```text
db1      PostgreSQL + Patroni + etcd1 + HAProxy
db2      PostgreSQL + Patroni + etcd2 + HAProxy
witness  etcd3
```

PostgreSQL 大版本維持不變。以下命令以 PostgreSQL 16 為例。

舊 PostgreSQL 與新 Patroni 分別位於不同容器。切換時先停止舊容器，再由 Patroni 容器掛載同一個 PGDATA。

---

## 1. 記錄現有 PostgreSQL 狀態

在現有 PostgreSQL 執行：

```sql
SELECT version();
SHOW data_directory;
SHOW config_file;
SHOW hba_file;
SHOW port;
SHOW listen_addresses;
SHOW wal_level;
SHOW wal_log_hints;
SHOW max_wal_senders;
SHOW max_replication_slots;
SELECT pg_current_wal_lsn();
```

本文使用以下 PGDATA：

```text
/srv/postgres/data
```

保存容器設定與日誌：

```bash
sudo docker inspect standalone-postgres \
  > standalone-postgres.inspect.json

sudo docker logs --tail 200 standalone-postgres \
  > standalone-postgres.log

sudo du -sh /srv/postgres/data
```

`config_file` 或 `hba_file` 位於 PGDATA 外部時，在 Patroni Compose 掛載相同路徑。

---

## 2. 建立 Patroni 帳號

在現有 PostgreSQL 執行：

```sql
CREATE ROLE patroni_admin
  WITH LOGIN SUPERUSER
  PASSWORD 'CHANGE_ME_PATRONI_SUPERUSER_PASSWORD';

CREATE ROLE replicator
  WITH LOGIN REPLICATION
  PASSWORD 'CHANGE_ME_REPLICATION_PASSWORD';

CREATE ROLE rewind_user
  WITH LOGIN
  PASSWORD 'CHANGE_ME_REWIND_PASSWORD';

GRANT EXECUTE ON FUNCTION pg_catalog.pg_ls_dir(text, boolean, boolean)
  TO rewind_user;

GRANT EXECUTE ON FUNCTION pg_catalog.pg_stat_file(text, boolean)
  TO rewind_user;

GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(text)
  TO rewind_user;

GRANT EXECUTE ON FUNCTION pg_catalog.pg_read_binary_file(
  text,
  bigint,
  bigint,
  boolean
) TO rewind_user;
```

在 `pg_hba.conf` 加入：

```conf
host replication replicator 192.168.50.11/32 scram-sha-256
host replication replicator 192.168.50.12/32 scram-sha-256
host all patroni_admin 192.168.50.0/24 scram-sha-256
host all rewind_user 192.168.50.0/24 scram-sha-256
host all all 192.168.50.0/24 scram-sha-256
```

重新載入設定：

```sql
SELECT pg_reload_conf();
```

---

## 3. 設定 PostgreSQL 複寫參數

在現有 PostgreSQL 設定中加入：

```conf
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
wal_log_hints = on
hot_standby = on
wal_keep_size = '256MB'
```

重新啟動 PostgreSQL。

檢查參數：

```sql
SHOW wal_level;
SHOW wal_log_hints;
SHOW max_wal_senders;
SHOW max_replication_slots;
```

---

## 4. 建立三成員 etcd

etcd peer 位址：

```text
etcd1=http://192.168.50.11:2380
etcd2=http://192.168.50.12:2380
etcd3=http://192.168.50.13:2380
```

etcd client 位址：

```text
http://192.168.50.11:2379
http://192.168.50.12:2379
http://192.168.50.13:2379
```

三個成員使用相同值：

```text
ETCD_INITIAL_CLUSTER=etcd1=http://192.168.50.11:2380,etcd2=http://192.168.50.12:2380,etcd3=http://192.168.50.13:2380
ETCD_CLUSTER_TOKEN=CHANGE_ME_ETCD_CLUSTER_TOKEN
```

啟動三個 etcd 成員後執行：

```bash
etcdctl \
  --endpoints=http://192.168.50.11:2379,http://192.168.50.12:2379,http://192.168.50.13:2379 \
  endpoint health --cluster

etcdctl \
  --endpoints=http://192.168.50.11:2379 \
  member list -w table
```

三個 endpoint 顯示 `healthy` 後執行下一步。

---

## 5. 建立 Patroni 映像

在 db1 與 db2 建立相同檔案。

### `Dockerfile.patroni`

```dockerfile
FROM postgres:16-bookworm

ARG PATRONI_VERSION=4.1.4

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       python3-pip curl jq \
    && pip3 install --break-system-packages --no-cache-dir \
       "patroni[etcd3,psycopg2-binary]==${PATRONI_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

COPY patroni-entrypoint.sh /usr/local/bin/patroni-entrypoint
RUN chmod 0755 /usr/local/bin/patroni-entrypoint

ENTRYPOINT ["/usr/local/bin/patroni-entrypoint"]
CMD ["/etc/patroni.yml"]
```

### `patroni-entrypoint.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

install -d -o postgres -g postgres /var/run/postgresql
umask 077

exec gosu postgres patroni "$@"
```

檢查原 PGDATA 所有者：

```bash
sudo stat -c '%u:%g %a %n' /srv/postgres/data
sudo docker run --rm postgres:16-bookworm id postgres
```

兩個 UID/GID 一致後掛載 PGDATA。

---

## 6. 建立 db1 Patroni 設定

`db1/patroni.yml`：

```yaml
scope: production-pg
namespace: /service/
name: db1

restapi:
  listen: 0.0.0.0:8008
  connect_address: 192.168.50.11:8008

etcd3:
  hosts:
    - 192.168.50.11:2379
    - 192.168.50.12:2379
    - 192.168.50.13:2379

bootstrap:
  dcs:
    ttl: 12
    loop_wait: 2
    retry_timeout: 4
    maximum_lag_on_failover: 1048576
    synchronous_mode: true
    synchronous_mode_strict: false
    synchronous_node_count: 1
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        wal_level: replica
        wal_log_hints: "on"
        hot_standby: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 256MB

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 192.168.50.11:5432
  data_dir: /var/lib/postgresql/data
  bin_dir: /usr/lib/postgresql/16/bin
  authentication:
    superuser:
      username: patroni_admin
    replication:
      username: replicator
    rewind:
      username: rewind_user
```

`db1/compose.yml`：

```yaml
services:
  patroni:
    build:
      context: .
      dockerfile: Dockerfile.patroni
    image: local/patroni-postgres:16-4.1.4
    container_name: pgsql-ha-patroni
    restart: unless-stopped
    network_mode: host
    environment:
      PATRONI_SUPERUSER_PASSWORD: CHANGE_ME_PATRONI_SUPERUSER_PASSWORD
      PATRONI_REPLICATION_PASSWORD: CHANGE_ME_REPLICATION_PASSWORD
      PATRONI_REWIND_PASSWORD: CHANGE_ME_REWIND_PASSWORD
    volumes:
      - /srv/postgres/data:/var/lib/postgresql/data
      - ./patroni.yml:/etc/patroni.yml:ro
    command: ["/etc/patroni.yml"]
```

---

## 7. 建立 db2 Patroni 設定

複製 db1 設定，修改：

```yaml
name: db2

restapi:
  connect_address: 192.168.50.12:8008

postgresql:
  connect_address: 192.168.50.12:5432
```

建立空資料目錄：

```bash
sudo install -d -m 0700 -o 999 -g 999 \
  /srv/pgsql-ha/postgresql
```

`db2/compose.yml` 的資料掛載：

```yaml
volumes:
  - /srv/pgsql-ha/postgresql:/var/lib/postgresql/data
  - ./patroni.yml:/etc/patroni.yml:ro
```

---

## 8. 停止現有 PostgreSQL

停止應用寫入。

在 PostgreSQL 執行：

```sql
CHECKPOINT;
SELECT pg_switch_wal();
```

停止舊容器：

```bash
sudo docker update --restart=no standalone-postgres
sudo docker stop standalone-postgres
```

檢查程序與 PID 檔案：

```bash
sudo ss -lntp | grep ':5432 ' || true
sudo test ! -f /srv/postgres/data/postmaster.pid
```

建立停止狀態副本：

```bash
sudo rsync -aHAX --numeric-ids \
  /srv/postgres/data/ \
  /srv/postgres/pre-ha-cutover/
```

重新命名舊容器：

```bash
sudo docker rename \
  standalone-postgres \
  standalone-postgres-pre-ha
```

---

## 9. 啟動 db1 Patroni

```bash
cd /opt/pgsql-ha/db1
sudo docker compose build patroni
sudo docker compose up -d patroni
sudo docker logs -f pgsql-ha-patroni
```

檢查 Patroni：

```bash
curl -fsS http://192.168.50.11:8008/patroni | jq
curl -fsS http://192.168.50.11:8008/primary
```

檢查 PostgreSQL：

```sql
SELECT pg_is_in_recovery();
SELECT pg_current_wal_lsn();
SELECT datname FROM pg_database ORDER BY datname;
```

`pg_is_in_recovery()` 回傳 `false`。

---

## 10. 啟動 db2 Patroni

```bash
cd /opt/pgsql-ha/db2
sudo docker compose build patroni
sudo docker compose up -d patroni
sudo docker logs -f pgsql-ha-patroni
```

檢查角色：

```bash
curl -fsS http://192.168.50.11:8008/primary
curl -fsS http://192.168.50.12:8008/replica
```

在 db1 查詢複寫狀態：

```sql
SELECT application_name,
       client_addr,
       state,
       sync_state,
       write_lsn,
       flush_lsn,
       replay_lsn
FROM pg_stat_replication;
```

---

## 11. 啟動 HAProxy

兩台 HAProxy 使用相同設定：

```haproxy
listen postgres-write
  bind 0.0.0.0:5000
  option httpchk GET /primary
  http-check expect status 200
  default-server inter 1s fall 2 rise 2 on-marked-down shutdown-sessions
  server db1 192.168.50.11:5432 check port 8008
  server db2 192.168.50.12:5432 check port 8008
```

檢查兩個入口：

```bash
psql -h 192.168.50.11 -p 5000 -U app -d appdb \
  -Atc 'SELECT inet_server_addr(), NOT pg_is_in_recovery();'

psql -h 192.168.50.12 -p 5000 -U app -d appdb \
  -Atc 'SELECT inet_server_addr(), NOT pg_is_in_recovery();'
```

兩個查詢的第二欄回傳 `t`。

應用程式 DSN：

```text
host=192.168.50.11,192.168.50.12 port=5000,5000 dbname=appdb user=app target_session_attrs=read-write connect_timeout=3
```

恢復應用流量。

---

## 12. 驗證資料複寫

在 primary 執行：

```sql
CREATE TABLE IF NOT EXISTS ha_migration_probe (
  id bigserial PRIMARY KEY,
  marker text UNIQUE NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO ha_migration_probe(marker)
VALUES ('after-ha-cutover');
```

在 replica 執行：

```sql
SELECT marker, pg_is_in_recovery()
FROM ha_migration_probe
WHERE marker = 'after-ha-cutover';
```

回傳：

```text
after-ha-cutover|true
```

---

## 13. 執行故障切換

停止目前 primary 的 Patroni：

```bash
sudo docker stop pgsql-ha-patroni
```

檢查另一台：

```bash
curl -fsS http://192.168.50.12:8008/primary
```

寫入第二筆資料：

```sql
INSERT INTO ha_migration_probe(marker)
VALUES ('after-first-failover');
```

恢復舊節點：

```bash
sudo docker start pgsql-ha-patroni
```

檢查舊節點：

```bash
curl -fsS http://192.168.50.11:8008/replica
```

查詢兩筆資料：

```sql
SELECT marker
FROM ha_migration_probe
ORDER BY id;
```

---

## 14. 回退

應用流量尚未恢復時執行：

```bash
sudo docker stop pgsql-ha-patroni

sudo rsync -aHAX --delete --numeric-ids \
  /srv/postgres/pre-ha-cutover/ \
  /srv/postgres/data/

sudo docker rename \
  standalone-postgres-pre-ha \
  standalone-postgres

sudo docker update \
  --restart=unless-stopped \
  standalone-postgres

sudo docker start standalone-postgres
```

HA 已接收新寫入後，使用目前 Patroni primary 重建故障節點。

---

## 15. 完成檢查

```text
[ ] 三個 etcd endpoint 顯示 healthy
[ ] db1 使用原 PGDATA 啟動
[ ] db2 完成 base backup
[ ] Patroni 顯示一個 primary
[ ] Patroni 顯示一個 replica
[ ] pg_stat_replication 顯示 db2
[ ] 兩個 HAProxy 寫入口回傳可寫狀態
[ ] 應用程式使用 HA DSN
[ ] 故障切換完成
[ ] 舊 primary 回到 replica
[ ] 舊 PostgreSQL 容器保持停止
[ ] 切換前副本已保存
```
