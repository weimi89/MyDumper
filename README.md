# MyDumper 資料庫備份工具

使用 MyDumper 進行 MySQL/MariaDB 資料庫的每日自動備份。

## 功能特點

- 支援單一或多組資料庫批次備份
- 自動偵測 CPU 核心數優化執行緒
- 按資料庫分類的目錄結構
- 自動清理過期備份
- 備份壓縮節省空間
- 詳細進度顯示與日誌記錄
- 支援 crontab 排程

## 目錄結構

```
MyDumper/
├── dump.sh                # 主備份腳本
├── restore.sh             # 還原腳本
├── setup.sh               # 排程設定腳本
├── backup.conf.example    # 基本設定檔範例
├── databases.ini.example  # 資料庫清單範例（多組備份用）
├── backup.conf            # 你的設定檔（不納入版控）
├── databases.ini          # 你的資料庫清單（不納入版控）
├── .gitignore             # Git 忽略設定
├── logs/                  # 日誌目錄
└── README.md
```

## 安裝步驟

### 1. 安裝 MyDumper

```bash
# Ubuntu/Debian
apt-get install mydumper

# CentOS/RHEL
yum install mydumper

# macOS
brew install mydumper
```

### 2. 複製腳本到主機

```bash
scp -r MyDumper root@你的主機:/root/
```

### 3. 設定 MySQL 權限

建議建立專用的備份帳號：

```sql
-- 登入 MySQL
mysql -u root -p
```

#### 建立備份專用帳號（推薦）

```sql
-- 1. 刪除可能存在的舊用戶（避免衝突）
DROP USER IF EXISTS 'backup'@'%';
DROP USER IF EXISTS 'backup'@'localhost';

-- 2. 建立新用戶
--    本機備份使用 'localhost'
--    遠端備份使用 '%'（任意 IP）或 '192.168.1.%'（限定網段）
CREATE USER 'backup'@'%' IDENTIFIED BY '你的安全密碼';

-- 3. 授予備份所需權限（可備份所有資料庫）
GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, RELOAD, PROCESS, BINLOG MONITOR
ON *.* TO 'backup'@'%';

-- 4. 套用權限
FLUSH PRIVILEGES;

-- 5. 確認用戶建立成功
SELECT user, host FROM mysql.user WHERE user = 'backup';
SHOW GRANTS FOR 'backup'@'%';
```

#### 只備份特定資料庫

```sql
-- 授權特定資料庫
GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES ON 資料庫名.* TO 'backup'@'%';
GRANT RELOAD, PROCESS ON *.* TO 'backup'@'%';  -- 這兩個必須是全域權限
FLUSH PRIVILEGES;
```

#### 測試連線

```bash
# 本機測試
mysql -u backup -p -e "SELECT 1"

# 遠端測試
mysql -u backup -p -h 192.168.1.100 -e "SELECT 1"

# 測試 mydumper
mydumper -h 192.168.1.100 -u backup -p '密碼' -B 資料庫名 --no-data -v 3
```

**權限說明**：
| 權限 | 用途 | 必要性 |
|------|------|--------|
| SELECT | 讀取資料 | 必要 |
| SHOW VIEW | 備份視圖 | 必要 |
| TRIGGER | 備份觸發器 | 必要 |
| LOCK TABLES | 鎖定表確保一致性 | 必要 |
| RELOAD | 執行 FLUSH TABLES | 建議 |
| PROCESS | 查看執行中的查詢 | 建議 |
| BINLOG MONITOR | 取得二進制日誌位置 | 選用（避免警告）|

> **注意**：如果遠端備份出現 `Access denied for user 'backup'@'xxx.xxx.xxx.xxx'`，
> 請確認沒有其他同名用戶（如 `backup@localhost`）造成優先級衝突。
> 執行 `SELECT user, host FROM mysql.user WHERE user = 'backup';` 檢查。

### 4. 複製並編輯設定檔

```bash
cd /root/MyDumper

# 複製設定檔範例
cp backup.conf.example backup.conf
cp databases.ini.example databases.ini

# 編輯基本設定
vim backup.conf
```

#### 基本設定 `backup.conf`

