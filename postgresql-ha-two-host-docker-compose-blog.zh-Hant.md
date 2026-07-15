# 用兩台獨立 Docker 資料庫主機部署 PostgreSQL HA：Patroni、etcd witness 與 HAProxy 實作

PostgreSQL 本身有成熟的串流複寫，但「有一台備援資料庫」不等於「已經具備高可用」。真正的高可用至少還要回答幾個問題：目前哪一台可以寫入？主庫失效後由誰決定提升副本？舊主庫恢復時如何避免雙主？應用程式又該連到哪裡？

這篇文章會從空白環境開始，在兩台彼此獨立的 Ubuntu 主機上，以 Docker Compose 部署 PostgreSQL 16、Patroni、etcd 與 HAProxy。兩台資料庫主機各自有自己的 Docker daemon、資料目錄與 Compose 專案；它們不共享 Docker network，也不共享 volume。

為了讓任一資料庫主機完全失效後仍能安全選主，我們會再放置一個很輕量的 etcd witness。它不執行 PostgreSQL，也不承載應用流量，只提供第三張仲裁票。這仍然是「兩台資料庫伺服器」架構，而不是三副本 PostgreSQL。

> 本文的設定適合區域網路實驗、homelab 與內部服務的起點。正式環境還需要 TLS、祕密管理、備份、監控、容量規劃及帶外 fencing。不要直接把文中的明文網路設定暴露到網際網路。

---

## 1. 最終架構

本文使用以下位址：

| 節點 | IP | 服務 |
|---|---:|---|
| `db1` | `192.168.50.11` | PostgreSQL、Patroni、etcd1、HAProxy |
| `db2` | `192.168.50.12` | PostgreSQL、Patroni、etcd2、HAProxy |
| `witness` | `192.168.50.13` | etcd3 |

拓撲如下：

```text
                         application
                              │
                 ┌────────────┴────────────┐
                 │                         │
        db1:5000 / 5001           db2:5000 / 5001
              HAProxy                   HAProxy
                 │                         │
                 └────── PostgreSQL ───────┘
                        streaming replication

       db1                         db2                     witness
┌─────────────────┐       ┌─────────────────┐       ┌─────────────────┐
│ Docker Engine   │       │ Docker Engine   │       │ Docker Engine   │
│                 │       │                 │       │                 │
│ etcd1           │◀─────▶│ etcd2           │◀─────▶│ etcd3           │
│ Patroni + PG16  │       │ Patroni + PG16  │       │                 │
│ HAProxy         │       │ HAProxy         │       │                 │
└─────────────────┘       └─────────────────┘       └─────────────────┘
```

etcd 三成員叢集的多數票是 2。這讓它可以容忍任意一個 etcd 成員失效：

- `db1` 整台失效時，`etcd2 + etcd3` 仍有兩票；
- `db2` 整台失效時，`etcd1 + etcd3` 仍有兩票；
- witness 失效時，`etcd1 + etcd2` 仍有兩票。

不要把 etcd 改成只有兩個成員。兩成員 etcd 的多數票也是 2，容錯數是 0；任一資料庫主機失效後都無法進行新的安全選主。

---

## 2. 每個元件負責什麼

### PostgreSQL

負責真正的資料儲存與串流複寫。平常是一台 primary、一台 replica。

### Patroni

Patroni 管理 PostgreSQL 的生命週期與角色。它會：

- 在 etcd 中維護 leader lock；
- 初始化第一台 PostgreSQL；
- 讓第二台透過 `pg_basebackup` 成為 replica；
- 在 primary 失效時判斷 replica 是否可提升；
- 在舊 primary 回來後，透過 `pg_rewind` 或重新初始化讓它回到正確 timeline。

### etcd

etcd 是 Patroni 的分散式協調儲存。它不保存資料表內容，只保存叢集角色、leader lock、動態設定與同步副本狀態。

### HAProxy

每台資料庫主機都執行一個 HAProxy：

- `5000/TCP` 只轉送到 Patroni 判定的 primary；
- `5001/TCP` 只轉送到 Patroni 判定的 replica。

HAProxy 不是靠猜測 PostgreSQL 狀態，而是查詢 Patroni REST API：

- `/primary` 只有真正持有 leader lock 的 primary 才回傳 HTTP 200；
- `/replica` 只有健康且可負載均衡的 replica 才回傳 HTTP 200。

---

## 3. 版本與前提

本文示範以下版本組合：

```text
Ubuntu 24.04 LTS
PostgreSQL 16
Patroni 4.1.4
etcd 3.5.21
HAProxy 3.0
Docker Engine + Docker Compose plugin
```

這些是固定範例版本，不代表永遠應使用這些版本。升級 PostgreSQL、Patroni 或 etcd 前，應先在測試環境跑過故障轉移、回復與備份還原。

三台主機都應具備：

- 固定 IP；
- 唯一 hostname；
- 穩定且互通的區域網路；
- 同步的系統時間；
- 持久化磁碟；
- `sudo` 權限。

先檢查主機狀態：

```bash
hostnamectl
ip -brief address
timedatectl status
```

安裝時間同步：

```bash
sudo apt-get update
sudo apt-get install -y chrony curl ca-certificates
sudo systemctl enable --now chrony
chronyc tracking
```

