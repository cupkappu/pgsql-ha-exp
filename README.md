# PostgreSQL 兩主機高可用實驗

本專案在 Lima Linux VM 中使用 containerlab 模擬兩台互相獨立的資料庫主機，並保存兩套 PostgreSQL 高可用實驗：

- 實驗一：PostgreSQL 16、Patroni、三成員 etcd 與 HAProxy。
- 實驗二：PostgreSQL 16、Pacemaker、Corosync、STONITH 與浮動 VIP。

目前預設 Lima 執行個體為 `fabric-clab`。實驗與後文的區域網路實機範本是兩個不同環境；請勿把實驗密碼或模擬網段直接用於正式環境。

## 專案狀態

2026-07-15 已對實驗一執行：

```bash
make status
make patroni-test
```

實際結果：

- `host1` 與 `host2` 使用不同的 Docker daemon。
- etcd 有三個健康成員，第三個成員是獨立 witness。
- Patroni 形成一個 primary 與一個 replica。
- 兩個 HAProxy 寫入入口均連到 primary。
- 寫入的探針資料可由 replica 讀取。
- PostgreSQL／Patroni 程序故障轉移通過。
- witness 停止期間的多數票與寫入驗證通過。
- primary 所在模擬主機停止後的故障轉移與重新加入通過。
- `make patroni-test` 結束狀態為 `0`。

實驗二的程式、拓撲與測試檔已存在，但本次 README 更新沒有重新執行其完整驗收，因此不把它描述為本次已驗證結果。

## 實驗一：Patroni、etcd 與 HAProxy

### 模擬拓撲

```text
macOS
└── Lima VM: fabric-clab
    └── containerlab: pgsql-ha
        ├── host1（獨立 dockerd）
        │   ├── etcd1
        │   ├── PostgreSQL 16 + Patroni pg1
        │   └── HAProxy
        ├── host2（獨立 dockerd）
        │   ├── etcd2
        │   ├── PostgreSQL 16 + Patroni pg2
        │   └── HAProxy
        └── witness
            └── etcd3
```

`host1` 與 `host2` 透過 `10.10.0.0/30` 點對點鏈路傳輸 PostgreSQL 複寫、Patroni REST 與 HAProxy 後端流量。etcd 使用 containerlab 管理網路：

```text
etcd1: 172.31.100.11:2379
etcd2: 172.31.100.12:2379
etcd3: 172.31.100.13:2379
```

三成員 etcd 需要兩票才能形成多數票。任一資料庫主機失效後，存活的資料庫主機與 witness 仍有兩票；witness 單獨失效時，兩台資料庫主機上的 etcd 成員也仍有兩票。

### 存取入口

HAProxy 寫入入口位於 Lima VM：

```text
127.0.0.1:15000
127.0.0.1:25000
```

HAProxy 唯讀入口：

```text
127.0.0.1:15001
127.0.0.1:25001
```

寫入入口以 Patroni `/primary` 為健康檢查；唯讀入口以 `/replica` 為健康檢查。

### 操作命令

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

`make up`、`make status`、`make test`、`make down` 與 `make clean` 是實驗一的別名。

`make patroni-clean` 會刪除 `/var/lib/pgsql-ha-exp` 下的執行狀態與全部實驗資料。`make patroni-down` 只停止實驗並保留資料。

### 測試內容

| 目標 | 命令 | 驗證內容 |
|---|---|---|
| 基本狀態 | `make patroni-smoke` | Docker daemon、三成員 etcd、主副角色、讀寫入口與複寫 |
| 程序故障 | `make patroni-process-failover` | 停止 primary 的 Patroni/PostgreSQL，副本提升，舊 primary 恢復為 replica |
| witness 故障 | `make patroni-witness-failure` | etcd3 停止時，etcd1 與 etcd2 保持多數票及寫入能力 |
| 整台主機故障 | `make patroni-host-failover` | 暫停 primary 所在模擬主機，存活主機與 witness 完成故障轉移 |

## 實驗二：Pacemaker 與 Corosync

