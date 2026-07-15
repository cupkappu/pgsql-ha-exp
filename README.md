# PostgreSQL 兩主機 HA 實驗

本倉庫包含兩套 PostgreSQL 16 高可用實驗、三種區域網路部署範本及一套獨立 Compose 範例。

## 狀態

| 實驗 | 元件 | 狀態 | 驗證命令 |
|---|---|---|---|
| Patroni | PostgreSQL、Patroni、三成員 etcd、HAProxy | 完成 | `make patroni-test` |
| Pacemaker | PostgreSQL、Corosync、Pacemaker、PAF、STONITH、VIP | 完成 | `make pcmk-test` |

`make test-all` 執行兩套驗證。

## 目錄

| 路徑 | 內容 |
|---|---|
| `topology.clab.yml` | Patroni 實驗拓撲 |
| `topology-pacemaker.clab.yml` | Pacemaker 實驗拓撲 |
| `config/` | 實驗設定 |
| `images/` | 實驗映像 |
| `scripts/` | 建立、狀態、停止、清理及節點恢復 |
| `tests/` | smoke、程序故障、主機故障、witness、fencing 測試 |
| `deploy/lan/` | 三種區域網路部署範本 |
| `standalone-compose-example/` | 可分別複製到三台主機的 Compose 檔 |

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
