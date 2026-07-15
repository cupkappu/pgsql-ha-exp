# Patroni 區域網路實機部署文件設計

日期：2026-07-15

## 目的

將現有 PostgreSQL 高可用實驗的主 README 改寫為繁體中文，依目前倉庫設定修正過時描述，並提供 Ubuntu 24.04 LTS 上可實際套用的 Docker Compose 部署範本。

文件只把 Lima/containerlab 中已執行的內容描述為「已驗證」。實體區域網路部署範本會標示為參考部署，直到它在獨立實體主機上完成驗證。

## 現況依據

目前倉庫只有一份讀者文件 `README.md`。狀態來源包括：

- `topology.clab.yml`
- `config/patroni/pg1.yml` 與 `config/patroni/pg2.yml`
- `config/haproxy.cfg`
- `scripts/lab-up.sh`、`scripts/host-stack.sh`、`scripts/lib.sh`
- `tests/smoke.sh`、`tests/failover-process.sh`、`tests/host-failover.sh`、`tests/witness-failure.sh`、`tests/two-node-limit.sh`
- `topology-pacemaker.clab.yml` 與 `scripts/pcmk-*.sh`
- 2026-07-15 執行的 `make status`、`make smoke` 與 `make patroni-test`

執行結果顯示：

- 兩個獨立 Docker daemon 均正常。
- etcd 叢集有三個成員，第三個成員是 witness。
- Patroni 形成一個 primary 與一個 replica。
- smoke、PostgreSQL 程序故障轉移、witness 故障及整台資料庫主機故障測試均通過。
- `make patroni-test` 結束狀態為 `0`。

原 README 所稱「兩成員 etcd」已與目前拓撲不符，必須修正。Pacemaker 相關檔案存在，但不描述為已完成驗證的實驗。

## 範例網路

| 節點 | 位址 | 服務 |
|---|---:|---|
| `db1` | `192.168.50.11` | PostgreSQL 16、Patroni、HAProxy、etcd1 |
| `db2` | `192.168.50.12` | PostgreSQL 16、Patroni、HAProxy、etcd2 |
| `witness` | `192.168.50.13` | etcd3 |
| `etcd-ext-1` | `192.168.50.21` | 外部 etcd 成員 1 |
| `etcd-ext-2` | `192.168.50.22` | 外部 etcd 成員 2 |
| `etcd-ext-3` | `192.168.50.23` | 外部 etcd 成員 3 |

所有位址均為文件範例。使用者必須依現場網段修改設定，並確保位址固定、主機間時鐘同步及必要連接埠可達。

## 支援的三種拓撲

### 類型 A：兩台資料庫主機加獨立 witness

- `db1` 執行 PostgreSQL、Patroni、HAProxy、etcd1。
- `db2` 執行 PostgreSQL、Patroni、HAProxy、etcd2。
- 第三台小型主機或 VM 執行 etcd3。
- 任一資料庫主機失效時，另一台資料庫主機與 witness 可保有 2/3 多數票。
- witness 單獨失效時，兩台資料庫主機仍可保有 2/3 多數票。

這是文件推薦的自建 etcd 拓撲。

### 類型 B：第三個 etcd 與 db1 共置

- `db1` 同時執行 etcd1 與 etcd3。
- etcd3 使用 `192.168.50.11:2479` 作為 client URL，使用 `192.168.50.11:2480` 作為 peer URL。
- `db2` 執行 etcd2。
- `db2` 失效時，`db1` 上兩個成員仍可形成多數票。
- `db1` 失效時會同時失去兩票，`db2` 無法形成多數票，Patroni 不應自行提升副本。

此拓撲只適合接受不對稱故障容忍的環境，不能描述為可容忍任一主機失效。

### 類型 C：既有外部 etcd 叢集

- `db1`、`db2` 不執行 etcd。
- Patroni 連接既有、獨立、至少三成員的外部 etcd 叢集。
- 範例端點為 `192.168.50.21:2379`、`192.168.50.22:2379`、`192.168.50.23:2379`。
- 範本提供明文測試連線與 TLS 參數說明；正式環境以啟用雙向 TLS 與最小權限認證為目標。
- 外部 etcd 的營運責任必須明確包含多數票、容量、延遲、監控、備份、升級、憑證與存取控制。
- 不假定任意既有 etcd 都適合共用。文件會要求評估命名空間、租約負載、延遲與共用故障影響。

外部 etcd 若只有一個成員，或所有成員位於同一故障域，仍不能提供所需的 DCS 可用性。

## 部署實作形式

實機範本以 Ubuntu 24.04 LTS、Docker Engine 與 Docker Compose Plugin 為基礎。跨主機服務使用 host network，不引入 Docker Swarm 或 overlay network。

預計檔案：

```text
deploy/lan/
├── db1/
│   ├── compose.yml
│   ├── patroni.yml
│   └── .env.example
├── db2/
│   ├── compose.yml
│   ├── patroni.yml
│   └── .env.example
├── witness/
│   ├── compose.yml
│   └── .env.example
├── colocated-witness/
│   ├── compose.yml
│   └── .env.example
├── external-etcd/
│   ├── db1.compose.yml
│   ├── db1.patroni.yml
│   ├── db2.compose.yml
│   ├── db2.patroni.yml
│   ├── .env.db1.example
│   └── .env.db2.example
└── haproxy.cfg
```