---

## 4. 安裝 Docker Engine 與 Compose plugin

在 `db1`、`db2` 與 witness 上執行：

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

printf '%s\n' \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

sudo apt-get update
sudo apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin

sudo systemctl enable --now docker
sudo docker version
sudo docker compose version
```

本文所有命令都使用 `sudo docker`，不要求把管理帳號加入 `docker` 群組。

---

## 5. 網路與防火牆

本文使用 host network。容器直接監聽宿主機連接埠，因此設定簡單，但防火牆不能偷懶。

| Port | 來源 | 用途 |
|---:|---|---|
| 2379/TCP | Patroni 節點、管理主機 | etcd client API |
| 2380/TCP | 三個 etcd 成員 | etcd peer traffic |
| 5432/TCP | db1、db2、管理主機 | PostgreSQL 複寫與管理 |
| 8008/TCP | db1、db2、受控管理主機 | Patroni REST API |
| 5000/TCP | 應用程式網段 | 可寫 PostgreSQL 入口 |
| 5001/TCP | 可接受 replica 延遲的應用程式 | 唯讀入口 |

假設整個受控網段是 `192.168.50.0/24`，UFW 可以先這樣設定：

```bash
sudo ufw allow from 192.168.50.0/24 to any port 2379 proto tcp
sudo ufw allow from 192.168.50.0/24 to any port 2380 proto tcp
sudo ufw allow from 192.168.50.0/24 to any port 5432 proto tcp
sudo ufw allow from 192.168.50.0/24 to any port 8008 proto tcp
sudo ufw allow from 192.168.50.0/24 to any port 5000 proto tcp
sudo ufw allow from 192.168.50.0/24 to any port 5001 proto tcp
```

啟用 UFW 前，先確認 SSH 管理連線已有允許規則。正式環境應把應用網段、管理網段與 etcd peer 網段分開，不要直接允許整個 LAN。

還要確認宿主機沒有其他 PostgreSQL、etcd 或 HAProxy 佔用這些 port：

```bash
sudo ss -lntp | grep -E ':(2379|2380|5432|8008|5000|5001)\b' || true
```

---

## 6. 建立目錄

### db1 與 db2

兩台資料庫主機都建立相同的設定目錄：

```bash
sudo install -d -m 0755 /opt/pgsql-ha
sudo install -d -m 0700 /srv/pgsql-ha/postgresql
```

在 db1 建立 etcd1 資料目錄：

```bash
sudo install -d -m 0700 /srv/pgsql-ha/etcd1
```

在 db2 建立 etcd2 資料目錄：

```bash
sudo install -d -m 0700 /srv/pgsql-ha/etcd2
```

### witness

```bash
sudo install -d -m 0755 /opt/pgsql-ha
sudo install -d -m 0700 /srv/pgsql-ha/etcd3
```

完成後，兩台資料庫主機的 `/opt/pgsql-ha` 會有：

```text
/opt/pgsql-ha/
├── .env
├── compose.yml
├── Dockerfile.patroni
├── patroni-entrypoint.sh
├── patroni.yml
└── haproxy.cfg
```

witness 只需要：

```text
/opt/pgsql-ha/
├── .env
└── compose.yml
```

---

## 7. 在 db1 與 db2 建立 Patroni 映像

以下三個檔案在 db1 與 db2 完全相同。

### `/opt/pgsql-ha/Dockerfile.patroni`

```dockerfile
FROM postgres:16-bookworm

ARG PATRONI_VERSION=4.1.4

