# Patroni 區域網路實機部署範本 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 將 README 改寫為繁體中文，修正目前三成員 etcd 實驗描述，並新增三種 Ubuntu 24.04 LTS 實機 Docker Compose 部署範本。

**Architecture:** 兩台資料庫主機都以 host network 執行 PostgreSQL 16／Patroni／HAProxy；自建 DCS 時每台資料庫主機各有一個 etcd 成員。第三票可位於獨立 witness、與 db1 共置，或由既有外部三成員 etcd 提供。範本以個別 Compose 檔和 Patroni YAML 表達，不引入 Swarm、Keepalived 或未驗證的自動部署程式。

**Tech Stack:** Markdown、Docker Compose、PostgreSQL 16、Patroni 4.1.4、etcd 3.5.21、HAProxy 3.0、Bash、Python/PyYAML。

**工作樹限制：** `/Users/kifuko/dev/pgsql-ha-exp` 沒有 `.git`，因此本計畫不能建立工作樹或提交。每項工作以檔案清單與驗證命令記錄狀態；若後續恢復 Git metadata，再依工作項目建立提交。

---

## 檔案責任

- `README.md`：繁體中文專案入口、已驗證實驗狀態、三種實機拓撲、部署程序、結果與限制。
- `deploy/lan/haproxy.cfg`：兩個資料庫節點共用的讀寫路由與 Patroni REST 健康檢查。
- `deploy/lan/db1/*`：類型 A／B 的 db1 Compose、Patroni 設定與環境變數範例。
- `deploy/lan/db2/*`：類型 A／B 的 db2 Compose、Patroni 設定與環境變數範例。
- `deploy/lan/witness/*`：類型 A 的獨立 etcd3。
- `deploy/lan/colocated-witness/*`：類型 B 的共置 etcd3，使用 2479/2480。
- `deploy/lan/external-etcd/*`：類型 C 的 db1/db2 Compose、Patroni 設定與環境變數範例，不啟動本機 etcd。
- `tests/deploy-templates.sh`：Compose 解析、YAML 解析、必要檔案與敏感預設值檢查。

### Task 1: 建立會先失敗的部署範本檢查

**Files:**
- Create: `tests/deploy-templates.sh`
- Modify: `Makefile`

- [ ] **Step 1: 建立檔案存在性與語法檢查**

建立 `tests/deploy-templates.sh`：

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

required=(
  deploy/lan/haproxy.cfg
  deploy/lan/db1/compose.yml
  deploy/lan/db1/patroni.yml
  deploy/lan/db1/.env.example
  deploy/lan/db2/compose.yml
  deploy/lan/db2/patroni.yml
  deploy/lan/db2/.env.example
  deploy/lan/witness/compose.yml
  deploy/lan/witness/.env.example
  deploy/lan/colocated-witness/compose.yml
  deploy/lan/colocated-witness/.env.example
  deploy/lan/external-etcd/db1.compose.yml
  deploy/lan/external-etcd/db1.patroni.yml
  deploy/lan/external-etcd/db2.compose.yml
  deploy/lan/external-etcd/db2.patroni.yml
  deploy/lan/external-etcd/.env.db1.example
  deploy/lan/external-etcd/.env.db2.example
)

for path in "${required[@]}"; do
  [[ -f "$path" ]] || { echo "missing: $path" >&2; exit 1; }
done

compose_cases=(
  'deploy/lan/db1/compose.yml|deploy/lan/db1/.env.example'
  'deploy/lan/db2/compose.yml|deploy/lan/db2/.env.example'
  'deploy/lan/witness/compose.yml|deploy/lan/witness/.env.example'
  'deploy/lan/colocated-witness/compose.yml|deploy/lan/colocated-witness/.env.example'
  'deploy/lan/external-etcd/db1.compose.yml|deploy/lan/external-etcd/.env.db1.example'
  'deploy/lan/external-etcd/db2.compose.yml|deploy/lan/external-etcd/.env.db2.example'
)

for item in "${compose_cases[@]}"; do
  compose="${item%%|*}"
  env_file="${item##*|}"
  docker compose --env-file "$env_file" -f "$compose" config --quiet
  echo "valid compose: $compose"
done

python3 - <<'PY'
from pathlib import Path
import yaml

for path in Path('deploy/lan').rglob('*.yml'):
    with path.open(encoding='utf-8') as stream:
        yaml.safe_load(stream)
    print(f'valid yaml: {path}')
PY

if grep -RInE '(postgres / postgres|app / apppass|replicator / replicator)' deploy/lan; then
  echo 'deploy templates contain laboratory credentials' >&2
  exit 1