範本使用現有 `images/patroni/Dockerfile` 建立 Patroni 映像，etcd 與 HAProxy 版本與實驗設定保持一致。資料目錄使用主機 bind mount，避免把正式資料保存在容器可寫層。

`.env.example` 只包含範例或明確的替換值。README 要求使用者建立不納入版本控制的 `.env`，設定 PostgreSQL superuser、複寫帳號與應用程式密碼。

## README 結構

1. 專案目的與實驗狀態。
2. Lima/containerlab 模擬拓撲。
3. 第一個實驗已驗證內容與實際結果。
4. 現有 Make 目標與清理行為。
5. 三種區域網路實機拓撲比較。
6. Ubuntu 24.04 LTS 前提、固定 IP、時間同步、防火牆與安裝程序。
7. 類型 A 的完整部署程序。
8. 類型 B 的差異程序及不對稱限制。
9. 類型 C 的外部 etcd 接入程序、TLS 與營運責任。
10. etcd、Patroni、PostgreSQL、HAProxy 的驗證命令。
11. 應用程式連線方式。
12. 故障情境、預期結果與恢復方式。
13. 安全、資料保護及正式環境限制。
14. 實驗預設憑證與禁止沿用警告。

## 啟動與資料流程

建議啟動順序：

1. 完成主機名稱、固定 IP、時間同步、防火牆及 Docker 安裝。
2. 建立資料目錄並設定權限。
3. 啟動三個 etcd 成員，確認 endpoint health 與 member list。
4. 啟動 `db1` Patroni，等待初始 primary 建立。
5. 啟動 `db2` Patroni，等待其由 primary 建立 replica。
6. 啟動兩台 HAProxy。
7. 建立應用程式角色與資料庫。
8. 從兩個 HAProxy 寫入端點測試目前 primary。
9. 寫入測試資料並由 replica 讀取。

HAProxy 寫入端點使用 Patroni `/primary` 健康檢查；唯讀端點使用 `/replica`。目前設計不提供浮動 VIP。應用程式需支援兩個 HAProxy 位址，或由外部負載平衡器提供單一入口。

## 故障結果

| 情境 | 類型 A | 類型 B | 類型 C |
|---|---|---|---|
| PostgreSQL／Patroni 程序失效 | 副本可在 DCS 有多數票時提升 | 相同 | 相同 |
| `db2` 整台失效 | `db1` 與 witness 保有多數票 | `db1` 上兩票保有多數票 | 由外部 etcd 狀態決定，正常三成員時可切換 |
| `db1` 整台失效 | `db2` 與 witness 保有多數票 | 失去兩票，不能自動提升 | 由外部 etcd 狀態決定，正常三成員時可切換 |
| witness 單獨失效 | 兩個資料庫主機仍有多數票 | 不適用，witness 與 db1 同一故障域 | 由外部 etcd 管理方處理 |
| etcd 失去多數票 | 不進行新的安全選主 | 不進行新的安全選主 | 不進行新的安全選主 |
| HAProxy 所在主機失效 | 該入口失效，另一入口仍可用 | 相同 | 相同 |

文件不保證零資料遺失。同步複寫的實際 RPO 取決於 Patroni 同步模式、同步副本狀態、交易確認時點及故障方式。

## 安全與正式環境限制

範本不等同完整正式環境方案。README 必須列出未涵蓋項目：

- PostgreSQL、Patroni REST API 與自建 etcd 的完整 TLS。
- Docker secrets、Vault 或其他祕密管理。
- WAL 歸檔、PITR、異地備份與定期還原演練。
- 監控、告警、容量規劃、稽核記錄及憑證輪替。
- 自動化作業系統更新與版本升級策略。
- 獨立 HAProxy、Keepalived、VIP 或 DNS 健康切換。
- 跨機房容災。
- 網路分割情境中的完整 fencing。

清除資料目錄、重建 etcd 成員或重建 Patroni scope 都是破壞性操作，文件必須把資料影響寫在指令之前。

## 驗證計畫

文件與範本完成後執行：

1. 對所有 Compose 檔執行 `docker compose config`。
2. 解析所有 YAML，確認語法有效。
3. 確認 README 引用的檔案均存在。
4. 搜尋遺留的簡體中文與過時的兩成員 etcd 描述。
5. 再次執行 `make status` 與 `make smoke`，確認文件變更未影響現有實驗。
6. 檢查檔案尾端換行、空白字元及預期變更清單。

目前工作目錄不是 Git 工作樹，因此無法建立規格提交，也無法執行 `git diff --check`。這項限制會在完成報告中明確列出。

## 完成條件

- README 全文使用繁體中文。
- README 的實驗拓撲與目前三成員 etcd 設定一致。
- README 清楚區分已驗證的模擬實驗與尚未經實體機器驗證的部署範本。
- 三種實機拓撲均有前提、程序、驗證、故障結果與限制。
- Compose 與 YAML 範本通過靜態驗證。
- 所有憑證與密碼均標示為範例，不可直接用於正式環境。
