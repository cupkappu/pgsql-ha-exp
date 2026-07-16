# PostgreSQL 雙節點手動切換 Docker Compose 演示

此目錄在單一 Docker daemon 內建立兩個 PostgreSQL 16 節點，用於演示串流複寫、人工提升、端點切換及舊 primary 重建。

此環境沒有 Patroni、etcd、Pacemaker、HAProxy 或 VIP。應用程式直接連接目前的 primary port。角色切換後，連線端點需要人工更新。

將既有單節點 Docker Compose PostgreSQL 擴展到兩台實體主機的流程位於根 [`README.md`](../README.md)，章節名稱為「將現有 Docker Compose 單節點擴展為雙機手動主備」。

## 拓撲

```text
Docker host
├── db1  172.31.121.11:5432  -> 127.0.0.1:35432
└── db2  172.31.121.12:5432  -> 127.0.0.1:45432
```

首次啟動的角色如下：

```text
db1  primary
db2  standby
```

資料儲存在兩個 named volume：

```text
pgsql-manual-demo-db1-data
pgsql-manual-demo-db2-data
```

`make manual-demo-down` 保留資料。`make manual-demo-clean` 刪除容器、網路及兩個資料 volume。

## 執行條件

需要 Docker Engine 及 Docker Compose plugin：

```bash
docker version
docker compose version
```

本機需要空出的 TCP port：

```text
35432
45432
```

實際 port 名稱為 `35432` 與 `45432`。若本機已有服務占用，建立 `manual-demo/.env` 並修改 `DB1_PORT`、`DB2_PORT`。

## 設定

未建立 `.env` 時，腳本直接使用 `manual-demo/.env.example`：

```dotenv
POSTGRES_IMAGE=postgres:16-bookworm
POSTGRES_DB=appdb
POSTGRES_PASSWORD=postgres
APP_PASSWORD=apppass
REPLICATION_PASSWORD=replicator
DB1_PORT=35432
DB2_PORT=45432
```

自訂設定：

```bash
cp manual-demo/.env.example manual-demo/.env
chmod 0600 manual-demo/.env
```

`.env` 由 shell 與 Docker Compose 共同讀取。密碼包含空白或 shell 特殊字元時，需要使用符合 shell 語法的引號。

## 首次啟動

```bash
make manual-demo-up
```

此命令依序執行：

1. 驗證 `manual-demo/compose.yml`。
2. 啟動 db1，建立 `appdb`、`app`、`replicator`。
3. 在 db1 的 `pg_hba.conf` 加入演示網段的複寫規則。
4. 使用 `pg_basebackup -R` 將 db1 複製到 db2。
5. 啟動 db2，等待一個 primary 與一個 standby。

既有 volume 再次啟動時，腳本保留現有角色。若兩個 volume 同時處於 primary 狀態，啟動檢查會失敗，需要先確認資料分支，再重建其中一個節點。

## 查看狀態

```bash
make manual-demo-status
```

輸出包含容器狀態、節點角色、客戶端 port、`pg_stat_replication` 與 `pg_stat_wal_receiver`。

首次啟動的預期角色：

```text
NODE ROLE      CONTAINER    CLIENT_PORT
db1  primary   running      35432
db2  standby   running      45432
```

## 連線

連接 db1：

```bash
PGPASSWORD=apppass psql \
  -h 127.0.0.1 -p 35432 \
  -U app -d appdb
```

連接 db2：

```bash
PGPASSWORD=apppass psql \
  -h 127.0.0.1 -p 45432 \
  -U app -d appdb
```

查詢目前角色：

```sql
SELECT inet_server_addr(), pg_is_in_recovery();
```

`pg_is_in_recovery() = false` 表示 primary；`true` 表示 standby。standby 允許唯讀查詢，寫入會被 PostgreSQL 拒絕。

## 驗證複寫

在 primary 建立資料：

```sql
CREATE TABLE IF NOT EXISTS ha_test (
  id bigserial PRIMARY KEY,
  phase text NOT NULL,
  payload text NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO ha_test (phase, payload)
VALUES ('before-switch', 'row-before-switch');
```

在 standby 查詢：

```sql
SELECT * FROM ha_test ORDER BY id;
```

自動 smoke test：

```bash
make manual-demo-smoke
```

此測試寫入隨機 marker，等待 standby 查到相同資料，並確認 primary 的 `pg_stat_replication` 存在一個 `streaming` 連線。