實驗二使用 `topology-pacemaker.clab.yml` 建立兩台資料庫節點，以 Corosync、Pacemaker、PAF `pgsqlms` resource agent、STONITH 與 `172.31.110.100` 浮動 VIP 管理 PostgreSQL。

```bash
make pcmk-up
make pcmk-status
make pcmk-smoke
make pcmk-failover
make pcmk-test
make pcmk-down
make pcmk-clean
```

模擬 STONITH agent `fence_peer_docker` 透過 Lima Docker daemon 停止對端容器。實體機器必須改用 IPMI、Redfish、智能 PDU 或虛擬化平台提供的 fence agent；一般的程序停止命令不能證明舊 primary 已失去寫入能力。

## 實機部署概覽

以下範本位於 `deploy/lan/`，目標環境是同一區域網路內的 Ubuntu 24.04 LTS 主機。範例位址：

| 節點 | 位址 | 服務 |
|---|---:|---|
| `db1` | `192.168.50.11` | PostgreSQL、Patroni、HAProxy、etcd1 |
| `db2` | `192.168.50.12` | PostgreSQL、Patroni、HAProxy、etcd2 |
| `witness` | `192.168.50.13` | 類型 A 的 etcd3 |
| `etcd-ext-1` | `192.168.50.21` | 類型 C 的外部 etcd 成員 |
| `etcd-ext-2` | `192.168.50.22` | 類型 C 的外部 etcd 成員 |
| `etcd-ext-3` | `192.168.50.23` | 類型 C 的外部 etcd 成員 |

三種拓撲：

| 類型 | 第三票位置 | 可用性特性 |
|---|---|---|
| A | 獨立小型主機或 VM | 推薦；可容忍任一資料庫主機失效 |
| B | 與 `db1` 共置 | 成本較低，但故障容忍不對稱 |
| C | 既有外部三成員 etcd | 資料庫主機不執行 etcd；可用性取決於外部叢集 |

範本採用 Docker host network。這讓跨主機 advertised URL 直接使用區域網路位址，也代表 PostgreSQL、Patroni REST 與 etcd 會直接監聽主機連接埠，必須以主機防火牆及網路 ACL 限制來源。

模擬實驗為縮短測試時間使用 `ttl: 12`、`loop_wait: 2`、`retry_timeout: 4`。實機範本改用 Patroni 可驗證的 `30/10/10`，同時符合 `ttl >= 20` 與 `loop_wait + 2 × retry_timeout <= ttl`。這些值影響故障偵測時間，需在實機演練後依 RTO 與網路狀況調整。

## 共同前提

### 硬體與系統

- `db1`、`db2` 是兩台不同實體機器或位於不同故障域的 VM。
- Ubuntu 24.04 LTS，具備 `sudo` 權限。
- 固定 IP；不得依賴會變動的 DHCP 租約。
- 主機名稱唯一，且所有節點可透過 IP 或內部 DNS 互相連線。
- 系統時間由同一組 NTP 來源同步。
- PostgreSQL 資料目錄位於可靠的持久化磁碟。
- 兩台資料庫主機的 PostgreSQL 大版本、Patroni 映像與設定一致。
- 已決定 RPO、RTO、備份、還原、監控與維護責任。

檢查固定位址、名稱與時間：

```bash
hostnamectl
ip -brief address
timedatectl status
```

安裝並啟用 chrony：

```bash
sudo apt-get update
sudo apt-get install -y chrony curl ca-certificates
sudo systemctl enable --now chrony
chronyc tracking
```

### 安裝 Docker Engine 與 Compose Plugin