```bash
# 資料庫連線（單一備份模式使用）
DB_HOST="localhost"
DB_PORT="3306"
DB_USER="root"
DB_PASS="你的密碼"
DB_NAME="資料庫名稱"      # 留空則備份全部

# 備份路徑
BACKUP_DIR="/root/backups"
RETENTION_DAYS=7          # 保留天數（0=不刪除）

# MyDumper 設定
THREADS=0                 # 0=自動偵測
COMPRESS=1                # 1=啟用壓縮
```

#### 多組資料庫 `databases.ini`

```ini
# 每個資料庫使用 [database_X] 區塊定義
# 密碼包含特殊字符請用雙引號包裹

[database_1]
host = localhost
port = 3306
user = root
pass = "password123"
name = website_db1

[database_2]
host = localhost
port = 3306
user = root
pass = "my:password:with:colons"    # 密碼可以包含冒號
name = website_db2

[database_3]
host = 192.168.1.100
port = 3306
user = backup_user
pass = secret
name = shop_db
```

**支援的 key 名稱**：
| Key | 別名 | 說明 |
|-----|------|------|
| host | - | 資料庫主機 |
| port | - | 連接埠（預設 3306）|
| user | - | 用戶名 |
| pass | password | 密碼（支援特殊字符）|
| name | database, dbname | 資料庫名稱 |

## 使用方式

### 手動執行備份

```bash
cd /root/MyDumper
./dump.sh
```

### 設定每日排程

```bash
./setup.sh
```

執行後會顯示排程設定指引，支援多種環境：

#### Hestia / cPanel 等控制面板

1. 登入控制面板後台
2. 進入 **Cron Jobs** → **Add Cron Job**
3. 填入腳本顯示的設定值

#### 手動設定 crontab

```bash
# 編輯 crontab
crontab -e

# 加入排程（每天凌晨 2 點執行）
0 2 * * * /root/MyDumper/dump.sh >> /root/MyDumper/logs/cron.log 2>&1
```

> **注意**：`setup.sh` 不會自動修改 crontab，避免影響控制面板的排程管理。

### 查看備份結果

```bash
# 備份檔案
ls -la /root/backups/database/

# 今日日誌
cat /root/MyDumper/logs/dump_$(date +%Y%m%d).log
```

## 還原備份

### 互動式還原

```bash
./restore.sh
```

執行流程：
```
==========================================
  MyLoader 資料庫還原工具
==========================================

可用的資料庫備份：

  1) website_db1 (7 個備份, 最新: 20251215)
  2) website_db2 (3 個備份, 最新: 20251215)

請選擇要還原的資料庫 [1-2]: 1

資料庫 [website_db1] 的可用備份：

  1) 20251215 (大小: 1.2G, 檔案: 156)
  2) 20251214 (大小: 1.1G, 檔案: 156)

請選擇要還原的備份 [1-2]: 1

MySQL 主機 [localhost]:
MySQL 端口 [3306]:
MySQL 用戶 [root]:
MySQL 密碼: ****
還原到資料庫名稱 [website_db1]: website_db1_restored

警告：還原將覆蓋目標資料庫中的現有資料！
是否要先清空目標資料庫？ [y/N]: y

確定要執行還原嗎？ [y/N]: y

>>> 正在還原 (執行中，請稍候...)
...

==========================================
  還原成功！
==========================================
  耗時: 3分45秒
  目標: website_db1_restored@localhost:3306
==========================================
```

### 還原到不同資料庫

可以將備份還原到不同名稱的資料庫：
- 來源備份：`website_db1`
- 還原目標：`website_db1_test` 或 `website_db1_20251215`

這適用於：
- 測試環境還原
- 資料遷移
- 建立開發環境副本

## 備份目錄結構

```
/root/backups/
└── database/
    ├── website_db1/
    │   ├── 20251213/
    │   ├── 20251214/
    │   └── 20251215/
    ├── website_db2/
    │   └── 20251215/
    └── shop_db/
        └── 20251215/
```

## 執行輸出範例

```
==========================================
  批次備份模式 - 共 2 個資料庫
==========================================

----------------------------------------
[1/2] website_db1
----------------------------------------
>>> 連線 root@localhost:3306 ...
>>> 正在備份 website_db1 (執行中，請稍候...)
** Message: Thread 1 dumping data for `website_db1`.`users`
** Message: Thread 2 dumping data for `website_db1`.`orders`
** Message: Finished dump at: 2025-12-15 14:31:56
✓ website_db1 完成 (2分15秒, 1.2G)

----------------------------------------
[2/2] website_db2
----------------------------------------
>>> 連線 root@localhost:3306 ...
>>> 正在備份 website_db2 (執行中，請稍候...)
...
✓ website_db2 完成 (0分45秒, 256M)

==========================================
  備份完成
==========================================
  總計: 2
  成功: 2
==========================================
```