fi

echo '[PASS] deployment templates passed static validation'
```

- [ ] **Step 2: 賦予執行權限並確認檢查先失敗**

Run:

```bash
chmod 0755 tests/deploy-templates.sh
bash tests/deploy-templates.sh
```

Expected: FAIL，第一個訊息為 `missing: deploy/lan/haproxy.cfg`。

- [ ] **Step 3: 加入 Make 目標**

將 `Makefile` 的 `.PHONY` 加入 `deploy-lint`，並新增：

```make
deploy-lint:
	bash tests/deploy-templates.sh
```

### Task 2: 建立類型 A／B 共用的資料庫節點範本

**Files:**
- Create: `deploy/lan/haproxy.cfg`
- Create: `deploy/lan/db1/compose.yml`
- Create: `deploy/lan/db1/patroni.yml`
- Create: `deploy/lan/db1/.env.example`
- Create: `deploy/lan/db2/compose.yml`
- Create: `deploy/lan/db2/patroni.yml`
- Create: `deploy/lan/db2/.env.example`

- [ ] **Step 1: 建立共用 HAProxy 設定**

使用 `192.168.50.11:5432/8008` 與 `192.168.50.12:5432/8008` 為後端；寫入 listener 綁定 `:5000` 並檢查 `/primary`，唯讀 listener 綁定 `:5001` 並檢查 `/replica`。保留目前實驗的 TCP timeout、fall/rise 與 `shutdown-sessions` 行為。

- [ ] **Step 2: 建立 db1/db2 Compose**

每份 Compose 包含三個服務：

```yaml
services:
  etcd:
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
    build:
      context: ../../..
      dockerfile: images/patroni/Dockerfile
    image: pgsql-ha-patroni:local
    restart: unless-stopped
    network_mode: host
    environment:
      PATRONI_SUPERUSER_PASSWORD: ${POSTGRES_SUPERUSER_PASSWORD:?set POSTGRES_SUPERUSER_PASSWORD}
      PATRONI_REPLICATION_PASSWORD: ${POSTGRES_REPLICATION_PASSWORD:?set POSTGRES_REPLICATION_PASSWORD}
    volumes:
      - ${PGDATA_DIR:?set PGDATA_DIR}:/var/lib/postgresql/data
      - ./patroni.yml:/etc/patroni.yml:ro
    command: [/etc/patroni.yml]
  haproxy:
    image: haproxy:3.0-alpine
    restart: unless-stopped
    network_mode: host
    volumes:
      - ../haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
```

db1 使用 `ETCD_NAME=etcd1`、`NODE_IP=192.168.50.11`；db2 使用 `ETCD_NAME=etcd2`、`NODE_IP=192.168.50.12`。兩份 `.env.example` 的 `ETCD_INITIAL_CLUSTER` 預設指向類型 A：

```text
etcd1=http://192.168.50.11:2380,etcd2=http://192.168.50.12:2380,etcd3=http://192.168.50.13:2380
```

密碼值使用 `CHANGE_ME_...`，不得使用實驗預設密碼。

- [ ] **Step 3: 建立兩份 Patroni 設定**

沿用實驗的 scope、同步模式、資料檢查碼、`pg_rewind`、複寫槽與 PostgreSQL 16 路徑。實機時間參數使用 `ttl: 30`、`loop_wait: 10`、`retry_timeout: 10`，符合 Patroni validator 的最低 TTL 與時間關係限制；兩個節點的差異僅為節點名稱與 connect address：

```yaml
scope: pgsql-ha
namespace: /service/
name: pg1 # db2 為 pg2
restapi:
  listen: 0.0.0.0:8008
  connect_address: 192.168.50.11:8008 # db2 為 .12
etcd3:
  hosts:
    - 192.168.50.11:2379
    - 192.168.50.12:2379
    - 192.168.50.13:2379
```

`pg_hba` 只允許 `192.168.50.0/24`，不沿用實驗的 `0.0.0.0/0`。

- [ ] **Step 4: 執行局部驗證**

Run:

```bash
docker compose --env-file deploy/lan/db1/.env.example -f deploy/lan/db1/compose.yml config --quiet
docker compose --env-file deploy/lan/db2/.env.example -f deploy/lan/db2/compose.yml config --quiet
python3 - <<'PY'
import yaml
for path in ('deploy/lan/db1/patroni.yml', 'deploy/lan/db2/patroni.yml'):
    with open(path, encoding='utf-8') as f:
        yaml.safe_load(f)
    print(path)