在每台會執行容器的 Ubuntu 主機執行：

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
sudo docker version
sudo docker compose version
```

將本專案複製到各主機的相同路徑，例如 `/opt/pgsql-ha-exp`。以下命令均假設使用該路徑。

### 連接埠

只允許必要來源。不要直接把 etcd 或 Patroni REST 開放至網際網路。

| 連接埠 | 允許來源 | 用途 |
|---:|---|---|
| 2379/TCP | Patroni 節點與管理主機 | etcd client |
| 2380/TCP | 三個 etcd 成員 | etcd peer |
| 2479/TCP | Patroni 節點與管理主機 | 類型 B 的共置 etcd3 client |
| 2480/TCP | 三個 etcd 成員 | 類型 B 的共置 etcd3 peer |
| 5432/TCP | `db1`、`db2` 與受控管理主機 | PostgreSQL 複寫及管理 |
| 8008/TCP | `db1`、`db2` | Patroni REST 與 HAProxy 健康檢查 |
| 5000/TCP | 應用程式網段 | PostgreSQL 寫入入口 |
| 5001/TCP | 允許讀取 replica 的應用程式 | PostgreSQL 唯讀入口 |

UFW 範例；啟用前先保留現有 SSH 管理連線：

```bash
sudo ufw allow from 192.168.50.0/24 to any port 2379 proto tcp
sudo ufw allow from 192.168.50.0/24 to any port 2380 proto tcp
sudo ufw allow from 192.168.50.0/24 to any port 5432 proto tcp
sudo ufw allow from 192.168.50.0/24 to any port 8008 proto tcp
sudo ufw allow from 192.168.50.0/24 to any port 5000 proto tcp
sudo ufw allow from 192.168.50.0/24 to any port 5001 proto tcp
```

### 密碼與資料目錄

`.env.example` 只含替換標記。每台主機建立自己的 `.env`，三台自建 etcd 節點必須使用完全相同的 `ETCD_CLUSTER_TOKEN` 與 `ETCD_INITIAL_CLUSTER`。

```bash
cd /opt/pgsql-ha-exp
sudo install -d -m 0700 /srv/pgsql-ha
```

在 `db1`：

```bash
cp deploy/lan/db1/.env.example deploy/lan/db1/.env
chmod 0600 deploy/lan/db1/.env
sudo install -d -m 0700 /srv/pgsql-ha/etcd1 /srv/pgsql-ha/postgresql
```

在 `db2`：

```bash
cp deploy/lan/db2/.env.example deploy/lan/db2/.env
chmod 0600 deploy/lan/db2/.env
sudo install -d -m 0700 /srv/pgsql-ha/etcd2 /srv/pgsql-ha/postgresql
```

編輯兩份 `.env`，把所有 `CHANGE_ME_...` 改成不同的高強度值。兩台資料庫主機的 superuser、replication 與 application 密碼必須一致。不要提交 `.env`。

## 類型 A：獨立 etcd witness

### 前提

`witness` 必須位於與 `db1`、`db2` 不同的故障域。它可以是小型實體主機或可靠 VM，不保存 PostgreSQL 資料，但其磁碟需持久保存 etcd data-dir。

### 部署過程

1. 在 witness 準備環境：

```bash
cd /opt/pgsql-ha-exp
cp deploy/lan/witness/.env.example deploy/lan/witness/.env
chmod 0600 deploy/lan/witness/.env
sudo install -d -m 0700 /srv/pgsql-ha/etcd3
```

2. 確認三份 `.env` 的 cluster token 與 initial cluster 完全一致：

```text
etcd1=http://192.168.50.11:2380,etcd2=http://192.168.50.12:2380,etcd3=http://192.168.50.13:2380
```

3. 在 `db1`、`db2`、`witness` 各自啟動 etcd：

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

4. 在 `db1` 檢查三成員狀態：

```bash
sudo docker compose --env-file deploy/lan/db1/.env \
  -f deploy/lan/db1/compose.yml exec etcd \
  etcdctl --endpoints=http://192.168.50.11:2379,http://192.168.50.12:2379,http://192.168.50.13:2379 \
  endpoint health --cluster

sudo docker compose --env-file deploy/lan/db1/.env \
  -f deploy/lan/db1/compose.yml exec etcd \
  etcdctl --endpoints=http://192.168.50.11:2379 \
  member list -w table