RUN apt-get update \
    && apt-get install -y --no-install-recommends python3-pip curl jq \
    && pip3 install --break-system-packages --no-cache-dir \
       "patroni[etcd3,psycopg2-binary]==${PATRONI_VERSION}" \
    && rm -rf /var/lib/apt/lists/*

COPY patroni-entrypoint.sh /usr/local/bin/patroni-entrypoint
RUN chmod 0755 /usr/local/bin/patroni-entrypoint

ENTRYPOINT ["/usr/local/bin/patroni-entrypoint"]
CMD ["/etc/patroni.yml"]
```

### `/opt/pgsql-ha/patroni-entrypoint.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

install -d -o postgres -g postgres -m 0700 \
  /var/lib/postgresql/data/pgdata
install -d -o postgres -g postgres /var/run/postgresql

chown -R postgres:postgres \
  /var/lib/postgresql/data \
  /var/run/postgresql
chmod 0700 /var/lib/postgresql/data/pgdata
umask 077

exec gosu postgres patroni "$@"
```

設定權限：

```bash
sudo chmod 0755 /opt/pgsql-ha/patroni-entrypoint.sh
```

這裡刻意把 PGDATA 放在 bind mount 內的 `pgdata` 子目錄，而不是直接使用 volume 根目錄。PostgreSQL 對資料目錄權限很嚴格，子目錄比較容易穩定維持 `0700`。

---

## 8. 兩台資料庫主機共用的 Compose 設定

db1 與 db2 使用相同的 Compose 檔案，節點差異由 `.env` 與 `patroni.yml` 提供。

### `/opt/pgsql-ha/compose.yml`

```yaml
name: pgsql-ha

services:
  etcd:
    container_name: pgsql-ha-etcd
    image: gcr.io/etcd-development/etcd:v3.5.21
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${ETCD_DATA_DIR:?set ETCD_DATA_DIR}:/etcd-data
    command:
      - /usr/local/bin/etcd
      - --name=${ETCD_NAME:?set ETCD_NAME}
      - --data-dir=/etcd-data
      - --listen-client-urls=http://0.0.0.0:2379
      - --advertise-client-urls=http://${NODE_IP:?set NODE_IP}:2379
      - --listen-peer-urls=http://0.0.0.0:2380
      - --initial-advertise-peer-urls=http://${NODE_IP}:2380
      - --initial-cluster=${ETCD_INITIAL_CLUSTER:?set ETCD_INITIAL_CLUSTER}
      - --initial-cluster-state=new
      - --initial-cluster-token=${ETCD_CLUSTER_TOKEN:?set ETCD_CLUSTER_TOKEN}
      - --auto-compaction-retention=1
      - --auto-compaction-mode=periodic

  patroni:
    container_name: pgsql-ha-patroni
    build:
      context: .
      dockerfile: Dockerfile.patroni
    image: local/patroni-postgres:16-4.1.4
    restart: unless-stopped
    network_mode: host
    environment:
      PATRONI_SUPERUSER_PASSWORD: ${POSTGRES_SUPERUSER_PASSWORD:?set POSTGRES_SUPERUSER_PASSWORD}
      PATRONI_REPLICATION_PASSWORD: ${POSTGRES_REPLICATION_PASSWORD:?set POSTGRES_REPLICATION_PASSWORD}
    volumes:
      - ${PGDATA_DIR:?set PGDATA_DIR}:/var/lib/postgresql/data
      - ./patroni.yml:/etc/patroni.yml:ro
    command: ["/etc/patroni.yml"]

  haproxy:
    container_name: pgsql-ha-haproxy
    image: haproxy:3.0-alpine
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
```

先不要啟動服務。後面會按 etcd、Patroni、HAProxy 的順序啟動。

---

## 9. HAProxy 設定

這個檔案在 db1 與 db2 完全相同。

### `/opt/pgsql-ha/haproxy.cfg`

```haproxy
global
  log stdout format raw local0
  maxconn 1024

defaults
  log global
  mode tcp
  option tcplog
  timeout connect 3s
  timeout client 30s
  timeout server 30s
  timeout check 2s

listen postgres-write
  bind 0.0.0.0:5000
  option httpchk GET /primary
  http-check expect status 200
  default-server inter 1s fall 2 rise 2 on-marked-down shutdown-sessions
  server pg1 192.168.50.11:5432 check port 8008
  server pg2 192.168.50.12:5432 check port 8008

listen postgres-read
  bind 0.0.0.0:5001
  balance roundrobin
  option httpchk GET /replica
  http-check expect status 200
  default-server inter 1s fall 2 rise 2
  server pg1 192.168.50.11:5432 check port 8008
  server pg2 192.168.50.12:5432 check port 8008
```

`postgres-write` 的健康檢查指向 Patroni `/primary`；所以兩台 HAProxy 雖然都列出 pg1 與 pg2，實際上同一時間只會把新連線送到目前 primary。

`on-marked-down shutdown-sessions` 會在後端失去 primary 身分時關閉既有連線。這通常比讓舊連線繼續黏在失效節點安全，但應用程式必須具備重新連線與交易重試能力。

---

## 10. db1 設定

### `/opt/pgsql-ha/.env`

```dotenv
NODE_IP=192.168.50.11
ETCD_NAME=etcd1
ETCD_DATA_DIR=/srv/pgsql-ha/etcd1
PGDATA_DIR=/srv/pgsql-ha/postgresql
ETCD_CLUSTER_TOKEN=CHANGE_ME_ETCD_CLUSTER_TOKEN
ETCD_INITIAL_CLUSTER=etcd1=http://192.168.50.11:2380,etcd2=http://192.168.50.12:2380,etcd3=http://192.168.50.13:2380
POSTGRES_SUPERUSER_PASSWORD=CHANGE_ME_POSTGRES_SUPERUSER_PASSWORD
POSTGRES_REPLICATION_PASSWORD=CHANGE_ME_POSTGRES_REPLICATION_PASSWORD
APP_PASSWORD=CHANGE_ME_APPLICATION_PASSWORD
```

### `/opt/pgsql-ha/patroni.yml`

```yaml
scope: pgsql-ha
namespace: /service/
name: pg1

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
        hot_standby: "on"
        wal_log_hints: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 256MB
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - host replication replicator 192.168.50.0/24 scram-sha-256
    - host all all 192.168.50.0/24 scram-sha-256

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 192.168.50.11:5432
  data_dir: /var/lib/postgresql/data/pgdata
  bin_dir: /usr/lib/postgresql/16/bin
  authentication:
    superuser:
      username: postgres
    replication:
      username: replicator
  parameters:
    password_encryption: scram-sha-256
    unix_socket_directories: /var/run/postgresql

watchdog:
  mode: off

tags:
  clonefrom: true
  noloadbalance: false
  nofailover: false
  nosync: false
```

---

## 11. db2 設定

### `/opt/pgsql-ha/.env`

```dotenv
NODE_IP=192.168.50.12
ETCD_NAME=etcd2
ETCD_DATA_DIR=/srv/pgsql-ha/etcd2
PGDATA_DIR=/srv/pgsql-ha/postgresql
ETCD_CLUSTER_TOKEN=CHANGE_ME_ETCD_CLUSTER_TOKEN
ETCD_INITIAL_CLUSTER=etcd1=http://192.168.50.11:2380,etcd2=http://192.168.50.12:2380,etcd3=http://192.168.50.13:2380
POSTGRES_SUPERUSER_PASSWORD=CHANGE_ME_POSTGRES_SUPERUSER_PASSWORD
POSTGRES_REPLICATION_PASSWORD=CHANGE_ME_POSTGRES_REPLICATION_PASSWORD
APP_PASSWORD=CHANGE_ME_APPLICATION_PASSWORD
```

### `/opt/pgsql-ha/patroni.yml`

```yaml
scope: pgsql-ha
namespace: /service/
name: pg2

restapi:
  listen: 0.0.0.0:8008
  connect_address: 192.168.50.12:8008

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
        hot_standby: "on"
        wal_log_hints: "on"
        max_wal_senders: 10
        max_replication_slots: 10
        wal_keep_size: 256MB
  initdb:
    - encoding: UTF8
    - data-checksums
  pg_hba:
    - host replication replicator 192.168.50.0/24 scram-sha-256
    - host all all 192.168.50.0/24 scram-sha-256

postgresql:
  listen: 0.0.0.0:5432
  connect_address: 192.168.50.12:5432
  data_dir: /var/lib/postgresql/data/pgdata
  bin_dir: /usr/lib/postgresql/16/bin
  authentication:
    superuser:
      username: postgres
    replication:
      username: replicator
  parameters:
    password_encryption: scram-sha-256
    unix_socket_directories: /var/run/postgresql

watchdog:
  mode: off

tags:
  clonefrom: true
  noloadbalance: false
  nofailover: false
  nosync: false
```

db1 與 db2 的以下值必須一致：

- `scope` 與 `namespace`；
- 三個 etcd endpoint；
- `ETCD_CLUSTER_TOKEN`；
- `ETCD_INITIAL_CLUSTER`；
- PostgreSQL superuser 密碼；
- replication 密碼。

以下值必須不同：

- Patroni `name`；
- `NODE_IP`；
- `ETCD_NAME`；
- Patroni REST `connect_address`；
- PostgreSQL `connect_address`。

---

## 12. witness 設定

witness 不需要 Patroni、PostgreSQL 或 HAProxy。

### `/opt/pgsql-ha/.env`

```dotenv
NODE_IP=192.168.50.13
ETCD_DATA_DIR=/srv/pgsql-ha/etcd3
ETCD_CLUSTER_TOKEN=CHANGE_ME_ETCD_CLUSTER_TOKEN
ETCD_INITIAL_CLUSTER=etcd1=http://192.168.50.11:2380,etcd2=http://192.168.50.12:2380,etcd3=http://192.168.50.13:2380
```

### `/opt/pgsql-ha/compose.yml`

```yaml
name: pgsql-ha-witness

services:
  etcd:
    container_name: pgsql-ha-etcd-witness
    image: gcr.io/etcd-development/etcd:v3.5.21
    restart: unless-stopped
    network_mode: host
    volumes:
      - ${ETCD_DATA_DIR:?set ETCD_DATA_DIR}:/etcd-data
    command:
      - /usr/local/bin/etcd
      - --name=etcd3
      - --data-dir=/etcd-data
      - --listen-client-urls=http://0.0.0.0:2379
      - --advertise-client-urls=http://${NODE_IP:?set NODE_IP}:2379
      - --listen-peer-urls=http://0.0.0.0:2380
      - --initial-advertise-peer-urls=http://${NODE_IP}:2380
      - --initial-cluster=${ETCD_INITIAL_CLUSTER:?set ETCD_INITIAL_CLUSTER}
      - --initial-cluster-state=new
      - --initial-cluster-token=${ETCD_CLUSTER_TOKEN:?set ETCD_CLUSTER_TOKEN}
      - --auto-compaction-retention=1
      - --auto-compaction-mode=periodic
```

---

## 13. 設定密碼

三台主機的 `ETCD_CLUSTER_TOKEN` 必須相同。db1 與 db2 的 PostgreSQL superuser、replication 與 application 密碼也必須相同。

可使用 hex 字串，避免 `.env` 特殊字元解析問題：

```bash
openssl rand -hex 32
openssl rand -hex 32
openssl rand -hex 32
openssl rand -hex 32
```

分別用作：

```text
ETCD_CLUSTER_TOKEN
POSTGRES_SUPERUSER_PASSWORD
POSTGRES_REPLICATION_PASSWORD
APP_PASSWORD
```

修改完後：

```bash
sudo chmod 0600 /opt/pgsql-ha/.env
```

不要把 `.env` 放進 Git，也不要把正式密碼寫在 `patroni.yml`。

先做 Compose 靜態驗證。

在 db1 與 db2：

```bash
cd /opt/pgsql-ha
sudo docker compose --env-file .env -f compose.yml config >/dev/null
```

在 witness：

```bash
cd /opt/pgsql-ha
sudo docker compose --env-file .env -f compose.yml config >/dev/null
```

沒有輸出且 exit code 為 0 才繼續。

---

## 14. 啟動三成員 etcd

先啟動 DCS，再啟動 Patroni。

### db1

```bash
cd /opt/pgsql-ha
sudo docker compose --env-file .env -f compose.yml up -d etcd
```

### db2

```bash
cd /opt/pgsql-ha
sudo docker compose --env-file .env -f compose.yml up -d etcd
```

### witness

```bash
cd /opt/pgsql-ha
sudo docker compose --env-file .env -f compose.yml up -d etcd
```

第一個 etcd 成員單獨啟動時可能暫時無法取得 leader，這是正常的。三個成員全部啟動後再檢查。

從 db1 執行：

```bash
sudo docker exec pgsql-ha-etcd \
  etcdctl \
  --endpoints=http://192.168.50.11:2379,http://192.168.50.12:2379,http://192.168.50.13:2379 \
  endpoint health --cluster
```

再看狀態與成員表：

```bash
sudo docker exec pgsql-ha-etcd \
  etcdctl \
  --endpoints=http://192.168.50.11:2379,http://192.168.50.12:2379,http://192.168.50.13:2379 \
  endpoint status --cluster -w table

sudo docker exec pgsql-ha-etcd \
  etcdctl \
  --endpoints=http://192.168.50.11:2379 \
  member list -w table
```

應確認：

- 三個 endpoint 都是 healthy；
- 三個 member 都是 started；
- 只有一個 etcd leader；
- 各成員 Raft index 接近。

如果 etcd 還沒有多數票，不要啟動 Patroni。

> `--initial-cluster` 只用於新叢集初始化。etcd data-dir 已存在後，直接修改這個字串不會正確改變叢集 membership。既有叢集要使用 `etcdctl member add/remove/update`。

---

## 15. 啟動 Patroni 與 PostgreSQL

先在 db1 建立映像並啟動 Patroni：

```bash
cd /opt/pgsql-ha
sudo docker compose --env-file .env -f compose.yml build patroni
sudo docker compose --env-file .env -f compose.yml up -d patroni
```

檢查 db1：

```bash
curl -fsS http://192.168.50.11:8008/patroni | jq
curl -fsS http://192.168.50.11:8008/primary
```

全新叢集通常會由 db1 初始化為 primary。確認它穩定後，在 db2 執行：

```bash
cd /opt/pgsql-ha
sudo docker compose --env-file .env -f compose.yml build patroni
sudo docker compose --env-file .env -f compose.yml up -d patroni
```

db2 會向目前 primary 取得 base backup，所需時間取決於資料量與網路速度。查看日誌：

```bash
sudo docker logs -f pgsql-ha-patroni
```

確認角色：

```bash
curl -fsS http://192.168.50.11:8008/patroni | jq '{name,role,state,timeline}'
curl -fsS http://192.168.50.12:8008/patroni | jq '{name,role,state,timeline}'
```

也可以直接測試健康端點：

```bash
curl -fsS http://192.168.50.11:8008/primary || true
curl -fsS http://192.168.50.11:8008/replica || true
curl -fsS http://192.168.50.12:8008/primary || true
curl -fsS http://192.168.50.12:8008/replica || true
```

最終應該剛好有一個 `/primary` 回傳成功，另一個 `/replica` 回傳成功。

---

## 16. 啟動兩個 HAProxy

在 db1：

```bash
cd /opt/pgsql-ha
sudo docker compose --env-file .env -f compose.yml up -d haproxy
```

在 db2：

```bash
cd /opt/pgsql-ha
sudo docker compose --env-file .env -f compose.yml up -d haproxy
```

查看 HAProxy 日誌：

```bash
sudo docker logs pgsql-ha-haproxy
```

正常情況下，`postgres-write` 只會有一個 UP backend，`postgres-read` 也只會有一個 UP backend。

---

## 17. 建立應用程式帳號與資料庫

可以直接用 PostgreSQL client container，不必在宿主機安裝 `psql`。

先從 db1 的 `.env` 取出實際密碼並手動填入下列變數。正式環境不要把密碼留在 shell history：

```bash
export POSTGRES_ADMIN_PASSWORD='替換成實際 superuser 密碼'
export APPLICATION_PASSWORD='替換成實際 app 密碼'
```

透過 db1 的 HAProxy 寫入入口執行：

```bash
sudo docker run --rm -i --network host \
  -e PGPASSWORD="$POSTGRES_ADMIN_PASSWORD" \
  postgres:16-bookworm \
  psql -v ON_ERROR_STOP=1 \
  -h 127.0.0.1 -p 5000 -U postgres -d postgres <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app') THEN
    CREATE ROLE app LOGIN PASSWORD '${APPLICATION_PASSWORD}';
  ELSE
    ALTER ROLE app LOGIN PASSWORD '${APPLICATION_PASSWORD}';
  END IF;
END
\$\$;

SELECT 'CREATE DATABASE appdb OWNER app'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'appdb')
\gexec
SQL
```

完成後清除 shell 變數：

```bash
unset POSTGRES_ADMIN_PASSWORD APPLICATION_PASSWORD
```

---

## 18. 驗證兩個寫入入口

兩台 HAProxy 的 `5000` 都應把連線送到同一個 primary。

```bash
export PGPASSWORD='替換成實際 app 密碼'

sudo docker run --rm --network host \
  -e PGPASSWORD="$PGPASSWORD" \
  postgres:16-bookworm \
  psql -At \
  -h 192.168.50.11 -p 5000 -U app -d appdb \
  -c 'SELECT inet_server_addr(), NOT pg_is_in_recovery();'

sudo docker run --rm --network host \
  -e PGPASSWORD="$PGPASSWORD" \
  postgres:16-bookworm \
  psql -At \
  -h 192.168.50.12 -p 5000 -U app -d appdb \
  -c 'SELECT inet_server_addr(), NOT pg_is_in_recovery();'
```

兩次都應在第二欄回傳 `t`，而且通常會顯示同一個 PostgreSQL server address。

建立測試資料：

```bash
sudo docker run --rm -i --network host \
  -e PGPASSWORD="$PGPASSWORD" \
  postgres:16-bookworm \
  psql -v ON_ERROR_STOP=1 \
  -h 192.168.50.11 -p 5000 -U app -d appdb <<'SQL'
CREATE TABLE IF NOT EXISTS ha_probe (
  id bigserial PRIMARY KEY,
  marker text UNIQUE NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO ha_probe(marker)
VALUES ('before-failover');
SQL
```

---

## 19. 驗證唯讀入口與複寫

`5001` 只連到 replica：

```bash
sudo docker run --rm --network host \
  -e PGPASSWORD="$PGPASSWORD" \
  postgres:16-bookworm \
  psql -At \
  -h 192.168.50.12 -p 5001 -U app -d appdb \
  -c "SELECT marker, pg_is_in_recovery() FROM ha_probe WHERE marker='before-failover';"
```

應看到：

```text
before-failover|t
```

這表示資料已到達 replica，而且連線確實不是 primary。

`5001` 不是強一致讀取入口。需要 read-your-writes、交易後立即讀取或不能接受複寫延遲的請求，應使用 `5000`。

完成後：

```bash
unset PGPASSWORD
```

---

## 20. 應用程式應如何連線

這套架構沒有浮動 VIP。兩台 HAProxy 是兩個獨立入口，所以應用程式必須知道兩個位址。

支援 libpq 多主機語法的驅動可使用：

```text
host=192.168.50.11,192.168.50.12 port=5000,5000 dbname=appdb user=app target_session_attrs=read-write connect_timeout=3
```

URI 形式：

```text
postgresql://app@192.168.50.11:5000,192.168.50.12:5000/appdb?target_session_attrs=read-write&connect_timeout=3
```

密碼應由應用程式的祕密管理系統提供，不要直接放在 URI。

`target_session_attrs=read-write` 讓 libpq 接受真正可寫的 session。雖然 HAProxy 已經做 primary 健康檢查，客戶端再做一次可寫性判斷仍然有價值。

連線池也必須正確處理故障轉移：

- 失效連線要被丟棄；
- 新連線要重新走 host list；
- 尚未確認提交結果的交易不能盲目重送；
- 具冪等性的操作才適合自動重試。

不支援多主機連線的驅動，需要另外部署高可用 VIP、外部負載平衡器、服務探索或受監控 DNS。兩個 HAProxy 容器本身不會自動變成單一入口。

---

## 21. 測試 PostgreSQL 程序故障轉移

先找出目前 primary：

```bash
curl -fsS http://192.168.50.11:8008/primary >/dev/null && echo db1-primary
curl -fsS http://192.168.50.12:8008/primary >/dev/null && echo db2-primary
```

假設 db1 是 primary，在 db1 停止 Patroni 容器：

```bash
cd /opt/pgsql-ha
sudo docker compose --env-file .env -f compose.yml stop patroni
```

觀察 db2：

```bash
watch -n 1 'curl -s -o /dev/null -w "%{http_code}\n" http://192.168.50.12:8008/primary'
```

當 db2 `/primary` 回傳 200 後，從 db2 的寫入入口測試：

```bash
export PGPASSWORD='替換成實際 app 密碼'

sudo docker run --rm --network host \
  -e PGPASSWORD="$PGPASSWORD" \
  postgres:16-bookworm \
  psql -v ON_ERROR_STOP=1 \
  -h 192.168.50.12 -p 5000 -U app -d appdb \
  -c "INSERT INTO ha_probe(marker) VALUES ('after-process-failover');"
```

恢復 db1：

```bash
cd /opt/pgsql-ha
sudo docker compose --env-file .env -f compose.yml up -d patroni
```

等待 db1 成為 replica：

```bash
curl -fsS http://192.168.50.11:8008/replica
```

最後確認兩筆資料：

```bash
sudo docker run --rm --network host \
  -e PGPASSWORD="$PGPASSWORD" \
  postgres:16-bookworm \
  psql -At \
  -h 192.168.50.11 -p 5000 -U app -d appdb \
  -c "SELECT marker FROM ha_probe ORDER BY id;"

unset PGPASSWORD
```

---

## 22. 測試整台資料庫主機失效

程序故障不等於主機故障。真正要驗證 HA，應在維護時段測試整台 primary 主機斷電或失去網路。

假設 db1 是 primary：

1. 先寫入唯一探針；
2. 關閉 db1 或停止其 Docker daemon；
3. 確認 etcd2 與 etcd3 仍有多數票；
4. 等待 db2 提升；
5. 從 db2:5000 寫入新資料；
6. 恢復 db1；
7. 確認 db1 以 replica 身分重新加入。

在 db2 可以檢查 etcd quorum：

```bash
sudo docker exec pgsql-ha-etcd \
  etcdctl \
  --endpoints=http://192.168.50.12:2379,http://192.168.50.13:2379 \
  endpoint health
```

然後檢查 Patroni：

```bash
curl -fsS http://192.168.50.12:8008/primary
```

主機恢復後，不要直接假定它仍可作為 primary。讓 Patroni 判斷 timeline 並執行 `pg_rewind`。若舊資料目錄無法 rewind，應從新 primary 重新初始化該 replica。

---

## 23. 測試 witness 故障

停止 witness 上的 etcd：

```bash
cd /opt/pgsql-ha
sudo docker compose --env-file .env -f compose.yml stop etcd
```

因為 etcd1 與 etcd2 還有兩票，叢集應繼續運作。從任一資料庫主機檢查：

```bash
sudo docker exec pgsql-ha-etcd \
  etcdctl \
  --endpoints=http://192.168.50.11:2379,http://192.168.50.12:2379 \
  endpoint health
```

並透過 `5000` 執行一次寫入。

恢復 witness：

```bash
cd /opt/pgsql-ha
sudo docker compose --env-file .env -f compose.yml up -d etcd
```

再次檢查三個 endpoint 與 Raft index。

---

## 24. 同步複寫設定代表什麼

本文啟用了：

```yaml
synchronous_mode: true
synchronous_mode_strict: false
synchronous_node_count: 1
```

正常狀態下，Patroni 會選一台同步 standby，並限制自動提升候選，避免把缺少已確認提交交易的副本提升為 primary。

但 `synchronous_mode_strict: false` 代表：當同步副本消失時，Patroni 可以在短暫等待後解除同步要求，讓 primary 繼續接受寫入。這比較偏向可用性，但不保證所有故障情境都是 RPO 0。

若改成：

```yaml
synchronous_mode_strict: true
```

沒有同步副本時，primary 的寫入會阻塞。這可以提高雙節點持久性保證，但任何 replica 維護、網路故障或磁碟延遲都可能直接影響寫入可用性。

兩台 PostgreSQL 資料節點沒有神奇的設定可以同時保證：

- 任意一台失效時仍持續寫入；
- 每一筆成功交易都已存在於兩台；
- 寫入永不因 replica 故障阻塞。

必須依業務選擇 RPO、RTO 與可用性取捨。

還要注意：`bootstrap.dcs` 只在第一次初始化叢集時寫進 DCS。叢集建立後修改 YAML 中的這一段，不會自動改變現有動態設定。後續應使用 `patronictl edit-config` 或 Patroni REST API。

---

## 25. 日常操作

### 查看狀態

```bash
cd /opt/pgsql-ha
sudo docker compose --env-file .env -f compose.yml ps
sudo docker logs --tail 100 pgsql-ha-patroni
sudo docker logs --tail 100 pgsql-ha-haproxy
sudo docker logs --tail 100 pgsql-ha-etcd
```

### 一般重啟

```bash
sudo docker compose --env-file .env -f compose.yml restart haproxy
sudo docker compose --env-file .env -f compose.yml restart patroni
```

維護 Patroni 前先確認目前角色。不要同時重啟兩台資料庫主機。

### 停止容器但保留資料

```bash
sudo docker compose --env-file .env -f compose.yml stop
```

### 移除容器但保留 bind-mounted 資料

```bash
sudo docker compose --env-file .env -f compose.yml down
```

### 重新啟動

```bash
sudo docker compose --env-file .env -f compose.yml up -d etcd
sudo docker compose --env-file .env -f compose.yml up -d patroni
sudo docker compose --env-file .env -f compose.yml up -d haproxy
```

---

## 26. 不要把刪除資料當成修復方式

下列目錄包含真正的 PostgreSQL 或 etcd 狀態：

```text
/srv/pgsql-ha/postgresql
/srv/pgsql-ha/etcd1
/srv/pgsql-ha/etcd2
/srv/pgsql-ha/etcd3
```

直接 `rm -rf` 不是普通重啟，也不是安全的「重新同步」。刪除前至少要確認：

- 目標主機與目錄；
- 目前 primary；
- PostgreSQL timeline；
- etcd member list；
- 備份是否可還原；
- 是否正在刪除唯一可用副本。

不要同時刪除兩個 etcd 成員資料。也不要把舊 primary 的 PGDATA 強行啟動成新的獨立 PostgreSQL。

---

## 27. 備份仍然必須另外做

串流複寫不是備份。以下事故會同步到 replica：

- 誤刪資料表；
- 錯誤的 `UPDATE` 或 `DELETE`；
- 應用程式邏輯錯誤；
- 勒索軟體或管理帳號誤操作；
- 某些形式的資料損壞。

正式環境至少需要：

- 定期 base backup；
- WAL 歸檔；
- Point-in-Time Recovery；
- 異機或異地備份；
- 實際還原演練；
- 備份失敗告警。

可使用 pgBackRest、Barman 或雲端供應商的受管備份方案，但不要只檢查「備份工作成功」，還要定期證明它真的能還原。

---

## 28. 正式環境還缺什麼

本文為了讓架構容易理解，使用明文區域網路。正式環境至少應補上以下內容。

### TLS

- etcd client 與 peer traffic 使用雙向 TLS；
- PostgreSQL 啟用 server certificate，依需求使用 client certificate；
- Patroni REST API 使用 TLS 或置於嚴格受控的管理網路。

### 祕密管理

`.env` 適合受控實驗，不適合大規模正式環境。可以改用 Docker secrets、Vault、SOPS 或其他祕密管理系統。

### 監控

至少監控：

- PostgreSQL 是否可寫；
- replication lag；
- timeline 與 replication slot；
- Patroni leader 與 HA loop；
- etcd leader、quorum、db size、fsync latency；
- HAProxy backend 狀態；
- 磁碟空間、IO latency、inode；
- 備份與還原演練。

### Fencing

Patroni 與 etcd 能大幅降低雙主風險，但本文沒有設定帶外 fencing。對資料完整性要求高的環境，應讓控制面能透過 IPMI、Redfish、智能 PDU 或虛擬化平台 API 關閉失聯的舊 primary。

### 映像管理

不要長期使用浮動 tag。固定 image digest，建立漏洞掃描、更新測試與回滾流程。

### 單一入口

需要單一 IP 時，可以在兩台 HAProxy 前面加入 Keepalived/VIP，但兩節點 VIP 同樣要處理網路分割與 fencing。另一個選擇是獨立負載平衡器或支援健康檢查的服務探索。

---

## 29. 如果真的只有兩台實體機器，連 witness 都沒有呢？

這時不要部署兩成員 etcd，然後假裝它能 HA。它不能容忍任何成員故障。

只有兩台機器又要安全自動切換，較合理的方向是：

```text
PostgreSQL streaming replication
+ Pacemaker
+ Corosync two-node mode
+ 可靠 STONITH/fencing
+ 浮動 VIP
```

存活節點必須能證明舊 primary 已被斷電或隔離，才允許提升自己。fencing 可以來自 IPMI、Redfish、智能 PDU 或虛擬化平台。只有 ping、SSH 失敗或停止某個程序，都不能證明對方已失去寫入能力。

如果沒有第三票，也沒有可靠 fencing，安全做法是保留人工故障轉移：先由管理員確認舊主庫已關閉或被隔離，再提升 replica。

---

## 30. 故障結果速查

| 故障 | 預期結果 |
|---|---|
| primary 的 PostgreSQL/Patroni 容器失效 | replica 在 etcd 有多數票且狀態合格時提升 |
| db1 整台失效 | db2 + witness 有兩票，db2 可提升 |
| db2 整台失效 | db1 + witness 有兩票，db1 可繼續或提升 |
| witness 失效 | db1 + db2 有兩票，叢集繼續運作 |
| etcd 失去多數票 | 不進行新的安全選主；寫入可能停止 |
| 一台 HAProxy 失效 | 該入口失效，應用程式改用另一入口 |
| replica 落後超過門檻 | Patroni 不應自動提升該 replica |
| 舊 primary 恢復 | Patroni 透過 pg_rewind 或重新初始化讓它成為 replica |

---

## 結語

Docker Compose 並不會自動把跨主機服務變成叢集。這套設計能運作，是因為每個元件的責任很清楚：PostgreSQL 複寫資料，Patroni 管理角色，etcd 提供一致性仲裁，HAProxy 將新連線送到正確節點，而應用程式負責在兩個入口之間重新連線。

真正值得做的不是看見兩個容器都在 running，而是親手完成故障演練：停止 primary、關閉整台主機、停止 witness、恢復舊 primary，再確認故障前後的資料、timeline、可寫性與應用連線。沒有經過這些驗證的 HA，大多只是畫得很好看的架構圖。

---

## 參考資料

- Docker Engine on Ubuntu：<https://docs.docker.com/engine/install/ubuntu/>
- Patroni YAML configuration：<https://patroni.readthedocs.io/en/latest/yaml_configuration.html>
- Patroni environment configuration：<https://patroni.readthedocs.io/en/latest/ENVIRONMENT.html>
- Patroni replication modes：<https://patroni.readthedocs.io/en/latest/replication_modes.html>
- Patroni REST API：<https://patroni.readthedocs.io/en/latest/rest_api.html>
- etcd clustering guide：<https://etcd.io/docs/v3.5/op-guide/clustering/>
- etcd FAQ：<https://etcd.io/docs/v3.5/faq/>
- PostgreSQL libpq connection parameters：<https://www.postgresql.org/docs/current/libpq-connect.html>