PY
```

Expected: 所有命令 exit 0，輸出兩個 Patroni 路徑。

### Task 3: 建立獨立與共置 witness 範本

**Files:**
- Create: `deploy/lan/witness/compose.yml`
- Create: `deploy/lan/witness/.env.example`
- Create: `deploy/lan/colocated-witness/compose.yml`
- Create: `deploy/lan/colocated-witness/.env.example`

- [ ] **Step 1: 建立類型 A witness**

使用 etcd3、`192.168.50.13:2379/2380`、與 db1/db2 相同的 `ETCD_INITIAL_CLUSTER` 和 cluster token。資料保存至 `${ETCD_DATA_DIR}`。

- [ ] **Step 2: 建立類型 B 共置 witness**

使用 etcd3、`192.168.50.11:2479/2480`，listen client URLs 為 `http://0.0.0.0:2479`，listen peer URLs 為 `http://0.0.0.0:2480`。三個成員的 initial cluster 必須完全一致：

```text
etcd1=http://192.168.50.11:2380,etcd2=http://192.168.50.12:2380,etcd3=http://192.168.50.11:2480
```

README 必須要求在第一次啟動前同步修改 db1、db2 的 `.env`；已初始化的 etcd data-dir 不得只靠修改 `--initial-cluster` 改變成員關係。

- [ ] **Step 3: 執行 witness Compose 驗證**

Run:

```bash
docker compose --env-file deploy/lan/witness/.env.example -f deploy/lan/witness/compose.yml config --quiet
docker compose --env-file deploy/lan/colocated-witness/.env.example -f deploy/lan/colocated-witness/compose.yml config --quiet
```

Expected: exit 0。

### Task 4: 建立外部 etcd 範本

**Files:**
- Create: `deploy/lan/external-etcd/db1.compose.yml`
- Create: `deploy/lan/external-etcd/db1.patroni.yml`
- Create: `deploy/lan/external-etcd/db2.compose.yml`
- Create: `deploy/lan/external-etcd/db2.patroni.yml`
- Create: `deploy/lan/external-etcd/.env.db1.example`
- Create: `deploy/lan/external-etcd/.env.db2.example`

- [ ] **Step 1: 建立不含 etcd 服務的 Compose**

每台主機只包含 Patroni 與 HAProxy。Patroni 仍使用 host network、bind-mounted PGDATA、`PATRONI_SUPERUSER_PASSWORD` 與 `PATRONI_REPLICATION_PASSWORD`。可選 TLS 目錄以唯讀方式掛載：

```yaml
volumes:
  - ${PGDATA_DIR:?set PGDATA_DIR}:/var/lib/postgresql/data
  - ./db1.patroni.yml:/etc/patroni.yml:ro
  - ${ETCD_PKI_DIR:-/etc/pgsql-ha/etcd-pki}:/etc/etcd/pki:ro
```

- [ ] **Step 2: 建立外部端點 Patroni 設定**

預設測試端點為：

```yaml
etcd3:
  hosts:
    - 192.168.50.21:2379
    - 192.168.50.22:2379
    - 192.168.50.23:2379
```

在同一位置加入註解化 TLS 範例，使用 Patroni 官方參數 `protocol: https`、`cacert`、`cert`、`key`。README 說明啟用 TLS 時需把端點、憑證 SAN、檔案權限與外部 etcd 認證一併調整。

- [ ] **Step 3: 執行外部 etcd Compose 驗證**

Run:

```bash
docker compose --env-file deploy/lan/external-etcd/.env.db1.example -f deploy/lan/external-etcd/db1.compose.yml config --quiet
docker compose --env-file deploy/lan/external-etcd/.env.db2.example -f deploy/lan/external-etcd/db2.compose.yml config --quiet
```

Expected: exit 0。

### Task 5: 將 README 改寫為繁體中文並對齊倉庫狀態

**Files:**
- Modify: `README.md`

- [ ] **Step 1: 寫入實驗現況與證據**

README 必須使用以下主結構：

```markdown
# PostgreSQL 兩主機 HA 實驗

## 專案狀態
## 實驗一：Patroni、etcd 與 HAProxy
### 模擬拓撲
### 已驗證結果
### 使用方式
### 測試內容
## 實驗二：Pacemaker 與 Corosync
## 實機部署：共同前提
## 類型 A：獨立 etcd witness
## 類型 B：第三個 etcd 與 db1 共置
## 類型 C：外部 etcd 叢集
## 驗證部署結果
## 應用程式連線
## 故障結果矩陣
## 恢復與破壞性操作
## 正式環境限制
## 實驗預設憑證
```

明確記錄 2026-07-15 的 `make status`、`make smoke` 與 `make patroni-test` 結果；不得聲稱 Pacemaker 實驗或實機範本已在實體主機通過。