```

三個 endpoint 都必須回報 healthy，member list 必須顯示三個 started 成員。未達此條件時不要啟動 Patroni。

5. 在 `db1` 與 `db2` 建立 Patroni 映像：

```bash
sudo docker compose --env-file deploy/lan/db1/.env \
  -f deploy/lan/db1/compose.yml build patroni

sudo docker compose --env-file deploy/lan/db2/.env \
  -f deploy/lan/db2/compose.yml build patroni
```

6. 先在 `db1` 啟動 Patroni，確認 primary 建立，再啟動 `db2`：

```bash
# db1
sudo docker compose --env-file deploy/lan/db1/.env \
  -f deploy/lan/db1/compose.yml up -d patroni
curl -fsS http://192.168.50.11:8008/patroni

# db2
sudo docker compose --env-file deploy/lan/db2/.env \
  -f deploy/lan/db2/compose.yml up -d patroni
curl -fsS http://192.168.50.12:8008/patroni
```

最終必須是一個 primary 與一個 replica：

```bash
curl -fsS http://192.168.50.11:8008/primary || true
curl -fsS http://192.168.50.11:8008/replica || true
curl -fsS http://192.168.50.12:8008/primary || true
curl -fsS http://192.168.50.12:8008/replica || true
```

7. 在兩台資料庫主機啟動 HAProxy：

```bash
sudo docker compose --env-file deploy/lan/db1/.env \
  -f deploy/lan/db1/compose.yml up -d haproxy
sudo docker compose --env-file deploy/lan/db2/.env \
  -f deploy/lan/db2/compose.yml up -d haproxy
```

8. 透過任一寫入入口建立應用程式帳號與資料庫。互動輸入 `.env` 內的兩個密碼，避免把密碼寫入 shell 歷史：

```bash
read -rsp 'PostgreSQL superuser password: ' PGPASSWORD; export PGPASSWORD; echo
read -rsp 'Application password: ' APP_PASSWORD; echo
psql -h 192.168.50.11 -p 5000 -U postgres -d postgres \
  -v app_password="$APP_PASSWORD" -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE app LOGIN PASSWORD :'app_password';
CREATE DATABASE appdb OWNER app;
SQL
unset PGPASSWORD APP_PASSWORD
```

psql 變數會把應用程式密碼轉成 SQL 字串，避免密碼中的引號改變 SQL。若角色或資料庫已存在，不要再次執行建立命令。

### 預期結果

- 任一資料庫主機失效後，另一台資料庫主機與 witness 保有 etcd 多數票。
- Patroni 可在複寫狀態符合條件時提升 replica。
- witness 單獨失效時，兩台資料庫主機仍可維持 etcd 多數票。
- 任一 HAProxy 主機失效時，應用程式仍可改用另一台 HAProxy。

## 類型 B：第三個 etcd 與 db1 共置

### 前提與限制

此類型仍有三個 etcd 成員，但 `etcd1` 與 `etcd3` 都位於 `db1`：

```text
etcd1: 192.168.50.11:2379 / 2380
etcd2: 192.168.50.12:2379 / 2380
etcd3: 192.168.50.11:2479 / 2480
```

這不是三個獨立故障域：

- `db2` 失效時，`db1` 上兩個 etcd 成員仍有多數票。
- `db1` 失效時會同時失去兩票，`db2` 無法取得多數票，也不應提升 replica。
- 可用性取決於哪台主機失效，因此不適合要求任一資料庫主機失效後都能自動恢復寫入的系統。

### 部署過程

此程序只適用於尚未初始化的新 etcd 叢集。

1. 在 `db1` 準備共置 etcd3：

```bash
cd /opt/pgsql-ha-exp
cp deploy/lan/colocated-witness/.env.example \
  deploy/lan/colocated-witness/.env
