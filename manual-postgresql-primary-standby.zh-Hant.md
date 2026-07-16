# 兩台 PostgreSQL 主備與手動切換實驗

## 拓撲

```text
db1  172.31.120.11  PostgreSQL 16
db2  172.31.120.12  PostgreSQL 16
```

兩台節點使用不同 Docker daemon。

```text
db1 client port  127.0.0.1:35432
db2 client port  127.0.0.1:45432
```

複寫模式：

```text
PostgreSQL streaming replication
primary + standby
manual promotion
manual rejoin with pg_basebackup
```

## 啟動

```bash
make manual-up
```

首次啟動結果：

```text
db1  primary
db2  standby
```

查看狀態：

```bash
make manual-status
```

輸出包含：

```text
節點角色
複寫位址
客戶端 port
pg_stat_replication
replication lag bytes
```

## 連線

憑證：

```text
postgres / postgres
app / apppass
replicator / replicator
appdb
```

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

查詢角色：

```sql
SELECT inet_server_addr(), pg_is_in_recovery();
```

回傳值：

```text
false  primary
true   standby
```

## 計畫內切換

確認目前角色：

```bash
make manual-status
```

從 db1 切到 db2：

```bash
make manual-switch FROM=db1 TO=db2
```

此命令依序執行：

```text
CHECKPOINT
db1 PostgreSQL stop
db2 pg_ctl promote
```

應用程式改連：

```text
127.0.0.1:45432
```

將 db1 重新建立為 standby：

```bash
make manual-rejoin NODE=db1
```

此命令清除 db1 舊資料目錄，從 db2 執行 `pg_basebackup -R`，再啟動 db1。

切回 db1：

```bash
make manual-switch FROM=db2 TO=db1
make manual-rejoin NODE=db2
```

## 主機不可用時的切換

假設 db1 是 primary，停止整個模擬主機：

```bash
limactl shell fabric-clab -- \
  sudo docker stop clab-pgsql-manual-db1
```

提升 db2：

```bash
make manual-promote NODE=db2
```

應用程式改連：

```text
127.0.0.1:45432
```

恢復 db1 外層主機：

```bash
limactl shell fabric-clab -- \
  sudo docker start clab-pgsql-manual-db1
```

重新建立 db1：

```bash
make manual-rejoin NODE=db1
```

最終角色：

```text
db1  standby
db2  primary
```

## 自動執行實驗驗收

```bash
make manual-test
```

驗收內容：

```text
建立 db1 primary
由 db1 建立 db2 standby
寫入 primary
從 standby 查詢資料
停止整個 primary 主機
提升 standby
故障後寫入
重啟舊主機
由新 primary 重建舊主機
確認一主一備與資料完整
```

單獨執行：

```bash
make manual-smoke
make manual-failover
```

## 停止與清理

停止兩個模擬主機並保留資料：

```bash
make manual-down
```

重新啟動：

```bash
make manual-up
```

刪除實驗資料：

```bash
make manual-clean
```

資料目錄：

```text
/var/lib/pgsql-ha-manual/db1-postgresql
/var/lib/pgsql-ha-manual/db2-postgresql
/var/lib/pgsql-ha-manual/db1-docker
/var/lib/pgsql-ha-manual/db2-docker
```