## 計畫內切換

先確認 db1 為 primary、db2 為 standby：

```bash
make manual-demo-status
```

從 db1 切到 db2：

```bash
make manual-demo-switch FROM=db1 TO=db2
```

切換腳本執行以下流程：

1. 在 db1 執行 `CHECKPOINT` 與 `pg_switch_wal()`。
2. 等待 db2 replay 到指定 WAL LSN。
3. 停止 db1 容器。
4. 在 db2 執行 `pg_ctl promote -w`。

切換完成後，應用程式寫入端點改為：

```text
127.0.0.1:45432
```

此時 db1 維持停止狀態。將 db1 重新建立為 standby：

```bash
make manual-demo-rejoin NODE=db1
```

`rejoin` 會刪除 db1 volume 內的舊資料，以 db2 執行新的 `pg_basebackup -R`，再啟動 db1。這項操作會覆蓋 db1 原有資料分支。

最終角色：

```text
db1  standby
db2  primary
```

切回 db1：

```bash
make manual-demo-switch FROM=db2 TO=db1
make manual-demo-rejoin NODE=db2
```

## primary 故障後提升 standby

先取得目前角色：

```bash
make manual-demo-status
```

假設 db1 為 primary，停止 db1：

```bash
docker compose \
  --env-file manual-demo/.env.example \
  -f manual-demo/compose.yml \
  stop db1
```

使用 `manual-demo/.env` 時，將上面的 env file 改為該檔案。

確認 db1 已停止：

```bash
make manual-demo-status
```

提升 db2：

```bash
make manual-demo-promote NODE=db2
```

提升命令會檢查 db2 原本是 standby，並檢查 db1 已停止。檢查通過後才執行 promote。

應用程式端點改為：

```text
127.0.0.1:45432
```

舊 db1 恢復後，直接執行重建：

```bash
make manual-demo-rejoin NODE=db1
```

不要直接啟動 db1 的舊資料。舊 primary 可能保留獨立 WAL 歷史；直接啟動會形成雙 primary。

## 自動故障切換驗收

```bash
make manual-demo-failover
```

測試流程：

1. 找出目前 primary 與 standby。
2. 在 primary 寫入故障前 marker，等待 standby 收到。
3. 停止 primary 容器。
4. 提升 standby。
5. 在新 primary 寫入故障後 marker。
6. 從新 primary 重建舊 primary。
7. 驗證兩筆 marker 均存在，並確認角色回到一主一備。

完整驗收：

```bash
make manual-demo-test
```

此命令執行啟動、smoke test 與 failover test。failover test 完成後，primary 角色會移到原 standby。

## 停止、重啟與清理

停止容器並保留資料：

```bash
make manual-demo-down
```

使用現有資料重新啟動：

```bash
make manual-demo-up
```

刪除全部演示資料：

```bash
make manual-demo-clean
```

確認 volume：

```bash
docker volume ls --filter name=pgsql-manual-demo
docker volume inspect pgsql-manual-demo-db1-data
docker volume inspect pgsql-manual-demo-db2-data
```

## 一致性範圍

此演示使用非同步串流複寫。計畫內切換會等待 standby replay 到切換 LSN。primary 突然停止時，尚未傳送或尚未 replay 的交易可能遺失。

雙節點環境沒有 quorum、fencing 服務與自動 leader election。提升操作依賴人工確認舊 primary 已停止。實體雙機部署需要同樣的停止確認，或使用可驗證的電源隔離機制。

串流複寫保存的是可用副本。備份、時間點復原及 WAL 歸檔需要獨立配置。

## 常用命令

| 命令 | 功能 |
|---|---|
| `make manual-demo-up` | 初始化或啟動一主一備 |
| `make manual-demo-status` | 顯示容器、角色與複寫狀態 |
| `make manual-demo-smoke` | 驗證寫入與串流複寫 |
| `make manual-demo-switch FROM=db1 TO=db2` | 執行計畫內切換 |
| `make manual-demo-promote NODE=db2` | 在舊 primary 已停止後提升 standby |
| `make manual-demo-rejoin NODE=db1` | 從目前 primary 重建指定節點 |
| `make manual-demo-failover` | 執行停止、提升、寫入及重建測試 |
| `make manual-demo-test` | 執行完整驗收 |
| `make manual-demo-down` | 停止並保留資料 |
| `make manual-demo-clean` | 刪除全部演示資料 |