chmod 0600 deploy/lan/colocated-witness/.env
sudo install -d -m 0700 /srv/pgsql-ha/etcd3
```

2. 把 `db1`、`db2` 與共置 witness 三份 `.env` 的 `ETCD_INITIAL_CLUSTER` 設為：

```text
etcd1=http://192.168.50.11:2380,etcd2=http://192.168.50.12:2380,etcd3=http://192.168.50.11:2480
```

3. 把 `deploy/lan/db1/patroni.yml` 與 `deploy/lan/db2/patroni.yml` 中的第三個 etcd client endpoint 從：

```text
192.168.50.13:2379
```

改為：

```text
192.168.50.11:2479
```

兩台主機上的 Patroni 設定必須一致。

4. 啟動 `db1` 的 etcd1、`db2` 的 etcd2，以及 `db1` 的 etcd3：

```bash
# db1: etcd1
sudo docker compose --env-file deploy/lan/db1/.env \
  -f deploy/lan/db1/compose.yml up -d etcd

# db2: etcd2
sudo docker compose --env-file deploy/lan/db2/.env \
  -f deploy/lan/db2/compose.yml up -d etcd

# db1: etcd3
sudo docker compose --env-file deploy/lan/colocated-witness/.env \
  -f deploy/lan/colocated-witness/compose.yml up -d etcd3
```

5. 檢查 endpoint：

```bash
sudo docker compose --env-file deploy/lan/db1/.env \
  -f deploy/lan/db1/compose.yml exec etcd \
  etcdctl --endpoints=http://192.168.50.11:2379,http://192.168.50.12:2379,http://192.168.50.11:2479 \
  endpoint health --cluster
```

6. etcd 三個 endpoint 都健康後，沿用類型 A 的 Patroni、HAProxy、應用程式帳號與資料庫建立程序。

已存在的 etcd data-dir 不會因為修改 `--initial-cluster` 自動改變成員配置。若要把既有類型 A 改成類型 B，必須使用 etcd 的 member add/remove 程序，或在確認沒有需要保留的 DCS 狀態後重建整個 etcd 叢集。直接刪除 etcd data-dir 是破壞性操作。

## 類型 C：外部 etcd 叢集

### 前提

- 外部 etcd 至少三個具投票權的成員，且分散於足以滿足可用性要求的故障域。
- 外部管理方負責容量、延遲、備份、監控、升級、憑證、使用者與權限。
- 已確認 Patroni 的租約與寫入負載符合外部 etcd 的共用政策。
- 已分配獨立 Patroni namespace/scope；範本使用 `/service/pgsql-ha`。
- `db1` 與 `db2` 到所有 etcd client endpoint 的網路均可達。

不能只因服務名稱是「外部 etcd」就假定它具備高可用。單成員 etcd、三個成員集中在同一台主機，或只有一條共同網路路徑，都可能令 Patroni 失去 DCS。

### 部署過程

1. 在 `db1`、`db2` 建立環境檔：

```bash
# db1
cp deploy/lan/external-etcd/.env.db1.example \
  deploy/lan/external-etcd/.env.db1
chmod 0600 deploy/lan/external-etcd/.env.db1

# db2
cp deploy/lan/external-etcd/.env.db2.example \
  deploy/lan/external-etcd/.env.db2
chmod 0600 deploy/lan/external-etcd/.env.db2
```

2. 在兩份 Patroni 設定中填入實際外部端點：

```text
deploy/lan/external-etcd/db1.patroni.yml
deploy/lan/external-etcd/db2.patroni.yml
```

範例是：

```yaml
etcd3:
  hosts:
    - 192.168.50.21:2379
    - 192.168.50.22:2379
    - 192.168.50.23:2379
```

若資料庫主機或應用程式不在範例的 `192.168.50.0/24`，也要同步修改兩份 Patroni 設定中的 `bootstrap.pg_hba`。外部 etcd 所在網段本身不需要加入 PostgreSQL `pg_hba`，除非該網段另有合法 PostgreSQL 客戶端。

3. 正式環境使用 TLS 時，在兩份設定啟用：

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

憑證 SAN 必須與 hosts 使用的名稱相符。將 CA、client certificate 與 private key 放在 `ETCD_PKI_DIR`，private key 權限只允許必要帳號讀取。若外部 etcd 啟用使用者認證，還需依該叢集政策設定 Patroni 專用帳號；不要在受版本控制的 YAML 內保存正式密碼。

4. 啟動 Patroni 前驗證外部 etcd。明文測試範例：

```bash
sudo docker run --rm --network host \
  gcr.io/etcd-development/etcd:v3.5.21 \
  etcdctl --endpoints=http://192.168.50.21:2379,http://192.168.50.22:2379,http://192.168.50.23:2379 \
  endpoint health --cluster