- [ ] **Step 2: 寫入 Ubuntu 24.04 LTS 前提與網路程序**

包含固定 IP、唯一 hostname、NTP、Docker Engine/Compose、資料磁碟、至少三個 etcd 故障域的含義，以及下列連接埠：

| 連接埠 | 來源 | 用途 |
|---|---|---|
| 2379/TCP | Patroni 與管理端 | etcd client |
| 2380/TCP | etcd 成員 | etcd peer |
| 2479/TCP | Patroni 與管理端 | 共置 etcd3 client |
| 2480/TCP | etcd 成員 | 共置 etcd3 peer |
| 5432/TCP | db1、db2 與受控管理端 | PostgreSQL 複寫與直接管理 |
| 8008/TCP | db1、db2 | Patroni REST／HAProxy 健康檢查 |
| 5000/TCP | 應用程式 | PostgreSQL 寫入入口 |
| 5001/TCP | 允許最終一致讀取的客戶端 | replica 唯讀入口 |

- [ ] **Step 3: 寫入三種拓撲的逐步命令**

每種程序都包含：複製 `.env.example`、替換 IP/密碼、建立資料目錄、建立 Patroni 映像、依序啟動 etcd/Patroni/HAProxy、健康檢查、角色檢查、資料寫入與副本讀取。類型 C 先以 `etcdctl endpoint health` 驗證外部端點，再啟動 Patroni。

- [ ] **Step 4: 寫入連線、故障與限制**

應用程式寫入 DSN 範例：

```text
host=192.168.50.11,192.168.50.12 port=5000,5000 dbname=appdb user=app target_session_attrs=read-write connect_timeout=3
```

說明驅動程式必須支援 libpq 多主機語法；否則需要外部負載平衡器。故障矩陣需與設計規格一致，並列出 TLS、祕密管理、WAL/PITR、備份還原、監控、升級、單一入口、跨機房與 fencing 限制。

- [ ] **Step 5: 搜尋繁簡與過時敘述**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
text = Path('README.md').read_text(encoding='utf-8')
for word in ('两主机', '两成员', '法定人数', '凭据', '验证内容', '默认'):
    assert word not in text, word
for required in ('三成員', '外部 etcd', '共置', '獨立 witness', 'make patroni-test'):
    assert required in text, required
print('README language and required sections: PASS')
PY
```

Expected: `README language and required sections: PASS`。

### Task 6: 執行完整靜態與實驗驗證

**Files:**
- Verify: all files above

- [ ] **Step 1: 執行部署範本檢查**

Run:

```bash
make deploy-lint
```

Expected: 六個 Compose 檔均顯示 `valid compose`、所有 YAML 顯示 `valid yaml`，最後為 `[PASS] deployment templates passed static validation`。

- [ ] **Step 2: 檢查 README 引用路徑**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
import re
text = Path('README.md').read_text(encoding='utf-8')
paths = sorted(set(re.findall(r'`((?:deploy|scripts|tests|config|images)/[^` ]+)`', text)))
missing = [path for path in paths if not Path(path).exists()]
print(f'referenced paths: {len(paths)}')
assert not missing, missing
PY
```

Expected: exit 0，`missing` 為空。

- [ ] **Step 3: 再次驗證現有實驗**

Run:

```bash
make status
make smoke
```

Expected: etcd 顯示三個健康成員；Patroni 顯示一個 primary 和一個 replica；smoke 結尾為 `[PASS] smoke test passed`。

- [ ] **Step 4: 檢查檔案與空白字元**

Run:

```bash
python3 - <<'PY'
from pathlib import Path
roots = [Path('README.md'), Path('Makefile'), Path('deploy/lan'), Path('tests/deploy-templates.sh'), Path('docs/superpowers')]
files = []
for root in roots:
    files.extend(root.rglob('*') if root.is_dir() else [root])
for path in files:
    if not path.is_file():
        continue
    data = path.read_bytes()
    assert data.endswith(b'\n'), f'no final newline: {path}'
    for number, line in enumerate(data.decode('utf-8').splitlines(), 1):
        assert line == line.rstrip(), f'trailing whitespace: {path}:{number}'
print(f'checked files: {len(files)}')
PY
```

Expected: exit 0 並輸出檢查檔案數量。

- [ ] **Step 5: 記錄完成狀態與剩餘限制**

完成報告必須列出：文件盤點數量、排除目錄、狀態來源、修改／新增檔案、驗證命令與結果、工作目錄沒有 `.git`、實機範本尚未在三台獨立設備執行，以及正式環境仍需處理的安全與營運項目。