## Git 版本控制

本專案使用 `.gitignore` 排除敏感設定檔，確保密碼等資訊不會被提交：

**會被追蹤的檔案：**
- `dump.sh`、`restore.sh`、`setup.sh`（腳本）
- `backup.conf.example`、`databases.ini.example`（範例設定）
- `README.md`

**不會被追蹤的檔案：**
- `backup.conf`、`databases.ini`（包含密碼的設定檔）
- `backups/`（備份資料）
- `logs/`（日誌）

```bash
# 更新專案時，你的設定檔不會被覆蓋
git pull origin main
```

## 常見問題

### Q: myloader 還原時出現 "Section [config] was not found on metadata file"

**原因**：備份端的 mydumper 版本與還原端的 myloader 版本不相容。

| 位置 | 版本 | metadata 格式 |
|------|------|---------------|
| 舊版 mydumper (< 0.12) | 0.10.x | 純文字格式 |
| 新版 myloader (> 0.14) | 0.21.x | INI 格式 ([config] section) |

**解決方案**：升級備份端的 mydumper 版本

```bash
# Ubuntu 24.04 LTS
wget https://github.com/mydumper/mydumper/releases/download/v0.21.1-1/mydumper_0.21.1-1.noble_amd64.deb
sudo dpkg -i mydumper_0.21.1-1.noble_amd64.deb

# Ubuntu 22.04 LTS
wget https://github.com/mydumper/mydumper/releases/download/v0.21.1-1/mydumper_0.21.1-1.jammy_amd64.deb
sudo dpkg -i mydumper_0.21.1-1.jammy_amd64.deb

# 驗證版本
mydumper --version
```

**版本下載**：https://github.com/mydumper/mydumper/releases

---

### Q: 備份時出現 "Couldn't get master position" 警告

**訊息**：
```
WARNING: Couldn't get master position - ERROR 1227: Access denied;
you need (at least one of) the BINLOG MONITOR privilege(s) for this operation
```

**原因**：備份用戶缺少 BINLOG MONITOR 權限，無法記錄複製位置。

**影響**：這只是警告，**不影響備份功能**。只有在需要設定主從複製時才需要此資訊。

**解決**（可選）：
```sql
GRANT BINLOG MONITOR ON *.* TO '用戶名'@'localhost';
FLUSH PRIVILEGES;
```

---

### Q: 備份時出現 "tokudb_version not found"

**訊息**：
```
Message: @@tokudb_version not found - ERROR 1193: Unknown system variable 'tokudb_version'
```

**原因**：TokuDB 是已停止維護的儲存引擎，新版 mydumper 會檢查它是否存在。

**影響**：**完全無影響**，可以忽略此訊息。

---

### Q: 出現 "Access denied; you need the RELOAD privilege"

**原因**：備份用戶缺少 RELOAD 權限

**解決**：
```sql
GRANT RELOAD ON *.* TO '用戶名'@'localhost';
FLUSH PRIVILEGES;
```

### Q: 出現 "mydumper: command not found"

**原因**：mydumper 未安裝或不在 PATH 中

**解決**：
```bash
# 找到 mydumper 位置
find /usr -name "mydumper" 2>/dev/null

# 在 backup.conf 中設定路徑
MYDUMPER_BIN="/usr/local/bin/mydumper"
```

### Q: 備份資料夾是空的

**原因**：通常是連線或權限問題

**解決**：
1. 檢查日誌 `cat logs/dump_$(date +%Y%m%d).log`
2. 手動測試連線 `mydumper -h localhost -u 用戶 -p密碼 -B 資料庫 -o /tmp/test -v 3`

### Q: 如何還原備份？

**方法 1：使用互動式還原腳本（推薦）**
```bash
./restore.sh
```

會引導你選擇：
1. 要還原的資料庫
2. 要還原的備份日期
3. 目標連線資訊
4. 是否清空現有資料

**方法 2：直接使用 myloader**
```bash
myloader -h localhost -u root -p'密碼' -B 資料庫名 -d /root/backups/database/資料庫名/20251215/ -o -v 3
```

## 授權

MIT License