```

TLS 範例：

```bash
sudo docker run --rm --network host \
  -v /etc/pgsql-ha/etcd-pki:/pki:ro \
  gcr.io/etcd-development/etcd:v3.5.21 \
  etcdctl \
  --endpoints=https://etcd-ext-1.internal.example:2379,https://etcd-ext-2.internal.example:2379,https://etcd-ext-3.internal.example:2379 \
  --cacert=/pki/ca.crt --cert=/pki/patroni.crt --key=/pki/patroni.key \
  endpoint health --cluster
```

5. 在兩台資料庫主機建立 Patroni 映像：

```bash
sudo docker compose --env-file deploy/lan/external-etcd/.env.db1 \
  -f deploy/lan/external-etcd/db1.compose.yml build patroni
sudo docker compose --env-file deploy/lan/external-etcd/.env.db2 \
  -f deploy/lan/external-etcd/db2.compose.yml build patroni
```

6. 先在 `db1` 啟動 Patroni，再在 `db2` 啟動 Patroni：

```bash
sudo docker compose --env-file deploy/lan/external-etcd/.env.db1 \
  -f deploy/lan/external-etcd/db1.compose.yml up -d patroni
curl -fsS http://192.168.50.11:8008/patroni

sudo docker compose --env-file deploy/lan/external-etcd/.env.db2 \
  -f deploy/lan/external-etcd/db2.compose.yml up -d patroni
curl -fsS http://192.168.50.12:8008/patroni
```

7. 形成一個 primary 與一個 replica 後，在兩台主機啟動 HAProxy：

```bash
sudo docker compose --env-file deploy/lan/external-etcd/.env.db1 \
  -f deploy/lan/external-etcd/db1.compose.yml up -d haproxy
sudo docker compose --env-file deploy/lan/external-etcd/.env.db2 \
  -f deploy/lan/external-etcd/db2.compose.yml up -d haproxy
```

8. 使用類型 A 的方式建立應用程式帳號與資料庫，再執行下節的讀寫驗證。

### 外部 etcd 的責任邊界

資料庫團隊仍需知道：

- 哪些 etcd 成員具有投票權，以及多數票如何計算。
- 維護時可同時停止幾個成員。
- 延遲、容量與告警門檻。
- 備份與還原程序是否包含 Patroni DCS 資料。
- 憑證、帳號與權限由誰輪替。
- 外部 etcd 故障時的聯絡與復原責任。

外部 etcd 恢復不代表 PostgreSQL 會自動回到預期角色；DCS 恢復後仍需檢查 Patroni timeline、角色、複寫延遲與可寫性。

## 驗證實機部署結果

### etcd

自建類型 A 在任一資料庫主機使用三個 endpoint 執行；類型 B 把第三個 endpoint 改為 `http://192.168.50.11:2479`：

```bash
export ETCDCTL_ENDPOINTS='http://192.168.50.11:2379,http://192.168.50.12:2379,http://192.168.50.13:2379'
sudo docker run --rm --network host \
  gcr.io/etcd-development/etcd:v3.5.21 \
  etcdctl --endpoints="$ETCDCTL_ENDPOINTS" endpoint status --cluster -w table
sudo docker run --rm --network host \
  gcr.io/etcd-development/etcd:v3.5.21 \
  etcdctl --endpoints="$ETCDCTL_ENDPOINTS" endpoint health --cluster
sudo docker run --rm --network host \
  gcr.io/etcd-development/etcd:v3.5.21 \
  etcdctl --endpoints="$ETCDCTL_ENDPOINTS" member list -w table
unset ETCDCTL_ENDPOINTS
```

必須確認：

- 三個成員都是 started。
- endpoint health 全部成功。
- 只有一個 etcd leader。
- 所有成員的 Raft index 接近，沒有持續擴大的差距。

### Patroni 與 PostgreSQL

```bash
curl -fsS http://192.168.50.11:8008/patroni
curl -fsS http://192.168.50.12:8008/patroni
```

透過兩個寫入入口檢查目前連線均為 primary：

```bash
export PGPASSWORD='實際的_APP_PASSWORD'
psql -h 192.168.50.11 -p 5000 -U app -d appdb \
  -Atc 'SELECT NOT pg_is_in_recovery();'
psql -h 192.168.50.12 -p 5000 -U app -d appdb \
  -Atc 'SELECT NOT pg_is_in_recovery();'
```

兩次都應回傳 `t`。

建立探針資料：

```bash
psql -h 192.168.50.11 -p 5000 -U app -d appdb -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS ha_probe (
  id bigserial PRIMARY KEY,
  marker text UNIQUE NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
INSERT INTO ha_probe(marker) VALUES ('lan-deployment-probe');
SQL
```

由唯讀入口查詢：

```bash
psql -h 192.168.50.12 -p 5001 -U app -d appdb \
  -Atc "SELECT marker FROM ha_probe WHERE marker='lan-deployment-probe';"
psql -h 192.168.50.12 -p 5001 -U app -d appdb \
  -Atc 'SELECT pg_is_in_recovery();'
unset PGPASSWORD
```

應回傳探針值與 `t`。同步複寫設定不代表任意時間都一定有可用 replica；維護與故障期間仍需查看 Patroni 狀態。

### 故障演練

先確認備份可還原、觀測與管理連線正常，再於維護時段執行。

1. 記錄目前 primary 與 replica。
2. 寫入唯一探針值。
3. 停止 primary 上的 Patroni 容器，確認 replica 是否在 DCS 有多數票時提升。
4. 從存活主機的 `:5000` 寫入新探針值。
5. 重新啟動舊 primary，確認它以 replica 身分加入。
6. 檢查故障前後資料、timeline、複寫延遲與 HAProxy 健康狀態。
7. 類型 A 另行停止 witness，確認兩台資料庫主機仍可存取 etcd。
8. 類型 B 分別測試 `db1` 與 `db2` 失效，記錄不對稱結果。
9. 類型 C 由外部 etcd 管理方配合測試單一成員維護及失去多數票的處置。

舊 primary 若無法透過 `pg_rewind` 恢復，可能需要由目前 primary 重新初始化。執行 `patronictl reinit` 或刪除 PGDATA 前，必須先確認目標節點、目前 primary、備份與資料影響。

## 應用程式連線

目前範本沒有浮動 VIP。每台資料庫主機各有一個 HAProxy，因此應用程式需設定兩個寫入位址。支援 libpq 多主機語法的驅動程式可使用：

```text
host=192.168.50.11,192.168.50.12 port=5000,5000 dbname=appdb user=app target_session_attrs=read-write connect_timeout=3
```

密碼由應用程式的祕密管理系統提供，不放入 DSN 或版本控制。

不支援多主機語法的驅動程式需要外部負載平衡器、服務探索或受監控的 DNS/VIP。只部署兩個 HAProxy 容器不會自動產生單一高可用入口。

`:5001` 只路由到 replica，適合允許複寫延遲的讀取。需要 read-your-writes 或強一致讀取的請求應使用 `:5000`。

## 故障結果矩陣

| 情境 | 類型 A | 類型 B | 類型 C |
|---|---|---|---|
| PostgreSQL／Patroni 程序失效 | 有 etcd 多數票且 replica 合格時可故障轉移 | 相同 | 相同 |
| `db2` 整台失效 | `db1` + witness 有兩票 | `db1` 上 etcd1 + etcd3 有兩票 | 正常外部 etcd 可繼續提供 DCS |
| `db1` 整台失效 | `db2` + witness 有兩票 | 同時失去 etcd1 + etcd3，不能安全提升 | 正常外部 etcd 可繼續提供 DCS |
| witness 單獨失效 | etcd1 + etcd2 有兩票 | 不適用；witness 與 `db1` 共用故障域 | 由外部 etcd 管理方處理 |
| etcd 失去多數票 | 不進行新的安全選主；寫入可能停止 | 相同 | 相同 |
| 一台 HAProxy 失效 | 該入口失效，另一入口可用 | 相同 | 相同 |
| 網路分割 | 行為取決於 etcd 多數票位置與 Patroni TTL | 類型 B 會偏向 `db1` 所在分區 | 取決於資料庫節點到外部 etcd 的路徑 |

## 恢復與破壞性操作

### 一般停止

```bash
sudo docker compose --env-file PATH_TO_ENV -f PATH_TO_COMPOSE stop
```

此命令保留 bind-mounted 資料。

### 移除容器但保留資料

```bash
sudo docker compose --env-file PATH_TO_ENV -f PATH_TO_COMPOSE down
```

資料位於 `/srv/pgsql-ha/...`，不會因移除容器而自動刪除。

### 刪除資料

以下操作會永久刪除 PostgreSQL 或 etcd 狀態，不能用作一般重新啟動方法：

```bash
sudo rm -rf /srv/pgsql-ha/postgresql
sudo rm -rf /srv/pgsql-ha/etcd1
sudo rm -rf /srv/pgsql-ha/etcd2
sudo rm -rf /srv/pgsql-ha/etcd3
```

執行前必須確認主機、目錄、目前 primary、備份可還原性與 etcd member 狀態。不要同時刪除多個 etcd 成員資料，也不要在未知 PostgreSQL timeline 的情況下重新使用舊 PGDATA。

## 正式環境限制

`deploy/lan/` 是以目前實驗為依據的參考範本，尚未在三台獨立實體設備上完成驗證。正式環境至少還需處理：

- **TLS**：自建 etcd、PostgreSQL 與 Patroni REST 目前沒有完整 TLS 設定。
- **祕密管理**：`.env` 只適合受控測試；正式環境應使用 Docker secrets、Vault 或等效系統。
- **備份與還原**：同步／串流複寫不是備份，仍需 WAL 歸檔、PITR、異地備份與還原演練。
- **RPO**：`synchronous_mode: true` 且 `synchronous_mode_strict: false` 不保證所有故障情境都是 RPO 0。
- **RTO**：故障偵測、Patroni TTL、複寫延遲、資料量與重新初始化時間都會影響恢復時間。
- **Fencing**：Patroni + etcd 可降低雙 primary 風險，但本範本沒有獨立帶外 fencing。
- **單一入口**：沒有 Keepalived、VIP、受監控 DNS 或獨立負載平衡器。
- **監控**：尚未提供 PostgreSQL、Patroni、etcd、HAProxy、磁碟與備份告警。
- **升級**：尚未提供 PostgreSQL 大版本、Patroni、etcd 或容器映像的滾動升級程序。
- **容量與延遲**：未替特定硬體、交易量或區域網路延遲提供容量保證。範本的 `wal_keep_size: 256MB` 只提供小型部署起始值，必須依 WAL 產生速率、replica 最長離線時間與 replication slot 監控結果調整。
- **跨機房容災**：三個區域網路節點不能替代異地災難復原。
- **外部 etcd 共用風險**：其他系統的負載、維護或權限錯誤可能同時影響 Patroni。

## 範本靜態驗證

```bash
make deploy-lint
```

此命令解析六份 Compose 設定與所有部署 YAML，確認必要檔案存在，並拒絕實驗預設密碼出現在實機範本中。它不能替代實體主機、網路分割、磁碟故障或還原演練。

## 實驗預設憑證

只供 Lima/containerlab 實驗使用：

```text
PostgreSQL superuser: postgres / postgres
Application user: app / apppass
Replication user: replicator / replicator
Database: appdb
```

實機範本使用 `CHANGE_ME_...` 標記，部署前必須替換。正式密碼、private key 與 `.env` 不得提交到版本控制。
